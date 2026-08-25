#!/usr/bin/env python3
"""
plot_api.py
===========
Live plot-generation API for the NOAA reanalysis website.

Instead of only serving pre-rendered PNGs from Supabase, this service lets
the frontend send ANY (lat, lon) for a time series, or ANY bounding box for
a spatial map, and returns a freshly rendered PNG -- generated from the
full aggregated NetCDF files the pipeline already produces.

It does not duplicate the plotting logic: it imports load_data / plot_spatial
/ plot_timeseries / plot_hovmoller / VAR_META directly from the noaa_plot.py
that noaa_pipeline.sh writes into $OUTDIR, so the live API and the batch
pipeline always render identically.

Requires:
    pip install fastapi uvicorn[standard]
    (plus everything noaa_plot.py needs: xarray, matplotlib, cartopy, ...)

Run:
    export NOAA_OUTDIR=/path/to/NOAA        # same OUTDIR the pipeline used
    uvicorn plot_api:app --host 0.0.0.0 --port 8000

Then point the frontend's API_BASE at wherever this is reachable
(behind a reverse proxy with HTTPS in production).
"""

import glob
import hashlib
import importlib.util
import os
import re
import sys
import types
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
OUTDIR = os.environ.get("NOAA_OUTDIR", os.path.join(os.getcwd(), "NOAA"))
AGG_ROOT = os.path.join(OUTDIR, "aggregated")
NOAA_PLOT_PY = os.path.join(OUTDIR, "noaa_plot.py")
CACHE_DIR = os.path.join(OUTDIR, "live_cache")
# Comma-separated list of allowed frontend origins, e.g.
#   ALLOWED_ORIGINS="https://your-site.com,https://www.your-site.com"
ALLOWED_ORIGINS = os.environ.get("ALLOWED_ORIGINS", "*").split(",")

os.makedirs(CACHE_DIR, exist_ok=True)

if not os.path.isfile(NOAA_PLOT_PY):
    print(f"[FATAL] {NOAA_PLOT_PY} not found. Run noaa_pipeline.sh at least "
          f"once (any --var) so noaa_plot.py exists in $OUTDIR, or set "
          f"NOAA_OUTDIR to the correct directory.")
    sys.exit(1)

# ── Import noaa_plot.py as a module (reuse, don't duplicate) ────────────────
spec = importlib.util.spec_from_file_location("noaa_plot", NOAA_PLOT_PY)
noaa_plot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(noaa_plot)

app = FastAPI(title="NOAA Live Plot API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


# ─────────────────────────────────────────────────────────────────────────────
# Locating aggregated NetCDF files produced by the pipeline
# ─────────────────────────────────────────────────────────────────────────────
def find_aggregated_file(var: str, level: str, aggr: str) -> str:
    """
    Aggregated files are named:
        {AGG_ROOT}/{var}/{var}_{level}hPa_{aggr}_{start_year}_{end_year}.nc
    start/end vary run to run (especially with --start all --end all), so
    glob for it and pick the one covering the widest year range.
    """
    pattern = os.path.join(AGG_ROOT, var, f"{var}_{level}hPa_{aggr}_*_*.nc")
    matches = glob.glob(pattern)
    if not matches:
        raise HTTPException(
            status_code=404,
            detail=(f"No aggregated file for var={var}, level={level}, aggr={aggr}. "
                    f"Run the pipeline for this combination first (see run_all_variables.sh)."),
        )

    def year_span(path: str) -> int:
        m = re.search(r"_(\d{4})_(\d{4})\.nc$", path)
        if not m:
            return 0
        return int(m.group(2)) - int(m.group(1))

    return max(matches, key=year_span)


def list_available_combos() -> list:
    """Scan AGG_ROOT for every var/level/aggr combination currently on disk."""
    combos = []
    if not os.path.isdir(AGG_ROOT):
        return combos
    for var in sorted(os.listdir(AGG_ROOT)):
        var_dir = os.path.join(AGG_ROOT, var)
        if not os.path.isdir(var_dir):
            continue
        for fname in sorted(os.listdir(var_dir)):
            m = re.match(rf"^{re.escape(var)}_(\d+)hPa_([a-zA-Z]+)_(\d{{4}})_(\d{{4}})\.nc$", fname)
            if m:
                level, aggr, start, end = m.groups()
                combos.append({
                    "var": var, "level": level, "aggr": aggr,
                    "start_year": int(start), "end_year": int(end),
                })
    return combos


# ─────────────────────────────────────────────────────────────────────────────
# Request schemas
# ─────────────────────────────────────────────────────────────────────────────
class TimeseriesRequest(BaseModel):
    var: str
    level: str = "850"
    aggr: str = "daily"
    lat: float
    lon: float
    start: str | None = Field(default=None, description="YYYY-MM-DD")
    end: str | None = Field(default=None, description="YYYY-MM-DD")
    include_hovmoller: bool = False


class SpatialRequest(BaseModel):
    var: str
    level: str = "850"
    aggr: str = "monthly"
    lat_min: float
    lat_max: float
    lon_min: float
    lon_max: float
    start: str | None = Field(default=None, description="YYYY-MM-DD")
    end: str | None = Field(default=None, description="YYYY-MM-DD")


# ─────────────────────────────────────────────────────────────────────────────
# Caching -- identical requests reuse the same rendered PNG on disk
# ─────────────────────────────────────────────────────────────────────────────
def cache_path(prefix: str, payload: BaseModel) -> str:
    key = hashlib.sha256(payload.model_dump_json().encode()).hexdigest()[:24]
    return os.path.join(CACHE_DIR, f"{prefix}_{key}.png")


def make_args(**overrides) -> types.SimpleNamespace:
    """Build the argparse.Namespace-shaped object noaa_plot.py's functions expect."""
    defaults = dict(
        nc=None, var="shum", lat=20.0, lon=80.0,
        lat_min=None, lat_max=None, lon_min=None, lon_max=None,
        plot_type="both", aggr="daily", outdir=CACHE_DIR, level="850",
        colormap=None, start=None, end=None, show=False,
        format="png", dpi=140,
    )
    defaults.update(overrides)
    return types.SimpleNamespace(**defaults)


# ─────────────────────────────────────────────────────────────────────────────
# Endpoints
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/api/health")
def health():
    return {"status": "ok", "outdir": OUTDIR}


@app.get("/api/meta")
def meta():
    """
    What the frontend needs to constrain the UI: which var/level/aggr
    combinations actually have data ready, so the map/coordinate picker
    doesn't let someone request something that doesn't exist yet.
    """
    return {"combos": list_available_combos()}


@app.post("/api/timeseries")
def timeseries(req: TimeseriesRequest):
    cpath = cache_path("ts", req)
    if os.path.isfile(cpath):
        return FileResponse(cpath, media_type="image/png")

    nc_path = find_aggregated_file(req.var, req.level, req.aggr)
    meta_info = noaa_plot.VAR_META.get(req.var, {
        "long_name": req.var.upper(), "units": "", "cmap": "viridis", "cmap_anom": "RdBu_r"
    })

    try:
        result = noaa_plot.load_data(
            nc_path, req.var, req.lat, req.lon, req.start, req.end, domain=None
        )
        args = make_args(
            nc=nc_path, var=req.var, level=req.level, aggr=req.aggr,
            lat=req.lat, lon=req.lon, start=req.start, end=req.end,
            plot_type="timeseries",
        )
        fpath = noaa_plot.plot_timeseries(
            result["ts"], result["var_name"], args, meta_info,
            result["actual_lat"], result["actual_lon"],
        )
        if fpath is None:
            raise HTTPException(status_code=422, detail="No valid data at that point/date range.")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Plot generation failed: {e}")

    os.replace(fpath, cpath)  # normalize to the cache key filename
    return FileResponse(cpath, media_type="image/png")


@app.post("/api/spatial")
def spatial(req: SpatialRequest):
    if req.lat_min >= req.lat_max or req.lon_min >= req.lon_max:
        raise HTTPException(status_code=422, detail="lat_min/lon_min must be less than lat_max/lon_max.")

    cpath = cache_path("sp", req)
    if os.path.isfile(cpath):
        return FileResponse(cpath, media_type="image/png")

    nc_path = find_aggregated_file(req.var, req.level, req.aggr)
    meta_info = noaa_plot.VAR_META.get(req.var, {
        "long_name": req.var.upper(), "units": "", "cmap": "viridis", "cmap_anom": "RdBu_r"
    })
    domain = {
        "lat_min": req.lat_min, "lat_max": req.lat_max,
        "lon_min": req.lon_min, "lon_max": req.lon_max,
    }
    center_lat = (req.lat_min + req.lat_max) / 2
    center_lon = (req.lon_min + req.lon_max) / 2

    try:
        result = noaa_plot.load_data(
            nc_path, req.var, center_lat, center_lon, req.start, req.end, domain=domain
        )
        args = make_args(
            nc=nc_path, var=req.var, level=req.level, aggr=req.aggr,
            lat=center_lat, lon=center_lon, start=req.start, end=req.end,
            plot_type="spatial",
        )
        fpath = noaa_plot.plot_spatial(
            result["spatial"], result["var_name"], args, meta_info,
            result["actual_lat"], result["actual_lon"], domain=result["domain"],
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Plot generation failed: {e}")

    os.replace(fpath, cpath)
    return FileResponse(cpath, media_type="image/png")

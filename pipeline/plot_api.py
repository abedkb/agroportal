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
import shutil
import sys
import tempfile
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
# NOTE: default is "*" for local development only. Set this explicitly to
# your real portal domain(s) before deploying -- an open CORS + unauthenticated,
# CPU-heavy render endpoint is an easy target for load-based abuse.
ALLOWED_ORIGINS = os.environ.get("ALLOWED_ORIGINS", "*").split(",")

# Tanzania + immediate neighbors -- keeps the live API scoped to what this
# portal is actually for, matching the default domain crop noaa_pipeline.sh
# now uses for its own generated maps. Requests outside this box are
# rejected rather than silently rendering some unrelated part of the globe
# (both to keep the site's purpose clear, and because this endpoint is
# otherwise unauthenticated -- an unrestricted region is an easy target for
# someone using your compute to render maps that have nothing to do with
# Tanzania).
REGION_BOUNDS = {
    "lat_min": -12.5, "lat_max": 1.5,
    "lon_min": 28.5, "lon_max": 41.5,
}


def require_point_in_region(lat: float, lon: float) -> None:
    if not (REGION_BOUNDS["lat_min"] <= lat <= REGION_BOUNDS["lat_max"]
            and REGION_BOUNDS["lon_min"] <= lon <= REGION_BOUNDS["lon_max"]):
        raise HTTPException(
            status_code=422,
            detail=(f"({lat}, {lon}) is outside the supported region "
                    f"(lat {REGION_BOUNDS['lat_min']} to {REGION_BOUNDS['lat_max']}, "
                    f"lon {REGION_BOUNDS['lon_min']} to {REGION_BOUNDS['lon_max']})."),
        )


def require_domain_in_region(lat_min: float, lat_max: float, lon_min: float, lon_max: float) -> None:
    if not (lat_min >= REGION_BOUNDS["lat_min"] and lat_max <= REGION_BOUNDS["lat_max"]
            and lon_min >= REGION_BOUNDS["lon_min"] and lon_max <= REGION_BOUNDS["lon_max"]):
        raise HTTPException(
            status_code=422,
            detail=(f"Requested box is outside the supported region "
                    f"(lat {REGION_BOUNDS['lat_min']} to {REGION_BOUNDS['lat_max']}, "
                    f"lon {REGION_BOUNDS['lon_min']} to {REGION_BOUNDS['lon_max']})."),
        )


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
def _year_span(path: str) -> tuple:
    """Extract (start_year, end_year) from a filename like
    .../shum_850hPa_monthly_1948_2024.nc -- returns (0, 0) if unparseable."""
    m = re.search(r"_(\d{4})_(\d{4})\.nc$", path)
    if not m:
        return (0, 0)
    return (int(m.group(1)), int(m.group(2)))


def find_aggregated_file(var: str, level: str, aggr: str,
                          start: str | None = None, end: str | None = None) -> str:
    """
    Aggregated files are named:
        {AGG_ROOT}/{var}/{var}_{level}hPa_{aggr}_{start_year}_{end_year}.nc
    start/end vary run to run (especially with --start all --end all), and
    it's possible to have more than one file for the same var/level/aggr
    covering different year ranges (e.g. an older 1948-2000 run alongside a
    newer 2001-2024 extension). Prefer whichever file's range actually
    *covers* the requested start/end dates; only fall back to "widest
    overall span" when no file covers the request (or none was given) --
    picking by widest span alone can silently return a file that doesn't
    even contain the requested dates.
    """
    pattern = os.path.join(AGG_ROOT, var, f"{var}_{level}hPa_{aggr}_*_*.nc")
    matches = glob.glob(pattern)
    if not matches:
        raise HTTPException(
            status_code=404,
            detail=(f"No aggregated file for var={var}, level={level}, aggr={aggr}. "
                    f"Run the pipeline for this combination first (see run_all_variables.sh)."),
        )

    req_start_year = int(start[:4]) if start else None
    req_end_year = int(end[:4]) if end else None

    if req_start_year is not None or req_end_year is not None:
        covering = [
            p for p in matches
            if (req_start_year is None or _year_span(p)[0] <= req_start_year)
            and (req_end_year is None or _year_span(p)[1] >= req_end_year)
        ]
        if covering:
            matches = covering

    return max(matches, key=lambda p: _year_span(p)[1] - _year_span(p)[0])


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
            m = re.match(rf"^{re.escape(var)}_([a-zA-Z0-9]+)hPa_([a-zA-Z]+)_(\d{{4}})_(\d{{4}})\.nc$", fname)
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


class HovmollerRequest(BaseModel):
    var: str
    level: str = "850"
    aggr: str = "daily"
    lat: float
    lon: float
    start: str | None = Field(default=None, description="YYYY-MM-DD")
    end: str | None = Field(default=None, description="YYYY-MM-DD")


# ─────────────────────────────────────────────────────────────────────────────
# Caching -- identical requests reuse the same rendered PNG on disk
# ─────────────────────────────────────────────────────────────────────────────
def cache_path(prefix: str, payload: BaseModel) -> str:
    key = hashlib.sha256(payload.model_dump_json().encode()).hexdigest()[:24]
    return os.path.join(CACHE_DIR, f"{prefix}_{key}.png")


def render_to_cache(cpath: str, render_fn) -> None:
    """
    Run render_fn(tmp_dir) -> generated_file_path inside an isolated,
    per-request temp directory, then atomically move the single result into
    the shared cache path.

    This matters because FastAPI runs sync `def` routes in a thread pool, so
    two requests genuinely can render concurrently. noaa_plot.py's plotting
    functions build output filenames from var/level/aggr/lat/lon (rounded),
    so two different users hitting close-but-different coordinates at the
    same moment could otherwise collide on the same filename inside the
    shared CACHE_DIR -- one request's rename can grab the other's
    half-written or already-renamed file, occasionally serving the WRONG
    plot to someone. Rendering into a private temp dir first makes that
    collision impossible.
    """
    tmp_dir = tempfile.mkdtemp(dir=CACHE_DIR)
    try:
        fpath = render_fn(tmp_dir)
        shutil.move(fpath, cpath)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


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


def get_var_meta(var: str) -> dict:
    return noaa_plot.VAR_META.get(var, {
        "long_name": var.upper(), "units": "", "cmap": "viridis", "cmap_anom": "RdBu_r"
    })


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
    doesn't let someone request something that doesn't exist yet. Also
    returns the supported region so the map picker can be bounded to it
    client-side too, not just enforced server-side.
    """
    return {"combos": list_available_combos(), "region": REGION_BOUNDS}


@app.post("/api/timeseries")
def timeseries(req: TimeseriesRequest):
    require_point_in_region(req.lat, req.lon)
    cpath = cache_path("ts", req)
    if os.path.isfile(cpath):
        return FileResponse(cpath, media_type="image/png")

    nc_path = find_aggregated_file(req.var, req.level, req.aggr, req.start, req.end)
    meta_info = get_var_meta(req.var)

    def render(tmp_dir):
        result = noaa_plot.load_data(
            nc_path, req.var, req.lat, req.lon, req.start, req.end, domain=None
        )
        args = make_args(
            nc=nc_path, var=req.var, level=req.level, aggr=req.aggr,
            lat=req.lat, lon=req.lon, start=req.start, end=req.end,
            plot_type="timeseries", outdir=tmp_dir,
        )
        fpath = noaa_plot.plot_timeseries(
            result["ts"], result["var_name"], args, meta_info,
            result["actual_lat"], result["actual_lon"],
        )
        if fpath is None:
            raise HTTPException(status_code=422, detail="No valid data at that point/date range.")
        return fpath

    try:
        render_to_cache(cpath, render)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Plot generation failed: {e}")

    return FileResponse(cpath, media_type="image/png")


@app.post("/api/spatial")
def spatial(req: SpatialRequest):
    if req.lat_min >= req.lat_max or req.lon_min >= req.lon_max:
        raise HTTPException(status_code=422, detail="lat_min/lon_min must be less than lat_max/lon_max.")
    require_domain_in_region(req.lat_min, req.lat_max, req.lon_min, req.lon_max)

    cpath = cache_path("sp", req)
    if os.path.isfile(cpath):
        return FileResponse(cpath, media_type="image/png")

    nc_path = find_aggregated_file(req.var, req.level, req.aggr, req.start, req.end)
    meta_info = get_var_meta(req.var)
    domain = {
        "lat_min": req.lat_min, "lat_max": req.lat_max,
        "lon_min": req.lon_min, "lon_max": req.lon_max,
    }
    center_lat = (req.lat_min + req.lat_max) / 2
    center_lon = (req.lon_min + req.lon_max) / 2

    def render(tmp_dir):
        result = noaa_plot.load_data(
            nc_path, req.var, center_lat, center_lon, req.start, req.end, domain=domain
        )
        args = make_args(
            nc=nc_path, var=req.var, level=req.level, aggr=req.aggr,
            lat=center_lat, lon=center_lon, start=req.start, end=req.end,
            plot_type="spatial", outdir=tmp_dir,
        )
        return noaa_plot.plot_spatial(
            result["spatial"], result["var_name"], args, meta_info,
            result["actual_lat"], result["actual_lon"], domain=result["domain"],
        )

    try:
        render_to_cache(cpath, render)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Plot generation failed: {e}")

    return FileResponse(cpath, media_type="image/png")


@app.post("/api/hovmoller")
def hovmoller(req: HovmollerRequest):
    """
    Longitude-time Hovmoller diagram for a latitude band centered on
    req.lat (see noaa_plot.plot_hovmoller -- it averages over lat +/- 2.5
    degrees). This was previously an `include_hovmoller` flag on the
    timeseries request that nothing ever read; split out into its own
    endpoint since a single PNG response can only carry one plot anyway.
    """
    require_point_in_region(req.lat, req.lon)
    cpath = cache_path("hv", req)
    if os.path.isfile(cpath):
        return FileResponse(cpath, media_type="image/png")

    nc_path = find_aggregated_file(req.var, req.level, req.aggr, req.start, req.end)
    meta_info = get_var_meta(req.var)

    def render(tmp_dir):
        result = noaa_plot.load_data(
            nc_path, req.var, req.lat, req.lon, req.start, req.end, domain=None
        )
        args = make_args(
            nc=nc_path, var=req.var, level=req.level, aggr=req.aggr,
            lat=req.lat, lon=req.lon, start=req.start, end=req.end,
            plot_type="timeseries", outdir=tmp_dir,
        )
        return noaa_plot.plot_hovmoller(
            result["da"], result["var_name"], args, meta_info,
            result["actual_lat"], result["actual_lon"],
        )

    try:
        render_to_cache(cpath, render)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Plot generation failed: {e}")

    return FileResponse(cpath, media_type="image/png")

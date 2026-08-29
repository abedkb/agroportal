#!/usr/bin/env python3
"""
agro_pipeline.py
=================
Unified Python tooling for the TMA AgroMet website's data pipeline.

DELIBERATELY SERVER-FREE. This combines three one-shot CLI subcommands --
period aggregation, static plot generation, and Supabase upload -- each of
which starts, does its work, and exits. Nothing here listens for requests
or stays running. That's a deliberate choice, not an oversight: the only
part of the wider system that genuinely needs an always-on server is Live
Explorer (arbitrary user-picked points/regions rendered on demand), and
that's intentionally NOT part of this file. See the project notes for why:
in short, a batch pipeline you run on a schedule (cron, GitHub Actions)
never needs to "listen" for anything, so it never needs a server, an open
port, a firewall rule, or a security story around any of that.

If Live Explorer is wanted later, that's a separate, additional piece
(a small FastAPI service) layered on TOP of this -- this file does not
need to change to support that; the two are independent.

Subcommands
-----------
    period-aggregate   Calendar-aligned dekad (10-day) / pentad (5-day)
                        aggregation. CDO has no operator for this that
                        respects calendar-month boundaries.
    plot                One-shot static plot generation (spatial map +
                        time series + Hovmoller) from an aggregated NetCDF.
    upload              Upload rendered PNGs to Supabase Storage and
                        upsert their metadata into noaa_products.

Tanzania-specific defaults (carried forward from noaa_pipeline.sh, NOT
present in the four-in-one merged script this replaces):
    - Sample point defaults to Dodoma (-6.1630, 35.7516), not South Asia
    - Spatial maps crop to Tanzania + neighbors by default
      (--lat-min -12.5 --lat-max 1.5 --lon-min 28.5 --lon-max 41.5)
    - Time series/Hovmoller average across Tanzania's actual extent by
      default (--area-average, tighter box than the map-display one
      above so neighboring countries' grid cells don't dilute it),
      rather than a single arbitrary point -- pass --point to opt out

Usage examples
--------------
    python3 agro_pipeline.py period-aggregate \
        --nc input.nc --var precip --period dekad --stat sum --out output.nc

    python3 agro_pipeline.py plot \
        --nc input.nc --var shum --level 850 --aggr monthly \
        --area-average --avg-lat-min -11.8 --avg-lat-max -0.9 \
        --avg-lon-min 29.3 --avg-lon-max 40.9 \
        --lat-min -12.5 --lat-max 1.5 --lon-min 28.5 --lon-max 41.5 \
        --outdir ./plots

    python3 agro_pipeline.py upload \
        --plots-dir ./NOAA/plots/shum --var shum --level 850 \
        --start-year 1948 --end-year 2026 --prefix shum/
"""

from __future__ import annotations

import argparse
import mimetypes
import os
import re
import sys
import warnings

warnings.filterwarnings("ignore")

# Shared with the upload step -- must match the bucket/table your Supabase
# project actually has (see the project's SQL setup).
BUCKET = "noaa-plots"
TABLE = "noaa_products"


# =============================================================================
# 1. Period aggregation
# =============================================================================
def dekad_index(day: int) -> int:
    """1, 2, or 3 -- days 1-10, 11-20, 21-end of month."""
    if day <= 10:
        return 1
    if day <= 20:
        return 2
    return 3


def pentad_index(day: int) -> int:
    """1..6 -- days 1-5, 6-10, 11-15, 16-20, 21-25, 26-end of month
    (the 6th group absorbs the trailing 3-6 days depending on month
    length, rather than creating a short 7th group)."""
    return min((day - 1) // 5 + 1, 6)


def run_period_aggregate(args: argparse.Namespace) -> int:
    import numpy as np
    import pandas as pd
    import xarray as xr

    ds = xr.open_dataset(args.nc)
    if args.var not in ds:
        print(f"[ERROR] Variable '{args.var}' not found in {args.nc}. "
              f"Available: {list(ds.data_vars)}", file=sys.stderr)
        return 1

    da = ds[args.var]

    time_vals = da["time"].values
    if np.issubdtype(time_vals.dtype, np.datetime64):
        pt = pd.DatetimeIndex(time_vals)
        years, months, days = pt.year.values, pt.month.values, pt.day.values
    else:
        cft = xr.CFTimeIndex(time_vals)
        years = np.array([t.year for t in cft])
        months = np.array([t.month for t in cft])
        days = np.array([t.day for t in cft])

    idx_fn = dekad_index if args.period == "dekad" else pentad_index
    period_idx = np.array([idx_fn(int(d)) for d in days])

    group_key = years.astype(np.int64) * 10000 + months.astype(np.int64) * 100 + period_idx
    da = da.assign_coords(_group=("time", group_key))

    if args.stat == "sum":
        out = da.groupby("_group").sum(dim="time", skipna=True)
    else:
        out = da.groupby("_group").mean(dim="time", skipna=True)

    resolved_keys = out["_group"].values
    rep_times = []
    for g in resolved_keys:
        g = int(g)
        yy, rem = divmod(g, 10000)
        mm, pidx = divmod(rem, 100)
        first_day = {1: 1, 2: 11, 3: 21}[pidx] if args.period == "dekad" else (pidx - 1) * 5 + 1
        rep_times.append(np.datetime64(f"{yy:04d}-{mm:02d}-{first_day:02d}"))

    out = out.assign_coords(_group=np.array(rep_times)).rename({"_group": "time"})
    out = out.sortby("time")
    out.attrs = da.attrs

    out.to_dataset(name=args.var).to_netcdf(args.out)
    print(f"[OK] {args.period} {args.stat} -> {args.out} ({out.sizes['time']} periods)")
    return 0


# =============================================================================
# 2. Plotting engine (spatial map / time series / Hovmoller)
# =============================================================================
VAR_META = {
    "shum":         {"long_name": "Specific Humidity",          "units": "kg/kg",   "cmap": "YlGnBu",   "cmap_anom": "BrBG"},
    "uwnd":         {"long_name": "U-Wind (Zonal)",             "units": "m/s",     "cmap": "RdBu_r",   "cmap_anom": "RdBu_r"},
    "vwnd":         {"long_name": "V-Wind (Meridional)",        "units": "m/s",     "cmap": "RdBu_r",   "cmap_anom": "RdBu_r"},
    "air":          {"long_name": "Air Temperature",            "units": "K",       "cmap": "RdYlBu_r", "cmap_anom": "RdBu_r"},
    "omega":        {"long_name": "Vertical Velocity",          "units": "Pa/s",    "cmap": "RdBu",     "cmap_anom": "RdBu"},
    "hgt":          {"long_name": "Geopotential Height",        "units": "m",       "cmap": "viridis",  "cmap_anom": "RdBu_r"},
    "rhum":         {"long_name": "Relative Humidity",          "units": "%",       "cmap": "YlGnBu",   "cmap_anom": "BrBG"},
    "prate":        {"long_name": "Precipitation Rate",         "units": "kg/m2/s", "cmap": "Blues",    "cmap_anom": "BrBG"},
    "slp":          {"long_name": "Sea Level Pressure",         "units": "Pa",      "cmap": "RdYlBu_r", "cmap_anom": "RdBu_r"},
    "pres.sfc":     {"long_name": "Surface Pressure",           "units": "Pa",      "cmap": "RdYlBu_r", "cmap_anom": "RdBu_r"},
    "pr_wtr.eatm":  {"long_name": "Precipitable Water",         "units": "kg/m2",   "cmap": "YlGnBu",   "cmap_anom": "BrBG"},
    "air.sig995":   {"long_name": "Surface Air Temperature",    "units": "K",       "cmap": "RdYlBu_r", "cmap_anom": "RdBu_r"},
    "uwnd.sig995":  {"long_name": "Surface U-Wind",             "units": "m/s",     "cmap": "RdBu_r",   "cmap_anom": "RdBu_r"},
    "vwnd.sig995":  {"long_name": "Surface V-Wind",             "units": "m/s",     "cmap": "RdBu_r",   "cmap_anom": "RdBu_r"},
    "rhum.sig995":  {"long_name": "Surface Relative Humidity",  "units": "%",       "cmap": "YlGnBu",   "cmap_anom": "BrBG"},
    "omega.sig995": {"long_name": "Surface Vertical Velocity",  "units": "Pa/s",    "cmap": "RdBu",     "cmap_anom": "RdBu"},
    "precip":       {"long_name": "CHIRPS Rainfall",            "units": "mm",      "cmap": "Blues",    "cmap_anom": "BrBG"},
}


def load_data(nc_path: str, var_name: str, lat: float, lon: float,
              start: str | None = None, end: str | None = None,
              domain: dict | None = None,
              area_average: bool = False, avg_domain: dict | None = None) -> dict:
    """Load and subset NetCDF data.

    domain, if given, crops the grid before the spatial mean is taken --
    used for spatial maps (typically wider, includes neighboring countries
    for visual context).

    area_average, if True, builds "ts" by averaging over avg_domain at
    every time step instead of extracting the nearest point to (lat, lon)
    -- what makes a "Tanzania" time series actually represent the whole
    country rather than one arbitrary location. avg_domain is deliberately
    a SEPARATE, tighter box than domain -- averaging in the wider
    map-display box would pull in neighboring countries' grid cells.
    """
    import numpy as np
    import xarray as xr

    print(f"[INFO] Loading: {nc_path}")
    ds = xr.open_dataset(nc_path, decode_times=True)

    if var_name not in ds:
        candidates = [v for v in ds.data_vars if var_name.lower() in v.lower()]
        if not candidates:
            raise ValueError(f"Variable '{var_name}' not found. Available: {list(ds.data_vars)}")
        var_name = candidates[0]
        print(f"[INFO] Using variable: {var_name}")

    da = ds[var_name]

    if "level" in da.dims and da.sizes["level"] == 1:
        da = da.squeeze("level")
    elif "level" in da.dims:
        print("[WARN] Multiple levels found. Taking level index 0.")
        da = da.isel(level=0)

    rename_map = {}
    for d in da.dims:
        if d.lower() in ("latitude", "lat"):
            rename_map[d] = "lat"
        elif d.lower() in ("longitude", "lon"):
            rename_map[d] = "lon"
        elif d.lower() in ("time", "t"):
            rename_map[d] = "time"
    if rename_map:
        da = da.rename(rename_map)

    if "lon" in da.coords and da.lon.max() > 180:
        da = da.assign_coords(lon=(da.lon + 180) % 360 - 180)
        da = da.sortby("lon")

    if "lat" in da.coords and da.lat.values[0] > da.lat.values[-1]:
        da = da.sortby("lat")

    if domain:
        da = da.sel(
            lat=slice(domain["lat_min"], domain["lat_max"]),
            lon=slice(domain["lon_min"], domain["lon_max"]),
        )
        if da.sizes.get("lat", 0) == 0 or da.sizes.get("lon", 0) == 0:
            raise ValueError(f"Domain crop produced an empty grid: {domain}")

    if start or end:
        da = da.sel(time=slice(start, end))

    print(f"[INFO] Data shape: {dict(da.sizes)}")
    print(f"[INFO] Time range: {str(da.time.values[0])[:10]} to {str(da.time.values[-1])[:10]}")
    print(f"[INFO] Lat range : {float(da.lat.min()):.2f} to {float(da.lat.max()):.2f}")
    print(f"[INFO] Lon range : {float(da.lon.min()):.2f} to {float(da.lon.max()):.2f}")

    if area_average:
        if not avg_domain:
            raise ValueError("area_average=True requires avg_domain "
                              "(avg-lat-min/max, avg-lon-min/max).")
        avg_da = da.sel(
            lat=slice(avg_domain["lat_min"], avg_domain["lat_max"]),
            lon=slice(avg_domain["lon_min"], avg_domain["lon_max"]),
        )
        if avg_da.sizes.get("lat", 0) == 0 or avg_da.sizes.get("lon", 0) == 0:
            raise ValueError(f"Area-average domain produced an empty grid: {avg_domain}")
        ts = avg_da.mean(dim=["lat", "lon"], skipna=True)
        actual_lat = (avg_domain["lat_min"] + avg_domain["lat_max"]) / 2
        actual_lon = (avg_domain["lon_min"] + avg_domain["lon_max"]) / 2
        n_cells = avg_da.sizes.get("lat", 0) * avg_da.sizes.get("lon", 0)
        print(f"[INFO] Area-averaging over {n_cells} grid cell(s) "
              f"(lat {avg_domain['lat_min']} to {avg_domain['lat_max']}, "
              f"lon {avg_domain['lon_min']} to {avg_domain['lon_max']})")
    else:
        ts = da.sel(lat=lat, lon=lon, method="nearest")
        actual_lat = float(ts.lat.values)
        actual_lon = float(ts.lon.values)
        print(f"[INFO] Nearest grid point: lat={actual_lat:.2f}, lon={actual_lon:.2f}")

    spatial_mean = da.mean(dim="time")

    return {
        "da": da, "ts": ts, "spatial": spatial_mean, "var_name": var_name,
        "actual_lat": actual_lat, "actual_lon": actual_lon, "domain": domain,
        "area_average": area_average, "avg_domain": avg_domain,
    }


def plot_spatial(da_spatial, var_name: str, args, meta: dict,
                 actual_lat: float, actual_lon: float, domain: dict | None = None,
                 area_average: bool = False, avg_domain: dict | None = None) -> str:
    """Spatial map. Draws the area-average region as an outlined box (what
    the accompanying time series/Hovmoller represent) instead of a single
    star marker, when area_average is set."""
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import TwoSlopeNorm

    try:
        import cartopy.crs as ccrs
        import cartopy.feature as cfeature
        HAS_CARTOPY = True
    except ImportError:
        HAS_CARTOPY = False
        print("[WARN] cartopy not available -- plotting without map features")

    cmap = args.colormap or meta.get("cmap", "viridis")
    data = da_spatial.values
    lats = da_spatial.lat.values
    lons = da_spatial.lon.values

    is_anomaly = "anomaly" in args.aggr.lower() or "anom" in str(args.nc).lower()
    if is_anomaly:
        cmap = args.colormap or meta.get("cmap_anom", "RdBu_r")
        vmax = np.nanpercentile(np.abs(data), 98)
        norm = TwoSlopeNorm(vcenter=0, vmin=-vmax, vmax=vmax)
    else:
        vmin = np.nanpercentile(data, 2)
        vmax = np.nanpercentile(data, 98)
        norm = None

    fig_title = f"{meta.get('long_name', var_name)} | {args.level} hPa | {args.aggr.title()} Mean"

    if HAS_CARTOPY:
        proj = ccrs.PlateCarree()
        fig, ax = plt.subplots(figsize=(14, 7), subplot_kw={"projection": proj}, facecolor="#0f0f1a")
        ax.set_facecolor("#0f0f1a")

        if is_anomaly:
            cf = ax.contourf(lons, lats, data, levels=21, cmap=cmap, norm=norm, transform=proj)
        else:
            cf = ax.contourf(lons, lats, data, levels=21, cmap=cmap, vmin=vmin, vmax=vmax, transform=proj)
        ax.contour(lons, lats, data, levels=10, colors="white", linewidths=0.4, alpha=0.4, transform=proj)

        ax.add_feature(cfeature.COASTLINE, linewidth=0.8, edgecolor="#aaaacc")
        ax.add_feature(cfeature.BORDERS, linewidth=0.4, edgecolor="#888899", linestyle="--")
        ax.add_feature(cfeature.LAND, facecolor="none", edgecolor="none")
        ax.add_feature(cfeature.OCEAN, facecolor="#0a0a15", alpha=0.3)
        ax.gridlines(draw_labels=True, linewidth=0.4, color="gray", alpha=0.5, linestyle="--",
                     xlocs=range(-180, 181, 30), ylocs=range(-90, 91, 30))

        if area_average and avg_domain:
            box_lons = [avg_domain["lon_min"], avg_domain["lon_max"], avg_domain["lon_max"],
                        avg_domain["lon_min"], avg_domain["lon_min"]]
            box_lats = [avg_domain["lat_min"], avg_domain["lat_min"], avg_domain["lat_max"],
                        avg_domain["lat_max"], avg_domain["lat_min"]]
            ax.plot(box_lons, box_lats, color="#ff6b6b", linewidth=1.8, transform=proj,
                    zorder=10, label="Tanzania average region")
        else:
            ax.plot(actual_lon, actual_lat, marker="*", color="#ff6b6b", markersize=14,
                    transform=proj, zorder=10, label=f"Selected: {actual_lat:.1f}N, {actual_lon:.1f}E")
        ax.legend(loc="lower left", fontsize=9, facecolor="#1a1a2e", edgecolor="#444466", labelcolor="white")

        if domain:
            ax.set_extent([domain["lon_min"], domain["lon_max"], domain["lat_min"], domain["lat_max"]], crs=proj)
        else:
            ax.set_global()
    else:
        fig, ax = plt.subplots(figsize=(14, 7), facecolor="#0f0f1a")
        ax.set_facecolor("#0f0f1a")
        lons2d, lats2d = np.meshgrid(lons, lats)
        if is_anomaly:
            cf = ax.pcolormesh(lons2d, lats2d, data, cmap=cmap, norm=norm, shading="auto")
        else:
            cf = ax.pcolormesh(lons2d, lats2d, data, cmap=cmap, vmin=vmin, vmax=vmax, shading="auto")
        if area_average and avg_domain:
            box_lons = [avg_domain["lon_min"], avg_domain["lon_max"], avg_domain["lon_max"],
                        avg_domain["lon_min"], avg_domain["lon_min"]]
            box_lats = [avg_domain["lat_min"], avg_domain["lat_min"], avg_domain["lat_max"],
                        avg_domain["lat_max"], avg_domain["lat_min"]]
            ax.plot(box_lons, box_lats, color="red", linewidth=1.8, label="Tanzania average region")
        else:
            ax.plot(actual_lon, actual_lat, "r*", markersize=14, label=f"Selected: {actual_lat:.1f}N, {actual_lon:.1f}E")
        ax.set_xlabel("Longitude", color="white")
        ax.set_ylabel("Latitude", color="white")
        ax.tick_params(colors="white")
        ax.spines[:].set_color("#444466")
        ax.legend(fontsize=9, facecolor="#1a1a2e", edgecolor="#444466", labelcolor="white")

    cbar = plt.colorbar(cf, ax=ax, orientation="horizontal", pad=0.04, fraction=0.03, aspect=50)
    cbar.set_label(f"{meta.get('long_name', var_name)} ({meta.get('units', '')})", color="white", fontsize=11)
    cbar.ax.tick_params(colors="white", labelsize=8)
    cbar.outline.set_edgecolor("#444466")

    ax.set_title(fig_title, color="white", fontsize=14, fontweight="bold", pad=12)
    fig.patch.set_facecolor("#0f0f1a")

    os.makedirs(args.outdir, exist_ok=True)
    if domain:
        fname = (f"{var_name}_{args.level}hPa_{args.aggr}_spatial_"
                  f"{domain['lat_min']:.1f}_{domain['lat_max']:.1f}_"
                  f"{domain['lon_min']:.1f}_{domain['lon_max']:.1f}.{args.format}")
    else:
        fname = f"{var_name}_{args.level}hPa_{args.aggr}_spatial.{args.format}"
    fpath = os.path.join(args.outdir, fname)
    plt.savefig(fpath, dpi=args.dpi, bbox_inches="tight", facecolor="#0f0f1a", edgecolor="none")
    print(f"[OK] Saved spatial map -> {fpath}")
    plt.close(fig)
    return fpath


def plot_timeseries(ts, var_name: str, args, meta: dict, actual_lat: float, actual_lon: float) -> str | None:
    import numpy as np
    import pandas as pd
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from scipy import stats as scipy_stats

    times = pd.to_datetime(ts.time.values)
    values = ts.values.astype(float)
    mask = ~np.isnan(values)
    times, values = times[mask], values[mask]
    if len(values) == 0:
        print("[ERROR] No valid data at selected point.")
        return None

    win_map = {"daily": 30, "monthly": 12, "seasonal": 4, "annual": 5,
               "pentad": 10, "climatology": 30, "anomaly": 30}
    win = win_map.get(args.aggr.lower(), 12)
    ts_series = pd.Series(values, index=times)
    rolling_mean = ts_series.rolling(window=win, center=True, min_periods=1).mean()

    x_num = np.arange(len(values), dtype=float)
    slope, intercept, r_val, p_val, std_err = scipy_stats.linregress(x_num, values)
    trend = slope * x_num + intercept

    display_values = values.copy()
    display_label = meta.get("units", "")
    if var_name == "shum":
        display_values = values * 1000
        display_label = "g/kg"
    rolling_display = rolling_mean.values.copy()
    trend_display = trend.copy()
    if var_name == "shum":
        rolling_display *= 1000
        trend_display *= 1000

    fig, axes = plt.subplots(2, 1, figsize=(14, 9), gridspec_kw={"height_ratios": [3, 1]}, facecolor="#0f0f1a")
    ax_main, ax_bar = axes

    is_anomaly = "anomaly" in args.aggr.lower()
    if is_anomaly:
        ax_main.axhline(0, color="#888899", linewidth=0.8, linestyle="--", alpha=0.6)

    ax_main.set_facecolor("#0f0f1a")
    ax_main.fill_between(times, display_values, alpha=0.25, color="#3a7bd5", linewidth=0)
    ax_main.plot(times, display_values, color="#3a7bd5", linewidth=0.7, alpha=0.6, label="Observed")
    ax_main.plot(times, rolling_display, color="#f0c040", linewidth=2.0, label=f"{win}-step Rolling Mean")
    ax_main.plot(times, trend_display, color="#ff6b6b", linewidth=1.5, linestyle="--",
                 label=f"Trend: {slope * (365 if args.aggr=='daily' else 1):.4g}/yr  (p={p_val:.3f})")

    loc_label = "Tanzania-wide average" if getattr(args, "area_average", False) \
        else f"({actual_lat:.2f}N, {actual_lon:.2f}E)"
    ax_main.set_title(f"{meta.get('long_name', var_name)} | {args.level} hPa | {loc_label} | {args.aggr.title()}",
                       color="white", fontsize=13, fontweight="bold", pad=10)
    ax_main.set_ylabel(f"{meta.get('long_name', var_name)} ({display_label})", color="white", fontsize=11)
    ax_main.tick_params(colors="white", labelsize=9)
    ax_main.spines[:].set_color("#2a2a3e")
    ax_main.spines["bottom"].set_color("#444466")
    ax_main.spines["left"].set_color("#444466")
    ax_main.legend(fontsize=9, facecolor="#1a1a2e", edgecolor="#444466", labelcolor="white")
    ax_main.grid(axis="y", color="#2a2a3e", linewidth=0.5, linestyle=":")

    ax_bar.set_facecolor("#0d0d1a")
    annual_ts = ts_series.resample("YE").mean()
    if var_name == "shum":
        annual_ts = annual_ts * 1000
    bar_c = ["#ff6b6b" if v >= annual_ts.mean() else "#6bb5ff" for v in annual_ts.values]
    ax_bar.bar(annual_ts.index.year, annual_ts.values, color=bar_c, width=0.7, alpha=0.85, edgecolor="none")
    ax_bar.axhline(annual_ts.mean(), color="#f0c040", linewidth=1.2, linestyle="--", alpha=0.7, label="Annual mean")
    ax_bar.set_ylabel("Annual\nMean", color="white", fontsize=8)
    ax_bar.tick_params(colors="white", labelsize=8)
    ax_bar.spines[:].set_color("#2a2a3e")
    ax_bar.spines["bottom"].set_color("#444466")
    ax_bar.spines["left"].set_color("#444466")
    ax_bar.grid(axis="y", color="#2a2a3e", linewidth=0.4, linestyle=":")
    ax_bar.legend(fontsize=8, facecolor="#1a1a2e", edgecolor="#444466", labelcolor="white")

    plt.tight_layout(rect=[0, 0, 1, 1], h_pad=0.5)

    os.makedirs(args.outdir, exist_ok=True)
    loc_tag = "tanzania_avg" if getattr(args, "area_average", False) else f"{actual_lat:.1f}N_{actual_lon:.1f}E"
    fname = f"{var_name}_{args.level}hPa_{args.aggr}_timeseries_{loc_tag}.{args.format}"
    fpath = os.path.join(args.outdir, fname)
    plt.savefig(fpath, dpi=args.dpi, bbox_inches="tight", facecolor="#0f0f1a", edgecolor="none")
    print(f"[OK] Saved time series -> {fpath}")
    plt.close(fig)
    return fpath


def plot_hovmoller(da, var_name: str, args, meta: dict, actual_lat: float, actual_lon: float,
                   avg_domain: dict | None = None) -> str:
    """In area-average mode, the latitude band averaged over is Tanzania's
    actual extent (avg_domain), not an arbitrary +/-2.5 degrees around one
    point -- so the diagram represents the whole country's longitude
    structure over time, not just a slice near one location."""
    import numpy as np
    import pandas as pd
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    cmap = args.colormap or meta.get("cmap", "RdBu_r")

    if getattr(args, "area_average", False) and avg_domain:
        lat_band = da.sel(lat=slice(avg_domain["lat_min"], avg_domain["lat_max"])).mean(dim="lat")
        band_label = "Tanzania-wide"
    else:
        lat_band = da.sel(lat=slice(actual_lat - 2.5, actual_lat + 2.5)).mean(dim="lat")
        band_label = f"~{actual_lat:.1f}"

    data = lat_band.values.astype(float)
    if var_name == "shum":
        data *= 1000
    times = pd.to_datetime(lat_band.time.values)
    lons = lat_band.lon.values

    fig, ax = plt.subplots(figsize=(14, 8), facecolor="#0f0f1a")
    ax.set_facecolor("#0d0d1a")

    vmin = np.nanpercentile(data, 2)
    vmax = np.nanpercentile(data, 98)
    cf = ax.contourf(lons, np.arange(len(times)), data, levels=21, cmap=cmap, vmin=vmin, vmax=vmax)
    ax.contour(lons, np.arange(len(times)), data, levels=10, colors="white", linewidths=0.3, alpha=0.3)

    n_ticks = min(12, len(times))
    tick_idx = np.linspace(0, len(times) - 1, n_ticks, dtype=int)
    ax.set_yticks(tick_idx)
    ax.set_yticklabels([str(times[i])[:10] for i in tick_idx], color="white", fontsize=8)
    ax.set_xlabel("Longitude", color="white", fontsize=11)
    ax.set_ylabel("Time", color="white", fontsize=11)
    ax.tick_params(colors="white", labelsize=9)
    ax.spines[:].set_color("#444466")

    cbar = plt.colorbar(cf, ax=ax, orientation="vertical", pad=0.02, fraction=0.025)
    cbar.set_label(f"{meta.get('long_name', var_name)} ({meta.get('units', '')})", color="white", fontsize=10)
    cbar.ax.tick_params(colors="white", labelsize=8)
    cbar.outline.set_edgecolor("#444466")

    ax.set_title(f"Hovmoller (Lon-Time) | {meta.get('long_name', var_name)} | "
                 f"Lat band {band_label} | {args.level} hPa", color="white", fontsize=13, fontweight="bold", pad=10)

    os.makedirs(args.outdir, exist_ok=True)
    loc_tag = "tanzania_avg" if getattr(args, "area_average", False) else f"{actual_lat:.1f}N"
    fname = f"{var_name}_{args.level}hPa_{args.aggr}_hovmoller_{loc_tag}.{args.format}"
    fpath = os.path.join(args.outdir, fname)
    plt.savefig(fpath, dpi=args.dpi, bbox_inches="tight", facecolor="#0f0f1a", edgecolor="none")
    print(f"[OK] Saved Hovmoller -> {fpath}")
    plt.close(fig)
    return fpath


def run_plot(args: argparse.Namespace) -> int:
    if not os.path.isfile(args.nc):
        print(f"[ERROR] File not found: {args.nc}")
        return 1

    meta = VAR_META.get(args.var, {
        "long_name": args.var.upper(), "units": "", "cmap": "viridis", "cmap_anom": "RdBu_r",
    })

    domain = None
    if None not in (args.lat_min, args.lat_max, args.lon_min, args.lon_max):
        domain = {"lat_min": args.lat_min, "lat_max": args.lat_max,
                  "lon_min": args.lon_min, "lon_max": args.lon_max}

    avg_domain = None
    if args.area_average:
        if None in (args.avg_lat_min, args.avg_lat_max, args.avg_lon_min, args.avg_lon_max):
            print("[ERROR] --area-average requires --avg-lat-min/--avg-lat-max/"
                  "--avg-lon-min/--avg-lon-max")
            return 1
        avg_domain = {"lat_min": args.avg_lat_min, "lat_max": args.avg_lat_max,
                      "lon_min": args.avg_lon_min, "lon_max": args.avg_lon_max}

    result = load_data(args.nc, args.var, args.lat, args.lon, args.start, args.end,
                       domain=domain, area_average=args.area_average, avg_domain=avg_domain)

    plots_saved = []

    if args.plot_type in ("spatial", "both"):
        p = plot_spatial(result["spatial"], result["var_name"], args, meta,
                         result["actual_lat"], result["actual_lon"], domain=result["domain"],
                         area_average=args.area_average, avg_domain=avg_domain)
        plots_saved.append(p)

    if args.plot_type in ("timeseries", "both"):
        p = plot_timeseries(result["ts"], result["var_name"], args, meta,
                            result["actual_lat"], result["actual_lon"])
        if p:
            plots_saved.append(p)

    if args.plot_type in ("timeseries", "both"):
        try:
            p = plot_hovmoller(result["da"], result["var_name"], args, meta,
                               result["actual_lat"], result["actual_lon"], avg_domain=avg_domain)
            plots_saved.append(p)
        except Exception as e:
            print(f"[WARN] Hovmoller skipped: {e}")

    print(f"\n[OK] Done! {len(plots_saved)} plot(s) saved to: {args.outdir}")
    for p in plots_saved:
        print(f"     -> {p}")
    return 0


# =============================================================================
# 3. Supabase upload -- matches the project's actual schema (bucket
#    "noaa-plots", table noaa_products with file_path as the unique key).
#    Plain HTTP via `requests` -- no supabase-py dependency needed.
# =============================================================================
FNAME_RE_TEMPLATE = (
    r"^{var}_{level}hPa_(?P<aggr>[a-zA-Z]+)_(?P<plot_type>spatial|timeseries|hovmoller)"
)


def supabase_headers(service_key: str, extra: dict | None = None) -> dict:
    h = {"apikey": service_key, "Authorization": f"Bearer {service_key}"}
    if extra:
        h.update(extra)
    return h


def upload_file(base_url: str, service_key: str, bucket: str, object_path: str, local_path: str) -> str:
    import requests

    content_type = mimetypes.guess_type(local_path)[0] or "application/octet-stream"
    url = f"{base_url}/storage/v1/object/{bucket}/{object_path}"
    with open(local_path, "rb") as f:
        data = f.read()
    resp = requests.post(
        url,
        headers=supabase_headers(service_key, {"Content-Type": content_type, "x-upsert": "true"}),
        data=data, timeout=60,
    )
    if resp.status_code not in (200, 201):
        raise RuntimeError(f"Upload failed for {object_path}: {resp.status_code} {resp.text}")
    return f"{base_url}/storage/v1/object/public/{bucket}/{object_path}"


def upsert_row(base_url: str, service_key: str, row: dict) -> None:
    import requests

    # file_path is the table's real unique constraint -- see the project's
    # SQL setup. A var+level+aggr+... combination has no unique constraint,
    # so using it as on_conflict would be rejected by PostgREST.
    url = f"{base_url}/rest/v1/{TABLE}?on_conflict=file_path"
    resp = requests.post(
        url,
        headers=supabase_headers(service_key, {"Content-Type": "application/json",
                                                "Prefer": "resolution=merge-duplicates,return=minimal"}),
        json=[row], timeout=30,
    )
    if resp.status_code not in (200, 201, 204):
        raise RuntimeError(f"Metadata upsert failed: {resp.status_code} {resp.text}")


def run_upload(args: argparse.Namespace) -> int:
    base_url = os.environ.get("SUPABASE_URL")
    service_key = os.environ.get("SUPABASE_SERVICE_KEY")
    if not base_url or not service_key:
        print("[ERROR] SUPABASE_URL / SUPABASE_SERVICE_KEY not set.", file=sys.stderr)
        return 1
    base_url = base_url.rstrip("/")

    if not os.path.isdir(args.plots_dir):
        print(f"[ERROR] Plots directory not found: {args.plots_dir}", file=sys.stderr)
        return 1

    fname_re = re.compile(FNAME_RE_TEMPLATE.format(var=re.escape(args.var), level=re.escape(str(args.level))))

    try:
        level_hpa = int(float(args.level))
    except ValueError:
        level_hpa = None  # surface variables (e.g. "sfc") have no numeric pressure level

    uploaded = skipped = failed = 0

    for fname in sorted(os.listdir(args.plots_dir)):
        local_path = os.path.join(args.plots_dir, fname)
        if not os.path.isfile(local_path):
            continue

        m = fname_re.match(fname)
        if not m:
            print(f"[SKIP] Doesn't match expected naming pattern: {fname}")
            skipped += 1
            continue

        aggr = m.group("aggr")
        plot_type = m.group("plot_type")
        object_path = f"{args.prefix}{fname}"
        file_size = os.path.getsize(local_path)

        print(f"[INFO] Uploading {fname} -> {BUCKET}/{object_path}")
        try:
            public_url = upload_file(base_url, service_key, BUCKET, object_path, local_path)
        except Exception as e:
            print(f"[ERROR] {e}", file=sys.stderr)
            failed += 1
            continue

        row = {
            "var": args.var, "level_label": str(args.level), "level_hpa": level_hpa,
            "aggr": aggr, "plot_type": plot_type,
            "start_year": int(args.start_year), "end_year": int(args.end_year),
            "file_path": object_path, "public_url": public_url, "file_size": file_size,
        }
        try:
            upsert_row(base_url, service_key, row)
        except Exception as e:
            print(f"[ERROR] {e}", file=sys.stderr)
            failed += 1
            continue

        print(f"[OK] {fname} -> {public_url}")
        uploaded += 1

    print(f"\n[SUMMARY] Uploaded: {uploaded}, Skipped: {skipped}, Failed: {failed}")
    if uploaded == 0 and failed > 0:
        return 1
    return 0


# =============================================================================
# Argument parsing
# =============================================================================
def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Server-free Agromet data tooling: period aggregation, "
                    "static plotting, and Supabase upload. No subcommand here "
                    "ever runs longer than one invocation."
    )
    sub = parser.add_subparsers(dest="cmd", required=True, metavar="SUBCOMMAND")

    p_agg = sub.add_parser("period-aggregate", help="Calendar-aligned dekad/pentad aggregation")
    p_agg.add_argument("--nc", required=True)
    p_agg.add_argument("--var", required=True)
    p_agg.add_argument("--period", required=True, choices=["dekad", "pentad"])
    p_agg.add_argument("--stat", required=True, choices=["sum", "mean"],
                        help="sum for accumulative quantities (rainfall); mean for state variables")
    p_agg.add_argument("--out", required=True)

    p_plot = sub.add_parser("plot", help="One-shot static plots from an aggregated NetCDF")
    p_plot.add_argument("--nc", required=True)
    p_plot.add_argument("--var", default="shum")
    p_plot.add_argument("--lat", type=float, default=-6.1630, help="Only used in --point mode (default: Dodoma)")
    p_plot.add_argument("--lon", type=float, default=35.7516, help="Only used in --point mode (default: Dodoma)")
    p_plot.add_argument("--lat-min", type=float, default=None)
    p_plot.add_argument("--lat-max", type=float, default=None)
    p_plot.add_argument("--lon-min", type=float, default=None)
    p_plot.add_argument("--lon-max", type=float, default=None)
    p_plot.add_argument("--area-average", action="store_true")
    p_plot.add_argument("--avg-lat-min", type=float, default=None)
    p_plot.add_argument("--avg-lat-max", type=float, default=None)
    p_plot.add_argument("--avg-lon-min", type=float, default=None)
    p_plot.add_argument("--avg-lon-max", type=float, default=None)
    p_plot.add_argument("--plot-type", default="both", choices=["spatial", "timeseries", "both"])
    p_plot.add_argument("--aggr", default="daily")
    p_plot.add_argument("--outdir", default="./plots")
    p_plot.add_argument("--level", default="850")
    p_plot.add_argument("--colormap", default=None)
    p_plot.add_argument("--start", default=None)
    p_plot.add_argument("--end", default=None)
    p_plot.add_argument("--format", default="png", choices=["png", "pdf", "svg"])
    p_plot.add_argument("--dpi", type=int, default=150)

    p_up = sub.add_parser("upload", help="Upload plot PNGs to Supabase Storage + metadata table")
    p_up.add_argument("--plots-dir", required=True)
    p_up.add_argument("--var", required=True)
    p_up.add_argument("--level", required=True)
    p_up.add_argument("--start-year", required=True)
    p_up.add_argument("--end-year", required=True)
    p_up.add_argument("--prefix", default="")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.cmd == "period-aggregate":
        return run_period_aggregate(args)
    if args.cmd == "plot":
        return run_plot(args)
    if args.cmd == "upload":
        return run_upload(args)
    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())

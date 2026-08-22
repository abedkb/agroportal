#!/bin/bash
# =============================================================================
# NOAA NCEP Reanalysis Downloader, Aggregator & Python Visualization Launcher
# =============================================================================
# Usage:
#   bash noaa_pipeline.sh [OPTIONS]
#
# Options:
#   --var       Variable to download (default: shum)
#               Options: shum | uwnd | vwnd | air | omega | hgt
#   --level     Pressure level in hPa (default: 850)
#               e.g.: 1000 925 850 700 600 500 400 300 250 200 150 100 50 10
#   --start     Start year (default: 1981)
#   --end       End year  (default: 2022)
#   --aggr      Aggregation(s), comma-separated (default: daily,monthly,seasonal,annual)
#               Options: daily | monthly | seasonal | annual
#   --plot      Launch Python plot after processing (default: true)
#   --lat       Latitude  for time series (default: 20.0)
#   --lon       Longitude for time series (default: 80.0)
#   --plot-type Plot type: spatial | timeseries | both (default: both)
#   --outdir    Output directory (default: current directory ./noaa_data)
#   --help      Show this help message
#
# Dependencies:
#   - wget or curl
#   - CDO (Climate Data Operators)
#   - NCO (ncrcat, ncks) -- optional but recommended
#   - Python 3 with: xarray, matplotlib, cartopy, numpy, pandas, scipy
#
# Examples:
#   bash noaa_pipeline.sh --var shum --level 850 --start 1981 --end 2022 --lat 20 --lon 80
#   bash noaa_pipeline.sh --var uwnd --level 500 --aggr monthly,seasonal --plot-type spatial
#   bash noaa_pipeline.sh --var air  --level 850 --start 2000 --end 2022 --plot-type timeseries
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Default Configuration
# ─────────────────────────────────────────────────────────────────────────────
VAR="shum"
LEVEL="850"
START_YEAR=1981
END_YEAR=2022
AGGREGATIONS="daily,monthly,seasonal,annual"
LAUNCH_PLOT=true
USER_LAT=20.0
USER_LON=80.0
PLOT_TYPE="both"
#OUTDIR="/mnt/d/Research_papers/paper10/Analysis/sample/mainpy/epd_network_data/global_monsoon/NOAA"
OUTDIR="$(pwd)/NOAA"

# NOAA PSL Base URLs (NCEP Reanalysis I Daily Pressure Level Data)
BASE_URL_DAILY="https://downloads.psl.noaa.gov/Datasets/ncep.reanalysis/Dailies/pressure"
BASE_URL_SURFACE="https://downloads.psl.noaa.gov/Datasets/ncep.reanalysis/Dailies/surface"

# ─────────────────────────────────────────────────────────────────────────────
# Color codes for terminal output
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}>>> $* ${NC}\n"; }

# ─────────────────────────────────────────────────────────────────────────────
# Parse Arguments
# ─────────────────────────────────────────────────────────────────────────────
show_help() {
    sed -n '4,35p' "$0" | sed 's/^# //; s/^#//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --var)        VAR="$2";          shift 2 ;;
        --level)      LEVEL="$2";        shift 2 ;;
        --start)      START_YEAR="$2";   shift 2 ;;
        --end)        END_YEAR="$2";     shift 2 ;;
        --aggr)       AGGREGATIONS="$2"; shift 2 ;;
        --plot)       LAUNCH_PLOT="$2";  shift 2 ;;
        --lat)        USER_LAT="$2";     shift 2 ;;
        --lon)        USER_LON="$2";     shift 2 ;;
        --plot-type)  PLOT_TYPE="$2";    shift 2 ;;
        --outdir)     OUTDIR="$2";       shift 2 ;;
        --help|-h)    show_help ;;
        *)  log_error "Unknown option: $1"; show_help ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Validate Variable Name & Determine URL Type
# ─────────────────────────────────────────────────────────────────────────────
SURFACE_VARS=("prate" "pr_wtr" "slp" "skt")
PRESSURE_VARS=("shum" "uwnd" "vwnd" "air" "omega" "hgt" "rhum")

is_surface_var() {
    local v="$1"
    for sv in "${SURFACE_VARS[@]}"; do
        [[ "$sv" == "$v" ]] && return 0
    done
    return 1
}

if is_surface_var "$VAR"; then
    BASE_URL="$BASE_URL_SURFACE"
    IS_PRESSURE_LEVEL=false
else
    BASE_URL="$BASE_URL_DAILY"
    IS_PRESSURE_LEVEL=true
fi

# ─────────────────────────────────────────────────────────────────────────────
# Directory Structure
# ─────────────────────────────────────────────────────────────────────────────
RAW_DIR="${OUTDIR}/raw/${VAR}"
AGG_DIR="${OUTDIR}/aggregated/${VAR}"
PLOT_DIR="${OUTDIR}/plots/${VAR}"
LOG_DIR="${OUTDIR}/logs"
PYTHON_SCRIPT="${OUTDIR}/noaa_plot.py"

mkdir -p "$RAW_DIR" "$AGG_DIR" "$PLOT_DIR" "$LOG_DIR"

MERGED_FILE="${AGG_DIR}/${VAR}_daily_${START_YEAR}_${END_YEAR}.nc"
LOG_FILE="${LOG_DIR}/pipeline_${VAR}_$(date +%Y%m%d_%H%M%S).log"

# Tee all output to log
exec > >(tee -a "$LOG_FILE") 2>&1

# ─────────────────────────────────────────────────────────────────────────────
# Dependency Checks
# ─────────────────────────────────────────────────────────────────────────────
log_section "Checking Dependencies"

check_dep() {
    if command -v "$1" &>/dev/null; then
        log_success "$1 found: $(command -v $1)"
    else
        log_error "$1 not found. Please install it."
        [[ "$2" == "required" ]] && exit 1
    fi
}

check_dep wget    required
check_dep cdo     required
check_dep python3 required
check_dep ncrcat  optional
check_dep ncks    optional

# Check Python packages
python3 -c "import xarray, matplotlib, numpy, pandas" 2>/dev/null \
    && log_success "Core Python packages found" \
    || { log_error "Missing Python packages. Run: pip install xarray matplotlib numpy pandas scipy cartopy"; exit 1; }

python3 -c "import cartopy" 2>/dev/null \
    && log_success "cartopy found" \
    || log_warn "cartopy not found -- spatial maps will be skipped. Install: pip install cartopy"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Download Raw Daily Files
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 1: Downloading ${VAR} Daily Data (${START_YEAR}-${END_YEAR})"

DOWNLOAD_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
FAILED_YEARS=()

for YEAR in $(seq "$START_YEAR" "$END_YEAR"); do
    URL="${BASE_URL}/${VAR}.${YEAR}.nc"
    OUTFILE="${RAW_DIR}/${VAR}.${YEAR}.nc"

    if [[ -f "$OUTFILE" ]]; then
        # Verify the file is not empty/corrupt
        if cdo -s info "$OUTFILE" &>/dev/null; then
            log_info "Skipping ${YEAR} -- file exists and is valid."
            (( SKIP_COUNT++ )) || true
            continue
        else
            log_warn "${YEAR} file exists but appears corrupt. Re-downloading..."
            rm -f "$OUTFILE"
        fi
    fi

    log_info "Downloading ${VAR} for ${YEAR}..."
    if wget -q --timeout=60 --tries=3 --retry-connrefused \
            --progress=bar:force \
            -O "$OUTFILE" "$URL" 2>&1; then
        log_success "Downloaded ${YEAR}"
        (( DOWNLOAD_COUNT++ )) || true
    else
        log_error "Failed to download ${YEAR} from: ${URL}"
        rm -f "$OUTFILE"
        FAILED_YEARS+=("$YEAR")
        (( FAIL_COUNT++ )) || true
    fi
done

# Report download summary
echo ""
log_info "Download Summary:"
log_info "  Downloaded : ${DOWNLOAD_COUNT}"
log_info "  Skipped    : ${SKIP_COUNT}"
log_info "  Failed     : ${FAIL_COUNT}"
if [[ ${#FAILED_YEARS[@]} -gt 0 ]]; then
    log_warn "Failed years: ${FAILED_YEARS[*]}"
fi

# Count available files before merging
AVAIL_FILES=( "${RAW_DIR}/${VAR}".*.nc )
if [[ ${#AVAIL_FILES[@]} -eq 0 ]]; then
    log_error "No files available to merge. Exiting."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Merge All Years into One Daily File
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 2: Merging Daily Files"

if [[ -f "$MERGED_FILE" ]]; then
    log_warn "Merged file already exists: ${MERGED_FILE}"
    log_warn "Delete it manually to re-merge."
else
    log_info "Running: cdo mergetime ..."
    cdo -O -f nc4 -z zip_6 mergetime \
        "${RAW_DIR}/${VAR}".*.nc \
        "$MERGED_FILE"

    if [[ $? -eq 0 ]]; then
        log_success "Merged -> ${MERGED_FILE}"
    else
        log_error "Merge failed. Check CDO installation."
        exit 1
    fi
fi

# Show dataset info
log_info "Dataset info:"
cdo info "$MERGED_FILE" 2>/dev/null | head -5 || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Extract Specific Pressure Level (if applicable)
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 3: Pressure Level Extraction (${LEVEL} hPa)"

LEVEL_FILE="${AGG_DIR}/${VAR}_${LEVEL}hPa_daily_${START_YEAR}_${END_YEAR}.nc"

if $IS_PRESSURE_LEVEL; then
    if [[ -f "$LEVEL_FILE" ]]; then
        log_warn "Level file exists: ${LEVEL_FILE} -- skipping"
    else
        log_info "Extracting pressure level ${LEVEL} hPa..."
        cdo -O -f nc4 -z zip_6 sellevel,"$LEVEL" "$MERGED_FILE" "$LEVEL_FILE"
        log_success "Extracted ${LEVEL} hPa -> ${LEVEL_FILE}"
    fi
    BASE_NC="$LEVEL_FILE"
else
    BASE_NC="$MERGED_FILE"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Temporal Aggregations
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 4: Temporal Aggregations (${AGGREGATIONS})"

PREFIX="${VAR}_${LEVEL}hPa"
IFS=',' read -ra AGGR_LIST <<< "$AGGREGATIONS"

for AGGR in "${AGGR_LIST[@]}"; do
    AGGR=$(echo "$AGGR" | xargs)  # trim whitespace
    OUT_NC="${AGG_DIR}/${PREFIX}_${AGGR}_${START_YEAR}_${END_YEAR}.nc"

    if [[ -f "$OUT_NC" ]]; then
        log_warn "${AGGR} file exists: ${OUT_NC} -- skipping"
        continue
    fi

    log_info "Computing ${AGGR} aggregation..."

    case "$AGGR" in
        daily)
            # Daily is the base -- just copy/symlink the level file
            cp "$BASE_NC" "$OUT_NC"
            log_success "daily -> ${OUT_NC}"
            ;;

        monthly)
            # Monthly mean
            cdo -O -f nc4 -z zip_6 monmean "$BASE_NC" "$OUT_NC"
            log_success "monthly mean -> ${OUT_NC}"
            ;;

        seasonal)
            # Seasonal mean (DJF, MAM, JJA, SON)
            SEAS_TMP="${AGG_DIR}/${PREFIX}_seasonal_tmp.nc"
            cdo -O -f nc4 -z zip_6 seasmean "$BASE_NC" "$SEAS_TMP"
            cdo -O -f nc4 -z zip_6 -select,month=3,6,9,12 "$SEAS_TMP" "$OUT_NC"
            rm -f "$SEAS_TMP"
            log_success "seasonal mean -> ${OUT_NC}"
            ;;

        annual)
            # Annual mean
            cdo -O -f nc4 -z zip_6 yearmean "$BASE_NC" "$OUT_NC"
            log_success "annual mean -> ${OUT_NC}"
            ;;

        climatology)
            # Long-term daily climatology (mean of each calendar day)
            cdo -O -f nc4 -z zip_6 ydaymean "$BASE_NC" "$OUT_NC"
            log_success "daily climatology -> ${OUT_NC}"
            ;;

        anomaly)
            # Daily anomalies (subtract daily climatology)
            CLIM_NC="${AGG_DIR}/${PREFIX}_climatology_${START_YEAR}_${END_YEAR}.nc"
            if [[ ! -f "$CLIM_NC" ]]; then
                log_info "Computing climatology first for anomaly..."
                cdo -O -f nc4 -z zip_6 ydaymean "$BASE_NC" "$CLIM_NC"
            fi
            cdo -O -f nc4 -z zip_6 ydaysub "$BASE_NC" "$CLIM_NC" "$OUT_NC"
            log_success "daily anomaly -> ${OUT_NC}"
            ;;

        dekad)
            # 10-day (dekad) mean
            cdo -O -f nc4 -z zip_6 runmean,10 "$BASE_NC" "$OUT_NC"
            log_success "dekad (10-day) mean -> ${OUT_NC}"
            ;;

        pentad)
            # 5-day (pentad) mean
            cdo -O -f nc4 -z zip_6 runmean,5 "$BASE_NC" "$OUT_NC"
            log_success "pentad (5-day) mean -> ${OUT_NC}"
            ;;

        *)
            log_warn "Unknown aggregation: '${AGGR}'. Skipping."
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Generate Python Visualization Script
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 5: Writing Python Visualization Script"

cat > "$PYTHON_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""
NOAA NCEP Reanalysis Visualization Script
==========================================
Auto-generated by noaa_pipeline.sh
Plots spatial maps and time series from processed NetCDF files.

Usage:
    python3 noaa_plot.py [OPTIONS]

Options:
    --nc         Path to NetCDF file
    --var        Variable name in NetCDF (default: shum)
    --lat        Latitude  for time series (default: 20.0)
    --lon        Longitude for time series (default: 80.0)
    --plot-type  spatial | timeseries | both (default: both)
    --aggr       Aggregation label for title (default: daily)
    --outdir     Output directory for saved plots (default: ./plots)
    --level      Pressure level label for title (default: 850)
    --colormap   Matplotlib colormap (default: auto)
    --start      Start date filter YYYY-MM-DD (optional)
    --end        End date filter YYYY-MM-DD (optional)
    --show       Display interactive plot (default: False)
    --format     Output figure format: png | pdf | svg (default: png)
    --dpi        Figure DPI (default: 150)
"""

import argparse
import sys
import os
import warnings
warnings.filterwarnings("ignore")

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")  # Non-interactive backend; change to TkAgg/Qt5Agg for --show
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
from matplotlib.colors import TwoSlopeNorm
from mpl_toolkits.axes_grid1 import make_axes_locatable
import xarray as xr

# ─────────────────────────────────────────────────────────────────────────────
# Variable Metadata
# ─────────────────────────────────────────────────────────────────────────────
VAR_META = {
    "shum":  {"long_name": "Specific Humidity",   "units": "kg/kg",   "cmap": "YlGnBu",  "cmap_anom": "BrBG"},
    "uwnd":  {"long_name": "U-Wind (Zonal)",       "units": "m/s",     "cmap": "RdBu_r",  "cmap_anom": "RdBu_r"},
    "vwnd":  {"long_name": "V-Wind (Meridional)",  "units": "m/s",     "cmap": "RdBu_r",  "cmap_anom": "RdBu_r"},
    "air":   {"long_name": "Air Temperature",      "units": "K",       "cmap": "RdYlBu_r","cmap_anom": "RdBu_r"},
    "omega": {"long_name": "Vertical Velocity",    "units": "Pa/s",    "cmap": "RdBu",    "cmap_anom": "RdBu"},
    "hgt":   {"long_name": "Geopotential Height",  "units": "m",       "cmap": "viridis", "cmap_anom": "RdBu_r"},
    "rhum":  {"long_name": "Relative Humidity",    "units": "%",       "cmap": "YlGnBu",  "cmap_anom": "BrBG"},
    "prate": {"long_name": "Precipitation Rate",   "units": "kg/m2/s", "cmap": "Blues",   "cmap_anom": "BrBG"},
    "slp":   {"long_name": "Sea Level Pressure",   "units": "Pa",      "cmap": "RdYlBu_r","cmap_anom": "RdBu_r"},
}

# ─────────────────────────────────────────────────────────────────────────────
# Argument Parsing
# ─────────────────────────────────────────────────────────────────────────────
def parse_args():
    p = argparse.ArgumentParser(description="NOAA NCEP Reanalysis Visualizer")
    p.add_argument("--nc",        required=True,  help="Path to NetCDF file")
    p.add_argument("--var",       default="shum", help="Variable name")
    p.add_argument("--lat",       type=float, default=20.0,  help="Latitude for time series")
    p.add_argument("--lon",       type=float, default=80.0,  help="Longitude for time series")
    p.add_argument("--plot-type", default="both", choices=["spatial","timeseries","both"])
    p.add_argument("--aggr",      default="daily", help="Aggregation label")
    p.add_argument("--outdir",    default="./plots", help="Output plot directory")
    p.add_argument("--level",     default="850",  help="Pressure level label")
    p.add_argument("--colormap",  default=None,   help="Override colormap")
    p.add_argument("--start",     default=None,   help="Start date YYYY-MM-DD")
    p.add_argument("--end",       default=None,   help="End date YYYY-MM-DD")
    p.add_argument("--show",      action="store_true", help="Show interactive plot")
    p.add_argument("--format",    default="png",  choices=["png","pdf","svg"])
    p.add_argument("--dpi",       type=int, default=150)
    return p.parse_args()

# ─────────────────────────────────────────────────────────────────────────────
# Data Loading
# ─────────────────────────────────────────────────────────────────────────────
def load_data(nc_path: str, var_name: str, lat: float, lon: float,
              start: str = None, end: str = None) -> dict:
    """Load and subset NetCDF data."""
    print(f"[INFO] Loading: {nc_path}")
    ds = xr.open_dataset(nc_path, decode_times=True)

    # Find variable (case-insensitive fallback)
    if var_name not in ds:
        candidates = [v for v in ds.data_vars if var_name.lower() in v.lower()]
        if not candidates:
            raise ValueError(f"Variable '{var_name}' not found. Available: {list(ds.data_vars)}")
        var_name = candidates[0]
        print(f"[INFO] Using variable: {var_name}")

    da = ds[var_name]

    # Squeeze pressure level dimension if present
    if "level" in da.dims and da.sizes["level"] == 1:
        da = da.squeeze("level")
    elif "level" in da.dims:
        # Take the first level if multiple
        print(f"[WARN] Multiple levels found. Taking level index 0.")
        da = da.isel(level=0)

    # Normalize dimension names
    rename_map = {}
    for d in da.dims:
        if d.lower() in ["latitude", "lat"]:
            rename_map[d] = "lat"
        elif d.lower() in ["longitude", "lon"]:
            rename_map[d] = "lon"
        elif d.lower() in ["time", "t"]:
            rename_map[d] = "time"
    if rename_map:
        da = da.rename(rename_map)

    # Normalize longitude: convert 0-360 to -180 to 180 if needed
    if "lon" in da.coords and da.lon.max() > 180:
        da = da.assign_coords(lon=(da.lon + 180) % 360 - 180)
        da = da.sortby("lon")

    # Ensure lat is sorted ascending
    if "lat" in da.coords and da.lat.values[0] > da.lat.values[-1]:
        da = da.sortby("lat")

    # Time filter
    if start or end:
        da = da.sel(time=slice(start, end))

    print(f"[INFO] Data shape: {dict(da.sizes)}")
    print(f"[INFO] Time range: {str(da.time.values[0])[:10]} to {str(da.time.values[-1])[:10]}")
    print(f"[INFO] Lat range : {float(da.lat.min()):.2f} to {float(da.lat.max()):.2f}")
    print(f"[INFO] Lon range : {float(da.lon.min()):.2f} to {float(da.lon.max()):.2f}")

    # Extract time series at (lat, lon)
    ts = da.sel(lat=lat, lon=lon, method="nearest")
    actual_lat = float(ts.lat.values)
    actual_lon = float(ts.lon.values)
    print(f"[INFO] Nearest grid point: lat={actual_lat:.2f}, lon={actual_lon:.2f}")

    # Compute climatological mean (spatial) -- mean over time
    spatial_mean = da.mean(dim="time")

    return {
        "da":         da,
        "ts":         ts,
        "spatial":    spatial_mean,
        "var_name":   var_name,
        "actual_lat": actual_lat,
        "actual_lon": actual_lon,
    }

# ─────────────────────────────────────────────────────────────────────────────
# Spatial Map
# ─────────────────────────────────────────────────────────────────────────────
def plot_spatial(da_spatial, var_name: str, args, meta: dict,
                 actual_lat: float, actual_lon: float):
    """Plot global/regional spatial map with optional cartopy."""
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

    # Detect if anomaly (use diverging colormap)
    is_anomaly = "anomaly" in args.aggr.lower() or "anom" in str(args.nc).lower()
    if is_anomaly:
        cmap = args.colormap or meta.get("cmap_anom", "RdBu_r")
        vmax = np.nanpercentile(np.abs(data), 98)
        norm = TwoSlopeNorm(vcenter=0, vmin=-vmax, vmax=vmax)
    else:
        vmin = np.nanpercentile(data, 2)
        vmax = np.nanpercentile(data, 98)
        norm = None

    fig_title = (f"{meta.get('long_name', var_name)} | {args.level} hPa | "
                 f"{args.aggr.title()} Mean")

    if HAS_CARTOPY:
        proj = ccrs.PlateCarree()
        fig, ax = plt.subplots(
            figsize=(14, 7),
            subplot_kw={"projection": proj},
            facecolor="#0f0f1a"
        )
        ax.set_facecolor("#0f0f1a")

        if is_anomaly:
            cf = ax.contourf(lons, lats, data, levels=21, cmap=cmap,
                             norm=norm, transform=proj)
        else:
            cf = ax.contourf(lons, lats, data, levels=21, cmap=cmap,
                             vmin=vmin, vmax=vmax, transform=proj)

        # Contour lines
        cs = ax.contour(lons, lats, data, levels=10, colors="white",
                        linewidths=0.4, alpha=0.4, transform=proj)

        # Map features
        ax.add_feature(cfeature.COASTLINE, linewidth=0.8, edgecolor="#aaaacc")
        ax.add_feature(cfeature.BORDERS,   linewidth=0.4, edgecolor="#888899", linestyle="--")
        ax.add_feature(cfeature.LAND,      facecolor="none", edgecolor="none")
        ax.add_feature(cfeature.OCEAN,     facecolor="#0a0a15", alpha=0.3)
        ax.gridlines(draw_labels=True, linewidth=0.4, color="gray",
                     alpha=0.5, linestyle="--",
                     xlocs=range(-180, 181, 30), ylocs=range(-90, 91, 30))

        # Mark selected coordinate
        ax.plot(actual_lon, actual_lat, marker="*", color="#ff6b6b",
                markersize=14, transform=proj, zorder=10,
                label=f"Selected: {actual_lat:.1f}N, {actual_lon:.1f}E")
        ax.legend(loc="lower left", fontsize=9,
                  facecolor="#1a1a2e", edgecolor="#444466", labelcolor="white")
        ax.set_global()

    else:
        # Fallback: plain matplotlib
        fig, ax = plt.subplots(figsize=(14, 7), facecolor="#0f0f1a")
        ax.set_facecolor("#0f0f1a")
        lons2d, lats2d = np.meshgrid(lons, lats)
        if is_anomaly:
            cf = ax.pcolormesh(lons2d, lats2d, data, cmap=cmap, norm=norm, shading="auto")
        else:
            cf = ax.pcolormesh(lons2d, lats2d, data, cmap=cmap,
                               vmin=vmin, vmax=vmax, shading="auto")
        ax.plot(actual_lon, actual_lat, "r*", markersize=14,
                label=f"Selected: {actual_lat:.1f}N, {actual_lon:.1f}E")
        ax.set_xlabel("Longitude", color="white")
        ax.set_ylabel("Latitude",  color="white")
        ax.tick_params(colors="white")
        ax.spines[:].set_color("#444466")
        ax.legend(fontsize=9, facecolor="#1a1a2e", edgecolor="#444466", labelcolor="white")

    # Colorbar
    cbar = plt.colorbar(cf, ax=ax, orientation="horizontal",
                        pad=0.04, fraction=0.03, aspect=50)
    cbar.set_label(f"{meta.get('long_name', var_name)} ({meta.get('units', '')})",
                   color="white", fontsize=11)
    cbar.ax.tick_params(colors="white", labelsize=8)
    cbar.outline.set_edgecolor("#444466")

    ax.set_title(fig_title, color="white", fontsize=14, fontweight="bold", pad=12)
    fig.patch.set_facecolor("#0f0f1a")

    os.makedirs(args.outdir, exist_ok=True)
    fname = f"{var_name}_{args.level}hPa_{args.aggr}_spatial.{args.format}"
    fpath = os.path.join(args.outdir, fname)
    plt.savefig(fpath, dpi=args.dpi, bbox_inches="tight",
                facecolor="#0f0f1a", edgecolor="none")
    print(f"[OK] Saved spatial map -> {fpath}")

    if args.show:
        matplotlib.use("TkAgg")
        plt.show()
    plt.close(fig)
    return fpath

# ─────────────────────────────────────────────────────────────────────────────
# Time Series
# ─────────────────────────────────────────────────────────────────────────────
def plot_timeseries(ts, var_name: str, args, meta: dict,
                    actual_lat: float, actual_lon: float):
    """Plot time series with rolling mean and trend line."""
    from scipy import stats as scipy_stats

    times  = pd.to_datetime(ts.time.values)
    values = ts.values.astype(float)

    # Remove NaN
    mask   = ~np.isnan(values)
    times  = times[mask]
    values = values[mask]

    if len(values) == 0:
        print("[ERROR] No valid data at selected point.")
        return None

    # Compute rolling mean (window depends on aggregation)
    win_map = {"daily": 30, "monthly": 12, "seasonal": 4, "annual": 5,
               "pentad": 10, "climatology": 30, "anomaly": 30}
    win = win_map.get(args.aggr.lower(), 12)
    ts_series   = pd.Series(values, index=times)
    rolling_mean = ts_series.rolling(window=win, center=True, min_periods=1).mean()

    # Linear trend
    x_num = np.arange(len(values), dtype=float)
    slope, intercept, r_val, p_val, std_err = scipy_stats.linregress(x_num, values)
    trend = slope * x_num + intercept

    # Unit conversion for display
    display_values = values.copy()
    display_label  = meta.get("units", "")
    if var_name == "shum":
        display_values = values * 1000
        display_label  = "g/kg"

    rolling_display = rolling_mean.values.copy()
    trend_display   = trend.copy()
    if var_name == "shum":
        rolling_display *= 1000
        trend_display   *= 1000

    # ── Figure ──────────────────────────────────────────────────────────────
    fig, axes = plt.subplots(2, 1, figsize=(14, 9),
                              gridspec_kw={"height_ratios": [3, 1]},
                              facecolor="#0f0f1a")
    ax_main, ax_bar = axes

    # Color based on positive/negative for anomaly
    is_anomaly = "anomaly" in args.aggr.lower()
    if is_anomaly:
        bar_colors = np.where(display_values >= 0, "#ff6b6b", "#6bb5ff")
        ax_main.axhline(0, color="#888899", linewidth=0.8, linestyle="--", alpha=0.6)
    else:
        bar_colors = "#3a7bd5"

    # Main time series
    ax_main.set_facecolor("#0f0f1a")
    ax_main.fill_between(times, display_values, alpha=0.25,
                          color="#3a7bd5", linewidth=0)
    ax_main.plot(times, display_values, color="#3a7bd5",
                  linewidth=0.7, alpha=0.6, label="Observed")
    ax_main.plot(times, rolling_display, color="#f0c040",
                  linewidth=2.0, label=f"{win}-step Rolling Mean")
    ax_main.plot(times, trend_display, color="#ff6b6b",
                  linewidth=1.5, linestyle="--",
                  label=f"Trend: {slope * (365 if args.aggr=='daily' else 1):.4g}/yr"
                        f"  (p={p_val:.3f})")

    # Mark selected point
    mid_idx = len(times) // 2
    ax_main.axvline(times[0], color="none")  # dummy for spacing

    ax_main.set_title(
        f"{meta.get('long_name', var_name)} | {args.level} hPa | "
        f"({actual_lat:.2f}N, {actual_lon:.2f}E) | {args.aggr.title()}",
        color="white", fontsize=13, fontweight="bold", pad=10
    )
    ax_main.set_ylabel(f"{meta.get('long_name', var_name)} ({display_label})",
                        color="white", fontsize=11)
    ax_main.tick_params(colors="white", labelsize=9)
    ax_main.spines[:].set_color("#2a2a3e")
    ax_main.spines["bottom"].set_color("#444466")
    ax_main.spines["left"].set_color("#444466")
    ax_main.legend(fontsize=9, facecolor="#1a1a2e",
                    edgecolor="#444466", labelcolor="white")
    ax_main.grid(axis="y", color="#2a2a3e", linewidth=0.5, linestyle=":")
    ax_main.set_facecolor("#0d0d1a")

    # Annual bar chart (bottom panel)
    ax_bar.set_facecolor("#0d0d1a")
    annual_ts = ts_series.resample("YE").mean()
    if var_name == "shum":
        annual_ts = annual_ts * 1000
    bar_c = ["#ff6b6b" if v >= annual_ts.mean() else "#6bb5ff"
              for v in annual_ts.values]
    ax_bar.bar(annual_ts.index.year, annual_ts.values,
                color=bar_c, width=0.7, alpha=0.85, edgecolor="none")
    ax_bar.axhline(annual_ts.mean(), color="#f0c040",
                    linewidth=1.2, linestyle="--", alpha=0.7, label="Annual mean")
    ax_bar.set_ylabel("Annual\nMean", color="white", fontsize=8)
    ax_bar.tick_params(colors="white", labelsize=8)
    ax_bar.spines[:].set_color("#2a2a3e")
    ax_bar.spines["bottom"].set_color("#444466")
    ax_bar.spines["left"].set_color("#444466")
    ax_bar.set_facecolor("#0d0d1a")
    ax_bar.grid(axis="y", color="#2a2a3e", linewidth=0.4, linestyle=":")
    ax_bar.legend(fontsize=8, facecolor="#1a1a2e",
                   edgecolor="#444466", labelcolor="white")

    plt.tight_layout(rect=[0, 0, 1, 1], h_pad=0.5)

    os.makedirs(args.outdir, exist_ok=True)
    fname = (f"{var_name}_{args.level}hPa_{args.aggr}_"
             f"timeseries_{actual_lat:.1f}N_{actual_lon:.1f}E.{args.format}")
    fpath = os.path.join(args.outdir, fname)
    plt.savefig(fpath, dpi=args.dpi, bbox_inches="tight",
                facecolor="#0f0f1a", edgecolor="none")
    print(f"[OK] Saved time series -> {fpath}")

    if args.show:
        matplotlib.use("TkAgg")
        plt.show()
    plt.close(fig)
    return fpath

# ─────────────────────────────────────────────────────────────────────────────
# Hovmoller Diagram (Lat-Time or Lon-Time)
# ─────────────────────────────────────────────────────────────────────────────
def plot_hovmoller(da, var_name: str, args, meta: dict,
                   actual_lat: float, actual_lon: float):
    """Plot a Hovmoller diagram (longitude-time) at selected latitude."""
    cmap = args.colormap or meta.get("cmap", "RdBu_r")

    # Slice lat band +/- 2.5 degrees
    lat_band = da.sel(lat=slice(actual_lat - 2.5, actual_lat + 2.5)).mean(dim="lat")
    data = lat_band.values.astype(float)
    if var_name == "shum":
        data *= 1000
    times = pd.to_datetime(lat_band.time.values)
    lons  = lat_band.lon.values

    fig, ax = plt.subplots(figsize=(14, 8), facecolor="#0f0f1a")
    ax.set_facecolor("#0d0d1a")

    vmin = np.nanpercentile(data, 2)
    vmax = np.nanpercentile(data, 98)
    cf   = ax.contourf(lons, np.arange(len(times)), data,
                        levels=21, cmap=cmap, vmin=vmin, vmax=vmax)
    ax.contour(lons, np.arange(len(times)), data,
               levels=10, colors="white", linewidths=0.3, alpha=0.3)

    # Y-axis: time labels
    n_ticks = min(12, len(times))
    tick_idx = np.linspace(0, len(times) - 1, n_ticks, dtype=int)
    ax.set_yticks(tick_idx)
    ax.set_yticklabels([str(times[i])[:10] for i in tick_idx],
                        color="white", fontsize=8)
    ax.set_xlabel("Longitude", color="white", fontsize=11)
    ax.set_ylabel("Time",      color="white", fontsize=11)
    ax.tick_params(colors="white", labelsize=9)
    ax.spines[:].set_color("#444466")

    cbar = plt.colorbar(cf, ax=ax, orientation="vertical", pad=0.02, fraction=0.025)
    cbar.set_label(f"{meta.get('long_name', var_name)} ({meta.get('units', '')})",
                   color="white", fontsize=10)
    cbar.ax.tick_params(colors="white", labelsize=8)
    cbar.outline.set_edgecolor("#444466")

    ax.set_title(f"Hovmoller (Lon-Time) | {meta.get('long_name', var_name)} | "
                 f"Lat band ~{actual_lat:.1f} | {args.level} hPa",
                 color="white", fontsize=13, fontweight="bold", pad=10)

    os.makedirs(args.outdir, exist_ok=True)
    fname = (f"{var_name}_{args.level}hPa_{args.aggr}_"
             f"hovmoller_{actual_lat:.1f}N.{args.format}")
    fpath = os.path.join(args.outdir, fname)
    plt.savefig(fpath, dpi=args.dpi, bbox_inches="tight",
                facecolor="#0f0f1a", edgecolor="none")
    print(f"[OK] Saved Hovmoller -> {fpath}")
    plt.close(fig)
    return fpath

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
def main():
    args = parse_args()

    if not os.path.isfile(args.nc):
        print(f"[ERROR] File not found: {args.nc}")
        sys.exit(1)

    meta = VAR_META.get(args.var, {
        "long_name": args.var.upper(),
        "units": "",
        "cmap": "viridis",
        "cmap_anom": "RdBu_r"
    })

    # Load data
    result = load_data(args.nc, args.var,
                       args.lat, args.lon,
                       args.start, args.end)

    plots_saved = []

    # Spatial map
    if args.plot_type in ("spatial", "both"):
        p = plot_spatial(result["spatial"], result["var_name"],
                         args, meta,
                         result["actual_lat"], result["actual_lon"])
        plots_saved.append(p)

    # Time series
    if args.plot_type in ("timeseries", "both"):
        p = plot_timeseries(result["ts"], result["var_name"],
                            args, meta,
                            result["actual_lat"], result["actual_lon"])
        if p:
            plots_saved.append(p)

    # Hovmoller (always generated when timeseries or both)
    if args.plot_type in ("timeseries", "both"):
        try:
            p = plot_hovmoller(result["da"], result["var_name"],
                               args, meta,
                               result["actual_lat"], result["actual_lon"])
            plots_saved.append(p)
        except Exception as e:
            print(f"[WARN] Hovmoller skipped: {e}")

    print(f"\n[OK] Done! {len(plots_saved)} plot(s) saved to: {args.outdir}")
    for p in plots_saved:
        print(f"     -> {p}")

if __name__ == "__main__":
    main()
PYEOF

chmod +x "$PYTHON_SCRIPT"
log_success "Python script written -> ${PYTHON_SCRIPT}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Launch Python Visualization
# ─────────────────────────────────────────────────────────────────────────────
if $LAUNCH_PLOT; then
    log_section "Step 6: Launching Python Visualization"

    # Build aggregations list for plotting
    IFS=',' read -ra AGGR_LIST <<< "$AGGREGATIONS"

    for AGGR in "${AGGR_LIST[@]}"; do
        AGGR=$(echo "$AGGR" | xargs)
        NC_FILE="${AGG_DIR}/${VAR}_${LEVEL}hPa_${AGGR}_${START_YEAR}_${END_YEAR}.nc"

        if [[ ! -f "$NC_FILE" ]]; then
            log_warn "Aggregated file not found for ${AGGR}: ${NC_FILE} -- skipping plot"
            continue
        fi

        log_info "Plotting ${AGGR} (${VAR} @ ${LEVEL}hPa) | lat=${USER_LAT}, lon=${USER_LON}"

        python3 "$PYTHON_SCRIPT" \
            --nc        "$NC_FILE"   \
            --var       "$VAR"       \
            --lat       "$USER_LAT"  \
            --lon       "$USER_LON"  \
            --plot-type "$PLOT_TYPE" \
            --aggr      "$AGGR"      \
            --level     "$LEVEL"     \
            --outdir    "$PLOT_DIR"  \
            --dpi       150          \
            --format    png

        if [[ $? -eq 0 ]]; then
            log_success "Plot completed for ${AGGR}"
        else
            log_error "Plotting failed for ${AGGR}"
        fi
    done
else
    log_info "Skipping Python visualization (--plot false)"
    log_info "To plot manually, run:"
    echo ""
    echo "  python3 ${PYTHON_SCRIPT} \\"
    echo "    --nc     ${AGG_DIR}/${VAR}_${LEVEL}hPa_monthly_${START_YEAR}_${END_YEAR}.nc \\"
    echo "    --var    ${VAR} \\"
    echo "    --lat    ${USER_LAT} \\"
    echo "    --lon    ${USER_LON} \\"
    echo "    --aggr   monthly \\"
    echo "    --level  ${LEVEL} \\"
    echo "    --outdir ${PLOT_DIR}"
    echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Upload Plots to Supabase (Storage + metadata table)
# ─────────────────────────────────────────────────────────────────────────────
UPLOAD_SCRIPT="${OUTDIR}/upload_to_supabase.py"

if [[ -f "$UPLOAD_SCRIPT" ]]; then
    log_section "Step 7: Uploading Plots to Supabase"

    if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_KEY:-}" ]]; then
        log_warn "SUPABASE_URL / SUPABASE_SERVICE_KEY not set -- skipping upload."
        log_warn "Export them (e.g. in ~/.bashrc) to enable automatic upload."
    else
        python3 "$UPLOAD_SCRIPT" \
            --plots-dir  "$PLOT_DIR" \
            --start-year "$START_YEAR" \
            --end-year   "$END_YEAR" \
            --prefix     "${VAR}/"

        if [[ $? -eq 0 ]]; then
            log_success "Supabase upload step finished"
        else
            log_error "Supabase upload step failed -- check output above"
        fi
    fi
else
    log_warn "upload_to_supabase.py not found at ${UPLOAD_SCRIPT} -- skipping upload step."
    log_warn "Copy it into ${OUTDIR} to enable automatic upload to the website."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Final Summary
# ─────────────────────────────────────────────────────────────────────────────
log_section "Pipeline Complete"
echo -e "${GREEN}Variable    :${NC} ${VAR} @ ${LEVEL} hPa"
echo -e "${GREEN}Period      :${NC} ${START_YEAR} - ${END_YEAR}"
echo -e "${GREEN}Aggregations:${NC} ${AGGREGATIONS}"
echo -e "${GREEN}Coordinate  :${NC} lat=${USER_LAT}, lon=${USER_LON}"
echo -e "${GREEN}Raw data    :${NC} ${RAW_DIR}"
echo -e "${GREEN}Aggregated  :${NC} ${AGG_DIR}"
echo -e "${GREEN}Plots       :${NC} ${PLOT_DIR}"
echo -e "${GREEN}Log file    :${NC} ${LOG_FILE}"
echo ""
log_success "All done!"


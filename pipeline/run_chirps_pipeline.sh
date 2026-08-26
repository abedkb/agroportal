#!/usr/bin/env bash
# =============================================================================
# run_chirps_pipeline.sh
# =============================================================================
# Downloads CHIRPS v2.0 daily global rainfall (0.25deg / p25 resolution --
# chosen deliberately over p05 for a manageable download/processing size
# while still supporting the full 1981-present record), normalizes it to
# the same lat/lon/time convention the NOAA pipeline uses, computes
# temporal aggregations, and writes into the SAME ${OUTDIR}/aggregated/
# structure noaa_pipeline.sh uses -- so plot_api.py, gallery.html, and
# explorer.html pick up rainfall data with NO changes to those files.
#
# CRITICAL METEOROLOGICAL POINT: rainfall is an ACCUMULATIVE quantity, not
# a state variable like temperature. A daily CHIRPS value is already a
# daily TOTAL (mm/day). Period aggregations (monthly/seasonal/annual/
# dekad/pentad) here use SUM, not mean -- summing daily mm gives the
# period's total accumulated rainfall, which is the standard product
# (e.g. "monthly rainfall total"). Averaging daily mm across a month
# instead would give a different, less commonly used quantity (mean
# daily rate). Daily climatology/anomaly remain MEAN-based (the typical/
# actual value for a given calendar day across years), matching how
# noaa_pipeline.sh already handles climatology for its variables.
#
# Data source (verified against the live server and public usage
# examples, since the index page itself blocks automated fetches):
#   https://data.chc.ucsb.edu/products/CHIRPS-2.0/global_daily/netcdf/p25/
#   chirps-v2.0.{year}.days_p25.nc  -- one file per year, all days
#   Variable: precip (mm/day). Dims: time, latitude, longitude.
#   Coverage: 1981-01-01 to near-present, 0.25deg, -50S to 50N, global lon.
#
# Usage:
#   bash run_chirps_pipeline.sh                                  # full record
#   bash run_chirps_pipeline.sh --start 2000 --end 2020
#   bash run_chirps_pipeline.sh --aggr dekad,pentad,monthly
#   bash run_chirps_pipeline.sh --clean-raw
#
# Options:
#   --start      Start year, or "all" for dataset start / 1981 (default: all)
#   --end        End year, or "all" to auto-detect latest year on the server (default: all)
#   --aggr       Aggregation(s), comma-separated (default: daily,monthly,seasonal,annual,dekad,pentad,climatology,anomaly)
#                Options: daily | monthly | seasonal | annual | dekad | pentad | climatology | anomaly
#   --lat        Latitude  for time series -- any value in the grid (default: 20.0)
#   --lon        Longitude for time series -- any value in the grid (default: 80.0)
#   --plot-type  Plot type: spatial | timeseries | both (default: both)
#   --plot       Generate the fixed-point sample plots (default: true; set
#                false if you're only using the live explorer -- see
#                run_all_variables.sh's --skip-static-plots for the NOAA
#                equivalent of this trade-off)
#   --clean-raw  Delete raw yearly downloads + merged intermediate after
#                aggregation succeeds, to save disk (default: false).
#                Same resume/re-download trade-off as noaa_pipeline.sh.
#   --outdir     Output directory (default: current directory ./NOAA -- same
#                default as noaa_pipeline.sh, so both write to one shared tree)
#   --help       Show this help message
#
# Dependencies: same as noaa_pipeline.sh (wget/curl, CDO, Python 3 with
# xarray/matplotlib/cartopy/numpy/pandas).
# =============================================================================
set -uo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────
START_YEAR="all"
END_YEAR="all"
AGGREGATIONS="daily,monthly,seasonal,annual,dekad,pentad,climatology,anomaly"
USER_LAT=-5.0
USER_LON=36.0
PLOT_TYPE="both"
LAUNCH_PLOT=true
CLEAN_RAW=false
OUTDIR="$(pwd)/NOAA"

VAR="precip"    # CHIRPS' native variable name -- fixed, this pipeline is single-purpose
LEVEL="sfc"     # surface/single-level, same convention already used for slp etc.
DATASET_START_YEAR=1981
BASE_URL="https://data.chc.ucsb.edu/products/CHIRPS-2.0/global_daily/netcdf/p25"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start)      START_YEAR="$2";     shift 2 ;;
        --end)        END_YEAR="$2";       shift 2 ;;
        --aggr)       AGGREGATIONS="$2";   shift 2 ;;
        --lat)        USER_LAT="$2";       shift 2 ;;
        --lon)        USER_LON="$2";       shift 2 ;;
        --plot-type)  PLOT_TYPE="$2";      shift 2 ;;
        --plot)       LAUNCH_PLOT="$2";    shift 2 ;;
        --clean-raw)  CLEAN_RAW="$2";      shift 2 ;;
        --outdir)     OUTDIR="$2";         shift 2 ;;
        --help|-h)
            sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RAW_DIR="${OUTDIR}/raw/${VAR}"
AGG_DIR="${OUTDIR}/aggregated/${VAR}"
PLOT_DIR="${OUTDIR}/plots/${VAR}"
LOG_DIR="${OUTDIR}/logs"
PYTHON_SCRIPT="${OUTDIR}/noaa_plot.py"           # shared plotting engine
PERIOD_AGG_SCRIPT="${OUTDIR}/period_aggregate.py" # shared dekad/pentad helper
UPLOAD_SCRIPT="${OUTDIR}/upload_to_supabase.py"

mkdir -p "$RAW_DIR" "$AGG_DIR" "$PLOT_DIR" "$LOG_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

log_section "CHIRPS v2.0 Rainfall Pipeline"
log_info "Output directory: ${OUTDIR}"
log_info "Resolution: 0.25deg (p25) | Aggregations: ${AGGREGATIONS}"

# ─────────────────────────────────────────────────────────────────────────────
# Dependency check
# ─────────────────────────────────────────────────────────────────────────────
command -v cdo >/dev/null 2>&1 || { log_error "cdo (Climate Data Operators) not found. Install it first."; exit 1; }
command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || { log_error "Need wget or curl."; exit 1; }
python3 -c "import xarray, matplotlib, numpy, pandas" 2>/dev/null \
    || { log_error "Missing Python deps. Run: pip install xarray matplotlib numpy pandas netCDF4 --break-system-packages"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Resolve "all" for --start/--end
# ─────────────────────────────────────────────────────────────────────────────
detect_latest_available_year() {
    local candidate
    candidate=$(date +%Y)
    while [[ "$candidate" -ge "$DATASET_START_YEAR" ]]; do
        if wget -q --spider --timeout=15 --tries=2 "${BASE_URL}/chirps-v2.0.${candidate}.days_p25.nc" 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
        candidate=$((candidate - 1))
    done
    echo ""
}

if [[ "$START_YEAR" == "all" || "$END_YEAR" == "all" ]]; then
    log_section "Resolving 'all' year range"
    if [[ "$START_YEAR" == "all" ]]; then
        START_YEAR="$DATASET_START_YEAR"
        log_info "Start year -> ${START_YEAR} (dataset start)"
    fi
    if [[ "$END_YEAR" == "all" ]]; then
        log_info "Probing server for latest available year..."
        DETECTED_END="$(detect_latest_available_year)"
        if [[ -z "$DETECTED_END" ]]; then
            log_error "Could not auto-detect latest year (network issue?). Pass --end explicitly."
            exit 1
        fi
        END_YEAR="$DETECTED_END"
        log_info "End year   -> ${END_YEAR} (latest file found on server)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Download raw yearly files
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 1: Downloading CHIRPS Daily Rainfall (${START_YEAR}-${END_YEAR})"

DOWNLOAD_FAIL_COUNT=0
for YEAR in $(seq "$START_YEAR" "$END_YEAR"); do
    OUT_FILE="${RAW_DIR}/chirps-v2.0.${YEAR}.days_p25.nc"
    if [[ -f "$OUT_FILE" && -s "$OUT_FILE" ]]; then
        log_info "Already have ${YEAR}, skipping."
        continue
    fi
    URL="${BASE_URL}/chirps-v2.0.${YEAR}.days_p25.nc"
    log_info "Downloading ${YEAR}..."
    if wget -q --show-progress --timeout=60 --tries=3 -O "$OUT_FILE" "$URL"; then
        log_success "${YEAR} -> ${OUT_FILE}"
    else
        log_error "Failed to download ${YEAR}"
        rm -f "$OUT_FILE"
        DOWNLOAD_FAIL_COUNT=$((DOWNLOAD_FAIL_COUNT + 1))
    fi
done

if [[ $DOWNLOAD_FAIL_COUNT -gt 0 ]]; then
    log_warn "${DOWNLOAD_FAIL_COUNT} year(s) failed to download. Continuing with what's available."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Merge years + normalize to the lat/lon convention the rest of
# the stack (noaa_plot.py, plot_api.py) already expects.
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 2: Merging Years & Normalizing Dimensions"

MERGED_RAW="${AGG_DIR}/${VAR}_merged_raw_${START_YEAR}_${END_YEAR}.nc"
MERGED_FILE="${AGG_DIR}/${VAR}_daily_${START_YEAR}_${END_YEAR}.nc"

if [[ -f "$MERGED_FILE" ]]; then
    log_info "Merged/normalized file already exists, skipping: ${MERGED_FILE}"
else
    YEAR_FILES=()
    for YEAR in $(seq "$START_YEAR" "$END_YEAR"); do
        F="${RAW_DIR}/chirps-v2.0.${YEAR}.days_p25.nc"
        [[ -f "$F" ]] && YEAR_FILES+=("$F")
    done

    if [[ ${#YEAR_FILES[@]} -eq 0 ]]; then
        log_error "No raw files available to merge. Aborting."
        exit 1
    fi

    cdo -O -f nc4 -z zip_6 mergetime "${YEAR_FILES[@]}" "$MERGED_RAW" \
        || { log_error "Merge failed."; exit 1; }

    # CHIRPS ships with dims "latitude"/"longitude"; the rest of this
    # stack (noaa_plot.py's load_data, plot_spatial/timeseries) expects
    # "lat"/"lon", matching the NOAA reanalysis convention. Normalize
    # once here so the shared plotting code needs no CHIRPS-specific
    # branches at all.
    cdo -O -f nc4 -z zip_6 chname,latitude,lat -chname,longitude,lon "$MERGED_RAW" "$MERGED_FILE" \
        || { log_error "Dimension rename failed."; exit 1; }

    rm -f "$MERGED_RAW"
    log_success "Merged + normalized -> ${MERGED_FILE}"
fi

BASE_NC="$MERGED_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Ensure shared helper scripts exist (written once, reused by
# noaa_pipeline.sh too -- skip if already present so a concurrently
# running NOAA pipeline isn't clobbered mid-use).
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 3: Shared Helper Scripts"

if [[ ! -f "$PERIOD_AGG_SCRIPT" ]]; then
    log_info "Writing shared dekad/pentad helper -> ${PERIOD_AGG_SCRIPT}"
    cat > "$PERIOD_AGG_SCRIPT" << 'PERIODEOF'
#!/usr/bin/env python3
"""
period_aggregate.py -- see noaa_pipeline.sh for the full docstring; this
copy is identical, written by whichever pipeline (NOAA or CHIRPS) runs
first, and reused by the other.
"""
import argparse
import sys

import numpy as np
import pandas as pd
import xarray as xr


def dekad_index(day: int) -> int:
    if day <= 10:
        return 1
    if day <= 20:
        return 2
    return 3


def pentad_index(day: int) -> int:
    return min((day - 1) // 5 + 1, 6)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--nc", required=True)
    p.add_argument("--var", required=True)
    p.add_argument("--period", required=True, choices=["dekad", "pentad"])
    p.add_argument("--stat", required=True, choices=["sum", "mean"])
    p.add_argument("--out", required=True)
    args = p.parse_args()

    ds = xr.open_dataset(args.nc)
    if args.var not in ds:
        print(f"[ERROR] Variable '{args.var}' not found in {args.nc}. "
              f"Available: {list(ds.data_vars)}", file=sys.stderr)
        sys.exit(1)

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


if __name__ == "__main__":
    main()
PERIODEOF
    chmod +x "$PERIOD_AGG_SCRIPT"
else
    log_info "Shared dekad/pentad helper already present: ${PERIOD_AGG_SCRIPT}"
fi

if [[ ! -f "$PYTHON_SCRIPT" ]]; then
    log_warn "Shared plotting script (noaa_plot.py) not found at ${PYTHON_SCRIPT}."
    log_warn "Run noaa_pipeline.sh at least once (any --var) first so it exists,"
    log_warn "or point --outdir at a directory where it's already been written."
    log_warn "Aggregation will still proceed; plotting will be skipped."
    LAUNCH_PLOT=false
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Temporal Aggregations
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 4: Temporal Aggregations (${AGGREGATIONS})"

PREFIX="${VAR}_${LEVEL}hPa"
IFS=',' read -ra AGGR_LIST <<< "$AGGREGATIONS"
AGGR_FAIL_COUNT=0
AGGR_FAILED_LIST=()

for AGGR in "${AGGR_LIST[@]}"; do
    OUT_NC="${AGG_DIR}/${PREFIX}_${AGGR}_${START_YEAR}_${END_YEAR}.nc"

    if [[ -f "$OUT_NC" ]]; then
        log_info "${AGGR} already exists, skipping: ${OUT_NC}"
        continue
    fi

    log_info "Computing ${AGGR} aggregation (sum-based where applicable -- rainfall is accumulative)..."
    STEP_OK=true

    case "$AGGR" in
        daily)
            # Daily is the base -- already a daily total, just copy
            cp "$BASE_NC" "$OUT_NC" || STEP_OK=false
            ;;

        monthly)
            # Monthly TOTAL rainfall (sum of daily mm), not mean daily rate
            cdo -O -f nc4 -z zip_6 monsum "$BASE_NC" "$OUT_NC" || STEP_OK=false
            ;;

        seasonal)
            # Seasonal TOTAL rainfall (DJF, MAM, JJA, SON)
            SEAS_TMP="${AGG_DIR}/${PREFIX}_seasonal_tmp.nc"
            cdo -O -f nc4 -z zip_6 seassum "$BASE_NC" "$SEAS_TMP" || STEP_OK=false
            if $STEP_OK; then
                cdo -O -f nc4 -z zip_6 -select,month=3,6,9,12 "$SEAS_TMP" "$OUT_NC" || STEP_OK=false
            fi
            rm -f "$SEAS_TMP"
            ;;

        annual)
            # Annual TOTAL rainfall
            cdo -O -f nc4 -z zip_6 yearsum "$BASE_NC" "$OUT_NC" || STEP_OK=false
            ;;

        dekad)
            # Calendar-aligned 10-day TOTAL (days 1-10, 11-20, 21-end of month)
            python3 "$PERIOD_AGG_SCRIPT" --nc "$BASE_NC" --var "$VAR" \
                --period dekad --stat sum --out "$OUT_NC" || STEP_OK=false
            ;;

        pentad)
            # Calendar-aligned 5-day TOTAL (days 1-5, 6-10, ..., 26-end of month)
            python3 "$PERIOD_AGG_SCRIPT" --nc "$BASE_NC" --var "$VAR" \
                --period pentad --stat sum --out "$OUT_NC" || STEP_OK=false
            ;;

        climatology)
            # Long-term daily climatology: MEAN of each calendar day across
            # years (the "typical" daily rainfall for that day-of-year) --
            # not a sum, since summing across years isn't a meaningful
            # single-year quantity.
            cdo -O -f nc4 -z zip_6 ydaymean "$BASE_NC" "$OUT_NC" || STEP_OK=false
            ;;

        anomaly)
            # Daily anomaly: actual daily total minus daily climatology (mm)
            CLIM_NC="${AGG_DIR}/${PREFIX}_climatology_${START_YEAR}_${END_YEAR}.nc"
            if [[ ! -f "$CLIM_NC" ]]; then
                log_info "Computing climatology first for anomaly..."
                cdo -O -f nc4 -z zip_6 ydaymean "$BASE_NC" "$CLIM_NC" || STEP_OK=false
            fi
            if $STEP_OK; then
                cdo -O -f nc4 -z zip_6 ydaysub "$BASE_NC" "$CLIM_NC" "$OUT_NC" || STEP_OK=false
            fi
            ;;

        *)
            log_warn "Unknown aggregation: '${AGGR}'. Skipping."
            continue
            ;;
    esac

    if $STEP_OK && [[ -s "$OUT_NC" ]]; then
        log_success "${AGGR} -> ${OUT_NC}"
    else
        log_error "${AGGR} aggregation failed (command error or empty/missing output)."
        AGGR_FAIL_COUNT=$((AGGR_FAIL_COUNT + 1))
        AGGR_FAILED_LIST+=("$AGGR")
        rm -f "$OUT_NC"
    fi
done

if [[ $AGGR_FAIL_COUNT -gt 0 ]]; then
    log_warn "Aggregations with problems: ${AGGR_FAILED_LIST[*]}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4b: Clean up raw downloads (optional)
# ─────────────────────────────────────────────────────────────────────────────
if $CLEAN_RAW; then
    log_section "Step 4b: Cleaning Raw Data"
    if [[ $AGGR_FAIL_COUNT -gt 0 ]]; then
        log_warn "Skipping cleanup -- ${AGGR_FAIL_COUNT} aggregation(s) failed: ${AGGR_FAILED_LIST[*]}"
        log_warn "Raw data kept so you can re-run the failed aggregation(s) without re-downloading."
    else
        # Note: unlike the NOAA pressure-variable pipeline, MERGED_FILE here
        # is NOT the same path as the "daily" aggregation output (daily's
        # OUT_NC is "${PREFIX}_daily_...", MERGED_FILE is "${VAR}_daily_..."
        # -- missing the "_sfchPa" segment -- so it's always a distinct,
        # genuinely redundant intermediate once aggregation succeeds,
        # never the product itself). Safe to delete either way.
        RECLAIMED=$(du -shc "${RAW_DIR}"/*.nc "$MERGED_FILE" 2>/dev/null | tail -1 | cut -f1)
        rm -f "${RAW_DIR}"/*.nc
        rmdir "$RAW_DIR" 2>/dev/null || true
        rm -f "$MERGED_FILE"
        log_success "Removed raw yearly downloads and merged intermediate."
        log_info "Reclaimed approximately ${RECLAIMED:-unknown amount of} disk space."
        log_warn "Re-running with an extended year range will require a full re-download."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Plot (reuses the shared noaa_plot.py -- no CHIRPS-specific
# plotting code needed, since dims were normalized to lat/lon in Step 2)
# ─────────────────────────────────────────────────────────────────────────────
if $LAUNCH_PLOT && [[ -f "$PYTHON_SCRIPT" ]]; then
    log_section "Step 5: Generating Plots"
    for AGGR in "${AGGR_LIST[@]}"; do
        NC_FILE="${AGG_DIR}/${PREFIX}_${AGGR}_${START_YEAR}_${END_YEAR}.nc"
        [[ -f "$NC_FILE" ]] || continue

        log_info "Plotting ${AGGR} (${VAR} @ ${LEVEL}) | lat=${USER_LAT}, lon=${USER_LON}"
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
            --format    png \
            || log_warn "Plotting failed for ${AGGR} -- continuing."
    done
else
    log_info "Skipping plot generation (--plot false, or noaa_plot.py unavailable)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Upload to Supabase (reuses the shared uploader)
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f "$UPLOAD_SCRIPT" ]]; then
    log_section "Step 6: Uploading Plots to Supabase"
    if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_KEY:-}" ]]; then
        log_warn "SUPABASE_URL / SUPABASE_SERVICE_KEY not set -- skipping upload."
    else
        python3 "$UPLOAD_SCRIPT" \
            --plots-dir  "$PLOT_DIR" \
            --var        "$VAR" \
            --level      "$LEVEL" \
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
fi

# ─────────────────────────────────────────────────────────────────────────────
# Final Summary
# ─────────────────────────────────────────────────────────────────────────────
log_section "Done"
echo -e "${GREEN}Variable    :${NC} ${VAR} (CHIRPS v2.0 rainfall, 0.25deg)"
echo -e "${GREEN}Years       :${NC} ${START_YEAR}-${END_YEAR}"
echo -e "${GREEN}Aggregations:${NC} ${AGGREGATIONS}"
echo -e "${GREEN}Output dir  :${NC} ${OUTDIR}"
echo
echo "Aggregated files ready for the live explorer at:"
echo "    ${AGG_DIR}/"
echo
echo "If plot_api.py is already running against this OUTDIR, rainfall will"
echo "appear in its /api/meta response (and the explorer's dropdowns) on"
echo "the next request -- no restart needed."

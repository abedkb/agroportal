#!/usr/bin/env bash
# =============================================================================
# run_all_variables.sh
# =============================================================================
# noaa_pipeline.sh processes ONE --var / --level combination per run.
#
# Its job here has shifted: since plot_api.py now generates timeseries/spatial
# plots LIVE for any lat/lon/domain the user picks on the website, this
# script's real purpose is to make sure the full-record AGGREGATED NetCDF
# files exist for every variable/level you want selectable -- those are what
# plot_api.py reads from at request time. The old fixed-point sample PNGs
# (Step 6 of the pipeline) are now optional -- useful for gallery thumbnails,
# not required for the live explorer to work.
#
# Usage:
#   bash run_all_variables.sh                       # full record, all combos below
#   bash run_all_variables.sh --start 1990 --end 2020
#   bash run_all_variables.sh --skip-static-plots    # faster: data only, no sample PNGs
#   bash run_all_variables.sh --clean-raw            # delete raw downloads after each var aggregates
#
# --clean-raw trades disk space for re-download time: after each variable's
# aggregations are verified successful, its raw yearly files and merged
# intermediate are deleted. Re-running that variable later (e.g. to extend
# the year range) means downloading it from scratch again. Good default for
# a "run once, keep only the aggregated products" setup; skip it if you
# expect to re-run/extend variables often.
#
# Edit the COMBOS array below to control exactly which variable/level
# pairs get generated.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="${SCRIPT_DIR}/noaa_pipeline.sh"

# ── Defaults, overridable via CLI (forwarded to every pipeline run) ─────────
# "all" now means: dataset start (1948) through the latest year the NOAA
# server actually has, auto-detected per variable by noaa_pipeline.sh.
# NOTE: --start all --end all downloads the FULL daily record per variable
# (~78 years) -- expect a large first run (many GB, could take hours per
# variable depending on your connection). Narrow with --start/--end while
# testing, widen once you know it works.
START_YEAR="all"
END_YEAR="all"
AGGREGATIONS="daily,monthly,seasonal,annual"
LAT=20.0
LON=80.0
PLOT_TYPE="both"
GENERATE_STATIC_PLOTS=true
CLEAN_RAW=false
OUTDIR=""   # empty = let noaa_pipeline.sh use its own default ($(pwd)/NOAA)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start)              START_YEAR="$2"; shift 2 ;;
        --end)                END_YEAR="$2";   shift 2 ;;
        --aggr)               AGGREGATIONS="$2"; shift 2 ;;
        --lat)                LAT="$2";        shift 2 ;;
        --lon)                LON="$2";        shift 2 ;;
        --plot-type)          PLOT_TYPE="$2";  shift 2 ;;
        --outdir)             OUTDIR="$2";     shift 2 ;;
        --skip-static-plots)  GENERATE_STATIC_PLOTS=false; shift ;;
        --clean-raw)          CLEAN_RAW=true;  shift ;;
        --help|-h)
            echo "Usage: $0 [--start YYYY|all] [--end YYYY|all] [--aggr a,b,c] [--lat N] [--lon N] [--plot-type spatial|timeseries|both] [--outdir PATH] [--skip-static-plots] [--clean-raw]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Variable:Level combinations to generate ─────────────────────────────────
# This is the full catalog NOAA actually serves for this dataset (verified
# against the live server), not a hand-picked subset. Two things NOT to
# get wrong here:
#
# 1. Not every pressure variable has all 17 standard levels. NOAA's own docs:
#    humidity (shum, rhum) only goes up to 300mb; omega only up to 100mb.
#    Requesting e.g. shum@100 would just 404 -- so levels are generated
#    per-variable below, not as one flat list crossed with every variable.
# 2. Surface variables are NOT simply "${var}.${year}.nc" on NOAA's server --
#    most carry a level suffix baked into the actual filename (e.g.
#    air.sig995, not air). Using the wrong name silently 404s. The names
#    below are verified; skt and prate were dropped because they don't
#    appear in this dataset's surface catalog at all (they live in a
#    different, Gaussian-grid product) -- add them back only after
#    confirming their real path, not by guessing.
#
# IMPORTANT -- SCALE: this generates 100+ combinations. With --start all
# --end all (the default), that's 100+ variables x ~78 years of global
# daily data each. This is genuinely large (realistically many tens of GB
# and a long runtime) -- trim the arrays below before running unmodified
# if that's not what you want.
#
# ALSO NOTE: NCEP/NCAR Reanalysis 1 stopped production, with its last date
# March 17, 2026 (per NOAA). "--end all" will keep landing on 2026 --
# that's expected, not a bug; the dataset simply isn't growing anymore.
PRESSURE_LEVELS_FULL=(1000 925 850 700 600 500 400 300 250 200 150 100 70 50 30 20 10)
PRESSURE_LEVELS_HUMIDITY=(1000 925 850 700 600 500 400 300)   # shum, rhum: to 300mb only
PRESSURE_LEVELS_OMEGA=(1000 925 850 700 600 500 400 300 250 200 150 100)  # omega: to 100mb only

levels_for_var() {
    case "$1" in
        shum|rhum) echo "${PRESSURE_LEVELS_HUMIDITY[@]}" ;;
        omega)     echo "${PRESSURE_LEVELS_OMEGA[@]}" ;;
        *)         echo "${PRESSURE_LEVELS_FULL[@]}" ;;
    esac
}

PRESSURE_VARIABLES=(air hgt omega rhum shum uwnd vwnd)

# Surface variables: verified download names, level is a fixed label (not
# looped) since each is inherently single-level.
SURFACE_COMBOS=(
    "slp:sfc"
    "pres.sfc:sfc"
    "pr_wtr.eatm:sfc"
    "air.sig995:sfc"
    "uwnd.sig995:sfc"
    "vwnd.sig995:sfc"
    "rhum.sig995:sfc"
    "omega.sig995:sfc"
)

COMBOS=()
for v in "${PRESSURE_VARIABLES[@]}"; do
    for lvl in $(levels_for_var "$v"); do
        COMBOS+=("${v}:${lvl}")
    done
done
COMBOS+=("${SURFACE_COMBOS[@]}")

TOTAL=${#COMBOS[@]}
OK=0
FAILED=()

echo "Running ${TOTAL} variable/level combinations (${START_YEAR}-${END_YEAR})..."
echo "Static per-point sample plots: ${GENERATE_STATIC_PLOTS}"
echo "Auto-clean raw data after each variable: ${CLEAN_RAW}"
echo

for i in "${!COMBOS[@]}"; do
    IFS=':' read -r VAR LEVEL <<< "${COMBOS[$i]}"
    N=$((i + 1))
    echo "──────────────────────────────────────────────────────────"
    echo "[$N/$TOTAL] ${VAR} @ ${LEVEL}"
    echo "──────────────────────────────────────────────────────────"

    ARGS=(
        --var        "$VAR"
        --level      "$LEVEL"
        --start      "$START_YEAR"
        --end        "$END_YEAR"
        --aggr       "$AGGREGATIONS"
        --lat        "$LAT"
        --lon        "$LON"
        --plot-type  "$PLOT_TYPE"
        --plot       "$GENERATE_STATIC_PLOTS"
        --clean-raw  "$CLEAN_RAW"
    )
    [[ -n "$OUTDIR" ]] && ARGS+=(--outdir "$OUTDIR")

    bash "$PIPELINE" "${ARGS[@]}"

    if [[ $? -eq 0 ]]; then
        OK=$((OK + 1))
    else
        FAILED+=("${VAR}:${LEVEL}")
        echo "!! Failed: ${VAR}:${LEVEL} -- continuing with the rest"
    fi
    echo
done

echo "=============================================================="
echo "Done: ${OK}/${TOTAL} combinations completed successfully."
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "Failed: ${FAILED[*]}"
    exit 1
fi
echo "=============================================================="
echo
echo "Aggregated NetCDF files are ready for the live explorer. Start the API with:"
echo
EFFECTIVE_OUTDIR="${OUTDIR:-$(pwd)/NOAA}"
echo "    export NOAA_OUTDIR=\"${EFFECTIVE_OUTDIR}\""
echo "    uvicorn plot_api:app --host 0.0.0.0 --port 8000"
echo
echo "Then open explorer.html (with API_BASE pointed at that server) to click"
echo "a point or draw a region and generate a live plot."
echo "=============================================================="

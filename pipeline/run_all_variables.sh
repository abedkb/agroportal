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
# Format "var:level". For surface variables (prate, pr_wtr, slp, skt) the
# level value is unused by the pipeline but still required as an argument --
# any placeholder like "sfc" works and shows up as a label only.
#
# Every combo listed here becomes selectable in the live explorer's
# Variable/Level dropdowns (plot_api.py's /api/meta reads this straight off
# disk, not from this script) -- add or remove entries to control what's
# offered on the website.
COMBOS=(
    "shum:850"
    "shum:700"
    "uwnd:850"
    "uwnd:200"
    "vwnd:850"
    "vwnd:200"
    "air:850"
    "air:1000"
    "hgt:500"
    "omega:500"
    "rhum:850"
    "slp:sfc"
)

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

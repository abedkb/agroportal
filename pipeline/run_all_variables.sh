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
#   bash run_all_variables.sh --vars shum,air --levels 1000,850   # scoped test run
#   bash run_all_variables.sh --skip-surface         # pressure-level variables only
#   bash run_all_variables.sh --global               # global spatial maps instead of Tanzania crop
#
# --vars       Comma-separated pressure-level variables to run, overriding
#              PRESSURE_VARIABLES below (e.g. --vars shum,air,uwnd). Applies
#              ONLY to pressure-level variables -- surface variables are a
#              small fixed set controlled separately via --skip-surface,
#              since they don't have a level dimension to loop over.
# --levels     Comma-separated pressure levels to run for EVERY selected
#              variable, overriding the safe per-variable defaults below
#              (e.g. --levels 1000,850,500). Use with care: the safe
#              defaults exist because not every variable has every level
#              (shum/rhum only go to 300mb, omega only to 100mb) --
#              requesting an invalid level for a given variable just 404s
#              that one combo and moves on (see the per-combo failure
#              handling further down), it won't stop the batch.
# --skip-surface  Skip the 8 surface-variable combos entirely (pressure-level
#                 variables only).
#
# --clean-raw trades disk space for re-download time: after each variable's
# aggregations are verified successful, its raw yearly files and merged
# intermediate are deleted. Re-running that variable later (e.g. to extend
# the year range) means downloading it from scratch again. Good default for
# a "run once, keep only the aggregated products" setup; skip it if you
# expect to re-run/extend variables often.
#
# Edit the COMBOS array below to control exactly which variable/level
# pairs get generated, or use --vars/--levels/--skip-surface above instead
# of hand-editing for a one-off scoped run.
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
# dekad/pentad included by default now -- Tanzania agromet reporting (TMA
# bulletins, crop monitoring) runs on dekadal periods, and this script's own
# default previously excluded them the same way noaa_pipeline.sh's did.
AGGREGATIONS="daily,monthly,seasonal,annual,dekad,pentad"
# Default sample point for the (optional) static gallery thumbnails: Dodoma,
# Tanzania's capital, roughly central to the country. Previously 20.0/80.0
# (South Asia), a leftover default from unrelated prior use of this script.
LAT=-6.1630
LON=35.7516
PLOT_TYPE="both"
GENERATE_STATIC_PLOTS=true
CLEAN_RAW=false
OUTDIR=""   # empty = let noaa_pipeline.sh use its own default ($(pwd)/NOAA)

# Default spatial-map domain crop: Tanzania + immediate neighbors, forwarded
# to noaa_pipeline.sh's own --lat-min/--lat-max/--lon-min/--lon-max (see that
# script for the full rationale). Pass --global here to opt out for the
# whole batch and get full-globe maps instead.
DOMAIN_LAT_MIN=-12.5
DOMAIN_LAT_MAX=1.5
DOMAIN_LON_MIN=28.5
DOMAIN_LON_MAX=41.5

# --vars / --levels / --skip-surface overrides -- empty/false means "use the
# safe per-variable defaults below", exactly as before this change.
VARS_OVERRIDE=""
LEVELS_OVERRIDE=""
SKIP_SURFACE=false

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
        --vars)               VARS_OVERRIDE="$2";   shift 2 ;;
        --levels)              LEVELS_OVERRIDE="$2"; shift 2 ;;
        --skip-surface)        SKIP_SURFACE=true;    shift ;;
        --lat-min)             DOMAIN_LAT_MIN="$2"; shift 2 ;;
        --lat-max)             DOMAIN_LAT_MAX="$2"; shift 2 ;;
        --lon-min)              DOMAIN_LON_MIN="$2"; shift 2 ;;
        --lon-max)              DOMAIN_LON_MAX="$2"; shift 2 ;;
        --global)               DOMAIN_LAT_MIN=""; DOMAIN_LAT_MAX=""; DOMAIN_LON_MIN=""; DOMAIN_LON_MAX=""; shift ;;
        --help|-h)
            echo "Usage: $0 [--start YYYY|all] [--end YYYY|all] [--aggr a,b,c] [--lat N] [--lon N]"
            echo "          [--plot-type spatial|timeseries|both] [--outdir PATH] [--skip-static-plots]"
            echo "          [--clean-raw] [--vars v1,v2,...] [--levels l1,l2,...] [--skip-surface]"
            echo "          [--lat-min N] [--lat-max N] [--lon-min N] [--lon-max N] [--global]"
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
#    (--levels overrides this per-variable safety net -- see the option
#    note near the top of the file.)
# 2. Surface variables are NOT simply "${var}.${year}.nc" on NOAA's server --
#    most carry a level suffix baked into the actual filename (e.g.
#    air.sig995, not air). Using the wrong name silently 404s. The names
#    below are verified; skt and prate were dropped because they don't
#    appear in this dataset's surface catalog at all (they live in a
#    different, Gaussian-grid product) -- add them back only after
#    confirming their real path, not by guessing.
#
# IMPORTANT -- SCALE: the full, un-scoped matrix generates 100+ combinations.
# With --start all --end all (the default), that's 100+ variables x ~78
# years of daily data each -- genuinely large (many tens of GB, a long
# runtime). Use --vars/--levels for a scoped test run before committing to
# the full matrix, e.g.:
#   bash run_all_variables.sh --vars shum,air --levels 1000,850 --start 2015 --end 2020
#
# ALSO NOTE: NCEP/NCAR Reanalysis 1 stopped production, with its last date
# March 17, 2026 (per NOAA). "--end all" will keep landing on 2026 --
# that's expected, not a bug; the dataset simply isn't growing anymore.
PRESSURE_LEVELS_FULL=(1000 925 850 700 600 500 400 300 250 200 150 100 70 50 30 20 10)
PRESSURE_LEVELS_HUMIDITY=(1000 925 850 700 600 500 400 300)   # shum, rhum: to 300mb only
PRESSURE_LEVELS_OMEGA=(1000 925 850 700 600 500 400 300 250 200 150 100)  # omega: to 100mb only

levels_for_var() {
    # --levels overrides the safe per-variable defaults below entirely --
    # the caller is responsible for only requesting levels valid for the
    # variable(s) they picked with --vars. Invalid combos simply fail (see
    # the per-combo error handling in the run loop) rather than stopping
    # the batch, so this is a "you can shoot yourself in the foot, but not
    # the whole run" tradeoff, not a hard validation.
    if [[ -n "$LEVELS_OVERRIDE" ]]; then
        echo "$LEVELS_OVERRIDE" | tr ',' ' '
        return
    fi
    case "$1" in
        shum|rhum) echo "${PRESSURE_LEVELS_HUMIDITY[@]}" ;;
        omega)     echo "${PRESSURE_LEVELS_OMEGA[@]}" ;;
        *)         echo "${PRESSURE_LEVELS_FULL[@]}" ;;
    esac
}

PRESSURE_VARIABLES=(air hgt omega rhum shum uwnd vwnd)
if [[ -n "$VARS_OVERRIDE" ]]; then
    IFS=',' read -ra PRESSURE_VARIABLES <<< "$VARS_OVERRIDE"
fi

# Surface variables: verified download names, level is a fixed label (not
# looped) since each is inherently single-level. Not affected by --vars --
# use --skip-surface to exclude this whole set instead.
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
if ! $SKIP_SURFACE; then
    COMBOS+=("${SURFACE_COMBOS[@]}")
fi

TOTAL=${#COMBOS[@]}
OK=0
FAILED=()

# Same domain-crop wiring as noaa_pipeline.sh: forwarded on every run below
# so generated spatial maps stay Tanzania-region by default, unless --global
# cleared these to empty above.
DOMAIN_ARGS=()
if [[ -n "$DOMAIN_LAT_MIN" && -n "$DOMAIN_LAT_MAX" && -n "$DOMAIN_LON_MIN" && -n "$DOMAIN_LON_MAX" ]]; then
    DOMAIN_ARGS=(--lat-min "$DOMAIN_LAT_MIN" --lat-max "$DOMAIN_LAT_MAX" --lon-min "$DOMAIN_LON_MIN" --lon-max "$DOMAIN_LON_MAX")
fi

echo "Running ${TOTAL} variable/level combinations (${START_YEAR}-${END_YEAR})..."
echo "Variables : ${PRESSURE_VARIABLES[*]}$($SKIP_SURFACE && echo '' || echo ' + 8 surface combos')"
echo "Static per-point sample plots: ${GENERATE_STATIC_PLOTS}"
echo "Auto-clean raw data after each variable: ${CLEAN_RAW}"
if [[ -n "$DOMAIN_LAT_MIN" ]]; then
    echo "Map domain: lat ${DOMAIN_LAT_MIN} to ${DOMAIN_LAT_MAX}, lon ${DOMAIN_LON_MIN} to ${DOMAIN_LON_MAX} (Tanzania region)"
else
    echo "Map domain: global"
fi
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
    ARGS+=("${DOMAIN_ARGS[@]}")
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

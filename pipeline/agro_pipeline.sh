#!/usr/bin/env bash
# =============================================================================
# agro_pipeline.sh
# =============================================================================
# Unified, DELIBERATELY SERVER-FREE Agromet data pipeline. Downloads NOAA
# reanalysis + CHIRPS rainfall, aggregates, plots, and uploads to Supabase --
# entirely as one-shot runs. Nothing in this file, or in agro_pipeline.py
# (its Python counterpart), ever listens for a request or stays running.
# That's intentional: it means this can run on your own laptop, a scheduled
# GitHub Actions job, or any machine you like, with no port to open, no
# firewall rule, and no "what if it goes down" story to worry about. If
# Live Explorer (arbitrary user-picked points rendered on demand) is wanted
# later, that's a genuinely separate, additional piece layered on top --
# this file doesn't need to change to support it.
#
# Subcommands
# -----------
#   noaa     One NOAA NCEP reanalysis variable/level.
#   chirps   CHIRPS v2.0 daily rainfall (0.25deg).
#   all      Loop the full NOAA catalog + CHIRPS in one run.
#   update   Incremental: only the new days since the last successful run.
#            Designed for daily cron / GitHub Actions (cheap, fast).
#
# Tanzania-specific defaults (same as noaa_pipeline.sh):
#   - dekad/pentad included in aggregations by default (TMA's agromet
#     bulletins run on dekadal periods)
#   - Sample point for static thumbnails: Dodoma (-6.1630, 35.7516)
#   - Spatial maps crop to Tanzania + neighbors by default
#   - Time series/Hovmoller average across Tanzania's actual extent by
#     default (tighter box than the map-display one, so neighboring
#     countries don't dilute the average) -- pass --point to opt out
#
# Examples
#   bash agro_pipeline.sh noaa --var shum --level 850
#   bash agro_pipeline.sh chirps --start 2010 --end 2024
#   bash agro_pipeline.sh all --vars shum,air --levels 1000,850 --start 2020 --end 2022
#   bash agro_pipeline.sh update                      # for cron/GitHub Actions
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OUTDIR="$(pwd)/NOAA"
SHARED_PY="${SCRIPT_DIR}/agro_pipeline.py"

BASE_URL_DAILY="https://downloads.psl.noaa.gov/Datasets/ncep.reanalysis/Dailies/pressure"
BASE_URL_SURFACE="https://downloads.psl.noaa.gov/Datasets/ncep.reanalysis/Dailies/surface"
BASE_URL_CHIRPS="https://data.chc.ucsb.edu/products/CHIRPS-2.0/global_daily/netcdf/p25"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}>>> $* ${NC}\n"; }

# Tanzania region defaults, shared by every subcommand that plots.
DOMAIN_LAT_MIN_DEFAULT=-12.5; DOMAIN_LAT_MAX_DEFAULT=1.5
DOMAIN_LON_MIN_DEFAULT=28.5;  DOMAIN_LON_MAX_DEFAULT=41.5
AVG_LAT_MIN_DEFAULT=-11.8;    AVG_LAT_MAX_DEFAULT=-0.9
AVG_LON_MIN_DEFAULT=29.3;     AVG_LON_MAX_DEFAULT=40.9
DODOMA_LAT=-6.1630; DODOMA_LON=35.7516

show_top_help() {
    awk '/^# =+$/{c++; next} c==2' "$0" | sed 's/^# //; s/^#//'
    exit 0
}

if [[ $# -eq 0 ]]; then show_top_help; fi
case "$1" in
    --help|-h) show_top_help ;;
    noaa|chirps|all|update) SUBCOMMAND="$1"; shift ;;
    *) log_error "Unknown subcommand: $1"; echo; show_top_help ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Shared helpers
# ─────────────────────────────────────────────────────────────────────────────
SURFACE_VARS=("slp" "pres.sfc" "pr_wtr.eatm" "air.sig995" "uwnd.sig995" "vwnd.sig995" "rhum.sig995" "omega.sig995")
PRESSURE_VARS=("shum" "uwnd" "vwnd" "air" "omega" "hgt" "rhum")

is_surface_var() {
    local v="$1"
    for sv in "${SURFACE_VARS[@]}"; do [[ "$sv" == "$v" ]] && return 0; done
    return 1
}

check_dep() {
    if command -v "$1" &>/dev/null; then
        log_success "$1 found: $(command -v "$1")"
    else
        log_error "$1 not found. Please install it."
        [[ "${2:-}" == "required" ]] && exit 1
    fi
}

check_common_deps() {
    log_section "Checking Dependencies"
    check_dep wget required
    check_dep cdo  required
    check_dep python3 required
    check_dep ncrcat optional
    check_dep ncks   optional
    python3 -c "import xarray, matplotlib, numpy, pandas" 2>/dev/null \
        && log_success "Core Python packages found" \
        || { log_error "Missing Python packages. Run: pip install xarray matplotlib numpy pandas scipy cartopy requests"; exit 1; }
    python3 -c "import cartopy" 2>/dev/null \
        && log_success "cartopy found" \
        || log_warn "cartopy not found -- spatial maps will be skipped. Install: pip install cartopy"
}

detect_latest_available_year() {
    local probe_var="$1" probe_base candidate
    if is_surface_var "$probe_var"; then probe_base="$BASE_URL_SURFACE"; else probe_base="$BASE_URL_DAILY"; fi
    candidate=$(date +%Y)
    while [[ "$candidate" -ge 1948 ]]; do
        if wget -q --spider --timeout=15 --tries=2 "${probe_base}/${probe_var}.${candidate}.nc" 2>/dev/null; then
            echo "$candidate"; return 0
        fi
        candidate=$((candidate - 1))
    done
    echo ""
}

detect_latest_chirps_year() {
    local candidate; candidate=$(date +%Y)
    while [[ "$candidate" -ge 1981 ]]; do
        if wget -q --spider --timeout=15 --tries=2 "${BASE_URL_CHIRPS}/chirps-v2.0.${candidate}.days_p25.nc" 2>/dev/null; then
            echo "$candidate"; return 0
        fi
        candidate=$((candidate - 1))
    done
    echo ""
}

# One aggregation case, shared by NOAA (mean-based) and CHIRPS (sum-based).
# The caller sets MONTH_OP/SEAS_OP/ANNUAL_OP/DEKAD_OP/PENTAD_OP beforehand.
run_aggregation() {
    local AGGR="$1" BASE_NC="$2" PREFIX="$3" VAR="$4" START_YEAR="$5" END_YEAR="$6" OUT_NC="$7" AGG_DIR="$8"
    local STEP_OK=true
    case "$AGGR" in
        daily)   cp "$BASE_NC" "$OUT_NC" || STEP_OK=false ;;
        monthly) cdo -O -f nc4 -z zip_6 "${MONTH_OP:-monmean}" "$BASE_NC" "$OUT_NC" || STEP_OK=false ;;
        seasonal)
            local SEAS_TMP="${AGG_DIR}/${PREFIX}_seasonal_tmp.nc"
            cdo -O -f nc4 -z zip_6 "${SEAS_OP:-seasmean}" "$BASE_NC" "$SEAS_TMP" || STEP_OK=false
            if $STEP_OK; then cdo -O -f nc4 -z zip_6 -select,month=3,6,9,12 "$SEAS_TMP" "$OUT_NC" || STEP_OK=false; fi
            rm -f "$SEAS_TMP" ;;
        annual)  cdo -O -f nc4 -z zip_6 "${ANNUAL_OP:-yearmean}" "$BASE_NC" "$OUT_NC" || STEP_OK=false ;;
        climatology) cdo -O -f nc4 -z zip_6 ydaymean "$BASE_NC" "$OUT_NC" || STEP_OK=false ;;
        anomaly)
            local CLIM_NC="${AGG_DIR}/${PREFIX}_climatology_${START_YEAR}_${END_YEAR}.nc"
            if [[ ! -f "$CLIM_NC" ]]; then
                cdo -O -f nc4 -z zip_6 ydaymean "$BASE_NC" "$CLIM_NC" || STEP_OK=false
            fi
            if $STEP_OK; then cdo -O -f nc4 -z zip_6 ydaysub "$BASE_NC" "$CLIM_NC" "$OUT_NC" || STEP_OK=false; fi ;;
        dekad)   python3 "$SHARED_PY" period-aggregate --nc "$BASE_NC" --var "$VAR" --period dekad --stat "${DEKAD_OP:-mean}" --out "$OUT_NC" || STEP_OK=false ;;
        pentad)  python3 "$SHARED_PY" period-aggregate --nc "$BASE_NC" --var "$VAR" --period pentad --stat "${PENTAD_OP:-mean}" --out "$OUT_NC" || STEP_OK=false ;;
        *) log_warn "Unknown aggregation: '${AGGR}'. Skipping."; return 2 ;;
    esac
    if $STEP_OK && [[ -s "$OUT_NC" ]]; then
        log_success "${AGGR} -> ${OUT_NC}"; return 0
    else
        log_error "${AGGR} aggregation failed."; rm -f "$OUT_NC"; return 1
    fi
}

# Domain-crop + area-average args, shared by every subcommand that plots.
# Built once per run since the region doesn't vary per-aggregation.
build_region_args() {
    DOMAIN_ARGS=()
    if [[ -n "${DOMAIN_LAT_MIN:-}" && -n "${DOMAIN_LAT_MAX:-}" && -n "${DOMAIN_LON_MIN:-}" && -n "${DOMAIN_LON_MAX:-}" ]]; then
        DOMAIN_ARGS=(--lat-min "$DOMAIN_LAT_MIN" --lat-max "$DOMAIN_LAT_MAX" --lon-min "$DOMAIN_LON_MIN" --lon-max "$DOMAIN_LON_MAX")
    fi
    AREA_AVG_ARGS=()
    if [[ "${AREA_AVERAGE:-true}" == "true" ]]; then
        AREA_AVG_ARGS=(--area-average --avg-lat-min "$AVG_LAT_MIN" --avg-lat-max "$AVG_LAT_MAX" --avg-lon-min "$AVG_LON_MIN" --avg-lon-max "$AVG_LON_MAX")
    fi
}

run_plot_step() {
    local AGG_DIR="$1" PLOT_DIR="$2" VAR="$3" LEVEL="$4" PREFIX="$5" \
          USER_LAT="$6" USER_LON="$7" PLOT_TYPE="$8" AGGR="$9" START_YEAR="${10}" END_YEAR="${11}"
    local NC_FILE="${AGG_DIR}/${PREFIX}_${AGGR}_${START_YEAR}_${END_YEAR}.nc"
    [[ -f "$NC_FILE" ]] || { log_warn "Aggregated file not found for ${AGGR}: ${NC_FILE} -- skipping plot"; return 0; }
    log_info "Plotting ${AGGR} (${VAR} @ ${LEVEL})"
    python3 "$SHARED_PY" plot --nc "$NC_FILE" --var "$VAR" --lat "$USER_LAT" --lon "$USER_LON" \
        --plot-type "$PLOT_TYPE" --aggr "$AGGR" --level "$LEVEL" --outdir "$PLOT_DIR" --dpi 150 --format png \
        "${DOMAIN_ARGS[@]}" "${AREA_AVG_ARGS[@]}"
}

run_upload_step() {
    local PLOT_DIR="$1" VAR="$2" LEVEL="$3" START_YEAR="$4" END_YEAR="$5"
    if [[ -z "${SUPABASE_URL:-}" || -z "${SUPABASE_SERVICE_KEY:-}" ]]; then
        log_warn "SUPABASE_URL / SUPABASE_SERVICE_KEY not set -- skipping upload."
        return 0
    fi
    python3 "$SHARED_PY" upload --plots-dir "$PLOT_DIR" --var "$VAR" --level "$LEVEL" \
        --start-year "$START_YEAR" --end-year "$END_YEAR" --prefix "${VAR}/"
}

# =============================================================================
# Subcommand: noaa
# =============================================================================
run_noaa() {
    local VAR="shum" LEVEL="850" START_YEAR="all" END_YEAR="all"
    local AGGREGATIONS="daily,monthly,seasonal,annual,dekad,pentad"
    local LAUNCH_PLOT=true USER_LAT="$DODOMA_LAT" USER_LON="$DODOMA_LON" PLOT_TYPE="both"
    local AREA_AVERAGE=true CLEAN_RAW=false OUTDIR="$DEFAULT_OUTDIR"
    local DOMAIN_LAT_MIN="$DOMAIN_LAT_MIN_DEFAULT" DOMAIN_LAT_MAX="$DOMAIN_LAT_MAX_DEFAULT"
    local DOMAIN_LON_MIN="$DOMAIN_LON_MIN_DEFAULT" DOMAIN_LON_MAX="$DOMAIN_LON_MAX_DEFAULT"
    local AVG_LAT_MIN="$AVG_LAT_MIN_DEFAULT" AVG_LAT_MAX="$AVG_LAT_MAX_DEFAULT"
    local AVG_LON_MIN="$AVG_LON_MIN_DEFAULT" AVG_LON_MAX="$AVG_LON_MAX_DEFAULT"
    local MONTH_OP="monmean" SEAS_OP="seasmean" ANNUAL_OP="yearmean" DEKAD_OP="mean" PENTAD_OP="mean"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --var) VAR="$2"; shift 2 ;;
            --level) LEVEL="$2"; shift 2 ;;
            --start) START_YEAR="$2"; shift 2 ;;
            --end) END_YEAR="$2"; shift 2 ;;
            --aggr) AGGREGATIONS="$2"; shift 2 ;;
            --plot) LAUNCH_PLOT="$2"; shift 2 ;;
            --lat) USER_LAT="$2"; shift 2 ;;
            --lon) USER_LON="$2"; shift 2 ;;
            --plot-type) PLOT_TYPE="$2"; shift 2 ;;
            --lat-min) DOMAIN_LAT_MIN="$2"; shift 2 ;;
            --lat-max) DOMAIN_LAT_MAX="$2"; shift 2 ;;
            --lon-min) DOMAIN_LON_MIN="$2"; shift 2 ;;
            --lon-max) DOMAIN_LON_MAX="$2"; shift 2 ;;
            --global) DOMAIN_LAT_MIN=""; DOMAIN_LAT_MAX=""; DOMAIN_LON_MIN=""; DOMAIN_LON_MAX=""; shift ;;
            --point) AREA_AVERAGE=false; shift ;;
            --avg-lat-min) AVG_LAT_MIN="$2"; shift 2 ;;
            --avg-lat-max) AVG_LAT_MAX="$2"; shift 2 ;;
            --avg-lon-min) AVG_LON_MIN="$2"; shift 2 ;;
            --avg-lon-max) AVG_LON_MAX="$2"; shift 2 ;;
            --clean-raw) CLEAN_RAW="$2"; shift 2 ;;
            --outdir) OUTDIR="$2"; shift 2 ;;
            --help|-h) echo "Usage: agro_pipeline.sh noaa --var V --level L [--start Y] [--end Y] [--aggr a,b,c] [--point --lat N --lon N] [--global] [--outdir PATH]"; return 0 ;;
            *) log_error "noaa: unknown option: $1"; return 1 ;;
        esac
    done

    if is_surface_var "$VAR"; then local BASE_URL="$BASE_URL_SURFACE" IS_PRESSURE_LEVEL=false
    else local BASE_URL="$BASE_URL_DAILY" IS_PRESSURE_LEVEL=true; fi

    local RAW_DIR="${OUTDIR}/raw/${VAR}" AGG_DIR="${OUTDIR}/aggregated/${VAR}" PLOT_DIR="${OUTDIR}/plots/${VAR}" LOG_DIR="${OUTDIR}/logs"
    mkdir -p "$RAW_DIR" "$AGG_DIR" "$PLOT_DIR" "$LOG_DIR"
    local MERGED_FILE="${AGG_DIR}/${VAR}_daily_${START_YEAR}_${END_YEAR}.nc"
    local LOG_FILE="${LOG_DIR}/pipeline_${VAR}_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "$LOG_FILE") 2>&1

    check_common_deps

    if [[ "$START_YEAR" == "all" || "$END_YEAR" == "all" ]]; then
        log_section "Resolving 'all' year range for ${VAR}"
        [[ "$START_YEAR" == "all" ]] && START_YEAR=1948 && log_info "Start year -> 1948"
        if [[ "$END_YEAR" == "all" ]]; then
            local DETECTED_END; DETECTED_END="$(detect_latest_available_year "$VAR")"
            [[ -z "$DETECTED_END" ]] && { log_error "Could not auto-detect latest year."; exit 1; }
            END_YEAR="$DETECTED_END"; log_info "End year -> ${END_YEAR}"
        fi
    fi

    log_section "Step 1: Downloading ${VAR} Daily Data (${START_YEAR}-${END_YEAR})"
    local DOWNLOAD_COUNT=0 SKIP_COUNT=0 FAIL_COUNT=0 FAILED_YEARS=()
    for YEAR in $(seq "$START_YEAR" "$END_YEAR"); do
        local URL="${BASE_URL}/${VAR}.${YEAR}.nc" OUTFILE="${RAW_DIR}/${VAR}.${YEAR}.nc"
        if [[ -f "$OUTFILE" ]]; then
            if cdo -s info "$OUTFILE" &>/dev/null; then log_info "Skipping ${YEAR} -- exists."; ((SKIP_COUNT++)) || true; continue
            else log_warn "${YEAR} corrupt, re-downloading..."; rm -f "$OUTFILE"; fi
        fi
        log_info "Downloading ${VAR} for ${YEAR}..."
        if wget -q --timeout=60 --tries=3 --retry-connrefused -O "$OUTFILE" "$URL" 2>&1; then
            log_success "Downloaded ${YEAR}"; ((DOWNLOAD_COUNT++)) || true
        else
            log_error "Failed: ${YEAR}"; rm -f "$OUTFILE"; FAILED_YEARS+=("$YEAR"); ((FAIL_COUNT++)) || true
        fi
    done
    log_info "Downloaded: ${DOWNLOAD_COUNT}, Skipped: ${SKIP_COUNT}, Failed: ${FAIL_COUNT}"
    [[ ${#FAILED_YEARS[@]} -gt 0 ]] && log_warn "Failed years: ${FAILED_YEARS[*]}"

    local AVAIL_FILES=( "${RAW_DIR}/${VAR}".*.nc )
    [[ ${#AVAIL_FILES[@]} -eq 0 ]] && { log_error "No files to merge."; exit 1; }

    log_section "Step 2: Merging"
    if [[ -f "$MERGED_FILE" ]]; then log_warn "Merged file exists: ${MERGED_FILE}"
    else cdo -O -f nc4 -z zip_6 mergetime "${RAW_DIR}/${VAR}".*.nc "$MERGED_FILE" || { log_error "Merge failed."; exit 1; }
         log_success "Merged -> ${MERGED_FILE}"; fi

    log_section "Step 3: Pressure Level Extraction (${LEVEL})"
    local LEVEL_FILE="${AGG_DIR}/${VAR}_${LEVEL}hPa_daily_${START_YEAR}_${END_YEAR}.nc" BASE_NC
    if $IS_PRESSURE_LEVEL; then
        if [[ -f "$LEVEL_FILE" ]]; then log_warn "Level file exists."
        else cdo -O -f nc4 -z zip_6 sellevel,"$LEVEL" "$MERGED_FILE" "$LEVEL_FILE"; log_success "Extracted -> ${LEVEL_FILE}"; fi
        BASE_NC="$LEVEL_FILE"
    else BASE_NC="$MERGED_FILE"; fi

    log_section "Step 4: Aggregations (${AGGREGATIONS})"
    local PREFIX="${VAR}_${LEVEL}hPa"
    IFS=',' read -ra AGGR_LIST <<< "$AGGREGATIONS"
    local AGGR_FAIL_COUNT=0 AGGR_FAILED_LIST=()
    for AGGR in "${AGGR_LIST[@]}"; do
        AGGR=$(echo "$AGGR" | xargs)
        local OUT_NC="${AGG_DIR}/${PREFIX}_${AGGR}_${START_YEAR}_${END_YEAR}.nc"
        [[ -f "$OUT_NC" ]] && { log_warn "${AGGR} exists, skipping."; continue; }
        local rc=0
        run_aggregation "$AGGR" "$BASE_NC" "$PREFIX" "$VAR" "$START_YEAR" "$END_YEAR" "$OUT_NC" "$AGG_DIR" || rc=$?
        [[ $rc -eq 1 ]] && { AGGR_FAIL_COUNT=$((AGGR_FAIL_COUNT + 1)); AGGR_FAILED_LIST+=("$AGGR"); }
    done
    [[ $AGGR_FAIL_COUNT -gt 0 ]] && log_warn "Aggregations with problems: ${AGGR_FAILED_LIST[*]}"

    if [[ "$CLEAN_RAW" == "true" ]] && [[ $AGGR_FAIL_COUNT -eq 0 ]]; then
        log_section "Step 4b: Cleaning Raw Data"
        rm -f "${RAW_DIR}"/*.nc; rmdir "$RAW_DIR" 2>/dev/null || true
        [[ "$MERGED_FILE" != "$LEVEL_FILE" ]] && rm -f "$MERGED_FILE"
        log_success "Raw data cleaned."
    fi

    build_region_args
    if [[ "$LAUNCH_PLOT" == "true" ]]; then
        log_section "Step 5: Plotting"
        if [[ -n "$DOMAIN_LAT_MIN" ]]; then log_info "Spatial maps cropped to Tanzania region"; else log_info "Spatial maps: global (--global set)"; fi
        if [[ "$AREA_AVERAGE" == "true" ]]; then log_info "Sample series: Tanzania-wide average"; else log_info "Sample series: point lat=${USER_LAT}, lon=${USER_LON}"; fi
        for AGGR in "${AGGR_LIST[@]}"; do
            AGGR=$(echo "$AGGR" | xargs)
            run_plot_step "$AGG_DIR" "$PLOT_DIR" "$VAR" "$LEVEL" "$PREFIX" "$USER_LAT" "$USER_LON" "$PLOT_TYPE" "$AGGR" "$START_YEAR" "$END_YEAR" \
                && log_success "Plot completed for ${AGGR}" || log_error "Plotting failed for ${AGGR}"
        done
    else
        log_info "Skipping plotting (--plot false)"
    fi

    log_section "Step 6: Uploading to Supabase"
    run_upload_step "$PLOT_DIR" "$VAR" "$LEVEL" "$START_YEAR" "$END_YEAR" \
        && log_success "Upload finished" || log_error "Upload failed -- check output above"

    log_section "Pipeline Complete (NOAA)"
    echo -e "${GREEN}Variable:${NC} ${VAR} @ ${LEVEL} | ${GREEN}Period:${NC} ${START_YEAR}-${END_YEAR} | ${GREEN}Aggregations:${NC} ${AGGREGATIONS}"
    log_success "All done!"
}

# =============================================================================
# Subcommand: chirps
# =============================================================================
# Rainfall is ACCUMULATIVE, not a state variable -- period aggregations use
# SUM (a monthly value is the monthly TOTAL), not mean. Climatology/anomaly
# stay mean-based (the typical/actual value for a given calendar day).
run_chirps() {
    local START_YEAR="all" END_YEAR="all"
    local AGGREGATIONS="daily,monthly,seasonal,annual,dekad,pentad,climatology,anomaly"
    local LAUNCH_PLOT=true PLOT_TYPE="both" AREA_AVERAGE=true CLEAN_RAW=false OUTDIR="$DEFAULT_OUTDIR"
    local USER_LAT="$DODOMA_LAT" USER_LON="$DODOMA_LON"
    local DOMAIN_LAT_MIN="$DOMAIN_LAT_MIN_DEFAULT" DOMAIN_LAT_MAX="$DOMAIN_LAT_MAX_DEFAULT"
    local DOMAIN_LON_MIN="$DOMAIN_LON_MIN_DEFAULT" DOMAIN_LON_MAX="$DOMAIN_LON_MAX_DEFAULT"
    local AVG_LAT_MIN="$AVG_LAT_MIN_DEFAULT" AVG_LAT_MAX="$AVG_LAT_MAX_DEFAULT"
    local AVG_LON_MIN="$AVG_LON_MIN_DEFAULT" AVG_LON_MAX="$AVG_LON_MAX_DEFAULT"
    local MONTH_OP="monsum" SEAS_OP="seassum" ANNUAL_OP="yearsum" DEKAD_OP="sum" PENTAD_OP="sum"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --start) START_YEAR="$2"; shift 2 ;;
            --end) END_YEAR="$2"; shift 2 ;;
            --aggr) AGGREGATIONS="$2"; shift 2 ;;
            --plot) LAUNCH_PLOT="$2"; shift 2 ;;
            --plot-type) PLOT_TYPE="$2"; shift 2 ;;
            --point) AREA_AVERAGE=false; shift ;;
            --lat) USER_LAT="$2"; shift 2 ;;
            --lon) USER_LON="$2"; shift 2 ;;
            --lat-min) DOMAIN_LAT_MIN="$2"; shift 2 ;;
            --lat-max) DOMAIN_LAT_MAX="$2"; shift 2 ;;
            --lon-min) DOMAIN_LON_MIN="$2"; shift 2 ;;
            --lon-max) DOMAIN_LON_MAX="$2"; shift 2 ;;
            --global) DOMAIN_LAT_MIN=""; DOMAIN_LAT_MAX=""; DOMAIN_LON_MIN=""; DOMAIN_LON_MAX=""; shift ;;
            --clean-raw) CLEAN_RAW="$2"; shift 2 ;;
            --outdir) OUTDIR="$2"; shift 2 ;;
            --help|-h) echo "Usage: agro_pipeline.sh chirps [--start Y] [--end Y] [--aggr a,b,c] [--outdir PATH]"; return 0 ;;
            *) log_error "chirps: unknown option: $1"; return 1 ;;
        esac
    done

    local VAR="precip" LEVEL="sfc"
    local RAW_DIR="${OUTDIR}/raw/${VAR}" AGG_DIR="${OUTDIR}/aggregated/${VAR}" PLOT_DIR="${OUTDIR}/plots/${VAR}" LOG_DIR="${OUTDIR}/logs"
    mkdir -p "$RAW_DIR" "$AGG_DIR" "$PLOT_DIR" "$LOG_DIR"

    log_section "CHIRPS v2.0 Rainfall Pipeline"
    check_common_deps

    if [[ "$START_YEAR" == "all" || "$END_YEAR" == "all" ]]; then
        [[ "$START_YEAR" == "all" ]] && START_YEAR=1981 && log_info "Start year -> 1981"
        if [[ "$END_YEAR" == "all" ]]; then
            local DETECTED_END; DETECTED_END="$(detect_latest_chirps_year)"
            [[ -z "$DETECTED_END" ]] && { log_error "Could not auto-detect latest year."; exit 1; }
            END_YEAR="$DETECTED_END"; log_info "End year -> ${END_YEAR}"
        fi
    fi

    log_section "Step 1: Downloading CHIRPS (${START_YEAR}-${END_YEAR})"
    for YEAR in $(seq "$START_YEAR" "$END_YEAR"); do
        local OUT_FILE="${RAW_DIR}/chirps-v2.0.${YEAR}.days_p25.nc"
        [[ -f "$OUT_FILE" && -s "$OUT_FILE" ]] && { log_info "Already have ${YEAR}."; continue; }
        log_info "Downloading ${YEAR}..."
        if wget -q --timeout=60 --tries=3 -O "$OUT_FILE" "${BASE_URL_CHIRPS}/chirps-v2.0.${YEAR}.days_p25.nc"; then
            log_success "${YEAR} -> ${OUT_FILE}"
        else log_error "Failed: ${YEAR}"; rm -f "$OUT_FILE"; fi
    done

    log_section "Step 2: Merging + Normalizing Dimensions"
    local MERGED_RAW="${AGG_DIR}/${VAR}_merged_raw_${START_YEAR}_${END_YEAR}.nc"
    local MERGED_FILE="${AGG_DIR}/${VAR}_daily_${START_YEAR}_${END_YEAR}.nc"
    if [[ -f "$MERGED_FILE" ]]; then log_info "Already merged: ${MERGED_FILE}"
    else
        local YEAR_FILES=()
        for YEAR in $(seq "$START_YEAR" "$END_YEAR"); do
            local F="${RAW_DIR}/chirps-v2.0.${YEAR}.days_p25.nc"; [[ -f "$F" ]] && YEAR_FILES+=("$F")
        done
        [[ ${#YEAR_FILES[@]} -eq 0 ]] && { log_error "No files to merge."; exit 1; }
        cdo -O -f nc4 -z zip_6 mergetime "${YEAR_FILES[@]}" "$MERGED_RAW" || { log_error "Merge failed."; exit 1; }
        # CHIRPS ships dims "latitude"/"longitude" -- normalize to "lat"/"lon"
        # (the NOAA convention) so agro_pipeline.py needs zero CHIRPS-specific code.
        cdo -O -f nc4 -z zip_6 chname,latitude,lat -chname,longitude,lon "$MERGED_RAW" "$MERGED_FILE" || { log_error "Rename failed."; exit 1; }
        rm -f "$MERGED_RAW"; log_success "Merged + normalized -> ${MERGED_FILE}"
    fi
    local BASE_NC="$MERGED_FILE"

    log_section "Step 3: Aggregations (${AGGREGATIONS}, sum-based where applicable)"
    local PREFIX="${VAR}_${LEVEL}hPa"
    IFS=',' read -ra AGGR_LIST <<< "$AGGREGATIONS"
    local AGGR_FAIL_COUNT=0 AGGR_FAILED_LIST=()
    for AGGR in "${AGGR_LIST[@]}"; do
        AGGR=$(echo "$AGGR" | xargs)
        local OUT_NC="${AGG_DIR}/${PREFIX}_${AGGR}_${START_YEAR}_${END_YEAR}.nc"
        [[ -f "$OUT_NC" ]] && { log_info "${AGGR} exists, skipping."; continue; }
        local rc=0
        run_aggregation "$AGGR" "$BASE_NC" "$PREFIX" "$VAR" "$START_YEAR" "$END_YEAR" "$OUT_NC" "$AGG_DIR" || rc=$?
        [[ $rc -eq 1 ]] && { AGGR_FAIL_COUNT=$((AGGR_FAIL_COUNT + 1)); AGGR_FAILED_LIST+=("$AGGR"); }
    done
    [[ $AGGR_FAIL_COUNT -gt 0 ]] && log_warn "Aggregations with problems: ${AGGR_FAILED_LIST[*]}"

    if [[ "$CLEAN_RAW" == "true" ]] && [[ $AGGR_FAIL_COUNT -eq 0 ]]; then
        rm -f "${RAW_DIR}"/*.nc; rmdir "$RAW_DIR" 2>/dev/null || true; rm -f "$MERGED_FILE"
        log_success "Raw data cleaned."
    fi

    build_region_args
    if [[ "$LAUNCH_PLOT" == "true" ]]; then
        log_section "Step 4: Plotting"
        for AGGR in "${AGGR_LIST[@]}"; do
            AGGR=$(echo "$AGGR" | xargs)
            run_plot_step "$AGG_DIR" "$PLOT_DIR" "$VAR" "$LEVEL" "$PREFIX" "$USER_LAT" "$USER_LON" "$PLOT_TYPE" "$AGGR" "$START_YEAR" "$END_YEAR" \
                || log_warn "Plotting failed for ${AGGR} -- continuing."
        done
    fi

    log_section "Step 5: Uploading to Supabase"
    run_upload_step "$PLOT_DIR" "$VAR" "$LEVEL" "$START_YEAR" "$END_YEAR" \
        && log_success "Upload finished" || log_error "Upload failed -- check output above"

    log_section "Done (CHIRPS)"
    log_success "All done!"
}

# =============================================================================
# Subcommand: all
# =============================================================================
run_all() {
    local START_YEAR="all" END_YEAR="all" AGGREGATIONS="daily,monthly,seasonal,annual,dekad,pentad"
    local GENERATE_STATIC_PLOTS=true CLEAN_RAW=false OUTDIR="" SKIP_CHIRPS=false SKIP_SURFACE=false
    local VARS_OVERRIDE="" LEVELS_OVERRIDE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --start) START_YEAR="$2"; shift 2 ;;
            --end) END_YEAR="$2"; shift 2 ;;
            --aggr) AGGREGATIONS="$2"; shift 2 ;;
            --vars) VARS_OVERRIDE="$2"; shift 2 ;;
            --levels) LEVELS_OVERRIDE="$2"; shift 2 ;;
            --outdir) OUTDIR="$2"; shift 2 ;;
            --skip-static-plots) GENERATE_STATIC_PLOTS=false; shift ;;
            --skip-chirps) SKIP_CHIRPS=true; shift ;;
            --skip-surface) SKIP_SURFACE=true; shift ;;
            --clean-raw) CLEAN_RAW=true; shift ;;
            --help|-h)
                echo "Usage: agro_pipeline.sh all [--vars v1,v2] [--levels l1,l2] [--start Y] [--end Y] [--skip-chirps] [--skip-surface] [--skip-static-plots]"
                return 0 ;;
            *) log_error "all: unknown option: $1"; return 1 ;;
        esac
    done

    local PRESSURE_LEVELS_FULL=(1000 925 850 700 600 500 400 300 250 200 150 100 70 50 30 20 10)
    local PRESSURE_LEVELS_HUMIDITY=(1000 925 850 700 600 500 400 300)
    local PRESSURE_LEVELS_OMEGA=(1000 925 850 700 600 500 400 300 250 200 150 100)
    levels_for_var() {
        [[ -n "$LEVELS_OVERRIDE" ]] && { echo "$LEVELS_OVERRIDE" | tr ',' ' '; return; }
        case "$1" in
            shum|rhum) echo "${PRESSURE_LEVELS_HUMIDITY[@]}" ;;
            omega)     echo "${PRESSURE_LEVELS_OMEGA[@]}" ;;
            *)         echo "${PRESSURE_LEVELS_FULL[@]}" ;;
        esac
    }
    local PRESSURE_VARIABLES=(air hgt omega rhum shum uwnd vwnd)
    [[ -n "$VARS_OVERRIDE" ]] && IFS=',' read -ra PRESSURE_VARIABLES <<< "$VARS_OVERRIDE"
    local SURFACE_COMBOS=("slp:sfc" "pres.sfc:sfc" "pr_wtr.eatm:sfc" "air.sig995:sfc" "uwnd.sig995:sfc" "vwnd.sig995:sfc" "rhum.sig995:sfc" "omega.sig995:sfc")

    local COMBOS=()
    for v in "${PRESSURE_VARIABLES[@]}"; do
        for lvl in $(levels_for_var "$v"); do COMBOS+=("${v}:${lvl}"); done
    done
    $SKIP_SURFACE || COMBOS+=("${SURFACE_COMBOS[@]}")

    local EFFECTIVE_OUTDIR="${OUTDIR:-$DEFAULT_OUTDIR}"
    local TOTAL=${#COMBOS[@]} OK=0 FAILED=()

    echo "Running ${TOTAL} NOAA combinations (${START_YEAR}-${END_YEAR}). Skip CHIRPS: ${SKIP_CHIRPS}"
    for i in "${!COMBOS[@]}"; do
        IFS=':' read -r VAR LEVEL <<< "${COMBOS[$i]}"
        echo "── [$((i+1))/$TOTAL] ${VAR} @ ${LEVEL} ──"
        if bash "$0" noaa --var "$VAR" --level "$LEVEL" --start "$START_YEAR" --end "$END_YEAR" \
            --aggr "$AGGREGATIONS" --plot "$GENERATE_STATIC_PLOTS" --clean-raw "$CLEAN_RAW" --outdir "$EFFECTIVE_OUTDIR"; then
            OK=$((OK + 1))
        else
            FAILED+=("${VAR}:${LEVEL}"); echo "!! Failed: ${VAR}:${LEVEL} -- continuing"
        fi
    done

    if ! $SKIP_CHIRPS; then
        echo "── [CHIRPS] precip @ sfc ──"
        bash "$0" chirps --start "$START_YEAR" --end "$END_YEAR" --plot "$GENERATE_STATIC_PLOTS" --clean-raw "$CLEAN_RAW" --outdir "$EFFECTIVE_OUTDIR" \
            || FAILED+=("precip:sfc")
    fi

    echo "=============================================================="
    echo "NOAA: ${OK}/${TOTAL} succeeded."
    [[ ${#FAILED[@]} -gt 0 ]] && { echo "Failed: ${FAILED[*]}"; exit 1; }
    echo "All done."
}

# =============================================================================
# Subcommand: update -- incremental, cheap, designed for cron/GitHub Actions
# =============================================================================
# No server, no admin token, no SSE stream -- just a plain CLI command that
# exits 0 or 1. Trigger it however you like: a cron line, a GitHub Actions
# workflow_dispatch button, or by hand. Records progress in
# $OUTDIR/.state/last_update so a second run the same day is a fast no-op.
run_update() {
    local OUTDIR="$DEFAULT_OUTDIR" SOURCES="noaa,chirps"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --outdir) OUTDIR="$2"; shift 2 ;;
            --sources) SOURCES="$2"; shift 2 ;;
            --help|-h) echo "Usage: agro_pipeline.sh update [--outdir PATH] [--sources noaa,chirps]"; return 0 ;;
            *) log_error "update: unknown option: $1"; return 1 ;;
        esac
    done

    if [[ ! -d "$OUTDIR/aggregated" ]]; then
        log_error "OUTDIR/aggregated not found. Run 'noaa'/'chirps'/'all' at least once first."
        return 2
    fi
    mkdir -p "${OUTDIR}/.state"

    log_section "Incremental update"
    local FAILED=0
    IFS=',' read -ra SRC_LIST <<< "$SOURCES"
    for SRC in "${SRC_LIST[@]}"; do
        SRC=$(echo "$SRC" | xargs)
        case "$SRC" in
            noaa)
                # NCEP Reanalysis I is frozen (last date 2026-03-17, per
                # NOAA) -- this just confirms that and logs it. If NOAA
                # ever resumes, extend one representative var then widen.
                local latest; latest="$(detect_latest_available_year shum)"
                if [[ -n "$latest" && "$latest" -gt 2026 ]]; then
                    log_info "New NOAA data detected (latest year: ${latest})"
                    bash "$0" noaa --var shum --level 850 --start 2027 --end "$latest" \
                        --outdir "$OUTDIR" --plot false --clean-raw true || FAILED=$((FAILED + 1))
                else
                    log_info "No new NOAA data (dataset frozen). No-op."
                fi ;;
            chirps)
                # CHIRPS publishes the current year-to-date daily -- pull
                # only if the current year's file has actually changed.
                local YEAR; YEAR=$(date +%Y)
                local URL="${BASE_URL_CHIRPS}/chirps-v2.0.${YEAR}.days_p25.nc"
                local RAW_DIR="${OUTDIR}/raw/precip" NEW_FILE="${RAW_DIR}/chirps-v2.0.${YEAR}.days_p25.nc"
                mkdir -p "$RAW_DIR"
                local SERVER_SIZE; SERVER_SIZE=$(curl -sIL --max-time 20 "$URL" | awk -v IGNORECASE=1 '/^content-length:/ {print $2}' | tr -d '\r' | tail -1)
                if [[ -z "$SERVER_SIZE" ]]; then
                    log_warn "Could not probe CHIRPS server. Skipping."
                else
                    local LOCAL_SIZE=0; [[ -f "$NEW_FILE" ]] && LOCAL_SIZE=$(stat -c%s "$NEW_FILE" 2>/dev/null || echo 0)
                    if [[ "$SERVER_SIZE" == "$LOCAL_SIZE" ]]; then
                        log_info "CHIRPS already up to date."
                    else
                        log_info "CHIRPS has new data (server=${SERVER_SIZE}, local=${LOCAL_SIZE}) -- re-running full chirps year ${YEAR}."
                        # Simplicity over cleverness: re-run just the current
                        # year (fast -- one file) rather than a delta-merge.
                        rm -f "${OUTDIR}/aggregated/precip/precip_sfchPa_"*"_${YEAR}_${YEAR}.nc" 2>/dev/null || true
                        bash "$0" chirps --start "$YEAR" --end "$YEAR" --outdir "$OUTDIR" --plot false || FAILED=$((FAILED + 1))
                    fi
                fi ;;
            *) log_warn "Unknown source: '${SRC}'" ;;
        esac
    done

    if [[ $FAILED -eq 0 ]]; then
        date -u +%Y-%m-%dT%H:%M:%SZ > "${OUTDIR}/.state/last_update"
        log_success "Update complete."
        return 0
    else
        log_error "Update finished with ${FAILED} source(s) failing."
        return 1
    fi
}

# =============================================================================
# Dispatch
# =============================================================================
case "$SUBCOMMAND" in
    noaa)   run_noaa   "$@" ;;
    chirps) run_chirps "$@" ;;
    all)    run_all    "$@" ;;
    update) run_update "$@" ;;
esac

#!/usr/bin/env bash
# ==============================================================================
# File:        Find_WP_Senior.sh
# Project:     Bash WP-CLI Update
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# Description: Discovers WordPress installations by locating wp-config.php,
#              supports multiple webroots, exclusions, per-site opt-out marker
#              (.no_wp_cli), deduplication and metadata enrichment.
#
# Usage:
#   ./Find_WP_Senior.sh [OPTIONS] [SEARCH_DIRS...]
#
# Options:
#   --output FILE      Output file with one site path per line
#   --exclude PATTERN  Exclude path or directory-name glob (repeatable)
#   --max-depth N      Limit find depth (default: 6)
#   --version          Print version and exit
#   -h, --help         Show usage and exit
#
# --exclude semantics:
#   - Starts with '/'  -> absolute path; the directory and its subtree are
#                         excluded, plus a second line of defence filters out
#                         any discovered site inside it
#   - Otherwise        -> directory NAME glob, matched against each directory
#                         component (e.g. 'node_modules', '*-backup', 'vendor')
#
# Requirements:
#   - Bash 4.2+ (CentOS 7+, RHEL, Ubuntu, Debian)
#   - GNU findutils, coreutils (find, sort, stat, mktemp, dirname)
#
# License: MIT (see LICENSE file in project root)
# Version: 2.0.0
# ==============================================================================

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2 ) )); then
    printf 'ERROR: %s requires Bash 4.2 or newer (found %s).\n' \
        "${0##*/}" "${BASH_VERSION:-unknown}" >&2
    exit 2
fi

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.0.0"

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

readonly -a DEFAULT_SEARCH_DIRS=(
    /var/www
    /usr/share/nginx/html
    /srv
    /usr/local/nginx/html
    /usr/local/var/www
    /home
)

# Directory-name globs pruned during traversal.
# NOTE: patterns are matched against a single path component only, so 'vendor'
# never accidentally matches '/var/www/ven' or '*.old' never swallows a site
# like 'golden.example.com' (that was a bug in v1.x).
readonly -a DEFAULT_NAME_EXCLUDES=(
    '.git'
    'node_modules'
    'vendor'
    '.svn'
    '.hg'
)

# Absolute paths that are never scanned / accepted.
readonly -a DEFAULT_PATH_EXCLUDES=(
    /proc
    /sys
    /dev
    /run
    /tmp
)

MAX_DEPTH=6

# ------------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------------

declare OUTPUT_FILE="${PWD}/wp-found.txt"
declare -a SEARCH_DIRS=()
declare -a NAME_EXCLUDES=()
declare -a PATH_EXCLUDES=()
declare TMP_RAW="" TMP_SORT="" TMP_DETAILS="" TMP_ERR=""

# ------------------------------------------------------------------------------
# Colors (stderr is what users see; decide on the stderr TTY)
# ------------------------------------------------------------------------------

if [[ -t 2 && "${NO_COLOR:-0}" != "1" && "${TERM:-}" != "dumb" ]]; then
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' BLUE=$'\033[0;34m' NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# ------------------------------------------------------------------------------
# Logging helpers (all diagnostics go to stderr; stdout carries machine data)
# ------------------------------------------------------------------------------

log()     { printf '%sINFO:%s %s\n' "${BLUE}" "${NC}" "$*" >&2; }
warn()    { printf '%sWARN:%s %s\n' "${YELLOW}" "${NC}" "$*" >&2; }
success() { printf '%sSUCCESS:%s %s\n' "${GREEN}" "${NC}" "$*" >&2; }
error()   { printf '%sERROR:%s %s\n' "${RED}" "${NC}" "$*" >&2; }

# ------------------------------------------------------------------------------
# is_valid_wp: minimal structural check of a suspected WordPress root
# ------------------------------------------------------------------------------

is_valid_wp() {
    local dir="$1"
    [[ -f "${dir}/wp-config.php" && -f "${dir}/wp-includes/version.php" ]]
}

# ------------------------------------------------------------------------------
# get_wp_info: owner, group and mtime in one stat round-trip
# ------------------------------------------------------------------------------

get_wp_info() {
    local dir="$1" user group date_str info
    if ! [[ -d "${dir}" ]]; then
        printf '%s\t<invalid>\t<invalid>\t<unknown>\n' "${dir}"
        return
    fi
    if info="$(stat -c '%U'$'\t''%G'$'\t''%y' "${dir}" 2>/dev/null)"; then
        IFS=$'\t' read -r user group date_str <<< "${info}"
        date_str="${date_str%%.*}"   # drop fractional seconds: YYYY-MM-DD HH:MM
        printf '%s\t%s\t%s\t%s\n' "${dir}" "${user:-<unknown>}" "${group:-<unknown>}" "${date_str:-<unknown>}"
    else
        printf '%s\t<unknown>\t<unknown>\t<unknown>\n' "${dir}"
    fi
}

# ------------------------------------------------------------------------------
# _is_excluded: second line of defence for excludes
# ------------------------------------------------------------------------------

_is_excluded() {
    local site_dir="$1" ex base
    for ex in "${PATH_EXCLUDES[@]}"; do
        [[ "${ex}" == /* ]] || continue
        if [[ "${site_dir}" == "${ex}" || "${site_dir}" == "${ex}"/* ]]; then
            return 0
        fi
    done
    base="${site_dir##*/}"
    for ex in "${NAME_EXCLUDES[@]}"; do
        [[ -z "${ex}" ]] && continue
        if [[ "${base}" == ${ex} ]]; then
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# scan_root: find wp-config.php files under one root, respecting prunes
# ------------------------------------------------------------------------------

scan_root() {
    local root="$1"
    local -a pr=()
    local first=1 p

    log "Scanning: ${root}"

    # Build the prune group: directories whose basename matches a name glob,
    # plus existing absolute path excludes.
    pr+=( -type d \( )
    for p in "${NAME_EXCLUDES[@]}"; do
        [[ -z "${p}" ]] && continue
        (( first )) || pr+=( -o )
        pr+=( -name "${p}" )
        first=0
    done
    for p in "${PATH_EXCLUDES[@]}"; do
        [[ "${p}" == /* && -e "${p}" ]] || continue
        (( first )) || pr+=( -o )
        pr+=( -path "${p}" -o -path "${p}/*" )
        first=0
    done

    local -a fargs=()
    if (( first )); then
        # no prunes at all
        fargs=( "${root}" -maxdepth "${MAX_DEPTH}" \( -type f -name wp-config.php \) -print )
    else
        pr+=( \) )
        fargs=( "${root}" -maxdepth "${MAX_DEPTH}" \( "${pr[@]}" -prune \) -o \( -type f -name wp-config.php \) -print )
    fi

    find "${fargs[@]}" 2>>"${TMP_ERR}" | while IFS= read -r config; do
        [[ -n "${config}" ]] || continue
        local site_dir
        site_dir="$(dirname "${config}")"

        if [[ -f "${site_dir}/.no_wp_cli" ]]; then
            log "Skipping ${site_dir} (contains .no_wp_cli opt-out marker)"
            continue
        fi
        if _is_excluded "${site_dir}"; then
            continue
        fi
        if is_valid_wp "${site_dir}"; then
            printf '%s\n' "${site_dir}"
        fi
    done
}

# ------------------------------------------------------------------------------
# discover_wordpress: scan roots, dedupe, enrich with metadata
# ------------------------------------------------------------------------------

discover_wordpress() {
    log "Starting WordPress discovery across ${#SEARCH_DIRS[@]} root(s)"
    log "Name exclusions: ${#NAME_EXCLUDES[@]}, path exclusions: ${#PATH_EXCLUDES[@]}"

    : > "${TMP_RAW}"

    local root
    for root in "${SEARCH_DIRS[@]}"; do
        [[ -d "${root}" && -r "${root}" ]] || { warn "Skipping unreadable/nonexistent root: ${root}"; continue; }
        scan_root "${root}" >> "${TMP_RAW}"
    done

    if ! sort -u "${TMP_RAW}" > "${TMP_SORT}"; then
        error "Failed to deduplicate results"
        exit 1
    fi

    if [[ -s "${TMP_SORT}" ]]; then
        local -a dirs=()
        mapfile -t dirs < "${TMP_SORT}"
        local dir
        for dir in "${dirs[@]}"; do
            get_wp_info "${dir}"
        done > "${TMP_DETAILS}"
    else
        : > "${TMP_DETAILS}"
    fi
}

# ------------------------------------------------------------------------------
# finalize_output: write path list, print human-readable table to stdout
# ------------------------------------------------------------------------------

finalize_output() {
    if [[ ! -s "${TMP_DETAILS}" ]]; then
        success "No WordPress installations found."
        : > "${OUTPUT_FILE}" 2>/dev/null || { error "Cannot write output file: ${OUTPUT_FILE}"; return 1; }
        return 0
    fi

    cut -f1 "${TMP_DETAILS}" > "${OUTPUT_FILE}" || { error "Cannot write output file: ${OUTPUT_FILE}"; return 1; }

    local count
    count="$(wc -l < "${OUTPUT_FILE}")"
    success "Found ${count} WordPress installation(s)."
    success "Paths saved to: ${OUTPUT_FILE}"

    printf '%sPATH%s\t%sUSER%s\t%sGROUP%s\t%sLAST MODIFIED%s\n' \
        "${GREEN}" "${NC}" "${BLUE}" "${NC}" "${BLUE}" "${NC}" "${YELLOW}" "${NC}" >&2

    while IFS=$'\t' read -r path user group date_m; do
        printf '%s\t%s\t%s\t%s\n' "${path}" "${user}" "${group}" "${date_m}"
    done < "${TMP_DETAILS}"
}

# ------------------------------------------------------------------------------
# cleanup: remove all temporary files (EXIT trap)
# ------------------------------------------------------------------------------

cleanup() {
    local f
    for f in TMP_RAW TMP_SORT TMP_DETAILS TMP_ERR; do
        if [[ -n "${!f:-}" && -f "${!f}" ]]; then
            rm -f "${!f}"
        fi
    done
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# usage / parse_args
# ------------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [SEARCH_DIRS...]

WordPress Installation Discovery Tool v${SCRIPT_VERSION}

OPTIONS:
  --output FILE       Output file with one site path per line (default: ${PWD}/wp-found.txt)
  --exclude PATTERN   Directory-name glob, or absolute path starting with '/' (repeatable)
  --max-depth N       Maximum find depth (default: ${MAX_DEPTH})
  --version           Print version and exit
  -h, --help          Show this help and exit

EXCLUSION SEMANTICS:
  'node_modules'      prunes directories named exactly 'node_modules'
  '*-backup'          prunes directories whose name ends with '-backup'
  '/var/www/old'      prunes this exact directory and everything below it

DEFAULT SEARCH DIRS:
  ${DEFAULT_SEARCH_DIRS[*]}

DEFAULT NAME EXCLUDES:
  ${DEFAULT_NAME_EXCLUDES[*]}

DEFAULT PATH EXCLUDES:
  ${DEFAULT_PATH_EXCLUDES[*]}

EXAMPLES:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} /var/www /srv
  ${SCRIPT_NAME} --exclude 'stage-*' --exclude '/var/www/archive' --output /root/sites.txt

NOTE: per-site opt-out: create an empty '.no_wp_cli' file inside a
WordPress root to hide it from discovery.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                if [[ -z "${2:-}" ]]; then
                    error "--output requires a file argument"
                    return 1
                fi
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --exclude)
                if [[ -z "${2:-}" ]]; then
                    error "--exclude requires a pattern argument"
                    return 1
                fi
                if [[ "$2" == /* ]]; then
                    PATH_EXCLUDES+=("$2")
                else
                    NAME_EXCLUDES+=("$2")
                fi
                shift 2
                ;;
            --max-depth)
                if [[ -z "${2:-}" || ! "${2}" =~ ^[0-9]+$ || "${2}" -lt 1 ]]; then
                    error "--max-depth requires a positive integer"
                    return 1
                fi
                MAX_DEPTH="$2"
                shift 2
                ;;
            --version)
                printf '%s v%s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                SEARCH_DIRS+=("$@")
                break
                ;;
            -*)
                error "Unknown option: $1"
                usage >&2
                return 1
                ;;
            *)
                SEARCH_DIRS+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#SEARCH_DIRS[@]} -eq 0 ]]; then
        SEARCH_DIRS=("${DEFAULT_SEARCH_DIRS[@]}")
    fi

    local -a merged_names=("${DEFAULT_NAME_EXCLUDES[@]}" "${NAME_EXCLUDES[@]}")
    local -a merged_paths=("${DEFAULT_PATH_EXCLUDES[@]}" "${PATH_EXCLUDES[@]}")
    NAME_EXCLUDES=("${merged_names[@]}")
    PATH_EXCLUDES=("${merged_paths[@]}")
    return 0
}

# ------------------------------------------------------------------------------
# _resolve_output: ensure the output parent directory exists
# ------------------------------------------------------------------------------

_resolve_output() {
    local parent resolved
    parent="$(dirname "${OUTPUT_FILE}")"
    if ! resolved="$(cd "${parent}" 2>/dev/null && pwd)"; then
        error "Output directory does not exist: ${parent}"
        return 1
    fi
    OUTPUT_FILE="${resolved}/$(basename "${OUTPUT_FILE}")"
    return 0
}

# ------------------------------------------------------------------------------
# main
# ------------------------------------------------------------------------------

main() {
    parse_args "$@" || exit 2
    _resolve_output || exit 1

    local start_time tmpbase
    start_time="$(date +%s)"

    # Safe temp-template base: never embed path separators (e.g. Windows
    # backslashes) into an mktemp template.
    tmpbase="${SCRIPT_NAME//[\\\/]/_}"
    [[ -n "${tmpbase}" ]] || tmpbase="wpfind"

    TMP_RAW="$(mktemp "${TMPDIR:-/tmp}/${tmpbase}.raw.XXXXXX")" || { error "Cannot create temp file"; exit 1; }
    TMP_SORT="$(mktemp "${TMPDIR:-/tmp}/${tmpbase}.sort.XXXXXX")" || { error "Cannot create temp file"; exit 1; }
    TMP_DETAILS="$(mktemp "${TMPDIR:-/tmp}/${tmpbase}.details.XXXXXX")" || { error "Cannot create temp file"; exit 1; }
    TMP_ERR="$(mktemp "${TMPDIR:-/tmp}/${tmpbase}.err.XXXXXX")" || { error "Cannot create temp file"; exit 1; }

    log "WordPress discovery started (v${SCRIPT_VERSION})..."

    discover_wordpress
    finalize_output

    if [[ -s "${TMP_ERR}" ]]; then
        warn "Some directories were unreadable during scan ($(wc -l < "${TMP_ERR}") lines); run as root to see everything."
    fi

    success "Completed in $(( $(date +%s) - start_time )) second(s)."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

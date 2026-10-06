#!/usr/bin/env bash
# ==============================================================================
# File:        Find_WP_Senior.sh
# Project:     Bash WP-CLI Update
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# Version:     2.0.0
# License:     MIT
#
# Description:
#   Scans one or more webroots for WordPress installations by locating
#   'wp-config.php' next to 'wp-includes/version.php', prunes excluded
#   directories with a single correct find expression, deduplicates results
#   and atomically writes unique site directories to a file.
#
# Usage:
#   ./Find_WP_Senior.sh [OPTIONS] [SEARCH_DIRS...]
#
# Options:
#   -o, --output FILE       Output file (default: <script_dir>/wp-found.txt)
#   -e, --exclude PATTERN   Exclude path (glob or absolute; repeatable)
#       --max-depth N       Maximum scan depth (default: 6)
#   -q, --quiet             No console output except errors
#       --no-defaults       Do not add the built-in search dirs/exclusions
#   -h, --help              Show help
#   -V, --version           Show version
#
# Configuration:
#   Optional config file <script_dir>/Find_WP_Senior.conf may override
#   SEARCH_DIRS, EXCLUDE_PATTERNS, OUTPUT_FILE and MAX_DEPTH. It is a bash
#   snippet sourced by the script - keep it trusted (chmod 600).
#
# Requirements:
#   - GNU/Linux with Bash 4.2+
#   - find, sort, mktemp, stat, wc in PATH
#
# Output guarantees:
#   * Output file contains ONLY site paths, one per line, sorted and
#     deduplicated.
#   * The file is written atomically (temp file + rename); the previous
#     content is preserved if discovery fails.
#   * Paths containing newline characters are not supported as site roots.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly VERSION="2.0.0"

# ------------------------------------------------------------------------------
# Configuration defaults (overridable via conf file and CLI)
# ------------------------------------------------------------------------------
DEFAULT_SEARCH_DIRS=(/var/www /usr/share/nginx/html /srv /usr/local/nginx/html /usr/local/var/www)

DEFAULT_EXCLUDE_PATTERNS=(
	'*/.git'
	'*/node_modules'
	'*/vendor'
	'*/cache'
	'*/backup*'
	'*/backups*'
	'*/old*'
	'*/test*'
	'*/tests*'
	'*/staging*'
)

OUTPUT_FILE=""
MAX_DEPTH=6
QUIET=false
NO_DEFAULTS=false

# Runtime state (user-provided values merged with defaults)
declare -a SEARCH_DIRS=()
declare -a EXCLUDE_PATTERNS=()
declare -a USER_SEARCH_DIRS=()
declare -a USER_EXCLUDE_PATTERNS=()

# Temporary files (created by main)
TMP_RAW=""
TMP_DETAILS=""
TMP_OUT=""

# ------------------------------------------------------------------------------
# Colors (stderr terminal only)
# ------------------------------------------------------------------------------
if [[ -t 2 ]]; then
	readonly RED=$'\033[0;31m' GREEN=$'\033[0;32m'
	readonly YELLOW=$'\033[1;33m' BLUE=$'\033[0;34m' NC=$'\033[0m'
else
	readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log() { [[ "${QUIET}" == true ]] || printf "${BLUE}INFO:${NC} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}WARN:${NC} %s\n" "$*" >&2; }
success() { [[ "${QUIET}" == true ]] || printf "${GREEN}SUCCESS:${NC} %s\n" "$*" >&2; }
detail() { [[ "${QUIET}" == true ]] || printf "%s\n" "$*" >&2; }
error() { printf "${RED}ERROR:${NC} %s\n" "$*" >&2; }

# ------------------------------------------------------------------------------
# Usage / version
# ------------------------------------------------------------------------------
usage() {
	cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS] [SEARCH_DIRS...]

WordPress Installation Discovery Tool v${VERSION}

Scans the given directories (or the built-in defaults) for WordPress
installations and writes one unique site path per line to the output file.

OPTIONS:
  -o, --output FILE       Output file (default: <script_dir>/wp-found.txt)
  -e, --exclude PATTERN   Exclude path (glob or absolute; repeatable)
      --max-depth N       Maximum depth below each search root (default: 6)
  -q, --quiet             Suppress non-error console output
      --no-defaults       Do not add built-in search dirs and exclusions
  -h, --help              Show this help and exit
  -V, --version           Show version and exit

DEFAULT SEARCH DIRS:
  ${DEFAULT_SEARCH_DIRS[*]}

EXAMPLES:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} /var/www /srv
  ${SCRIPT_NAME} --exclude '*/staging' --exclude '/var/www/old-site'
  ${SCRIPT_NAME} --no-defaults --exclude '*/cache' /srv/www

CONFIG FILE:
  ${SCRIPT_DIR}/Find_WP_Senior.conf (optional bash snippet)
EOF
	exit 0
}

version_info() {
	printf '%s %s\n' "${SCRIPT_NAME}" "v${VERSION}"
	exit 0
}

# ------------------------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------------------------

# die <message>: print error to stderr and fail hard.
die() {
	error "$*"
	exit 1
}

# matches_glob <path> <pattern>: bash "case" pattern match (basic glob only).
matches_glob() {
	local path="$1" pattern="$2"
	[[ -n "${pattern}" ]] || return 1
	case "${path}" in
	"${pattern}") return 0 ;;
	*) return 1 ;;
	esac
}

# canonicalize_dir <path>: strip trailing slashes unless root.
canonicalize_dir() {
	local d="$1"
	if [[ "${d}" == "/" ]]; then
		printf '%s' "/"
		return
	fi
	while [[ "${d}" == */ ]]; do
		d="${d%/}"
	done
	printf '%s' "${d}"
}

# excluded_by_patterns <path>: print "true" when any EXCLUDE_PATTERNS entry
# matches the path. Absolute star-less patterns compare canonical paths; glob
# patterns are matched against the whole path and the trailing-slash form.
excluded_by_patterns() {
	local site="$1"
	local ex canon_ex canon_site
	for ex in "${EXCLUDE_PATTERNS[@]}"; do
		[[ -n "${ex}" ]] || continue
		if [[ "${ex}" == /* && "${ex}" != *'*'* ]]; then
			canon_ex="$(canonicalize_dir "${ex}")"
			canon_site="$(canonicalize_dir "${site}")"
			if [[ "${canon_site}" == "${canon_ex}" ]]; then
				printf 'true'
				return 0
			fi
		elif matches_glob "${site}" "${ex}" || matches_glob "${site%/}" "${ex}"; then
			printf 'true'
			return 0
		fi
	done
	printf 'false'
}

# is_valid_wp <dir>: a WordPress root must carry wp-config.php and
# wp-includes/version.php.
is_valid_wp() {
	local dir="$1"
	[[ -f "${dir}/wp-config.php" && -f "${dir}/wp-includes/version.php" ]]
}

# make_temp <template>: create a temp file in the OUTPUT_FILE directory.
make_temp() {
	local tmpl="$1"
	local out_dir
	out_dir="$(dirname "${OUTPUT_FILE}")"
	local f
	if ! f="$(mktemp --tmpdir="${out_dir}" "${tmpl}.XXXXXX" 2>/dev/null)"; then
		if ! f="$(mktemp "${out_dir}/${tmpl}.XXXXXX" 2>/dev/null)"; then
			die "Failed to create temporary file in ${out_dir}"
		fi
	fi
	printf '%s' "${f}"
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
cleanup() {
	local rc=$?
	[[ -n "${TMP_RAW}" && -f "${TMP_RAW}" ]] && rm -f "${TMP_RAW}"
	[[ -n "${TMP_DETAILS}" && -f "${TMP_DETAILS}" ]] && rm -f "${TMP_DETAILS}"
	[[ -n "${TMP_OUT}" && -f "${TMP_OUT}" ]] && rm -f "${TMP_OUT}"
	exit "${rc}"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Optional configuration file
# ------------------------------------------------------------------------------
load_config_file() {
	local conf="${SCRIPT_DIR}/Find_WP_Senior.conf"
	[[ -f "${conf}" ]] || return 0
	# The file may override SEARCH_DIRS, EXCLUDE_PATTERNS, OUTPUT_FILE, MAX_DEPTH.
	# shellcheck disable=SC1091
	source "${conf}"
	log "Loaded config file: ${conf}"
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
parse_args() {
	local opt
	while [[ $# -gt 0 ]]; do
		opt="$1"
		case "${opt}" in
		-o | --output)
			[[ $# -ge 2 ]] || die "Option '${opt}' requires an argument"
			OUTPUT_FILE="$2"
			shift 2
			;;
		-e | --exclude)
			[[ $# -ge 2 ]] || die "Option '${opt}' requires an argument"
			USER_EXCLUDE_PATTERNS+=("$2")
			shift 2
			;;
		--max-depth)
			[[ $# -ge 2 ]] || die "Option '${opt}' requires an argument"
			if [[ ! "$2" =~ ^[0-9]+$ ]] || (($2 < 1)); then
				die "Invalid --max-depth value: $2 (must be a positive integer)"
			fi
			MAX_DEPTH="$2"
			shift 2
			;;
		-q | --quiet)
			QUIET=true
			shift
			;;
		--no-defaults)
			NO_DEFAULTS=true
			shift
			;;
		-h | --help)
			usage
			;;
		-V | --version)
			version_info
			;;
		--)
			shift
			USER_SEARCH_DIRS+=("$@")
			set --
			;;
		-*)
			die "Unknown option: ${opt} (see --help)"
			;;
		*)
			USER_SEARCH_DIRS+=("${opt}")
			shift
			;;
		esac
	done

	# Merge CLI values with defaults.
	if [[ "${NO_DEFAULTS}" == true ]]; then
		SEARCH_DIRS=("${USER_SEARCH_DIRS[@]}")
		EXCLUDE_PATTERNS=("${USER_EXCLUDE_PATTERNS[@]}")
	else
		SEARCH_DIRS=("${DEFAULT_SEARCH_DIRS[@]}")
		EXCLUDE_PATTERNS=("${DEFAULT_EXCLUDE_PATTERNS[@]}")
		if [[ ${#USER_SEARCH_DIRS[@]} -gt 0 ]]; then
			# Explicit CLI dirs REPLACE the defaults (classic behaviour).
			SEARCH_DIRS=("${USER_SEARCH_DIRS[@]}")
		fi
		if [[ ${#USER_EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
			EXCLUDE_PATTERNS+=("${USER_EXCLUDE_PATTERNS[@]}")
		fi
	fi

	if [[ ${#SEARCH_DIRS[@]} -eq 0 ]]; then
		die "No search directories configured (use --no-defaults only with explicit dirs)"
	fi

	[[ -n "${OUTPUT_FILE}" ]] || OUTPUT_FILE="${SCRIPT_DIR}/wp-found.txt"
}

# ------------------------------------------------------------------------------
# find expression builder
#
# Builds the -type/-path/-prune part of the find command.
# Expression shape (balanced):
#   ( -type d ( -path A -o -path B ) -prune -o -true ) \
#       -type f -name wp-config.php -print0
# Every printed path is a wp-config.php; pruned dirs never descend.
# ------------------------------------------------------------------------------
build_find_args() {
	local -a args=(find)
	local root="$1"
	args+=("${root}" -maxdepth "${MAX_DEPTH}")

	# Prune part (only dirs).
	args+=("(" -type d "(")
	local pat first=true
	for pat in "${EXCLUDE_PATTERNS[@]}"; do
		[[ -n "${pat}" ]] || continue
		[[ "${first}" == true ]] || args+=(-o)
		args+=(-path "${pat}")
		first=false
	done
	if [[ "${first}" == false ]]; then
		args+=(")" -prune -o -true ")")
	else
		# No exclusions: close what we opened.
		args=(find "${root}" -maxdepth "${MAX_DEPTH}")
	fi

	# Selection + NUL-safe emission.
	args+=(-type f -name wp-config.php -print0)
	FIND_ARGS=("${args[@]}")
}

# FIND_ARGS_OUT - filled by build_find_args above.
declare -a FIND_ARGS=()

# ------------------------------------------------------------------------------
# Scan one root; append NUL-separated wp-config.php paths to stdout
# ------------------------------------------------------------------------------
scan_root() {
	local root="$1"
	[[ -d "${root}" ]] || {
		warn "Search root does not exist, skipping: ${root}"
		return 0
	}

	build_find_args "${root}"
	log "Scanning: ${root} (max depth ${MAX_DEPTH})"
	"${FIND_ARGS[@]}" 2>/dev/null
	return 0
}

# ------------------------------------------------------------------------------
# Main discovery
# ------------------------------------------------------------------------------
discover_wordpress() {
	local root
	log "Starting WordPress discovery across ${#SEARCH_DIRS[@]} root(s)"
	log "Active exclusions: ${#EXCLUDE_PATTERNS[@]} pattern(s)"

	# Collect raw wp-config.php paths, NUL-separated.
	: >"${TMP_RAW}" || die "Cannot write temporary file"
	for root in "${SEARCH_DIRS[@]}"; do
		scan_root "${root}" >>"${TMP_RAW}"
	done

	# Enrich with metadata (single read per path, no pipes into while).
	if [[ -s "${TMP_RAW}" ]]; then
		while IFS= read -r -d '' config; do
			site_dir="$(dirname "${config}")"
			[[ -d "${site_dir}" ]] || continue
			[[ "$(excluded_by_patterns "${site_dir}")" == true ]] && continue
			is_valid_wp "${site_dir}" || continue
			get_wp_info "${site_dir}"
		done <"${TMP_RAW}" >"${TMP_DETAILS}"
	else
		: >"${TMP_DETAILS}"
	fi

	if [[ -s "${TMP_DETAILS}" ]]; then
		sort -u "${TMP_DETAILS}" -o "${TMP_DETAILS}" || die "sort failed while processing results"
	fi
}

# ------------------------------------------------------------------------------
# Site info (user, group, mtime) - GNU stat with graceful fallback
# ------------------------------------------------------------------------------
get_wp_info() {
	local dir="$1"
	local user group date_str

	user="$(stat -c '%U' "${dir}" 2>/dev/null || true)"
	group="$(stat -c '%G' "${dir}" 2>/dev/null || true)"
	date_str="$(stat -c '%y' "${dir}" 2>/dev/null || true)"
	date_str="${date_str%%.*}"
	date_str="${date_str:0:16}"
	printf '%s\t%s\t%s\t%s\n' \
		"${dir}" "${user:-<unknown>}" "${group:-<unknown>}" "${date_str:-<unknown>}"
}

# ------------------------------------------------------------------------------
# Final output: paths only (atomic write) + rich details on screen
# ------------------------------------------------------------------------------
finalize_output() {
	if [[ ! -s "${TMP_DETAILS}" ]]; then
		# Still create/overwrite the output file (empty) for downstream tools.
		: >"${TMP_OUT}" || die "Cannot write output file: ${OUTPUT_FILE}"
		mv -f "${TMP_OUT}" "${OUTPUT_FILE}" || die "Cannot move output file into place: ${OUTPUT_FILE}"
		success "No WordPress installations found."
		return 0
	fi

	local count
	count="$(wc -l <"${TMP_DETAILS}")"
	cut -f1 "${TMP_DETAILS}" >"${TMP_OUT}" || die "Cannot prepare output data"
	mv -f "${TMP_OUT}" "${OUTPUT_FILE}" || die "Cannot write output file: ${OUTPUT_FILE}"

	success "Found ${count} WordPress installation(s)."
	success "Paths saved to: ${OUTPUT_FILE}"

	[[ "${QUIET}" == true ]] && return 0

	detail ""
	detail "Details of found installations:"
	detail "PATH\tUSER\tGROUP\tLAST MODIFIED"
	local line
	while IFS= read -r line; do
		detail "${line}"
	done <"${TMP_DETAILS}"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
	local start_time
	start_time="$(date +%s)"

	load_config_file
	parse_args "$@"

	TMP_RAW="$(make_temp "${SCRIPT_NAME}.raw")"
	TMP_DETAILS="$(make_temp "${SCRIPT_NAME}.details")"
	TMP_OUT="$(make_temp "${SCRIPT_NAME}.out")"

	discover_wordpress
	finalize_output

	local end_time
	end_time="$(date +%s)"
	success "Completed in $((end_time - start_time)) seconds."
}

# ------------------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi

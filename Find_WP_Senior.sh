#!/bin/sh
# ------------------------------------------------------------------------------
# wp-find.sh — Fast, reliable WordPress installation discovery
#
# Scans multiple common web roots to locate real WordPress installations.
# Validates core files to avoid false positives.
#
# https://github.com/paulmann/Bash_WP-CLI_Update/edit/main/Find_WP_Senior.sh
#
# Features:
# • Multi-root scanning (supports /var/www, /home, /srv, etc.)
# • Smart exclusions (system dirs, node_modules, backups, etc.)
# • Shows USER, GROUP, and folder date for each install
# • Colorized, user-friendly logging
# • Secure temporary handling & cleanup
# • Works on CentOS 7+, RHEL, Ubuntu, Debian
# ------------------------------------------------------------------------------

# Test for bash features and adapt
if [ -n "$BASH_VERSION" ]; then
    # We're running in bash, can use some extensions
    set -euo pipefail 2>/dev/null || true
else
    # POSIX mode
    set -e
fi

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="${0##*/}"
readonly DEFAULT_OUTPUT_FILE="${PWD}/wp-found.txt"
readonly MAX_DEPTH=6

# ──────────────────────────────────────────────────────────────────────────────
# Configuration — Search roots and exclusions
# ──────────────────────────────────────────────────────────────────────────────

readonly -a DEFAULT_SEARCH_DIRS=(
	/var/www/batterydb/data/www/
	/var/www/bsgtech/data/www/
)

# Common directories to exclude by default (safe for most systems)
readonly -a DEFAULT_EXCLUDE_PATTERNS=(
	'*/.git'
	'*/node_modules'
	'*/vendor'
	'/proc/*'
	'/sys/*'
	'/dev/*'
	'/run/*'
	'/tmp/*'
	'*/backup*'
	'*/backups*'
	'*/old*'
	'*/test*'
	'*/tests*'
)

# ──────────────────────────────────────────────────────────────────────────────
# Color setup (only if outputting to terminal)
# ──────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
	readonly RED='\033[0;31m' GREEN='\033[0;32m'
	readonly YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'
else
	readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# ──────────────────────────────────────────────────────────────────────────────
# Logging helpers
# ──────────────────────────────────────────────────────────────────────────────

log() { printf "${BLUE}INFO:${NC} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}WARN:${NC} %s\n" "$*" >&2; }
success() { printf "${GREEN}SUCCESS:${NC} %s\n" "$*" >&2; }
error() { printf "${RED}ERROR:${NC} %s\n" "$*" >&2; }

# ──────────────────────────────────────────────────────────────────────────────
# Globals
# ──────────────────────────────────────────────────────────────────────────────

declare OUTPUT_FILE
declare -a SEARCH_DIRS=()
declare -a EXCLUDE_PATTERNS=()
declare TMP_FILE
declare TMP_DETAILS_FILE

# ──────────────────────────────────────────────────────────────────────────────
# Build find -prune arguments from absolute exclusion paths
# ──────────────────────────────────────────────────────────────────────────────

build_prune_args() {
	local path prune_args=()
	for path in "${EXCLUDE_PATTERNS[@]}"; do
		if [[ "${path}" == /* ]] && [[ -d "${path}" ]]; then
			prune_args+=(-path "${path}" -prune -o)
		fi
	done
	if (( ${#prune_args[@]} > 0 )); then
		printf '%s ' "${prune_args[@]}"
	fi
	printf '%s' '-print'
}

# ──────────────────────────────────────────────────────────────────────────────
# Validate WordPress installation
# ──────────────────────────────────────────────────────────────────────────────

is_valid_wp() {
	local dir="$1"
	[[ -f "${dir}/wp-config.php" ]] && [[ -f "${dir}/wp-includes/version.php" ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# Get formatted file info: user, group, date
# Uses stat with fallback for CentOS 7 (GNU stat)
# ──────────────────────────────────────────────────────────────────────────────

get_wp_info() {
	local dir="$1"
	if ! [[ -d "${dir}" ]]; then
		printf '%s\t<invalid>\t<invalid>\t<unknown>\n' "${dir}"
		return
	fi

	# Try to get user/group and timestamp
	local user group date_str
	if user="$(stat -c '%U' "${dir}" 2>/dev/null)" &&
	   group="$(stat -c '%G' "${dir}" 2>/dev/null)" &&
	   date_str="$(stat -c '%y' "${dir}" 2>/dev/null)"; then
		# Format date: YYYY-MM-DD HH:MM
		date_str="${date_str%%.*}"  # remove fractional seconds
		printf '%s\t%s\t%s\t%s\n' "${dir}" "${user}" "${group}" "${date_str}"
	else
		# Fallback (should not happen on Linux)
		printf '%s\t<unknown>\t<unknown>\t<unknown>\n' "${dir}"
	fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Scan a single root and collect valid WP paths
# ──────────────────────────────────────────────────────────────────────────────

scan_root() {
	local root="$1"
	log "Scanning: ${root}"

	local prune_expr
	prune_expr=$(build_prune_args)

	find "${root}" \
		-maxdepth "${MAX_DEPTH}" \
		-type f \
		-name "wp-config.php" \
		${prune_expr} \
		2>/dev/null | while read -r config; do
		
		local site_dir
		site_dir="$(dirname "${config}")"

		# Skip if matches glob exclusion
		local exclude
		for exclude in "${EXCLUDE_PATTERNS[@]}"; do
			if [[ "${site_dir}" == ${exclude} ]]; then
				continue 2
			fi
		done

		if is_valid_wp "${site_dir}"; then
			printf '%s\n' "${site_dir}"
		fi
	done
}

# ──────────────────────────────────────────────────────────────────────────────
# Discover all WordPress installations and enrich with metadata
# ──────────────────────────────────────────────────────────────────────────────

discover_wordpress() {
	log "Starting WordPress discovery across ${#SEARCH_DIRS[@]} root(s)"
	log "Exclusions: ${#EXCLUDE_PATTERNS[@]} patterns"

	# Create temp file — assign immediately
	local raw_file=""
	raw_file="$(mktemp -t "${SCRIPT_NAME}.raw.XXXXXX")" || {
	    error "Failed to create temp file"
	    exit 1
	}

	# Collect raw paths
	{
		for root in "${SEARCH_DIRS[@]}"; do
			if [[ -d "${root}" ]]; then
				scan_root "${root}"
			fi
		done
	} > "${raw_file}"

	# Enrich with metadata
	if [[ -s "${raw_file}" ]]; then
		sort -u "${raw_file}" | while IFS= read -r dir; do
			get_wp_info "${dir}"
		done > "${TMP_DETAILS_FILE}"
	else
		> "${TMP_DETAILS_FILE}"
	fi

	# Clean up — explicit, no trap needed
	rm -f "${raw_file}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Finalize output: save paths only to file, show rich info on screen
# ──────────────────────────────────────────────────────────────────────────────

finalize_output() {
	if [[ ! -s "${TMP_DETAILS_FILE}" ]]; then
		success "No WordPress installations found."
		touch "${OUTPUT_FILE}"
		return 0
	fi

	# Save only paths to output file (for scripting compatibility)
	cut -f1 "${TMP_DETAILS_FILE}" > "${OUTPUT_FILE}"
	local count
	count=$(wc -l < "${OUTPUT_FILE}")

	success "Found ${count} WordPress installation(s)."
	success "Paths saved to: ${OUTPUT_FILE}"

	# Display rich info on screen
	log "Details of found installations:"
	printf "${GREEN}%s${NC}\t${BLUE}%s${NC}\t${BLUE}%s${NC}\t${YELLOW}%s${NC}\n" \
		"PATH" "USER" "GROUP" "LAST MODIFIED"

	while IFS=$'\t' read -r path user group date; do
		printf "%s\t%s\t%s\t%s\n" "${path}" "${user}" "${group}" "${date}"
	done < "${TMP_DETAILS_FILE}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup
# ──────────────────────────────────────────────────────────────────────────────

cleanup() {
	[[ -n "${TMP_FILE:-}" && -f "${TMP_FILE}" ]] && rm -f "${TMP_FILE}"
	[[ -n "${TMP_DETAILS_FILE:-}" && -f "${TMP_DETAILS_FILE}" ]] && rm -f "${TMP_DETAILS_FILE}"
	log "Cleaned up temporary files."
}
trap cleanup EXIT

# ──────────────────────────────────────────────────────────────────────────────
# Parse command-line arguments
# ──────────────────────────────────────────────────────────────────────────────

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--output)
				OUTPUT_FILE="$2"
				shift 2
				;;
			--exclude)
				EXCLUDE_PATTERNS+=("$2")
				shift 2
				;;
			-h|--help)
				cat <<EOF
Usage: $0 [OPTIONS] [SEARCH_DIRS...]

WordPress Installation Discovery Tool

By default, scans:
  ${DEFAULT_SEARCH_DIRS[*]}

OPTIONS:
  --output FILE       Set output file (default: ${DEFAULT_OUTPUT_FILE})
  --exclude PATTERN   Exclude path (glob or absolute; repeatable)
  -h, --help          Show this help

EXAMPLES:
  $0
  $0 /var/www /srv
  $0 --exclude '*/staging'

EOF
				exit 0
				;;
			--)
				shift
				SEARCH_DIRS+=("$@")
				break
				;;
			-*)
				error "Unknown option: $1"
				exit 1
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

 local -a merged_excludes=("${DEFAULT_EXCLUDE_PATTERNS[@]}")
 if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
 	merged_excludes+=("${EXCLUDE_PATTERNS[@]}")
 fi
 EXCLUDE_PATTERNS=("${merged_excludes[@]}")

	[[ -z "${OUTPUT_FILE:-}" ]] && OUTPUT_FILE="${DEFAULT_OUTPUT_FILE}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main execution
# ──────────────────────────────────────────────────────────────────────────────

main() {
	local start_time end_time
	start_time=$(date +%s)
	log "WordPress discovery started..."

	TMP_FILE="$(mktemp -t "${SCRIPT_NAME}.XXXXXX")"
	TMP_DETAILS_FILE="$(mktemp -t "${SCRIPT_NAME}.details.XXXXXX")"
	parse_args "$@"

	discover_wordpress
	finalize_output

	end_time=$(date +%s)
	success "Completed in $((end_time - start_time)) seconds."
}

# ──────────────────────────────────────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi

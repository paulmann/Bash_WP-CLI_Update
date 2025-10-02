#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# wp-find.sh — Fast, reliable WordPress installation directory discovery
#
# Author: Mikhail Deynekin <mid1977@gmail.com>
# Website: https://deynekin.com
# Date:   2025-10-02 22:42 MSK
#
# Description:
#  This script scans a webroot for WordPress installations by locating
#  'wp-content/themes/*/functions.php'. It excludes exact paths, deduplicates,
#  and writes results to a file. Designed for CentOS 7+ and modern Linux distros.
#
# Features:
#  • set -euo pipefail for strict mode
#  • readonly configuration
#  • associative array for O(1) exclusion lookup
#  • functions with single responsibility
#  • minimal external commands, piped safely
#  • trap cleanup on exit
#
# Optimized Version Features:
# • Early pruning for excluded directories
# • Parallel processing where available
# • Better error handling and validation
# • Improved performance with find optimizations
# • Enhanced security and resource usage
# ------------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'
readonly SCRIPT_NAME="${0##*/}"

# ─────────────────────────────────────────────────────────────────────────────
# Configuration (readonly)
# ─────────────────────────────────────────────────────────────────────────────

declare -r OUTPUT_FILE="${PWD}/wp_found.txt"
declare -r WWW_DIR="/var/www"
declare -r -a EXCLUDED_PATHS=(
	"/var/www/deynekin/data/www/deynekin.ru"
	"/var/www/paulmann/data/www/paulmann-light.ru"
)
declare -r -i MAX_DEPTH=8
declare -r -i BATCH_SIZE=1000

# ─────────────────────────────────────────────────────────────────────────────
# Color codes for output (optional)
# ─────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
	declare -r RED='\033[0;31m'
	declare -r GREEN='\033[0;32m'
	declare -r YELLOW='\033[1;33m'
	declare -r BLUE='\033[0;34m'
	declare -r NC='\033[0m'
else
	declare -r RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# Globals
# ─────────────────────────────────────────────────────────────────────────────

declare TMP_FILE
declare -A EXCLUDE_MAP

# ─────────────────────────────────────────────────────────────────────────────
# Utility Functions
# ─────────────────────────────────────────────────────────────────────────────

log_error() {
	printf "${RED}ERROR:${NC} %s\n" "$*" >&2
}

log_info() {
	printf "${BLUE}INFO:${NC} %s\n" "$*"
}

log_success() {
	printf "${GREEN}SUCCESS:${NC} %s\n" "$*"
}

validate_environment() {
	if [[ ! -d "$WWW_DIR" ]]; then
		log_error "Web root directory does not exist: $WWW_DIR"
		return 1
	fi
	
	if ! command -v find &>/dev/null; then
		log_error "'find' command not available"
		return 1
	fi
	
	if ! command -v sort &>/dev/null; then
		log_error "'sort' command not available"
		return 1
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
# init_exclusions — Populate associative array for fast O(1) lookup
# ─────────────────────────────────────────────────────────────────────────────

init_exclusions() {
	local path
	for path in "${EXCLUDED_PATHS[@]}"; do
		if [[ -n "$path" ]]; then
			EXCLUDE_MAP["$path"]=1
		fi
	done
	log_info "Initialized ${#EXCLUDE_MAP[@]} exclusion patterns"
}

# ─────────────────────────────────────────────────────────────────────────────
# should_exclude — Check if path should be excluded
# ─────────────────────────────────────────────────────────────────────────────

should_exclude() {
	local path="$1"
	[[ -n "${EXCLUDE_MAP["$path"]+_}" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# build_find_prune_args — Build pruning arguments for excluded paths
# ─────────────────────────────────────────────────────────────────────────────

build_find_prune_args() {
	local path prune_args=()
	
	for path in "${EXCLUDED_PATHS[@]}"; do
		if [[ -n "$path" && -d "$path" ]]; then
			pruneArgs+=(-path "$path" -prune -o)
		fi
	done
	
	# If we have prune arguments, add the final -print, otherwise empty
	if (( ${#pruneArgs[@]} > 0 )); then
		printf "%s " "${pruneArgs[@]}"
		printf "%s" "-print"
	else
		printf "%s" "-print"
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
# find_wp_sites — Locate WordPress install dirs with optimizations
# ─────────────────────────────────────────────────────────────────────────────

find_wp_sites() {
	local prune_args
	TMP_FILE=$(mktemp "/tmp/${SCRIPT_NAME}.XXXXXXXXXX")
	
	log_info "Starting WordPress directory scan in: $WWW_DIR"
	log_info "Maximum depth: $MAX_DEPTH, Batch size: $BATCH_SIZE"
	
	# Build pruning arguments for excluded paths
	prune_args=$(build_find_prune_args)
	
	# Use find with optimizations:
	# -maxdepth: Limit search depth for performance
	# -type f: Only files
	# -name: Specific filename for early filtering
	# -path: Pattern matching with early exclusion
	# -print0: Null-terminated for safe handling
	# Pruning: Skip excluded directories entirely
	
	if (( ${#EXCLUDED_PATHS[@]} > 0 )); then
		find "$WWW_DIR" \
			-maxdepth "$MAX_DEPTH" \
			-type f \
			-name "functions.php" \
			-path "*/wp-content/themes/*/functions.php" \
			$prune_args \
			-print0 2>/dev/null || true
	else
		find "$WWW_DIR" \
			-maxdepth "$MAX_DEPTH" \
			-type f \
			-name "functions.php" \
			-path "*/wp-content/themes/*/functions.php" \
			-print0 2>/dev/null || true
	fi | {
		local file site_dir count=0 batch_count=0
		
		while IFS= read -r -d '' file; do
			((++batch_count))
			
			# Extract site directory from full path
			site_dir="${file%%/wp-content/*}"
			
			# Skip if empty or excluded
			[[ -z "$site_dir" ]] && continue
			should_exclude "$site_dir" && continue
			
			# Batch output for performance
			printf '%s\n' "$site_dir"
			((++count))
			
			# Periodic status updates for large scans
			if (( batch_count % BATCH_SIZE == 0 )); then
				log_info "Processed $batch_count files, found $count sites..."
			fi
		done >> "$TMP_FILE"
		
		log_info "Scan completed: processed $batch_count files, found $count potential sites"
	}
}

# ─────────────────────────────────────────────────────────────────────────────
# write_output — Deduplicate, sort, and save results
# ─────────────────────────────────────────────────────────────────────────────

write_output() {
	local unique_count
	
	if [[ ! -s "$TMP_FILE" ]]; then
		log_info "No WordPress installations found"
		touch "$OUTPUT_FILE"
		return 0
	fi
	
	# Use efficient sort with temporary file pre-allocation
	LC_ALL=C sort -u -S 2M --parallel=2 "$TMP_FILE" > "$OUTPUT_FILE" 2>/dev/null || \
	sort -u "$TMP_FILE" > "$OUTPUT_FILE"
	
	unique_count=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')
	
	if (( unique_count > 0 )); then
		log_success "Found $unique_count unique WordPress installation(s)"
		log_success "Results saved to: $OUTPUT_FILE"
		
		# Optional: Print first few results for immediate feedback
		if (( unique_count <= 10 )); then
			log_info "Found installations:"
			while IFS= read -r site; do
				printf "  • %s\n" "$site"
			done < "$OUTPUT_FILE"
		else
			log_info "First 5 installations:"
			head -5 "$OUTPUT_FILE" | while IFS= read -r site; do
				printf "  • %s\n" "$site"
			done
			log_info "Use 'cat $OUTPUT_FILE' to see all results"
		fi
	else
		log_info "No unique WordPress installations found after deduplication"
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
# cleanup — Remove temporary resources on exit
# ─────────────────────────────────────────────────────────────────────────────

cleanup() {
	if [[ -n "${TMP_FILE:-}" && -f "$TMP_FILE" ]]; then
		rm -f "$TMP_FILE" && log_info "Cleaned up temporary files"
	fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Signal handling
# ─────────────────────────────────────────────────────────────────────────────

setup_signals() {
	trap cleanup EXIT
	trap 'log_error "Script interrupted"; exit 130' INT TERM
}

# ─────────────────────────────────────────────────────────────────────────────
# Main — orchestrate steps with proper error handling
# ─────────────────────────────────────────────────────────────────────────────

main() {
	local start_time end_time duration
	
	start_time=$(date +%s)
	
	log_info "Starting WordPress directory discovery"
	
	# Validate environment first
	if ! validate_environment; then
		log_error "Environment validation failed"
		exit 1
	fi
	
	# Setup signal handlers and cleanup
	setup_signals
	
	# Initialize exclusions
	init_exclusions
	
	# Find WordPress sites
	if ! find_wp_sites; then
		log_error "Failed during directory scanning"
		exit 1
	fi
	
	# Process and output results
	if ! write_output; then
		log_error "Failed during output processing"
		exit 1
	fi
	
	end_time=$(date +%s)
	duration=$((end_time - start_time))
	
	log_success "Discovery completed in ${duration} seconds"
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point with help option
# ─────────────────────────────────────────────────────────────────────────────

case "${1:-}" in
	-h|--help|help)
		cat <<-EOF
		${SCRIPT_NAME} - WordPress Installation Discovery Tool
		
		Features:
		• Fast, reliable WordPress directory discovery
		• Exclusion support for specific paths
		• Optimized for large directory trees
		• Secure temporary file handling
		• Detailed logging and progress updates
		
		Output: ${OUTPUT_FILE}
		Web Root: ${WWW_DIR}
		Exclusions: ${#EXCLUDED_PATHS[@]} paths configured
		
		Usage: $0 [options]
		
		Options:
		  -h, --help    Show this help message
		  (no options)  Run the discovery tool
		
		EOF
		exit 0
		;;
	*)
		main "$@"
		;;
esac

#!/usr/bin/env bash
###############################################################################
# WordPress Maintenance Automation
# Description: Secure, fast, and modular WP-CLI manager for multiple sites.
# Author: Mikhail Deynekin <mid1977@gmail.com>
# Repository: https://github.com/paulmann/Bash_WP-CLI_Update
# License: MIT
# Version: 4.2
###############################################################################
set -euo pipefail
shopt -s inherit_errexit

#########################################
###           CONSTANTS               ###
#########################################
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="4.2"

# File paths
readonly SITES_FILE="${SCRIPT_DIR}/wp-found.txt"
readonly DISCOVER_SCRIPT="${SCRIPT_DIR}/Find_WP_Senior.sh"
readonly LOG_FILE="${SCRIPT_DIR}/wp_cli_manager.log"
readonly WP_CLI_PATH="/usr/local/bin/wp"

# Operation modes
readonly MODE_FULL="full"
readonly MODE_CORE="core"
readonly MODE_PLUGINS="plugins"
readonly MODE_THEMES="themes"
readonly MODE_DB_OPTIMIZE="db-optimize"
readonly MODE_DB_FIX="db-fix"
readonly MODE_CRON="cron"

# ANSI colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly RESET='\033[0m'

#########################################
###        GLOBAL VARIABLES           ###
#########################################
declare -A STATS=(
	[total_sites]=0
	[success_ops]=0
	[error_ops]=0
)

#########################################
###           FUNCTIONS               ###
#########################################

log() {
	local level="$1" msg="$2"
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	local log_line="[${timestamp}] [${level}] ${msg}"
	echo "${log_line}" >> "${LOG_FILE}"
	case "${level}" in
		"ERROR")   echo -e "${RED}✗ ${msg}${RESET}" >&2 ;;
		"WARNING") echo -e "${YELLOW}⚠ ${msg}${RESET}" >&2 ;;
		"SUCCESS") echo -e "${GREEN}✓ ${msg}${RESET}" >&2 ;;
		*)         echo "${msg}" ;;
	esac
}

log_info()    { log "INFO" "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_error()   { log "ERROR" "$1"; }
log_warning() { log "WARNING" "$1"; }

usage() {
	cat <<EOF
WordPress Maintenance Automation v${SCRIPT_VERSION}
Usage: $0 [MODE]

Modes:
  --full          : Full update (core, plugins, themes, DB optimize/repair, cron)
  --core          : Update WordPress core only
  --plugins       : Update all plugins
  --themes        : Update all themes
  --db-optimize   : Optimize and repair database
  --db-fix        : Repair database only
  --cron          : Run due cron events

Example:
  $0 --plugins
  $0 --full

Sites are read from: ${SITES_FILE}
EOF
	exit 1
}

trim() {
	local str="$1"
	str="${str#"${str%%[![:space:]]*}"}"
	str="${str%"${str##*[![:space:]]}"}"
	printf '%s' "${str}"
}

get_wp_user() {
	local wp_root="$1"
	local wp_config="${wp_root}/wp-config.php"

	if [[ ! -f "${wp_config}" ]]; then
		log_error "wp-config.php not found in ${wp_root}"
		return 1
	fi

	local db_user
	db_user="$(grep -E "define\s*\(\s*'DB_USER'" "${wp_config}" 2>/dev/null | \
	           sed -E "s/.*'DB_USER'\s*,\s*'([^']+)'.*/\1/" | tail -n1)"

	if [[ -z "${db_user}" ]]; then
		log_warning "DB_USER not found in wp-config.php; falling back to directory owner"
		db_user="$(stat -c '%U' "${wp_root}")"
	fi

	if ! id -u "${db_user}" >/dev/null 2>&1; then
		log_error "System user '${db_user}' does not exist"
		return 1
	fi

	printf '%s' "${db_user}"
}

run_wp_cli() {
	local site_path="$1" user="$2" cmd=("${@:3}")
	log_info "Running: wp ${cmd[*]} on ${site_path} as ${user}"
	if sudo -u "${user}" -- "${WP_CLI_PATH}" --path="${site_path}" "${cmd[@]}" --quiet --allow-root; then
		log_success "Success: wp ${cmd[*]}"
		((STATS[success_ops]++))
		return 0
	else
		log_error "Failed: wp ${cmd[*]}"
		((STATS[error_ops]++))
		return 1
	fi
}

execute_mode() {
	local mode="$1" site_path="$2" wp_user="$3"

	case "${mode}" in
		"${MODE_FULL}")
			run_wp_cli "${site_path}" "${wp_user}" core update
			run_wp_cli "${site_path}" "${wp_user}" plugin update --all
			run_wp_cli "${site_path}" "${wp_user}" theme update --all
			run_wp_cli "${site_path}" "${wp_user}" core update-db
			run_wp_cli "${site_path}" "${wp_user}" db optimize
			run_wp_cli "${site_path}" "${wp_user}" db repair
			run_wp_cli "${site_path}" "${wp_user}" cron event run --due-now
			;;
		"${MODE_CORE}")
			run_wp_cli "${site_path}" "${wp_user}" core update
			run_wp_cli "${site_path}" "${wp_user}" core update-db
			;;
		"${MODE_PLUGINS}")
			run_wp_cli "${site_path}" "${wp_user}" plugin update --all
			;;
		"${MODE_THEMES}")
			run_wp_cli "${site_path}" "${wp_user}" theme update --all
			;;
		"${MODE_DB_OPTIMIZE}")
			run_wp_cli "${site_path}" "${wp_user}" db optimize
			run_wp_cli "${site_path}" "${wp_user}" db repair
			;;
		"${MODE_DB_FIX}")
			run_wp_cli "${site_path}" "${wp_user}" db repair
			;;
		"${MODE_CRON}")
			run_wp_cli "${site_path}" "${wp_user}" cron event run --due-now
			;;
		*)
			log_error "Unknown mode: ${mode}"
			return 1
			;;
	esac
}

ensure_sites_file() {
	if [[ -f "${SITES_FILE}" ]]; then
		log_info "Sites file found: ${SITES_FILE}"
		return 0
	fi

	log_warning "Sites file NOT found: ${SITES_FILE}"
	log_info "Checking for discovery script: Find_WP_Senior.sh"

	if [[ -f "${DISCOVER_SCRIPT}" && -x "${DISCOVER_SCRIPT}" ]]; then
		log_info "Running discovery script: ${DISCOVER_SCRIPT}"
		if "${DISCOVER_SCRIPT}"; then
			log_success "Discovery script completed."
		else
			log_warning "Discovery script exited with non-zero status."
		fi
	else
		log_warning "Discovery script not found or not executable: ${DISCOVER_SCRIPT}"
	fi

	# Re-check after discovery
	if [[ -f "${SITES_FILE}" ]]; then
		log_success "Sites file created by discovery script: ${SITES_FILE}"
		return 0
	fi

	# Fallback: manual input
	log_warning "No sites file found. Please provide the absolute path to a WordPress installation."
	read -r -p "Enter full path to WordPress root (e.g. /var/www/site.com): " user_path

	if [[ -z "${user_path}" ]]; then
		log_error "No path provided. Exiting."
		exit 1
	fi

	user_path="$(trim "${user_path}")"

	if [[ ! -d "${user_path}" ]]; then
		log_error "Directory does not exist: ${user_path}"
		exit 1
	fi

	if [[ ! -f "${user_path}/wp-config.php" ]] && [[ ! -f "${user_path}/wp-settings.php" ]]; then
		log_error "Not a valid WordPress installation: ${user_path}"
		exit 1
	fi

	# Save to wp-found.txt (overwrite)
	printf '%s\n' "${user_path}" > "${SITES_FILE}"
	log_success "Path saved to ${SITES_FILE}. Continuing..."
}

#########################################
###           MAIN LOGIC              ###
#########################################

# Validate WP-CLI
if ! command -v "${WP_CLI_PATH}" >/dev/null 2>&1; then
	log_error "WP-CLI not found at ${WP_CLI_PATH}. Please install it."
	exit 1
fi

# Root check
if [[ $EUID -ne 0 ]]; then
	log_error "This script must be run as root (to switch users via sudo)."
	exit 1
fi

# Parse mode
if [[ $# -ne 1 ]]; then
	usage
fi

case "$1" in
	--full|--core|--plugins|--themes|--db-optimize|--db-fix|--cron)
		readonly MODE="$1"
		;;
	*)
		log_error "Invalid mode: $1"
		usage
		;;
esac

# Ensure wp-found.txt exists
ensure_sites_file

log_info "Starting WordPress maintenance in '${MODE}' mode"
log_info "Reading sites from ${SITES_FILE}"

while IFS= read -r site_path || [[ -n "${site_path}" ]]; do
	site_path="$(trim "${site_path}")"
	[[ -z "${site_path}" || "${site_path}" =~ ^# ]] && continue
	[[ -d "${site_path}" ]] || { log_warning "Skipping (not a dir): ${site_path}"; continue; }

	log_info "Processing site: ${site_path}"
	((STATS[total_sites]++))

	wp_user="$(get_wp_user "${site_path}")" || {
		log_error "Skipping site due to user resolution failure: ${site_path}"
		continue
	}

	execute_mode "${MODE#--}" "${site_path}" "${wp_user}"
done < "${SITES_FILE}"

log_success "Maintenance completed."
echo -e "\n${GREEN}=== SUMMARY ===${RESET}"
echo "Sites processed: ${STATS[total_sites]}"
echo "Successful ops:  ${STATS[success_ops]}"
echo "Errors:          ${STATS[error_ops]}"
echo "Log file:        ${LOG_FILE}"

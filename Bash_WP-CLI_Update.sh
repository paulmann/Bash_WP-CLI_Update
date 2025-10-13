#!/bin/sh
#!/usr/bin/env bash
###############################################################################
# WordPress Maintenance Automation
# Description: Secure, fast, and modular WP-CLI manager for multiple sites.
# Author: Mikhail Deynekin <mid1977@gmail.com>
# Repository: https://github.com/paulmann/Bash_WP-CLI_Update
# License: MIT
# Version: 4.4
###############################################################################
#set -euo pipefail
#shopt -s inherit_errexit

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
readonly ERROR_LOG_FILE="${SCRIPT_DIR}/wp_cli_errors.log"
readonly WP_CLI_PATH="/usr/local/bin/wp"

# Operation modes
readonly MODE_FULL="full"
readonly MODE_CORE="core"
readonly MODE_PLUGINS="plugins"
readonly MODE_THEMES="themes"
readonly MODE_DB_OPTIMIZE="db-optimize"
readonly MODE_DB_FIX="db-fix"
readonly MODE_CRON="cron"
readonly MODE_ASTRA="astra"

# Astra Pro license key (replace YOUR_KEY with actual license key)
readonly ASTRA_KEY="YOUR_KEY"

# ANSI colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly RESET='\033[0m'

#########################################
###        GLOBAL VARIABLES           ###
#########################################
declare -A STATS=(
	[total_sites]=0
	[success_ops]=0
	[error_ops]=0
)

DEBUG_MODE=false

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
		"DEBUG")   echo -e "${CYAN}🐞 ${msg}${RESET}" >&2 ;;
		*)         echo "${msg}" ;;
	esac
}

log_error_detail() {
	local context="$1" command="$2" output="$3" exit_code="$4"
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	
	cat >> "${ERROR_LOG_FILE}" <<EOF
[${timestamp}] [ERROR DETAIL]
Context: ${context}
Command: ${command}
Exit Code: ${exit_code}
Output: ${output}
---
EOF
}

log_info()    { log "INFO" "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_error()   { log "ERROR" "$1"; }
log_warning() { log "WARNING" "$1"; }
log_debug()   { 
	if [[ "${DEBUG_MODE}" == true ]]; then
		log "DEBUG" "$1"
	fi
}

debug_echo() {
	if [[ "${DEBUG_MODE}" == true ]]; then
		echo -e "${CYAN}🐞 DEBUG: $1${RESET}" >&2
	fi
}

usage() {
	cat <<EOF
WordPress Maintenance Automation v${SCRIPT_VERSION}
Usage: $0 [MODE] [OPTIONS]

Modes:
  --full, -f       : Full update (core, plugins, themes, DB optimize/repair, cron)
  --core, -c       : Update WordPress core only
  --plugins, -p    : Update all plugins
  --themes, -t     : Update all themes
  --db-optimize, -d: Optimize and repair database
  --db-fix, -x     : Repair database only
  --cron, -r       : Run due cron events
  --astra, -s      : Update Astra plugin with license activation if needed

Options:
  --DEBUG, -D      : Enable debug mode with detailed logging

Example:
  $0 --plugins
  $0 -p
  $0 --full --DEBUG
  $0 -f -D
  $0 --astra

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

	debug_echo "🚩 START get_wp_user for: ${wp_root}"
	debug_echo "📁 Checking wp-config.php at: ${wp_config}"
	
	# Метод 1: Владелец файла wp-config.php
	if [[ -f "${wp_config}" ]]; then
		debug_echo "📄 wp-config.php exists, checking file owner"
		local file_owner
		file_owner="$(stat -c '%U' "${wp_config}" 2>&1 || echo "stat_error")"
		debug_echo "👤 File owner of wp-config.php: '${file_owner}'"
		
		if [[ -n "${file_owner}" && "${file_owner}" != "root" && "${file_owner}" != "stat_error" ]]; then
			debug_echo "✅ Using file owner: ${file_owner}"
			if id -u "${file_owner}" >/dev/null 2>&1; then
				debug_echo "✅ User ${file_owner} exists in system"
				printf '%s' "${file_owner}"
				return 0
			else
				debug_echo "❌ User ${file_owner} does NOT exist in system"
			fi
		else
			debug_echo "❌ File owner not suitable: '${file_owner}'"
		fi
	else
		debug_echo "❌ wp-config.php not found at: ${wp_config}"
	fi

	# Метод 2: Владелец директории
	debug_echo "📁 Checking directory owner"
	local dir_owner
	dir_owner="$(stat -c '%U' "${wp_root}" 2>&1 || echo "stat_error")"
	debug_echo "👤 Directory owner: '${dir_owner}'"

	if [[ -n "${dir_owner}" && "${dir_owner}" != "root" && "${dir_owner}" != "stat_error" ]]; then
		debug_echo "✅ Using directory owner: ${dir_owner}"
		if id -u "${dir_owner}" >/dev/null 2>&1; then
			debug_echo "✅ User ${dir_owner} exists in system"
			printf '%s' "${dir_owner}"
			return 0
		else
			debug_echo "❌ User ${dir_owner} does NOT exist in system"
		fi
	else
		debug_echo "❌ Directory owner not suitable: '${dir_owner}'"
	fi

	# Метод 3: Извлечение из пути
	debug_echo "🛣️  Trying to extract user from path"
	IFS='/' read -r -a path_parts <<< "${wp_root}"
	debug_echo "📊 Path parts: ${#path_parts[@]} - ${path_parts[*]}"
	
	if [[ ${#path_parts[@]} -ge 4 ]]; then
		local potential_user="${path_parts[3]}"  # /var/www/USER/data/...
		debug_echo "👤 Potential user from path: '${potential_user}'"
		
		if id -u "${potential_user}" >/dev/null 2>&1; then
			debug_echo "✅ Using user from path: ${potential_user}"
			printf '%s' "${potential_user}"
			return 0
		else
			debug_echo "❌ User from path does NOT exist: ${potential_user}"
		fi
	else
		debug_echo "❌ Path too short for extraction"
	fi

	# Метод 4: DB_USER из wp-config.php
	if [[ -f "${wp_config}" ]]; then
		debug_echo "🔍 Trying DB_USER from wp-config.php"
		local db_user
		db_user="$(grep -E "define\s*\(\s*'DB_USER'" "${wp_config}" 2>/dev/null | \
		           sed -E "s/.*'DB_USER'\s*,\s*'([^']+)'.*/\1/" | tail -n1)"
		debug_echo "👤 DB_USER from wp-config: '${db_user}'"

		if [[ -n "${db_user}" ]] && id -u "${db_user}" >/dev/null 2>&1; then
			debug_echo "✅ Using DB_USER: ${db_user}"
			printf '%s' "${db_user}"
			return 0
		else
			debug_echo "❌ DB_USER not found or invalid: '${db_user}'"
		fi
	fi

	debug_echo "💥 ALL METHODS FAILED - Cannot determine WordPress user for: ${wp_root}"
	return 1
}

run_wp_cli() {
	local site_path="$1" user="$2" cmd=("${@:3}")
	
	debug_echo "🚩 START run_wp_cli"
	debug_echo "📍 site_path: ${site_path}"
	debug_echo "👤 user: ${user}"
	debug_echo "⚡ command: wp ${cmd[*]}"
	
	# Проверяем существование пользователя
	if ! id -u "${user}" >/dev/null 2>&1; then
		debug_echo "💥 USER CHECK FAILED: User '${user}' does not exist"
		log_error "User '${user}' does not exist. Cannot run WP-CLI command."
		((STATS[error_ops]++))
		return 1
	fi
	debug_echo "✅ User '${user}' exists"
	
	# Проверяем существование директории
	if [[ ! -d "${site_path}" ]]; then
		debug_echo "💥 DIRECTORY CHECK FAILED: Directory '${site_path}' does not exist"
		log_error "Directory '${site_path}' does not exist."
		((STATS[error_ops]++))
		return 1
	fi
	debug_echo "✅ Directory '${site_path}' exists"
	
	log_info "Running: wp ${cmd[*]} on ${site_path} as ${user}"
	
	# Подготовка команды как в рабочем скрипте wp-cli.sh
	local wp_command="${WP_CLI_PATH} --path=\"${site_path}\" ${cmd[*]} --skip-plugins=saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer --quiet --allow-root"
	local home_dir="$(dirname "$(dirname "${site_path}")")"
	local domain="$(basename "${site_path}")"
	
	debug_echo "🏠 home_dir: ${home_dir}"
	debug_echo "🌐 domain: ${domain}"
	debug_echo "🔧 wp_command: ${wp_command}"
	
	local export_vars="export DOCUMENT_URI=${domain} && DOCUMENT_ROOT=${site_path} && HOMEDIR=${home_dir} && export HTTP_HOST=${domain}"
	local full_command="cd ${site_path} && ${export_vars} && ${wp_command}"
	
	debug_echo "🔧 full_command: ${full_command}"
	debug_echo "👤 Executing as user: ${user}"
	
	debug_echo "🎯 EXECUTING COMMAND: su - \"${user}\" -c \"${full_command}\""
	
	# Выполняем команду и перехватываем ВЕСЬ вывод
	local output
	local exit_code=0
	
	output=$(su - "${user}" -c "${full_command}" 2>&1) || exit_code=$?
	
	debug_echo "📤 COMMAND OUTPUT: ${output}"
	debug_echo "🔚 EXIT CODE: ${exit_code}"
	
	if [[ ${exit_code} -eq 0 ]]; then
		log_success "Success: wp ${cmd[*]}"
		((STATS[success_ops]++))
		debug_echo "✅ Command completed successfully"
		return 0
	else
		log_error "Failed: wp ${cmd[*]} (exit code: ${exit_code})"
		log_error_detail "run_wp_cli" "wp ${cmd[*]}" "${output}" "${exit_code}"
		((STATS[error_ops]++))
		debug_echo "💥 Command failed with exit code: ${exit_code}"
		return 1
	fi
}

execute_mode() {
	local mode="$1" site_path="$2" wp_user="$3"
	
	debug_echo "🚩 START execute_mode"
	debug_echo "📋 mode: ${mode}"
	debug_echo "📍 site_path: ${site_path}"
	debug_echo "👤 wp_user: ${wp_user}"

	case "${mode}" in
		"${MODE_FULL}")
			debug_echo "🔧 Executing FULL mode operations"
			run_wp_cli "${site_path}" "${wp_user}" core update
			run_wp_cli "${site_path}" "${wp_user}" plugin update --all
			
			# Astra processing in full mode if key is set
			if [[ "${ASTRA_KEY}" != "YOUR_KEY" ]]; then
				debug_echo "🔧 Processing Astra in FULL mode"
				_handle_astra_in_full_mode "${site_path}" "${wp_user}"
			else
				debug_echo "⏩ Skipping Astra in FULL mode - key not set"
			fi
			
			run_wp_cli "${site_path}" "${wp_user}" theme update --all
			run_wp_cli "${site_path}" "${wp_user}" core update-db
			run_wp_cli "${site_path}" "${wp_user}" db optimize
			run_wp_cli "${site_path}" "${wp_user}" db repair
			run_wp_cli "${site_path}" "${wp_user}" cron event run --due-now
			;;
		"${MODE_CORE}")
			debug_echo "🔧 Executing CORE mode operations"
			run_wp_cli "${site_path}" "${wp_user}" core update
			run_wp_cli "${site_path}" "${wp_user}" core update-db
			;;
		"${MODE_PLUGINS}")
			debug_echo "🔧 Executing PLUGINS mode operations"
			run_wp_cli "${site_path}" "${wp_user}" plugin update --all
			;;
		"${MODE_THEMES}")
			debug_echo "🔧 Executing THEMES mode operations"
			run_wp_cli "${site_path}" "${wp_user}" theme update --all
			;;
		"${MODE_DB_OPTIMIZE}")
			debug_echo "🔧 Executing DB_OPTIMIZE mode operations"
			run_wp_cli "${site_path}" "${wp_user}" db optimize
			run_wp_cli "${site_path}" "${wp_user}" db repair
			;;
		"${MODE_DB_FIX}")
			debug_echo "🔧 Executing DB_FIX mode operations"
			run_wp_cli "${site_path}" "${wp_user}" db repair
			;;
		"${MODE_CRON}")
			debug_echo "🔧 Executing CRON mode operations"
			run_wp_cli "${site_path}" "${wp_user}" cron event run --due-now
			;;
		"${MODE_ASTRA}")
			debug_echo "🔧 Executing ASTRA mode operations"
			_handle_astra_operations "${site_path}" "${wp_user}"
			;;
		*)
			log_error "Unknown mode: ${mode}"
			return 1
			;;
	esac
	
	debug_echo "✅ COMPLETED execute_mode for ${mode}"
}

_handle_astra_in_full_mode() {
	local site_path="$1" wp_user="$2"
	
	debug_echo "🚩 START _handle_astra_in_full_mode"
	
	# Check if Astra plugin is installed and active
	log_info "Checking Astra plugin status for: ${site_path}"
	
	if ! run_wp_cli "${site_path}" "${wp_user}" plugin status astra-addon >/dev/null 2>&1; then
		log_warning "Astra plugin not found or not active for: ${site_path}"
		debug_echo "❌ Astra plugin check failed"
		return 0  # Continue execution in full mode even if Astra not found
	fi
	
	log_success "Astra plugin found and active"
	debug_echo "✅ Astra plugin is installed and active"
	
	# Check if update is available
	log_info "Checking if Astra plugin update is available"
	debug_echo "🔍 Checking for available updates with dry-run"
	
	local dry_run_output
	dry_run_output=$(su - "${wp_user}" -c "cd ${site_path} && ${WP_CLI_PATH} --path=\"${site_path}\" plugin update astra-addon --dry-run --skip-plugins=saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer --quiet --allow-root 2>&1")
	
	debug_echo "📊 Dry-run output: ${dry_run_output}"
	
	# If dry-run shows update is available, try to update
	if echo "${dry_run_output}" | grep -q "Available"; then
		log_info "Astra update available, attempting update"
		debug_echo "🔄 Running Astra plugin update"
		
		if run_wp_cli "${site_path}" "${wp_user}" plugin update astra-addon; then
			log_success "Astra plugin updated successfully in full mode"
			debug_echo "✅ Astra plugin updated successfully"
		else
			log_warning "Astra plugin update failed, activating license and retrying"
			debug_echo "🔑 Astra license activation needed"
			
			# Activate license and retry update
			if run_wp_cli "${site_path}" "${wp_user}" brainstormforce license activate astra-addon "${ASTRA_KEY}"; then
				log_success "Astra license activated successfully"
				debug_echo "✅ License activation successful"
				
				# Retry update after license activation
				if run_wp_cli "${site_path}" "${wp_user}" plugin update astra-addon; then
					log_success "Astra plugin updated successfully after license activation"
					debug_echo "✅ Astra plugin updated after license activation"
				else
					log_error "Astra plugin update failed even after license activation"
					debug_echo "❌ Update failed after license activation"
				fi
			else
				log_error "Failed to activate Astra license"
				debug_echo "❌ License activation failed"
			fi
		fi
	else
		log_info "No Astra update available"
		debug_echo "ℹ️ No Astra update available"
	fi
	
	debug_echo "✅ COMPLETED _handle_astra_in_full_mode"
}

_handle_astra_operations() {
	local site_path="$1" wp_user="$2"
	
	debug_echo "🚩 START _handle_astra_operations"
	
	# Check if Astra license key is set
	if [[ "${ASTRA_KEY}" == "YOUR_KEY" ]]; then
		log_error "Astra license key is not configured. Please set ASTRA_KEY in the script."
		echo -e "${RED}❌ ERROR: Astra license key is not configured.${RESET}"
		echo -e "${YELLOW}Please edit the script and set ASTRA_KEY to your actual license key.${RESET}"
		return 1
	fi
	
	# Check if Astra plugin is installed and active
	log_info "Checking Astra plugin status for: ${site_path}"
	
	if ! run_wp_cli "${site_path}" "${wp_user}" plugin status astra-addon >/dev/null 2>&1; then
		log_warning "Astra plugin not found or not active for: ${site_path}"
		debug_echo "❌ Astra plugin check failed"
		return 1
	fi
	
	log_success "Astra plugin found and active"
	debug_echo "✅ Astra plugin is installed and active"
	
	# Try to update Astra plugin
	log_info "Attempting to update Astra plugin"
	debug_echo "🔄 Running initial Astra plugin update"
	
	if run_wp_cli "${site_path}" "${wp_user}" plugin update astra-addon; then
		log_success "Astra plugin updated successfully"
		debug_echo "✅ Astra plugin updated on first attempt"
		return 0
	fi
	
	# If update failed, check if update is available with dry-run
	log_warning "Astra plugin update failed, checking if update is available"
	debug_echo "🔍 Checking for available updates with dry-run"
	
	local dry_run_output
	dry_run_output=$(su - "${wp_user}" -c "cd ${site_path} && ${WP_CLI_PATH} --path=\"${site_path}\" plugin update astra-addon --dry-run --skip-plugins=saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer --quiet --allow-root 2>&1")
	
	debug_echo "📊 Dry-run output: ${dry_run_output}"
	
	# If dry-run shows update is available but previous update failed, likely license issue
	if echo "${dry_run_output}" | grep -q "Available"; then
		log_info "Astra update available but failed, activating license and retrying"
		debug_echo "🔑 Astra license activation needed"
		
		# Activate license
		log_info "Activating Astra license"
		debug_echo "🔑 Activating license with key: ${ASTRA_KEY}"
		
		if run_wp_cli "${site_path}" "${wp_user}" brainstormforce license activate astra-addon "${ASTRA_KEY}"; then
			log_success "Astra license activated successfully"
			debug_echo "✅ License activation successful"
			
			# Retry update after license activation
			log_info "Retrying Astra plugin update after license activation"
			debug_echo "🔄 Retrying plugin update"
			
			if run_wp_cli "${site_path}" "${wp_user}" plugin update astra-addon; then
				log_success "Astra plugin updated successfully after license activation"
				debug_echo "✅ Astra plugin updated after license activation"
				return 0
			else
				log_error "Astra plugin update failed even after license activation"
				debug_echo "❌ Update failed after license activation"
				return 1
			fi
		else
			log_error "Failed to activate Astra license"
			debug_echo "❌ License activation failed"
			return 1
		fi
	else
		log_info "No Astra update available or dry-run check failed"
		debug_echo "ℹ️ No update available or dry-run issue"
		return 0
	fi
	
	debug_echo "✅ COMPLETED _handle_astra_operations"
}

ensure_sites_file() {
	debug_echo "🚩 START ensure_sites_file"
	
	if [[ -f "${SITES_FILE}" ]]; then
		log_info "Sites file found: ${SITES_FILE}"
		debug_echo "✅ Sites file exists"
		return 0
	fi

	log_warning "Sites file NOT found: ${SITES_FILE}"
	log_info "Checking for discovery script: Find_WP_Senior.sh"

	if [[ -f "${DISCOVER_SCRIPT}" && -x "${DISCOVER_SCRIPT}" ]]; then
		log_info "Running discovery script: ${DISCOVER_SCRIPT}"
		debug_echo "🔍 Executing discovery script: ${DISCOVER_SCRIPT}"
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
	debug_echo "📝 User provided path: ${user_path}"

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
	debug_echo "✅ Completed ensure_sites_file"
}

#########################################
###           MAIN LOGIC              ###
#########################################

debug_echo "🚀 SCRIPT STARTING: ${SCRIPT_NAME}"

# Initialize error log
debug_echo "📝 Initializing error log: ${ERROR_LOG_FILE}"
echo "=== WordPress CLI Error Log - Started at: $(date) ===" > "${ERROR_LOG_FILE}"

# Parse arguments
debug_echo "🔧 Parsing command line arguments: $*"

DEBUG_MODE=false
MODE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--DEBUG|-D)
			DEBUG_MODE=true
			debug_echo "🔍 DEBUG mode enabled"
			shift
			;;
		--full|-f)
			MODE="$MODE_FULL"
			debug_echo "🎯 Mode set to: FULL"
			shift
			;;
		--core|-c)
			MODE="$MODE_CORE"
			debug_echo "🎯 Mode set to: CORE"
			shift
			;;
		--plugins|-p)
			MODE="$MODE_PLUGINS"
			debug_echo "🎯 Mode set to: PLUGINS"
			shift
			;;
		--themes|-t)
			MODE="$MODE_THEMES"
			debug_echo "🎯 Mode set to: THEMES"
			shift
			;;
		--db-optimize|-d)
			MODE="$MODE_DB_OPTIMIZE"
			debug_echo "🎯 Mode set to: DB_OPTIMIZE"
			shift
			;;
		--db-fix|-x)
			MODE="$MODE_DB_FIX"
			debug_echo "🎯 Mode set to: DB_FIX"
			shift
			;;
		--cron|-r)
			MODE="$MODE_CRON"
			debug_echo "🎯 Mode set to: CRON"
			shift
			;;
		--astra|-s)
			MODE="$MODE_ASTRA"
			debug_echo "🎯 Mode set to: ASTRA"
			shift
			;;
		*)
			log_error "Invalid argument: $1"
			usage
			;;
	esac
done

if [[ -z "${MODE}" ]]; then
	log_error "No mode specified."
	usage
fi

readonly DEBUG_MODE
readonly MODE

debug_echo "🎯 Final mode: ${MODE}"
debug_echo "🔍 Final DEBUG_MODE: ${DEBUG_MODE}"

# Validate WP-CLI
debug_echo "🔧 Validating WP-CLI installation at: ${WP_CLI_PATH}"
if ! command -v "${WP_CLI_PATH}" >/dev/null 2>&1; then
	log_error "WP-CLI not found at ${WP_CLI_PATH}. Please install it."
	exit 1
fi
debug_echo "✅ WP-CLI validation passed"

# Root check
debug_echo "🔧 Checking if running as root"
if [[ $EUID -ne 0 ]]; then
	log_error "This script must be run as root (to switch users via sudo)."
	exit 1
fi
debug_echo "✅ Root check passed"

# Ensure wp-found.txt exists
debug_echo "🔧 Ensuring sites file exists"
ensure_sites_file

log_info "Starting WordPress maintenance in '${MODE}' mode"
log_info "Reading sites from ${SITES_FILE}"

debug_echo "🔄 Starting main processing loop"
while IFS= read -r site_path || [[ -n "${site_path}" ]]; do
	site_path="$(trim "${site_path}")"
	[[ -z "${site_path}" || "${site_path}" =~ ^# ]] && {
		debug_echo "⏩ Skipping empty or commented line"
		continue
	}
	
	debug_echo "📍 Processing site path: '${site_path}'"
	
	[[ -d "${site_path}" ]] || { 
		log_warning "Skipping (not a dir): ${site_path}"
		debug_echo "⏩ Path is not a directory, skipping"
		continue
	}

	log_info "Processing site: ${site_path}"
	((STATS[total_sites]++))
	debug_echo "📊 Total sites counter: ${STATS[total_sites]}"

	debug_echo "🔍 Getting WordPress user for: ${site_path}"
	wp_user="$(get_wp_user "${site_path}")" || {
		log_error "Skipping site due to user resolution failure: ${site_path}"
		debug_echo "⏩ User resolution failed, skipping site"
		continue
	}
	debug_echo "✅ Resolved WordPress user: '${wp_user}'"

	debug_echo "🔧 Executing mode '${MODE}' for site: ${site_path}"
	execute_mode "${MODE}" "${site_path}" "${wp_user}"
	debug_echo "✅ Completed processing for site: ${site_path}"
	
done < "${SITES_FILE}"

debug_echo "✅ Main processing loop completed"

log_success "Maintenance completed."
echo -e "\n${GREEN}=== SUMMARY ===${RESET}"
echo "Sites processed: ${STATS[total_sites]}"
echo "Successful ops:  ${STATS[success_ops]}"
echo "Errors:          ${STATS[error_ops]}"
echo "Log file:        ${LOG_FILE}"
echo "Error log:       ${ERROR_LOG_FILE}"

debug_echo "🎉 Script completed successfully"

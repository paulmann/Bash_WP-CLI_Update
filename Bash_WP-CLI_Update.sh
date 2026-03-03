#!/usr/bin/env bash
###############################################################################
# WordPress Maintenance Automation
# Description: Secure, fast, and modular WP-CLI manager for multiple sites.
# Author: Mikhail Deynekin <mid1977@gmail.com>
# Repository: https://github.com/paulmann/Bash_WP-CLI_Update
# License: MIT
# Version: 5.0
###############################################################################
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

#########################################
###           CONSTANTS               ###
#########################################
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="5.0"

# Global variable to preserve last WP-CLI error
LAST_WP_CLI_ERROR=""
export LAST_WP_CLI_ERROR
HEADER_SHOWN=false

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
readonly MODE_LIST_PLUGINS="list-plugins"
readonly MODE_PLUGIN_MANAGE="plugin-manage"

# Astra license key (replace with your actual key)
readonly ASTRA_KEY="a1d0c3d68c9b4227e2c86e9a59103d7f"

# ANSI colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RESET='\033[0m'
readonly WHITE='\033[0;37m'

# Plugin actions
readonly ACTION_ACTIVATE="activate"
readonly ACTION_DEACTIVATE="deactivate"
readonly ACTION_DELETE="delete"

# Terminal UI settings
readonly TABLE_WIDTH=90
readonly PROGRESS_CHAR="█"

#########################################
###        GLOBAL VARIABLES           ###
#########################################
declare -A STATS=(
	[total_sites]=0
	[success_ops]=0
	[error_ops]=0
)

DEBUG_MODE=false
TARGET_SITE=""
PLUGIN_NAME=""
PLUGIN_ACTION=""
FORCE_MODE=false
JSON_OUTPUT=false

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
		"INFO")    echo -e "${BLUE}ℹ ${msg}${RESET}" >&2 ;;
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
log_debug() { 
	if [[ "${DEBUG_MODE}" == true ]]; then
		log "DEBUG" "$1"
	fi
}

debug_echo() {
	if [[ "${DEBUG_MODE}" == true ]]; then
		echo -e "${CYAN}🐞 DEBUG: $1${RESET}" >&2
	fi
}

# ---------------------------------------------------------------------
# Modern progress indicator for terminal UI (FIXED v3)
# ---------------------------------------------------------------------
show_progress() {
    local current="$1"
    local total="$2"
    local message="${3:-Processing}"
    
    if [[ -z "${total}" || "${total}" -eq 0 ]] 2>/dev/null; then
        total=1
    fi
    if [[ -z "${current}" || "${current}" -eq 0 ]] 2>/dev/null; then
        current=1
    fi
    
    local percent=$(( current * 100 / total ))
    local filled=$(( percent * 40 / 100 ))
    local empty=$(( 40 - filled ))
    
    printf "\r\033[K${DIM}[${GREEN}"
    printf '%*s' "${filled}" '' | tr ' ' "${PROGRESS_CHAR}"
    printf "${RESET}"
    printf '%*s' "${empty}" '' | tr ' ' '░'
    printf "${DIM}]${RESET} ${message}\n" >&2
}

# ---------------------------------------------------------------------
# Show final newline after progress bar (call before summary)
# ---------------------------------------------------------------------
finalize_progress() {
    echo "" >&2
}

usage() {
	cat <<EOF
WordPress Maintenance Automation v${SCRIPT_VERSION}
Usage: ${SCRIPT_NAME} [MODE] [OPTIONS]

Modes:
  --full, -f           : Full update (core, plugins, themes, DB optimize/repair, cron)
  --core, -c           : Update WordPress core only
  --plugins, -p        : Update all plugins
  --themes, -t         : Update all themes
  --db-optimize, -d    : Optimize and repair database
  --db-fix, -x         : Repair database only
  --cron, -r           : Run due cron events
  --astra, -s          : Update Astra plugin with license activation if needed
  --list-plugins, -l   : List all plugins for site(s) with modern table view
  --plugin-manage, -m  : Manage plugin (activate/deactivate/delete)

Options:
  --DEBUG, -D                  : Enable debug mode with detailed logging
  --site, -S <path>            : Target a specific site path (optional, overrides wp-found.txt)
  --action, -A <action>        : Plugin action: activate|deactivate|delete (for --plugin-manage)
  --name, -N <plugin_name>     : Plugin slug or partial name for matching
  --force, -F                  : Skip confirmation for destructive actions (delete)
  --json, -J                   : Output in JSON format (for --list-plugins)
  --help, -h                   : Show this help message

Examples:
  ${SCRIPT_NAME} --plugins
  ${SCRIPT_NAME} -p
  ${SCRIPT_NAME} --full --DEBUG
  ${SCRIPT_NAME} --list-plugins --site /var/www/example.com
  ${SCRIPT_NAME} --list-plugins -N "woocommerce" --json
  ${SCRIPT_NAME} --plugin-manage --action deactivate --name "jetpack" --site /var/www/example.com
  ${SCRIPT_NAME} -m -A delete -N "old-plugin" -S /var/www/example.com --force

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

# ---------------------------------------------------------------------
# Helper: Clean potential PHP warnings/notices from command output and
#         ensure we have valid JSON. If output becomes empty, return "[]".
# ---------------------------------------------------------------------
clean_json_output() {
	local raw_output="$1"
	local cleaned

	# If output doesn't start with '[', try to strip everything up to the first '['
	if [[ "${raw_output}" != "["* ]]; then
		debug_echo "⚠️ Output does not start with '[', stripping leading lines..."
		cleaned=$(echo "${raw_output}" | sed -n '/^\[/,$p')
	else
		cleaned="${raw_output}"
	fi

	# If after stripping we have empty output, assume empty plugin list
	if [[ -z "${cleaned}" ]]; then
		debug_echo "ℹ️ Output became empty after stripping. Assuming no plugins (empty array)."
		cleaned="[]"
	fi

	# Final validation: must start with '['
	if [[ "${cleaned:0:1}" != "[" ]]; then
		log_error "Cannot find valid JSON array in output. Raw output: ${raw_output}"
		return 1
	fi

	printf '%s' "${cleaned}"
	return 0
}

# ---------------------------------------------------------------------
# Get WordPress system user for a given site path
# Uses multiple methods: owner of wp-config.php, directory owner,
# path-based guessing, DB_USER from wp-config.php
# ---------------------------------------------------------------------
get_wp_user() {
	local wp_root="$1"
	local wp_config="${wp_root}/wp-config.php"

	debug_echo "🚩 START get_wp_user for: ${wp_root}"
	debug_echo "📁 Checking wp-config.php at: ${wp_config}"
	
	# Method 1: owner of wp-config.php
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

	# Method 2: directory owner
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

	# Method 3: extract user from path (e.g., /var/www/USER/data/...)
	debug_echo "🛣️  Trying to extract user from path"
	IFS='/' read -r -a path_parts <<< "${wp_root}"
	debug_echo "📊 Path parts: ${#path_parts[@]} - ${path_parts[*]}"
	
	if [[ ${#path_parts[@]} -ge 4 ]]; then
		local potential_user="${path_parts[3]}"
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

	# Method 4: DB_USER from wp-config.php
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

# ---------------------------------------------------------------------
# Run any WP-CLI command with proper environment and user switching
# Enhanced with detailed error output display
# ---------------------------------------------------------------------
run_wp_cli() {
    local site_path="$1" user="$2"
    shift 2
    local -a cmd=("$@")
    debug_echo "🚩 START run_wp_cli"
    debug_echo "📍 site_path: ${site_path}"
    debug_echo "👤 user: ${user}"
    debug_echo "⚡ command: wp ${cmd[*]}"
    
    # Check if user exists
    if ! id -u "${user}" >/dev/null 2>&1; then
        debug_echo "💥 USER CHECK FAILED: User '${user}' does not exist"
        log_error "User '${user}' does not exist. Cannot run WP-CLI command."
        ((STATS[error_ops]++)) || true
        return 1
    fi
    debug_echo "✅ User '${user}' exists"
    
    # Check if directory exists
    if [[ ! -d "${site_path}" ]]; then
        debug_echo "💥 DIRECTORY CHECK FAILED: Directory '${site_path}' does not exist"
        log_error "Directory '${site_path}' does not exist."
        ((STATS[error_ops]++)) || true
        return 1
    fi
    debug_echo "✅ Directory '${site_path}' exists"
    
    log_info "Running: wp ${cmd[*]} on ${site_path} as ${user}"
    
    # Build command with proper quoting
    local wp_command="${WP_CLI_PATH} --path=\"${site_path}\" ${cmd[*]} --skip-plugins=saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer --quiet --allow-root"
    local home_dir
    home_dir="$(dirname "$(dirname "${site_path}")")"
    local domain
    domain="$(basename "${site_path}")"
    debug_echo "🏠 home_dir: ${home_dir}"
    debug_echo "🌐 domain: ${domain}"
    debug_echo "🔧 wp_command: ${wp_command}"
    
    # Export necessary environment variables
    local export_vars="export DOCUMENT_URI=\"${domain}\" && export DOCUMENT_ROOT=\"${site_path}\" && export HOMEDIR=\"${home_dir}\" && export HTTP_HOST=\"${domain}\""
    local full_command="cd \"${site_path}\" && ${export_vars} && ${wp_command}"
    debug_echo "🔧 full_command: ${full_command}"
    debug_echo "👤 Executing as user: ${user}"
    debug_echo "🎯 EXECUTING COMMAND: su - \"${user}\" -c \"${full_command}\""
    
    local output
    local exit_code=0
    
    # Capture both stdout and stderr
    output=$(su - "${user}" -c "${full_command}" 2>&1) || exit_code=$?
    
    debug_echo "📤 COMMAND OUTPUT (length: ${#output} bytes):"
    if [[ -n "${output}" ]]; then
        echo "${output}" | while IFS= read -r line; do
            debug_echo "   ${line}"
        done
    fi
    debug_echo "🔚 EXIT CODE: ${exit_code}"
    
    if [[ ${exit_code} -eq 0 ]]; then
        log_success "Success: wp ${cmd[*]}"
        ((STATS[success_ops]++)) || true
        debug_echo "✅ Command completed successfully"
        # Output successful command result if not empty
        if [[ -n "${output}" ]]; then
            echo "${output}"
        fi
        return 0
    else
        log_error "Failed: wp ${cmd[*]} (exit code: ${exit_code})"
        log_error_detail "run_wp_cli" "wp ${cmd[*]}" "${output}" "${exit_code}"
        ((STATS[error_ops]++)) || true
        debug_echo "💥 Command failed with exit code: ${exit_code}"
        
        # Display actual error to user (not just in debug)
        if [[ -n "${output}" ]]; then
            echo "" >&2
            echo -e "${RED}┌─ WP-CLI Error Detail ──────────────────────────────────────${RESET}" >&2
            echo -e "${RED}│ Site: ${site_path}${RESET}" >&2
            echo -e "${RED}│ Command: wp ${cmd[*]}${RESET}" >&2
            echo -e "${RED}│ Exit Code: ${exit_code}${RESET}" >&2
            echo -e "${RED}├─────────────────────────────────────────────────────────────${RESET}" >&2
            
            # Show first 20 lines of error output
            local line_count=0
            echo "${output}" | while IFS= read -r line; do
                if [[ ${line_count} -lt 20 ]]; then
                    echo -e "${RED}│ ${line}${RESET}" >&2
                    ((line_count++)) || true
                fi
            done
            
            # If output is longer than 20 lines, indicate truncation
            local total_lines
            total_lines=$(echo "${output}" | wc -l)
            if [[ ${total_lines} -gt 20 ]]; then
                echo -e "${RED}│ [... ${total_lines} total lines, see log for full output]${RESET}" >&2
            fi
            
            echo -e "${RED}├─────────────────────────────────────────────────────────────${RESET}" >&2
            echo -e "${RED}│ Full error log: ${ERROR_LOG_FILE}${RESET}" >&2
            echo -e "${RED}└─────────────────────────────────────────────────────────────${RESET}" >&2
            echo "" >&2
        else
            echo -e "${RED}⚠ No error output captured (command failed silently)${RESET}" >&2
        fi
        
        return 1
    fi
}

# ---------------------------------------------------------------------
# Get list of installed plugins as cleaned JSON array.
# Enhanced with error preservation for calling functions
# ---------------------------------------------------------------------
get_plugins_json() {
    local site_path="$1" wp_user="$2"
    local home_dir domain export_vars base_cmd full_cmd plugin_list exit_code
    debug_echo "🚩 ENTER get_plugins_json for ${site_path}"
    home_dir="$(dirname "$(dirname "${site_path}")")"
    domain="$(basename "${site_path}")"
    export_vars="export DOCUMENT_URI=\"${domain}\" && export DOCUMENT_ROOT=\"${site_path}\" && export HOMEDIR=\"${home_dir}\" && export HTTP_HOST=\"${domain}\""
    base_cmd="${WP_CLI_PATH} --path=\"${site_path}\" plugin list --format=json --skip-plugins=saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer --quiet --allow-root"
    
    # First attempt: suppress stderr
    full_cmd="cd \"${site_path}\" && ${export_vars} && ${base_cmd} 2>/dev/null"
    debug_echo "📡 Running WP-CLI plugin list command (stderr suppressed)..."
    debug_echo "🔧 full_command: ${full_cmd}"
    plugin_list=$(su - "${wp_user}" -c "${full_cmd}" 2>&1)
    exit_code=$?
    debug_echo "📊 WP-CLI exit_code: ${exit_code}"
    
    if [[ ${exit_code} -eq 0 && -n "${plugin_list}" ]]; then
        if cleaned_json="$(clean_json_output "${plugin_list}" 2>/dev/null)"; then
            printf '%s' "${cleaned_json}"
            return 0
        fi
    fi
    
    # Second attempt without stderr suppression for error capture
    if [[ "${DEBUG_MODE}" == true ]]; then
        log_warning "First attempt failed. Retrying without stderr suppression for diagnostics..."
        full_cmd="cd \"${site_path}\" && ${export_vars} && ${base_cmd}"
        debug_echo "🔧 full_command: ${full_cmd}"
        plugin_list=$(su - "${wp_user}" -c "${full_cmd}" 2>&1)
        exit_code=$?
        debug_echo "📊 WP-CLI exit_code (second attempt): ${exit_code}"
        debug_echo "❌ Raw output from command (length: ${#plugin_list} bytes):"
        if [[ -n "${plugin_list}" ]]; then
            echo "${plugin_list}" | while IFS= read -r line; do
                debug_echo "   ${line}"
            done
        fi
        debug_echo "🔍 Used environment: DOCUMENT_URI='${domain}', DOCUMENT_ROOT='${site_path}', HOMEDIR='${home_dir}', HTTP_HOST='${domain}'"
        debug_echo "🔍 User: ${wp_user}"
    fi
    
    # 💡 Save error for calling functions
    LAST_WP_CLI_ERROR="${plugin_list}"
    export LAST_WP_CLI_ERROR
    
    log_error "Failed to retrieve plugin list for ${site_path} (exit ${exit_code})"
    
    # 💡 Display error to user
    if [[ -n "${LAST_WP_CLI_ERROR}" ]]; then
        echo "" >&2
        echo -e "${RED}┌─ Plugin List Error ────────────────────────────────────────${RESET}" >&2
        echo -e "${RED}│ Site: ${site_path}${RESET}" >&2
        echo -e "${RED}├─────────────────────────────────────────────────────────────${RESET}" >&2
        echo "${LAST_WP_CLI_ERROR}" | head -15 | while IFS= read -r line; do
            echo -e "${RED}│ ${line}${RESET}" >&2
        done
        echo -e "${RED}└─────────────────────────────────────────────────────────────${RESET}" >&2
        echo "" >&2
    fi
    
    return 1
}

# ---------------------------------------------------------------------
# List plugins for a site with modern terminal UI (or JSON)
# ---------------------------------------------------------------------
list_plugins_for_site() {
	local site_path="$1"
	local wp_user="$2"
	local plugin_filter="${3:-}"
	local json_mode="${4:-false}"
	
	debug_echo "🚩 ENTER list_plugins_for_site"
	debug_echo "   site_path: [${site_path}]"
	debug_echo "   wp_user: [${wp_user}]"
	debug_echo "   plugin_filter: [${plugin_filter}]"
	debug_echo "   json_mode: [${json_mode}]"
	
	# Input validation
	if [[ -z "${site_path}" ]]; then
		log_error "site_path is empty!"
		return 1
	fi
	if [[ -z "${wp_user}" ]]; then
		log_error "wp_user is empty!"
		return 1
	fi
	if [[ ! -d "${site_path}" ]]; then
		log_error "Directory does not exist: ${site_path}"
		return 1
	fi
	
# Get plugin list (first attempt with stderr suppressed)
local plugins_json
plugins_json="$(get_plugins_json "${site_path}" "${wp_user}" true)" || {
    # If suppressed fails, try without suppression for better error message
    log_warning "Failed to get plugin list with stderr suppressed, retrying without suppression..."
    plugins_json="$(get_plugins_json "${site_path}" "${wp_user}" false)" || {
        if [[ -n "${LAST_WP_CLI_ERROR:-}" ]]; then
            log_error "Cannot retrieve plugin list - WP-CLI failed with error above"
        else
            log_error "Cannot retrieve plugin list even without suppression."
        fi
        return 1
    }
}	
	# Apply filter if provided
	if [[ -n "${plugin_filter}" ]]; then
		debug_echo "🔍 Applying plugin filter: ${plugin_filter}"
		if command -v jq &>/dev/null; then
			plugins_json=$(echo "${plugins_json}" | jq -c "[.[] | select(.name | test(\"${plugin_filter}\"; \"i\"))]" 2>/dev/null) || plugins_json="[]"
		else
			# fallback: crude grep (less reliable)
			plugins_json=$(echo "${plugins_json}" | grep -i "${plugin_filter}" || true)
			plugins_json="[${plugins_json}]"
		fi
		debug_echo "📊 After filter: length ${#plugins_json}"
	fi
	
	# JSON mode output
	if [[ "${json_mode}" == "true" ]]; then
		debug_echo "📄 JSON output mode"
		if command -v jq &>/dev/null; then
			echo "${plugins_json}" | jq '.' 2>/dev/null || echo "[]"
		else
			echo "ERROR: jq required for JSON" >&2
			return 1
		fi
		return 0
	fi
	
	# Table output
	debug_echo "📊 Rendering table..."
	echo ""
	echo -e "${BOLD}${CYAN}📦 Plugins for: ${BOLD}${WHITE}${site_path}${RESET}"
	echo -e "${DIM}$(printf '─%.0s' $(seq 1 ${TABLE_WIDTH}))${RESET}"
	printf "${BOLD}%-40s %-12s %-10s %-8s %-15s${RESET}\n" "Plugin Name" "Status" "Version" "Update" "Slug"
	echo -e "${DIM}$(printf '─%.0s' $(seq 1 ${TABLE_WIDTH}))${RESET}"
	
	local count=0
	
	if command -v jq &>/dev/null; then
		while IFS= read -r line; do
			[[ -z "${line}" ]] && continue
			((count++)) || true
			
			local name status version update_avail slug
			name=$(echo "${line}" | jq -r '.name // "N/A"' 2>/dev/null)
			status=$(echo "${line}" | jq -r '.status // "unknown"' 2>/dev/null)
			version=$(echo "${line}" | jq -r '.version // "N/A"' 2>/dev/null)
			update_avail=$(echo "${line}" | jq -r '.update // "none"' 2>/dev/null)
			slug=$(echo "${line}" | jq -r '.slug // "N/A"' 2>/dev/null)
			
			debug_echo "   [#${count}] ${name} | ${status} | ${version}"
			
			local status_color="${GREEN}" status_symbol="●"
			case "${status}" in
				"active")   status_color="${GREEN}"; status_symbol="✓" ;;
				"inactive") status_color="${YELLOW}"; status_symbol="○" ;;
				*)          status_color="${RED}";   status_symbol="✗" ;;
			esac
			
			local update_ind="${GREEN}✓" update_txt="none"
			[[ "${update_avail}" == "available" ]] && { update_ind="${RED}✗"; update_txt="update"; }
			
			local disp_name="${name:0:39}"
			[[ ${#name} -gt 39 ]] && disp_name="${name:0:36}..."
			
			printf "%-40s ${status_color}${status_symbol} %-8s${RESET} %-10s ${update_ind} %-6s ${DIM}%s${RESET}\n" \
				"${disp_name}" "${status}" "${version}" "${update_txt}" "${slug:0:14}"
		done < <(echo "${plugins_json}" | jq -c '.[]' 2>/dev/null)
	else
		# Fallback without jq: use wp-cli table output
		log_warning "jq not found, using fallback table format"
		local table_out
		table_out=$(su - "${wp_user}" -c "cd '${site_path}' && ${WP_CLI_PATH} --path='${site_path}' plugin list --allow-root 2>&1") || true
		echo "${table_out}"
		count=$(echo "${table_out}" | grep -c "^|" || echo 0)
		count=$((count > 2 ? count - 2 : 0))
	fi
	
	echo -e "${DIM}$(printf '─%.0s' $(seq 1 ${TABLE_WIDTH}))${RESET}"
	echo -e "${DIM}Total: ${count} plugin(s)${RESET}"
	debug_echo "✅ Exit: count=${count}"
	return 0
}

# ---------------------------------------------------------------------
# Manage plugin (activate/deactivate/delete) with safety checks
# ---------------------------------------------------------------------
manage_plugin_for_site() {
	local site_path="$1" wp_user="$2" plugin_name="$3" action="$4" force="${5:-false}"
	
	debug_echo "🚩 START manage_plugin_for_site: ${action} '${plugin_name}' on ${site_path}"
	
	# Validate action
	case "${action}" in
		"${ACTION_ACTIVATE}"|"${ACTION_DEACTIVATE}"|"${ACTION_DELETE}") ;;
		*)
			log_error "Invalid action: ${action}. Must be: activate|deactivate|delete"
			return 1
			;;
	esac
	
# Get plugin list (with stderr suppressed)
local plugins_json
plugins_json="$(get_plugins_json "${site_path}" "${wp_user}" true)" || {
    if [[ -n "${LAST_WP_CLI_ERROR:-}" ]]; then
        log_error "Cannot manage plugin - WP-CLI failed with error above"
    else
        log_error "Failed to retrieve plugin list for ${site_path}"
    fi
    return 1
}	
	# Find matching plugin(s) by partial name (case-insensitive)
	local matching_plugins=""
	if command -v jq &>/dev/null; then
		matching_plugins=$(echo "${plugins_json}" | jq -r ".[] | select(.name | test(\"${plugin_name}\"; \"i\")) | .name" 2>/dev/null) || true
	else
		# fallback grep
		matching_plugins=$(echo "${plugins_json}" | grep -oi "\"name\"[[:space:]]*:[[:space:]]*\"[^\"]*${plugin_name}[^\"]*\"" | \
			sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' | sort -u) || true
	fi
	
	if [[ -z "${matching_plugins}" ]]; then
		log_error "No plugin found matching '${plugin_name}' on ${site_path}"
		log_info "Available plugins (use --list-plugins to see all):"
		if command -v jq &>/dev/null; then
			echo "${plugins_json}" | jq -r '.[].name' | head -10 | while read -r p; do
				echo "  $p"
			done
		else
			echo "${plugins_json}" | head -5 | tr ',' '\n' | grep -o '"name":"[^"]*"' | head -10 || true
		fi
		return 1
	fi
	
	# Handle multiple matches
	local plugin_count
	plugin_count=$(echo "${matching_plugins}" | grep -c . || echo 0)
	
	if [[ ${plugin_count} -gt 1 ]]; then
		log_warning "Multiple plugins match '${plugin_name}':"
		echo "${matching_plugins}" | while read -r p; do
			echo -e "  ${CYAN}•${RESET} ${p}"
		done
		echo ""
		log_info "Please specify a more exact plugin name or use the full slug"
		return 1
	fi
	
	local exact_plugin_name
	exact_plugin_name="${matching_plugins}"
	debug_echo "✅ Found exact plugin: ${exact_plugin_name}"
	
	# Get current status for smart handling
	local current_status="unknown"
	if command -v jq &>/dev/null; then
		current_status=$(echo "${plugins_json}" | jq -r ".[] | select(.name == \"${exact_plugin_name}\") | .status" 2>/dev/null) || true
	fi
	debug_echo "📊 Current plugin status: ${current_status}"
	
	# Confirmation for destructive actions (unless --force)
	if [[ "${action}" == "${ACTION_DELETE}" && "${force}" != "true" ]]; then
		echo ""
		echo -e "${BOLD}${RED}⚠️  DESTRUCTIVE ACTION WARNING${RESET}"
		echo -e "${DIM}─────────────────────────────────────────${RESET}"
		echo -e "Site:     ${BOLD}${site_path}${RESET}"
		echo -e "Plugin:   ${BOLD}${exact_plugin_name}${RESET}"
		echo -e "Action:   ${BOLD}DELETE${RESET} (permanent removal)"
		echo -e "${DIM}─────────────────────────────────────────${RESET}"
		echo -e "${YELLOW}This will permanently delete all plugin files and data.${RESET}"
		echo -e "${YELLOW}This action CANNOT be undone.${RESET}"
		echo ""
		read -r -p "Type 'DELETE' to confirm or any other key to cancel: " confirm
		if [[ "${confirm}" != "DELETE" ]]; then
			log_info "Plugin deletion cancelled by user"
			return 0
		fi
		echo -e "${GREEN}✓ Confirmed${RESET}"
	fi
	
	# Execute the action
	local wp_cmd=()
	local action_text=""
	
	case "${action}" in
		"${ACTION_ACTIVATE}")
			if [[ "${current_status}" == "active" ]]; then
				log_info "Plugin '${exact_plugin_name}' is already active"
				return 0
			fi
			wp_cmd=(plugin activate "${exact_plugin_name}")
			action_text="Activating"
			;;
		"${ACTION_DEACTIVATE}")
			if [[ "${current_status}" == "inactive" ]]; then
				log_info "Plugin '${exact_plugin_name}' is already inactive"
				return 0
			fi
			wp_cmd=(plugin deactivate "${exact_plugin_name}")
			action_text="Deactivating"
			;;
		"${ACTION_DELETE}")
			# Auto-deactivate if active before deletion
			if [[ "${current_status}" == "active" ]]; then
				log_info "Deactivating plugin before deletion: ${exact_plugin_name}"
				run_wp_cli "${site_path}" "${wp_user}" plugin deactivate "${exact_plugin_name}" || true
			fi
			wp_cmd=(plugin delete "${exact_plugin_name}")
			action_text="Deleting"
			;;
	esac
	
	log_info "${action_text} plugin: ${exact_plugin_name}"
	
	if run_wp_cli "${site_path}" "${wp_user}" "${wp_cmd[@]}"; then
		log_success "Plugin '${exact_plugin_name}' ${action}d successfully on ${site_path}"
		debug_echo "✅ Plugin management completed"
		return 0
	else
		log_error "Failed to ${action} plugin '${exact_plugin_name}' on ${site_path}"
		return 1
	fi
}

# ---------------------------------------------------------------------
# Astra specific handlers (unchanged, but comments translated)
# ---------------------------------------------------------------------
_handle_astra_in_full_mode() {
	local site_path="$1" wp_user="$2"
	
	debug_echo "🚩 START _handle_astra_in_full_mode"
	
	log_info "Checking Astra plugin status for: ${site_path}"
	
	if ! run_wp_cli "${site_path}" "${wp_user}" plugin status astra-addon >/dev/null 2>&1; then
		log_warning "Astra plugin not found or not active for: ${site_path}"
		debug_echo "❌ Astra plugin check failed"
		return 0
	fi
	
	log_success "Astra plugin found and active"
	debug_echo "✅ Astra plugin is installed and active"
	
	log_info "Checking if Astra plugin update is available"
	debug_echo "🔍 Checking for available updates with dry-run"
	
	local dry_run_output
	dry_run_output=$(su - "${wp_user}" -c "cd \"${site_path}\" && ${WP_CLI_PATH} --path=\"${site_path}\" plugin update astra-addon --dry-run --skip-plugins=saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer --quiet --allow-root 2>&1") || true
	
	if echo "${dry_run_output}" | grep -q "Available"; then
		log_info "Astra update available, attempting update"
		debug_echo "🔄 Running Astra plugin update"
		
		if run_wp_cli "${site_path}" "${wp_user}" plugin update astra-addon; then
			log_success "Astra plugin updated successfully in full mode"
			debug_echo "✅ Astra plugin updated successfully"
		else
			log_warning "Astra plugin update failed, activating license and retrying"
			debug_echo "🔑 Astra license activation needed"
			
			if run_wp_cli "${site_path}" "${wp_user}" brainstormforce license activate astra-addon "${ASTRA_KEY}"; then
				log_success "Astra license activated successfully"
				debug_echo "✅ License activation successful"
				
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
	
	if [[ "${ASTRA_KEY}" == "YOUR_KEY" ]]; then
		log_error "Astra license key is not configured. Please set ASTRA_KEY in the script."
		echo -e "${RED}❌ ERROR: Astra license key is not configured.${RESET}"
		echo -e "${YELLOW}Please edit the script and set ASTRA_KEY to your actual license key.${RESET}"
		return 1
	fi
	
	log_info "Checking Astra plugin status for: ${site_path}"
	
	if ! run_wp_cli "${site_path}" "${wp_user}" plugin status astra-addon >/dev/null 2>&1; then
		log_warning "Astra plugin not found or not active for: ${site_path}"
		debug_echo "❌ Astra plugin check failed"
		return 1
	fi
	
	log_success "Astra plugin found and active"
	debug_echo "✅ Astra plugin is installed and active"
	
	log_info "Attempting to update Astra plugin"
	debug_echo "🔄 Running initial Astra plugin update"
	
	if run_wp_cli "${site_path}" "${wp_user}" plugin update astra-addon; then
		log_success "Astra plugin updated successfully"
		debug_echo "✅ Astra plugin updated on first attempt"
		return 0
	fi
	
	log_warning "Astra plugin update failed, checking if update is available"
	debug_echo "🔍 Checking for available updates with dry-run"
	
	local dry_run_output
	dry_run_output=$(su - "${wp_user}" -c "cd \"${site_path}\" && ${WP_CLI_PATH} --path=\"${site_path}\" plugin update astra-addon --dry-run --skip-plugins=saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer --quiet --allow-root 2>&1") || true
	
	if echo "${dry_run_output}" | grep -q "Available"; then
		log_info "Astra update available but failed, activating license and retrying"
		debug_echo "🔑 Astra license activation needed"
		
		log_info "Activating Astra license"
		debug_echo "🔑 Activating license with key: ${ASTRA_KEY}"
		
		if run_wp_cli "${site_path}" "${wp_user}" brainstormforce license activate astra-addon "${ASTRA_KEY}"; then
			log_success "Astra license activated successfully"
			debug_echo "✅ License activation successful"
			
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

# ---------------------------------------------------------------------
# Ensure sites file exists; if not, try discovery script or ask user.
# ---------------------------------------------------------------------
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

	printf '%s\n' "${user_path}" > "${SITES_FILE}"
	log_success "Path saved to ${SITES_FILE}. Continuing..."
	debug_echo "✅ Completed ensure_sites_file"
}

# ---------------------------------------------------------------------
# Process a single site based on current mode and options
# ---------------------------------------------------------------------
process_site() {
	local site_path="$1"
	
	debug_echo "📍 Processing site path: '${site_path}'"
	
	[[ -d "${site_path}" ]] || { 
		log_warning "Skipping (not a dir): ${site_path}"
		debug_echo "⏩ Path is not a directory, skipping"
		return 0
	}

	log_info "Processing site: ${site_path}"
	((STATS[total_sites]++)) || true
	debug_echo "📊 Total sites counter: ${STATS[total_sites]}"

	debug_echo "🔍 Getting WordPress user for: ${site_path}"
	local wp_user
	wp_user="$(get_wp_user "${site_path}")" || {
		log_error "Skipping site due to user resolution failure: ${site_path}"
		debug_echo "⏩ User resolution failed, skipping site"
		return 0
	}
	debug_echo "✅ Resolved WordPress user: '${wp_user}'"

	debug_echo "🔧 Executing mode '${MODE}' for site: ${site_path}"
	execute_mode "${MODE}" "${site_path}" "${wp_user}"
	debug_echo "✅ Completed processing for site: ${site_path}"
	
	return 0
}

# ---------------------------------------------------------------------
# Execute the appropriate operations for the given mode
# ---------------------------------------------------------------------
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
		"${MODE_LIST_PLUGINS}")
			debug_echo "🔧 Executing LIST_PLUGINS mode operations"
			debug_echo "📍 site_path=${site_path}, wp_user=${wp_user}"
			debug_echo "🔍 PLUGIN_NAME=${PLUGIN_NAME}, JSON_OUTPUT=${JSON_OUTPUT}"
			list_plugins_for_site "${site_path}" "${wp_user}" "${PLUGIN_NAME}" "${JSON_OUTPUT}"
			;;
		"${MODE_PLUGIN_MANAGE}")
			debug_echo "🔧 Executing PLUGIN_MANAGE mode operations"
			if [[ -z "${PLUGIN_ACTION}" || -z "${PLUGIN_NAME}" ]]; then
				log_error "Plugin management requires --action and --name options"
				return 1
			fi
			manage_plugin_for_site "${site_path}" "${wp_user}" "${PLUGIN_NAME}" "${PLUGIN_ACTION}" "${FORCE_MODE}"
			;;
		*)
			log_error "Unknown mode: ${mode}"
			return 1
			;;
	esac
	
	debug_echo "✅ COMPLETED execute_mode for ${mode}"
}

# ---------------------------------------------------------------------
# Display startup banner with all parameters and planned operations
# ---------------------------------------------------------------------
show_startup_info() {
    $HEADER_SHOWN && return 0
    HEADER_SHOWN=true
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║${RESET}     ${BOLD}WordPress Maintenance Automation v${SCRIPT_VERSION}${RESET}                    ${BOLD}${CYAN}║${RESET}"
    echo -e "${BOLD}${CYAN}║${RESET}     ${DIM}Secure, fast, and modular WP-CLI manager${RESET}                  ${BOLD}${CYAN}║${RESET}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    
    echo -e "${BOLD}📋 SCRIPT CONFIGURATION${RESET}"
    echo -e "${DIM}$(printf '─%.0s' $(seq 1 65))${RESET}"
    
    # Mode information
    local mode_desc=""
    case "${MODE}" in
        "${MODE_FULL}")          mode_desc="Full update (core + plugins + themes + DB + cron)" ;;
        "${MODE_CORE}")          mode_desc="WordPress core update only" ;;
        "${MODE_PLUGINS}")       mode_desc="Update all plugins" ;;
        "${MODE_THEMES}")        mode_desc="Update all themes" ;;
        "${MODE_DB_OPTIMIZE}")   mode_desc="Database optimization and repair" ;;
        "${MODE_DB_FIX}")        mode_desc="Database repair only" ;;
        "${MODE_CRON}")          mode_desc="Run due cron events" ;;
        "${MODE_ASTRA}")         mode_desc="Astra plugin update with license activation" ;;
        "${MODE_LIST_PLUGINS}")  mode_desc="List plugins with table/JSON view" ;;
        "${MODE_PLUGIN_MANAGE}") mode_desc="Plugin management (activate/deactivate/delete)" ;;
        *)                       mode_desc="Unknown mode" ;;
    esac
    printf "${BOLD}🎯 Operation Mode:${RESET}     %-38s${RESET}\n" "${mode_desc}"
    printf "${BOLD}🔧 Mode Flag:${RESET}          %-38s${RESET}\n" "${MODE}"
    
    # Target sites
    if [[ -n "${TARGET_SITE}" ]]; then
        printf "${BOLD}📍 Target Site:${RESET}        %-38s${RESET}\n" "${TARGET_SITE}"
    else
        printf "${BOLD}📍 Target Sites:${RESET}       %-38s${RESET}\n" "All sites from ${SITES_FILE}"
    fi
    
    # Plugin-specific options
    if [[ "${MODE}" == "${MODE_PLUGIN_MANAGE}" || "${MODE}" == "${MODE_LIST_PLUGINS}" ]]; then
        if [[ -n "${PLUGIN_NAME}" ]]; then
            printf "${BOLD}🔌 Plugin Filter:${RESET}      %-38s${RESET}\n" "${PLUGIN_NAME}"
        fi
        if [[ "${MODE}" == "${MODE_PLUGIN_MANAGE}" ]]; then
            local action_desc=""
            case "${PLUGIN_ACTION}" in
                "${ACTION_ACTIVATE}")   action_desc="Activate plugin" ;;
                "${ACTION_DEACTIVATE}") action_desc="Deactivate plugin" ;;
                "${ACTION_DELETE}")     action_desc="Delete plugin (DESTRUCTIVE)" ;;
            esac
            printf "${BOLD}⚡ Plugin Action:${RESET}     %-38s${RESET}\n" "${action_desc}"
            if [[ "${FORCE_MODE}" == "true" ]]; then
                printf "${BOLD}🚀 Force Mode:${RESET}        %-38s${RESET}\n" "ENABLED (skip confirmations)"
            else
                printf "${BOLD}🚀 Force Mode:${RESET}        %-38s${RESET}\n" "DISABLED (confirmations enabled)"
            fi
        fi
        if [[ "${JSON_OUTPUT}" == "true" ]]; then
            printf "${BOLD}📄 Output Format:${RESET}       %-38s${RESET}\n" "JSON"
        else
            printf "${BOLD}📄 Output Format:${RESET}       %-38s${RESET}\n" "Table"
        fi
    fi
    
    # Debug mode
    if [[ "${DEBUG_MODE}" == "true" ]]; then
        printf "${BOLD}🐞 Debug Mode:${RESET}          %-38s${RESET}\n" "ENABLED"
    else
        printf "${BOLD}🐞 Debug Mode:${RESET}          %-38s${RESET}\n" "DISABLED"
    fi
    
    echo -e "${DIM}$(printf '─%.0s' $(seq 1 65))${RESET}"
    
    # Planned operations based on mode
    echo -e "${BOLD}📝 PLANNED OPERATIONS:${RESET}"
    echo -e "${DIM}$(printf '─%.0s' $(seq 1 65))${RESET}"
    
    case "${MODE}" in
        "${MODE_FULL}")
            echo -e "  ${GREEN}✓${RESET} WordPress core update"
            echo -e "  ${GREEN}✓${RESET} All plugins update"
            echo -e "  ${GREEN}✓${RESET} Astra plugin update (if installed)"
            echo -e "  ${GREEN}✓${RESET} All themes update"
            echo -e "  ${GREEN}✓${RESET} Database update (wp update-db)"
            echo -e "  ${GREEN}✓${RESET} Database optimization"
            echo -e "  ${GREEN}✓${RESET} Database repair"
            echo -e "  ${GREEN}✓${RESET} Cron events execution"
            ;;
        "${MODE_CORE}")
            echo -e "  ${GREEN}✓${RESET} WordPress core update"
            echo -e "  ${GREEN}✓${RESET} Database update (wp update-db)"
            ;;
        "${MODE_PLUGINS}")
            echo -e "  ${GREEN}✓${RESET} All plugins update"
            ;;
        "${MODE_THEMES}")
            echo -e "  ${GREEN}✓${RESET} All themes update"
            ;;
        "${MODE_DB_OPTIMIZE}")
            echo -e "  ${GREEN}✓${RESET} Database optimization"
            echo -e "  ${GREEN}✓${RESET} Database repair"
            ;;
        "${MODE_DB_FIX}")
            echo -e "  ${GREEN}✓${RESET} Database repair"
            ;;
        "${MODE_CRON}")
            echo -e "  ${GREEN}✓${RESET} Run due cron events"
            ;;
        "${MODE_ASTRA}")
            echo -e "  ${GREEN}✓${RESET} Check Astra plugin status"
            echo -e "  ${GREEN}✓${RESET} Update Astra plugin"
            echo -e "  ${GREEN}✓${RESET} Activate license if update fails"
            ;;
        "${MODE_LIST_PLUGINS}")
            echo -e "  ${GREEN}✓${RESET} Retrieve plugin list"
            if [[ -n "${PLUGIN_NAME}" ]]; then
                echo -e "  ${GREEN}✓${RESET} Filter by: ${PLUGIN_NAME}"
            fi
            if [[ "${JSON_OUTPUT}" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Output in JSON format"
            else
                echo -e "  ${GREEN}✓${RESET} Output in table format"
            fi
            ;;
        "${MODE_PLUGIN_MANAGE}")
            echo -e "  ${GREEN}✓${RESET} Find plugin matching: ${PLUGIN_NAME}"
            echo -e "  ${GREEN}✓${RESET} ${action_desc:-Perform action}"
            if [[ "${PLUGIN_ACTION}" == "${ACTION_DELETE}" ]]; then
                echo -e "  ${RED}⚠${RESET} ${RED}DESTRUCTIVE ACTION - files will be permanently deleted${RESET}"
            fi
            ;;
    esac
    
    echo -e "${DIM}$(printf '─%.0s' $(seq 1 65))${RESET}"
    
    # Warnings
    local has_warnings=false
    echo -e "${BOLD}⚠️  WARNINGS & NOTES:${RESET}"
    echo -e "${DIM}$(printf '─%.0s' $(seq 1 65))${RESET}"
    
    if [[ "${PLUGIN_ACTION}" == "${ACTION_DELETE}" && "${FORCE_MODE}" != "true" ]]; then
        echo -e "  ${YELLOW}⚠${RESET} Deletion requires manual confirmation (type 'DELETE')"
        has_warnings=true
    fi
    
    if [[ "${DEBUG_MODE}" == "true" ]]; then
        echo -e "  ${YELLOW}⚠${RESET} Debug mode enabled - verbose output to stderr"
        echo -e "  ${YELLOW}⚠${RESET} Log file: ${LOG_FILE}"
        echo -e "  ${YELLOW}⚠${RESET} Error log: ${ERROR_LOG_FILE}"
        has_warnings=true
    fi
    
    if [[ "${MODE}" == "${MODE_FULL}" ]]; then
        echo -e "  ${YELLOW}⚠${RESET} Full mode may take several minutes per site"
        has_warnings=true
    fi
    
    if [[ -n "${TARGET_SITE}" && ! -d "${TARGET_SITE}" ]]; then
        echo -e "  ${RED}✗${RESET} Target site directory does not exist: ${TARGET_SITE}"
        has_warnings=true
    fi
    
    if [[ "${has_warnings}" == "false" ]]; then
        echo -e "  ${GREEN}✓${RESET} No warnings - ready to proceed"
    fi
    
    echo ""
    echo -e "${DIM}$(printf '─%.0s' $(seq 1 65))${RESET}"
    echo ""
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
TARGET_SITE=""
PLUGIN_NAME=""
PLUGIN_ACTION=""
FORCE_MODE=false
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--DEBUG|-D)
			DEBUG_MODE=true
			debug_echo "🔍 DEBUG mode enabled"
			shift
			;;
		--full|-f)
			MODE="${MODE_FULL}"
			debug_echo "🎯 Mode set to: FULL"
			shift
			;;
		--core|-c)
			MODE="${MODE_CORE}"
			debug_echo "🎯 Mode set to: CORE"
			shift
			;;
		--plugins|-p)
			MODE="${MODE_PLUGINS}"
			debug_echo "🎯 Mode set to: PLUGINS"
			shift
			;;
		--themes|-t)
			MODE="${MODE_THEMES}"
			debug_echo "🎯 Mode set to: THEMES"
			shift
			;;
		--db-optimize|-d)
			MODE="${MODE_DB_OPTIMIZE}"
			debug_echo "🎯 Mode set to: DB_OPTIMIZE"
			shift
			;;
		--db-fix|-x)
			MODE="${MODE_DB_FIX}"
			debug_echo "🎯 Mode set to: DB_FIX"
			shift
			;;
		--cron|-r)
			MODE="${MODE_CRON}"
			debug_echo "🎯 Mode set to: CRON"
			shift
			;;
		--astra|-s)
			MODE="${MODE_ASTRA}"
			debug_echo "🎯 Mode set to: ASTRA"
			shift
			;;
		--list-plugins|-l)
			MODE="${MODE_LIST_PLUGINS}"
			debug_echo "🎯 Mode set to: LIST_PLUGINS"
			shift
			;;
		--plugin-manage|-m)
			MODE="${MODE_PLUGIN_MANAGE}"
			debug_echo "🎯 Mode set to: PLUGIN_MANAGE"
			shift
			;;
		--site|-S)
			if [[ -z "${2:-}" || "${2}" == --* ]]; then
				log_error "--site requires a path argument"
				usage
			fi
			TARGET_SITE="$2"
			debug_echo "🎯 Target site set to: ${TARGET_SITE}"
			shift 2
			;;
		--action|-A)
			if [[ -z "${2:-}" || "${2}" == --* ]]; then
				log_error "--action requires: activate|deactivate|delete"
				usage
			fi
			PLUGIN_ACTION="$2"
			debug_echo "🎯 Plugin action set to: ${PLUGIN_ACTION}"
			shift 2
			;;
		--name|-N)
			if [[ -z "${2:-}" || "${2}" == --* ]]; then
				log_error "--name requires a plugin name argument"
				usage
			fi
			PLUGIN_NAME="$2"
			debug_echo "🎯 Plugin name filter set to: ${PLUGIN_NAME}"
			shift 2
			;;
		--force|-F)
			FORCE_MODE=true
			debug_echo "🎯 Force mode enabled (skip confirmations)"
			shift
			;;
		--json|-J)
			JSON_OUTPUT=true
			debug_echo "🎯 JSON output enabled"
			shift
			;;
		--help|-h)
			usage
			;;
		*)
			log_error "Invalid argument: $1"
			usage
			;;
	esac
done

# Validate mode
if [[ -z "${MODE}" ]]; then
	log_error "No mode specified."
	usage
fi

# Validate plugin-manage requirements
if [[ "${MODE}" == "${MODE_PLUGIN_MANAGE}" ]]; then
	if [[ -z "${PLUGIN_ACTION}" ]]; then
		log_error "--plugin-manage requires --action (activate|deactivate|delete)"
		usage
	fi
	if [[ -z "${PLUGIN_NAME}" ]]; then
		log_error "--plugin-manage requires --name (plugin slug or partial name)"
		usage
	fi
	if [[ "${PLUGIN_ACTION}" != "${ACTION_ACTIVATE}" && "${PLUGIN_ACTION}" != "${ACTION_DEACTIVATE}" && "${PLUGIN_ACTION}" != "${ACTION_DELETE}" ]]; then
		log_error "Invalid action: ${PLUGIN_ACTION}. Must be: activate|deactivate|delete"
		usage
	fi
fi

# Validate list-plugins requirements (no strict requirement, just info)
if [[ "${MODE}" == "${MODE_LIST_PLUGINS}" ]]; then
	if [[ -z "${TARGET_SITE}" && -z "${PLUGIN_NAME}" ]]; then
		debug_echo "ℹ️  No --site or --name specified, will process all sites from ${SITES_FILE}"
	fi
fi

debug_echo "🎯 Final mode: ${MODE}"
debug_echo "🔍 Final DEBUG_MODE: ${DEBUG_MODE}"
debug_echo "🎯 Final TARGET_SITE: ${TARGET_SITE:-all sites}"
debug_echo "🎯 Final PLUGIN_NAME: ${PLUGIN_NAME:-all plugins}"
debug_echo "🎯 Final PLUGIN_ACTION: ${PLUGIN_ACTION:-N/A}"
debug_echo "🎯 Final FORCE_MODE: ${FORCE_MODE}"
debug_echo "🎯 Final JSON_OUTPUT: ${JSON_OUTPUT}"

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

# Ensure sites file exists (unless targeting a single site)
if [[ -z "${TARGET_SITE}" ]]; then
	debug_echo "🔧 Ensuring sites file exists"
	ensure_sites_file
fi

# Show startup banner with parameters and planned operations
if [[ "${DEBUG_MODE}" != "true" ]]; then
    show_startup_info
else
    debug_echo "📋 Skipping startup banner in DEBUG mode (all info shown in debug output)"
fi

# Show startup banner with parameters and planned operations
if [[ "${DEBUG_MODE}" != "true" ]]; then
    show_startup_info
else
    debug_echo "📋 Skipping startup banner in DEBUG mode (all info shown in debug output)"
fi

log_info "Starting WordPress maintenance in '${MODE}' mode"

# Check jq for JSON operations if needed
if [[ "${JSON_OUTPUT}" == "true" || "${MODE}" == "${MODE_LIST_PLUGINS}" || "${MODE}" == "${MODE_PLUGIN_MANAGE}" ]]; then
	if ! command -v jq &>/dev/null; then
		log_warning "jq not found. Some features may be limited."
		log_info "Install jq for better JSON handling: yum install jq"
	fi
fi

# Process sites
if [[ -n "${TARGET_SITE}" ]]; then
    # Single site mode
    debug_echo "🔄 Processing single target site: ${TARGET_SITE}"
    if [[ ! -d "${TARGET_SITE}" ]]; then
        log_error "Target site directory does not exist: ${TARGET_SITE}"
        exit 1
    fi
    process_site "${TARGET_SITE}"
else
    # Multi-site mode from file
    log_info "Reading sites from ${SITES_FILE}"
    debug_echo "🔄 Starting main processing loop"
    
    # ✅ Подсчёт сайтов
    total_lines=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="$(trim "${line}")"
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue
        ((total_lines++)) || true
    done < "${SITES_FILE}"
    
    debug_echo "📊 Total sites to process: ${total_lines}"
    
    current_site=0
    while IFS= read -r site_path || [[ -n "${site_path}" ]]; do
        site_path="$(trim "${site_path}")"
        [[ -z "${site_path}" || "${site_path}" =~ ^# ]] && {
            debug_echo "⏩ Skipping empty or commented line"
            continue
        }
        ((current_site++)) || true
        
        # ✅ Прогресс БЕЗ echo после
        if [[ "${DEBUG_MODE}" != "true" && "${total_lines}" -gt 1 ]]; then
            show_progress "${current_site}" "${total_lines}" "Site ${current_site}/${total_lines}"
        fi
        
        if ! process_site "${site_path}"; then
            log_error "Failed to process site: ${site_path}"
            ((STATS[error_ops]++)) || true
        fi
    done < "${SITES_FILE}"
    
    # ✅ Финальная новая строка после завершения цикла
    if [[ "${DEBUG_MODE}" != "true" && "${total_lines}" -gt 1 ]]; then
        echo "" >&2
    fi
fi
debug_echo "✅ Main processing loop completed"

log_success "Maintenance completed."
echo ""
echo -e "${BOLD}${GREEN}=== SUMMARY ===${RESET}"
echo "Sites processed: ${STATS[total_sites]}"
echo "Successful ops:  ${STATS[success_ops]}"
echo "Errors:          ${STATS[error_ops]}"
echo "Log file:        ${LOG_FILE}"
echo "Error log:       ${ERROR_LOG_FILE}"

# =============================================================================
#                           FINAL STATUS & SUMMARY
# =============================================================================

debug_echo "✅ Main processing loop completed"
log_success "Maintenance completed."

echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║${RESET}                    ${BOLD}OPERATION SUMMARY${RESET}                          ${BOLD}${GREEN}║${RESET}"
echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${DIM}┌─────────────────────────────────────────────────────────────────${RESET}"
echo -e "${DIM}│${RESET} Sites processed:  ${BOLD}${STATS[total_sites]}${RESET}"
echo -e "${DIM}│${RESET} Successful ops:   ${BOLD}${GREEN}${STATS[success_ops]}${RESET}"
echo -e "${DIM}│${RESET} Errors:           ${BOLD}${RED}${STATS[error_ops]}${RESET}"
echo -e "${DIM}│${RESET} Log file:         ${LOG_FILE}"
echo -e "${DIM}│${RESET} Error log:        ${ERROR_LOG_FILE}"
echo -e "${DIM}└─────────────────────────────────────────────────────────────────${RESET}"
echo ""

# Final status indicator
if [[ ${STATS[error_ops]} -eq 0 ]]; then
    echo -e "${GREEN}✓ All operations completed successfully${RESET}"
    exit 0
else
    echo -e "${RED}✗ ${STATS[error_ops]} error(s) occurred - check logs${RESET}"
    exit 1
fi

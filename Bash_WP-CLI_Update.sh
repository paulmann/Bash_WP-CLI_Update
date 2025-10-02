#!/usr/bin/env bash
# WordPress Maintenance Automation v3.2
# Author: Mikhail Deynekin
# Created: 2023-08-20
# Modified: 2025-05-19

set -o errexit
set -o nounset
set -o pipefail
shopt -s inherit_errexit

#########################################
###       CONFIGURATION SECTION       ###
#########################################

# Array of WordPress installations with format:
# --------------------------------------------
# Format 1: "/full/path/to/wordpress" 
#   - User auto-detected from path: /var/www/[USER]/data/www/...
#   - Domain auto-detected from last directory name
#
# Format 2: "/full/path | username" 
#   - Domain auto-detected from path
#
# Format 3: "/full/path | username | domain.com"
declare -a SITES=(
    "/var/www/md/data/www/paulman.ru/news|md|news.paulman.ru"
    "/var/www/md/data/www/iya.ru|md|ya.ru"
    "/var/www/md/data/www/sukulent.ru"
)

# WP-CLI commands to execute for each site
declare -a WP_COMMANDS=(
    'core update'
    'plugin update --all'
    'theme update --all'
    'wc update'
    'core update-db'
    'cron event run --all'
    'cache flush'
    'db repair'
    'db optimize'
)

# Skip plugin list (override via env var SKIP_PLUGINS)
declare -a DEFAULT_SKIP_PLUGINS=(
    "saphali-woocommerce-lite"
    "jet-compare-wishlist"
    "jet-data-importer"
)

#########################################
###      ADVANCED CONFIGURATION       ###
#########################################
readonly SCRIPT_NAME="${0##*/}"
readonly DEBUG=1
readonly VERSION="3.2"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME}.lock"
readonly LOG_DIR="/var/log/wp-automation"
readonly PATH_PATTERN="/var/www/(.+)/data/www/(.+)"

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

declare -gA STATS=(
    [total_sites]=0
    [success_cmds]=0
    [warning_cmds]=0
    [error_cmds]=0
    [start_time]=0
    [end_time]=0
    [longest_site]=""
    [longest_duration]=0
    [total_cmds]=0
)

declare -A ENV_CONFIG=(
    [DEFAULT_OWNER]="www-data"
    [WP_CLI_PATH]="/usr/local/bin/wp"
    [SAFE_MODE]="false"
    [DRY_RUN]="false"
)

#########################################
###      FUNCTION IMPLEMENTATIONS     ###
#########################################

check_running_processes() {
local script_name="Bash_WP-CLI_Update.sh"  # Имя скрипта
    local current_pid=$$                      # PID текущего процесса
    local pids=$(pgrep -f "$script_name" | grep -v "$current_pid")  # Поиск процессов, исключая текущий

    # Если другие процессы найдены, проверяем время их работы
    for pid in $pids; do
        local elapsed_time=$(ps -p "$pid" -o etimes= | tr -d ' ')  # Время работы процесса в секундах
        if [ "$elapsed_time" -gt 5 ]; then
            echo "✗ ERROR: Other running script copy found: PID $pid ($script_name), running for $elapsed_time seconds"
            exit 1
        fi
    done
    echo "✓ No other significant running instances found."
}

acquire_lock() {
    check_running_processes
    if [[ -e "${LOCK_FILE}" ]]; then
        echo -e "${RED}✗ ERROR: Another instance is running${RESET}" >&2
        exit 1
    fi
    trap 'rm -f "${LOCK_FILE}"' EXIT
    echo $$ > "${LOCK_FILE}"
}

init_logging() {
    mkdir -p "${LOG_DIR}"
    for level in INFO SUCCESS WARNING ERROR; do
        local log_file="${LOG_DIR}/${level}_${SCRIPT_NAME}.log"
        [[ -f "${log_file}.bak" ]] && rm -f "${log_file}.bak"
        [[ -f "${log_file}" ]] && mv "${log_file}" "${log_file}.bak"
        echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] WP-CLI v$("${ENV_CONFIG[WP_CLI_PATH]}" --version --allow-root | awk '/WP-CLI/ {print $2}')" > "${log_file}"
    done
}

log() {
    local level="$1" msg="$2"
    local log_file="${LOG_DIR}/${level}_${SCRIPT_NAME}.log"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color symbol

    case "$level" in
        "INFO") color="${BLUE}" symbol="ℹ️";;
        "SUCCESS") color="${GREEN}" symbol="✓";;
        "WARNING") color="${YELLOW}" symbol="⚠";;
        "ERROR") color="${RED}" symbol="✗";;
        *) color="${RESET}" symbol="";;
    esac

    # Log to file without color
    echo "[${timestamp}] [${level}] ${msg}" >> "${log_file}"
    # Print to console with color and symbol
    echo -e "${color}${symbol} [${level}] ${msg}${RESET}"
}

validate_environment() {
    [[ $EUID -eq 0 ]] || {
        log ERROR "Run as root"
        exit 1
    }
    
    command -v "${ENV_CONFIG[WP_CLI_PATH]}" >/dev/null 2>&1 || {
        log ERROR "WP-CLI not found"
        exit 1
    }
}

parse_site() {
    IFS='|' read -r -a parts <<< "$1"
    local path=$(echo "${parts[0]}" | xargs)
    local user=$(echo "${parts[1]-}" | xargs)
    local domain=$(echo "${parts[2]-}" | xargs)

    if [[ -z "${user}" ]]; then
        if [[ -d "${path}" ]]; then
            user=$(stat -c '%U' "${path}")
            if [[ $? -ne 0 ]]; then
                log ERROR "Failed to determine owner for: ${path}"
                return 1
            fi
        else
            log ERROR "Directory does not exist: ${path}"
            return 1
        fi
    fi

    if [[ -z "${domain}" ]]; then
        domain=$(basename "${path}")
    fi

    echo "${path}" "${user}" "${domain}"
}

execute_wp_operations() {
    local path="$1" user="$2" domain="$3"
    local skip_plugins=$(IFS=,; echo "${DEFAULT_SKIP_PLUGINS[*]}")
    
    for cmd in "${WP_COMMANDS[@]}"; do
        local full_cmd="${ENV_CONFIG[WP_CLI_PATH]} ${cmd} --path='${path}' --url='https://${domain}/' --skip-plugins='${skip_plugins}'"
        
        # Print command if DEBUG=1
        if [[ "${DEBUG:-0}" -eq 1 ]]; then
            echo -e "${BLUE}DEBUG: Executing command: ${full_cmd}${RESET}"
        fi

        log INFO "Executing: ${full_cmd} as ${user}"
        local output=$(sudo -u "${user}" -i -- /bin/bash -c "${full_cmd}" 2>&1)
        local status=$?
        
        ((STATS[total_cmds]++))
        
        if [[ ${status} -eq 0 ]]; then
            log SUCCESS "${cmd} on ${domain}"
            ((STATS[success_cmds]++))
        elif [[ ${status} -eq 1 ]]; then
            log WARNING "${cmd} on ${domain}: ${output}"
            ((STATS[warning_cmds]++))
        else
            log ERROR "${cmd} failed on ${domain}: ${output}"
            ((STATS[error_cmds]++))
        fi
    done
}

generate_report() {
    STATS[end_time]=$(date +%s)
    local total_time=$((STATS[end_time] - STATS[start_time]))
    
    echo -e "${BOLD}Script Execution Summary (v${VERSION}):${RESET}"
    echo -e "Total sites processed : ${STATS[total_sites]}"
    echo -e "Total commands executed: ${STATS[total_cmds]}"
    echo -e "${GREEN}✓ Successful commands: ${STATS[success_cmds]}${RESET}"
    echo -e "${YELLOW}⚠ Warnings:            ${STATS[warning_cmds]}${RESET}"
    echo -e "${RED}✗ Errors:              ${STATS[error_cmds]}${RESET}"
    echo -e "Total execution time:  $(convert_seconds ${total_time})"
    echo -e "Longest site execution: ${STATS[longest_site]} (${STATS[longest_duration]}s)"
    
    echo -e "\n${BOLD}Log files:${RESET}"
    echo -e "${BLUE}INFO:    ${LOG_DIR}/INFO_${SCRIPT_NAME}.log${RESET}"
    echo -e "${GREEN}SUCCESS: ${LOG_DIR}/SUCCESS_${SCRIPT_NAME}.log${RESET}"
    echo -e "${YELLOW}WARNING: ${LOG_DIR}/WARNING_${SCRIPT_NAME}.log${RESET}"
    echo -e "${RED}ERROR:   ${LOG_DIR}/ERROR_${SCRIPT_NAME}.log${RESET}"
}

convert_seconds() {
    local seconds=$1
    printf "%02d:%02d:%02d" $((seconds/3600)) $((seconds%3600/60)) $((seconds%60))
}

main() {
    validate_environment
    acquire_lock
    init_logging
    
    STATS[start_time]=$(date +%s)
    log INFO "Starting WP Maintenance Automation v${VERSION}"
    
    "${ENV_CONFIG[WP_CLI_PATH]}" cli update --yes &>> "${LOG_DIR}/INFO_${SCRIPT_NAME}.log"
    
    for entry in "${SITES[@]}"; do
        local site_start=$(date +%s)
        local parse_result=$(parse_site "${entry}")
        if [[ $? -ne 0 ]]; then
            continue
        fi
        read path user domain <<< "${parse_result}"
        
        if [[ "${user}" == "root" ]]; then
            log ERROR "Cannot run WP-CLI as root for site: ${path}"
            continue
        fi

        if ! id "${user}" &> /dev/null; then
            log ERROR "User not found for: ${path}"
            continue
        fi

        ((STATS[total_sites]++))
        execute_wp_operations "${path}" "${user}" "${domain}"
        
        local duration=$(( $(date +%s) - site_start ))
        if (( duration > STATS[longest_duration] )); then
            STATS[longest_duration]=${duration}
            STATS[longest_site]="${domain}"
        fi
    done

    generate_report
}

main "$@"
exit 0

#!/usr/bin/env bash
# =============================================================================
# File:        Find_WP_Senior.sh
# Project:     Bash WP-CLI Update
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# Version:     2.0.0
# License:     MIT (see LICENSE)
#
# Purpose:
#   Locate WordPress installations under one or more web roots by finding
#   wp-config.php files, validate them, and write the unique installation
#   roots (one path per line) into the site list that Bash_WP-CLI_Update.sh
#   reads.
#
# Usage:
#   ./Find_WP_Senior.sh [OPTIONS] [SEARCH_DIR ...]
#
# Options:
#   -o, --output FILE          Output file. Default: <script dir>/wp-found.txt
#                              ("-" prints the list to stdout)
#   -e, --exclude PATTERN      Exclusion rule, repeatable. Two forms:
#                                name -> "node_modules", "backup*" prune every
#                                        directory whose basename matches;
#                                path -> "/var/www/archive" prunes that path
#                                        and its whole subtree.
#   -d, --max-depth N          Maximum search depth per root (default: 6)
#       --no-default-excludes  Start with an empty exclusion list
#   -q, --quiet                Suppress informational messages
#   -j, --json                 Emit the result as JSON on stdout
#       --fail-empty           Exit 4 when no installation was found
#       --color / --no-color   Force / disable colored messages
#       --debug                Print diagnostics to stderr
#   -V, --version              Print the version and exit
#   -h, --help                 Print this help and exit
#
# Exit status:
#   0  success (list written, may be empty)
#   1  usage or environment error
#   2  the output file cannot be written
#   4  nothing found while --fail-empty was given
#
# Definitions:
#   WordPress root  a directory containing wp-config.php plus either
#                   wp-includes/version.php or wp-load.php.
#   .no_wp_cli      a marker FILE inside a WordPress root; that installation is
#                   skipped and never written to the list. Markers in parent
#                   directories do NOT affect nested installations.
#
# Exclusion semantics:
#   Patterns are anchored: "test*" matches a directory named "test"/"tests"
#   but no longer "<root>/home/testuser/site". The default rules
#   (backup*, old*, test*) protect maintenance runs from touching stale copies;
#   pass --no-default-excludes when they would hide real installations.
#
# Requirements: Bash 4.2+, GNU or BSD find/stat/sort, mktemp.
# =============================================================================

set -o errexit
set -o nounset
set -o pipefail
shopt -s inherit_errexit 2>/dev/null || true

# $0 can carry Windows-style separators when the script is launched from
# Git Bash / MSYS; normalise them before extracting the basename.
_self_ref="${0//\\//}"
readonly SCRIPT_NAME="${_self_ref##*/}"
readonly SCRIPT_VERSION="2.0.0"
unset _self_ref

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
	printf 'ERROR: %s requires Bash 4.2 or newer (found %s)\n' \
		"${SCRIPT_NAME}" "${BASH_VERSION:-unknown}" >&2
	exit 1
fi

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------

_resolve_script_dir() {
	local src="${BASH_SOURCE[0]}" dir
	while [[ -L "${src}" ]]; do
		dir="$(cd -P -- "$(dirname -- "${src}")" >/dev/null 2>&1 && pwd)" || dir='.'
		src="$(readlink -- "${src}")" || { src="${dir}"; break; }
		[[ "${src}" == /* ]] || src="${dir}/${src}"
	done
	dir="$(cd -P -- "$(dirname -- "${src}")" >/dev/null 2>&1 && pwd)" || dir='.'
	printf '%s' "${dir}"
}
readonly SCRIPT_DIR="$(_resolve_script_dir)"

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

readonly DEFAULT_OUTPUT_FILE="${SCRIPT_DIR}/wp-found.txt"
readonly DEFAULT_MAX_DEPTH=6
readonly HARD_MAX_DEPTH=64

readonly -a DEFAULT_SEARCH_DIRS=(
	/var/www
	/usr/share/nginx/html
	/srv
	/usr/local/nginx/html
	/usr/local/var/www
	/home
)

# Name patterns are anchored on the directory basename, absolute paths on the
# full path. See the header for the exact semantics.
readonly -a DEFAULT_EXCLUDE_PATTERNS=(
	'.git'
	'.svn'
	'.hg'
	'node_modules'
	'bower_components'
	'vendor'
	'backup*'
	'old*'
	'test*'
	'/proc'
	'/sys'
	'/dev'
	'/run'
	'/tmp'
)

# -----------------------------------------------------------------------------
# Runtime state
# -----------------------------------------------------------------------------

OUTPUT_FILE="${DEFAULT_OUTPUT_FILE}"
MAX_DEPTH="${DEFAULT_MAX_DEPTH}"
USE_DEFAULT_EXCLUDES=true
QUIET=false
JSON_OUTPUT=false
FAIL_EMPTY=false
DEBUG=false
COLOR_MODE=auto

TMP_DIR=''
FIND_ERR_FILE=''

SKIPPED_OPTOUT=0
SKIPPED_INVALID=0
SKIPPED_EXCLUDED=0
SKIPPED_DUPLICATE=0

# Effective configuration
EXCLUDE_PATTERNS=()
FIND_EXPR=()
SITES=()
META_LINES=()
declare -A SEEN=()
declare -A ROOT_FROM_CLI=()
CLI_ROOTS=()
EXCLUDE_CLI=()

# Colors (assigned by setup_colors)
C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_DIM=''

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

setup_colors() {
	case "${COLOR_MODE}" in
		never) return 0 ;;
		always) : ;;
		*)
			[[ -t 2 ]] || return 0
			[[ "${TERM:-dumb}" != 'dumb' ]] || return 0
			if [[ -n "${NO_COLOR:-}" ]]; then return 0; fi
			;;
	esac
	C_RESET=$'\033[0m'
	C_RED=$'\033[31m'
	C_GREEN=$'\033[32m'
	C_YELLOW=$'\033[33m'
	C_BLUE=$'\033[34m'
	C_DIM=$'\033[2m'
}

log_info()    { if [[ "${QUIET}" != true ]]; then printf '%sINFO:%s %s\n'    "${C_BLUE}"   "${C_RESET}" "$*" >&2; fi; }
log_success() { if [[ "${QUIET}" != true ]]; then printf '%sOK:%s %s\n'      "${C_GREEN}"  "${C_RESET}" "$*" >&2; fi; }
log_warn()    { printf '%sWARN:%s %s\n'    "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
log_error()   { printf '%sERROR:%s %s\n'   "${C_RED}"    "${C_RESET}" "$*" >&2; }
log_debug()   { if [[ "${DEBUG}" == true ]]; then printf '%sDEBUG:%s %s\n' "${C_DIM}" "${C_RESET}" "$*" >&2; fi; }

die() {
	log_error "$*"
	exit 1
}

cleanup() {
	local rc=$?
	if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
		rm -rf -- "${TMP_DIR}"
	fi
	return "${rc}"
}

# -----------------------------------------------------------------------------
# Help / version
# -----------------------------------------------------------------------------

usage() {
	local p
	printf 'WordPress installation discovery tool v%s\n' "${SCRIPT_VERSION}"
	printf 'Usage: %s [OPTIONS] [SEARCH_DIR ...]\n\n' "${SCRIPT_NAME}"
	printf 'Options:\n'
	printf '  -o, --output FILE          Output file (default: %s)\n' "${DEFAULT_OUTPUT_FILE}"
	printf '  -e, --exclude PATTERN      Exclude a name pattern or absolute path (repeatable)\n'
	printf '  -d, --max-depth N          Maximum search depth per root (default: %s)\n' "${DEFAULT_MAX_DEPTH}"
	printf '      --no-default-excludes  Start with an empty exclusion list\n'
	printf '  -q, --quiet                Suppress informational messages\n'
	printf '  -j, --json                 Print the result as JSON on stdout\n'
	printf '      --fail-empty           Exit 4 when nothing was found\n'
	printf '      --color, --no-color    Force / disable colored output\n'
	printf '      --debug                Print diagnostics to stderr\n'
	printf '  -V, --version              Print the version and exit\n'
	printf '  -h, --help                 Print this help and exit\n\n'
	printf 'Default search directories:\n'
	for p in "${DEFAULT_SEARCH_DIRS[@]}"; do printf '  %s\n' "${p}"; done
	printf '\nDefault exclusions:\n'
	for p in "${DEFAULT_EXCLUDE_PATTERNS[@]}"; do printf '  %s\n' "${p}"; done
	printf '\nExamples:\n'
	printf '  %s\n' "${SCRIPT_NAME}"
	printf '  %s /var/www /srv\n' "${SCRIPT_NAME}"
	printf "  %s --exclude '/var/www/archive' --max-depth 4\n" "${SCRIPT_NAME}"
	printf "  %s --no-default-excludes --exclude 'backup*' /home\n" "${SCRIPT_NAME}"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

require_value() { # $1 = option, $2 = value
	if [[ $# -lt 2 || -z "${2:-}" ]]; then
		die "option $1 requires a value"
	fi
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-o|--output)
				require_value "$1" "${2:-}"
				OUTPUT_FILE="$2"
				shift 2
				;;
			--output=*)
				OUTPUT_FILE="${1#*=}"
				[[ -n "${OUTPUT_FILE}" ]] || die "--output requires a value"
				shift
				;;
			-e|--exclude)
				require_value "$1" "${2:-}"
				EXCLUDE_CLI+=( "$2" )
				shift 2
				;;
			--exclude=*)
				EXCLUDE_CLI+=( "${1#*=}" )
				shift
				;;
			-d|--max-depth)
				require_value "$1" "${2:-}"
				MAX_DEPTH="$2"
				shift 2
				;;
			--max-depth=*)
				MAX_DEPTH="${1#*=}"
				shift
				;;
			--no-default-excludes)
				USE_DEFAULT_EXCLUDES=false
				shift
				;;
			-q|--quiet)   QUIET=true; shift ;;
			-j|--json)    JSON_OUTPUT=true; QUIET=true; shift ;;
			--fail-empty) FAIL_EMPTY=true; shift ;;
			--color)      COLOR_MODE=always; shift ;;
			--no-color)   COLOR_MODE=never; shift ;;
			--debug)      DEBUG=true; shift ;;
			-V|--version) printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit 0 ;;
			-h|--help)    usage; exit 0 ;;
			--)
				shift
				while [[ $# -gt 0 ]]; do
					CLI_ROOTS=("${CLI_ROOTS[@]:-}" "$1")
					shift
				done
				;;
			-*)
				die "unknown option: $1 (see --help)"
				;;
			*)
				CLI_ROOTS=("${CLI_ROOTS[@]:-}" "$1")
				shift
				;;
		esac
	done
}

# -----------------------------------------------------------------------------
# Configuration resolution
# -----------------------------------------------------------------------------

load_config() {
	local -a roots=() excludes=()

	if ((${#CLI_ROOTS[@]})); then
		roots=( "${CLI_ROOTS[@]}" )
	else
		roots=( "${DEFAULT_SEARCH_DIRS[@]}" )
	fi

	local r
	for r in "${roots[@]}"; do
		r="${r%/}"
		[[ -n "${r}" ]] || r='/'   # a bare "/" must stay "/"
		SEARCH_DIRS+=("${r}")
		done

	local i
	for ((i = 0; i < ${#CLI_ROOTS[@]}; i++)); do
		r="${CLI_ROOTS[i]%/}"
		[[ -n "${r}" ]] || r='/'
		ROOT_FROM_CLI["${r}"]=1
	done

	if [[ "${USE_DEFAULT_EXCLUDES}" == true ]]; then
		excludes=( "${DEFAULT_EXCLUDE_PATTERNS[@]}" )
	fi
	if [[ -n "${EXCLUDE_CLI[*]:-}" ]]; then
		excludes+=( "${EXCLUDE_CLI[@]}" )
	fi
	EXCLUDE_PATTERNS=( "${excludes[@]:-}" )

	if [[ ! "${MAX_DEPTH}" =~ ^[0-9]+$ ]] || (( MAX_DEPTH < 1 || MAX_DEPTH > HARD_MAX_DEPTH )); then
		die "--max-depth must be an integer between 1 and ${HARD_MAX_DEPTH}"
	fi
}

# -----------------------------------------------------------------------------
# Exclusion handling
# -----------------------------------------------------------------------------

# A candidate directory is excluded when its basename matches a name pattern or
# when its path equals / lies below an absolute path pattern.
is_excluded_path() {
	local path="$1" base="${1##*/}" pat
	for pat in "${EXCLUDE_PATTERNS[@]}"; do
		[[ -n "${pat}" ]] || continue
		if [[ "${pat}" == /* ]]; then
			[[ "${path}" == "${pat}" || "${path}" == "${pat}"/* ]] && return 0
		else
			# Intentional glob match of the basename against the pattern.
			case "${base}" in
				${pat}) return 0 ;;
			esac
		fi
	done
	return 1
}

# Build the find expression as an argument array: no eval, no string splitting.
build_find_expression() {
	local -a names=() paths=() expr=()
	local pat first

	for pat in "${EXCLUDE_PATTERNS[@]}"; do
		[[ -n "${pat}" ]] || continue
		if [[ "${pat}" == /* ]]; then
			paths+=( "${pat%/}" )
		else
			names+=( "${pat}" )
		fi
	done

	if ((${#names[@]})); then
		first=1
		expr+=( '(' )
		for pat in "${names[@]}"; do
			(( first )) || expr+=( '-o' )
			first=0
			expr+=( '-name' "${pat}" )
		done
		expr+=( ')' '-prune' '-o' )
	fi

	if ((${#paths[@]})); then
		first=1
		expr+=( '(' )
		for pat in "${paths[@]}"; do
			(( first )) || expr+=( '-o' )
			first=0
			expr+=( '-path' "${pat}" '-o' '-path' "${pat}/*" )
		done
		expr+=( ')' '-prune' '-o' )
	fi

	expr+=( '-type' 'f' '-name' 'wp-config.php' '-print0' )
	FIND_EXPR=( "${expr[@]}" )
}

# -----------------------------------------------------------------------------
# Validation and registration
# -----------------------------------------------------------------------------

is_valid_wp() {
	local dir="$1"
	[[ -f "${dir}/wp-config.php" ]] || return 1
	[[ -f "${dir}/wp-includes/version.php" || -f "${dir}/wp-load.php" ]] || return 1
	return 0
}

register_site() {
	local site="$1"
	[[ -d "${site}" ]] || return 0

	if [[ -e "${site}/.no_wp_cli" ]]; then
		(( SKIPPED_OPTOUT++ )) || true
		log_debug "opt-out marker, skipped: ${site}"
		return 0
	fi

	if is_excluded_path "${site}"; then
		(( SKIPPED_EXCLUDED++ )) || true
		log_debug "excluded by pattern: ${site}"
		return 0
	fi

	if ! is_valid_wp "${site}"; then
		(( SKIPPED_INVALID++ )) || true
		log_debug "wp-config.php without WordPress core files, skipped: ${site}"
		return 0
	fi

	if [[ -n "${SEEN[${site}]:-}" ]]; then
		(( SKIPPED_DUPLICATE++ )) || true
		return 0
	fi

	SEEN["${site}"]=1
	SITES+=( "${site}" )
	log_debug "accepted: ${site}"
}

# -----------------------------------------------------------------------------
# Discovery
# -----------------------------------------------------------------------------

scan_root() {
	local root="$1" cfg site
	local -a argv=( "${root}" '-mindepth' '1' '-maxdepth' "${MAX_DEPTH}" )

	argv+=( "${FIND_EXPR[@]}" )

	log_debug "find arguments: ${argv[*]}"

	# -print0 keeps paths with spaces/globs intact; the loop body runs in the
	# current shell (process substitution), so arrays and counters persist.
	while IFS= read -r -d '' cfg; do
		site="${cfg%/*}"
		[[ -n "${site}" ]] || site='/'
		register_site "${site}"
	done < <(find "${argv[@]}" 2>>"${FIND_ERR_FILE}")
}

discover_sites() {
	local scanned=0 root

	FIND_ERR_FILE="${TMP_DIR}/find.err"
	: > "${FIND_ERR_FILE}"

	for root in "${SEARCH_DIRS[@]}"; do
		if [[ ! -d "${root}" ]]; then
			if [[ -n "${ROOT_FROM_CLI[${root}]:-}" ]]; then
				die "search directory not found: ${root}"
			fi
			log_debug "default root not present on this host: ${root}"
			continue
		fi
		(( scanned++ )) || true
		log_info "scanning: ${root}"
		scan_root "${root}"
	done

	if (( scanned == 0 )); then
		log_warn 'none of the search directories exist on this host - the list will be empty'
	fi

	local find_errors
	find_errors="$(wc -l < "${FIND_ERR_FILE}" 2>/dev/null | tr -d '[:space:]')"
	find_errors="${find_errors:-0}"
	if [[ "${find_errors}" -gt 0 ]]; then
		log_warn "find reported ${find_errors} warning line(s) (permissions?); use --debug to inspect"
		if [[ "${DEBUG}" == true ]]; then
			sed 's/^/  find: /' "${FIND_ERR_FILE}" >&2
		fi
	fi
}

# -----------------------------------------------------------------------------
# Metadata + sorting
# -----------------------------------------------------------------------------

sort_sites() {
	((${#SITES[@]})) || return 0
	local -a sorted=() line
	while IFS= read -r line; do
		[[ -n "${line}" ]] && sorted+=( "${line}" )
	done < <(printf '%s\n' "${SITES[@]}" | LC_ALL=C sort -u)
	SITES=( "${sorted[@]}" )
}

# Prints "user<TAB>group<TAB>last-modified" for a directory, using GNU stat
# first and BSD stat as a fallback (one call, no subprocess storm).
get_site_meta() {
	local dir="$1" out user group mtime
	if out="$(stat -c '%U|%G|%y' -- "${dir}" 2>/dev/null)" || out="$(stat -f '%Su|%Sg|%Sm' -- "${dir}" 2>/dev/null)"; then
		user="${out%%|*}"
		out="${out#*|}"
		group="${out%%|*}"
		mtime="${out#*|}"
		mtime="${mtime%%.*}"   # drop fractional seconds when present
		printf '%s\t%s\t%s\n' "${user:-unknown}" "${group:-unknown}" "${mtime:-unknown}"
	else
		printf 'unknown\tunknown\tunknown\n'
	fi
}

collect_meta() {
	local site meta
	META_LINES=()
	((${#SITES[@]})) || return 0
	for site in "${SITES[@]}"; do
		meta="$(get_site_meta "${site}")"
		META_LINES+=( "${site}"$'\t'"${meta}" )
	done
}

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------

write_site_list() {
	local out="${OUTPUT_FILE}" tmp

	if [[ "${out}" == '-' ]]; then
		if ((${#SITES[@]})); then
			printf '%s\n' "${SITES[@]}"
		fi
		return 0
	fi

	tmp="${out}.tmp.$$"
	if ! {
		if ((${#SITES[@]})); then
			printf '%s\n' "${SITES[@]}"
		fi
	} > "${tmp}" 2>/dev/null; then
		rm -f -- "${tmp}" 2>/dev/null || true
		log_error "cannot write the site list to ${out}"
		return 2
	fi

	if ! mv -f -- "${tmp}" "${out}"; then
		rm -f -- "${tmp}" 2>/dev/null || true
		log_error "cannot replace the site list ${out}"
		return 2
	fi
	return 0
}

json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\t'/\\t}"
	s="${s//$'\r'/\\r}"
	s="${s//$'\n'/\\n}"
	printf '%s' "${s}"
}

render_json() {
	local entry path user group mtime first=1
	printf '[\n'
	for entry in "${META_LINES[@]:-}"; do
		[[ -n "${entry}" ]] || continue
		IFS=$'\t' read -r path user group mtime <<< "${entry}"
		(( first )) || printf ',\n'
		first=0
		printf '  {"path": "%s", "user": "%s", "group": "%s", "mtime": "%s"}' \
			"$(json_escape "${path}")" "$(json_escape "${user}")" \
			"$(json_escape "${group}")" "$(json_escape "${mtime}")"
	done
	(( first )) || printf '\n'
	printf ']\n'
}

render_table() {
	local entry path user group mtime width=4

	for entry in "${META_LINES[@]:-}"; do
		[[ -n "${entry}" ]] || continue
		path="${entry%%$'\t'*}"
		(( ${#path} > width )) && width=${#path}
	done
	(( width > 80 )) && width=80

	local header_fmt="%-${width}s  %-12s  %-12s  %s\n"
	printf "${header_fmt}" 'PATH' 'USER' 'GROUP' 'LAST MODIFIED'
	printf '%s\n' "${C_DIM}$(printf '%*s' "$(( width + 32 ))" '' | tr ' ' '-')${C_RESET}"
	for entry in "${META_LINES[@]:-}"; do
		[[ -n "${entry}" ]] || continue
		IFS=$'\t' read -r path user group mtime <<< "${entry}"
		printf "${header_fmt}" "${path}" "${user}" "${group}" "${mtime}"
	done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
	local start_ts end_ts rc=0
	start_ts=${SECONDS}

	parse_args "$@"
	setup_colors
	load_config

	local tmp_base="${TMPDIR:-/tmp}"
	tmp_base="${tmp_base//\\//}"        # MSYS/Git Bash compatibility
	TMP_DIR="$(mktemp -d "${tmp_base}/${SCRIPT_NAME}.XXXXXX")" || die 'cannot create a temporary directory'
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	build_find_expression
	discover_sites
	sort_sites
	collect_meta

	log_success "found ${#SITES[@]} WordPress installation(s)"
	if (( SKIPPED_OPTOUT + SKIPPED_INVALID + SKIPPED_EXCLUDED )); then
		log_info "skipped: ${SKIPPED_OPTOUT} opt-out, ${SKIPPED_INVALID} not a WP root, ${SKIPPED_EXCLUDED} excluded, ${SKIPPED_DUPLICATE} duplicate(s)"
	fi

	if [[ "${JSON_OUTPUT}" == true ]]; then
		render_json
	else
		write_site_list || rc=$?
		if [[ "${rc}" -eq 0 && "${OUTPUT_FILE}" != '-' ]]; then
			log_success "site list written: ${OUTPUT_FILE}"
		fi
	fi

	if [[ "${JSON_OUTPUT}" != true && "${QUIET}" != true ]]; then
		if ((${#META_LINES[@]})); then
			render_table
		else
			log_warn 'no WordPress installations were found'
		fi
	fi

	end_ts=${SECONDS}
	log_info "completed in $(( end_ts - start_ts )) second(s)"

	if [[ "${rc}" -ne 0 ]]; then
		exit "${rc}"
	fi
	if ((${#SITES[@]} == 0)) && [[ "${FAIL_EMPTY}" == true ]]; then
		exit 4
	fi
	exit 0
}

main "$@"

#!/usr/bin/env bash
# ==============================================================================
# File:        Find_WP_Senior.sh
# Project:     Bash WP-CLI Update
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# Version:     2.2.0
# License:     MIT — see LICENSE file in project root.
#
# Description:
#   Scans one or more webroots for WordPress installations, resolves the real
#   WordPress root (including "wp-config.php one level above the core" and
#   Bedrock-style layouts), honours per-site opt-out markers, applies safe
#   exclusions and writes a deduplicated, atomically replaced site list that is
#   consumed by Bash_WP-CLI_Update.sh.
#
# Usage:
#   ./Find_WP_Senior.sh [OPTIONS] [SEARCH_DIRS...]
#
# Options:
#   -o, --output FILE      Output file (default: <script dir>/wp-found.txt, "-" = stdout)
#   -e, --exclude PATTERN  Exclude a directory. Repeatable.
#                            No "/"  -> matches the directory NAME  (e.g. 'backup*')
#                            With "/" -> matches the whole PATH     (e.g. '*/staging', '/srv/old')
#   -m, --max-depth N      Maximum scan depth (default: 6)
#   -L, --follow           Follow symbolic links (deduplicated via realpath when available)
#   -d, --details          Print the found sites table (default when stderr is a TTY)
#       --no-details       Do not print the table
#       --json             Print machine-readable JSON to stdout
#   -q, --quiet            Only errors on stderr
#   -v, --verbose          Show skipped paths and their reasons
#       --dry-run          Discover only, do not write the output file
#       --fail-if-empty    Exit with code 3 when nothing was found
#       --no-color         Disable ANSI colours (also honoured: NO_COLOR=1)
#   -V, --version          Print version and exit
#   -h, --help             Print this help and exit
#
# Per-site opt-out marker:
#   • .no_wp_cli  — if this file exists in the resolved WordPress root (or in its
#                   parent directory, which covers Bedrock layouts), the site is
#                   skipped and never written to the output file.
#
# Logging/diagnostics always go to STDERR; STDOUT carries only machine-readable
# data (JSON or paths with --output -).
#
# Exit codes:
#   0  success
#   1  runtime error (unreadable output dir, find failure on every root, ...)
#   2  usage error
#   3  nothing found and --fail-if-empty was given
#
# Requirements:
#   • Bash 4.2+
#   • find, sort, mktemp, dirname, basename (GNU coreutils or BSD userland)
#
# Author & Support:
#   Paul Mann — https://github.com/paulmann
# ==============================================================================

set -Eeuo pipefail

# Bash 4.2+ is required (associative arrays, printf -v, array slicing).
# Keeping this check before any 4.x-only declaration makes old shells fail with
# a readable message instead of "declare: -A: invalid option".
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
	printf 'ERROR: %s requires Bash 4.2 or newer (running: %s)\n' "${0##*/}" "${BASH_VERSION}" >&2
	printf '       On macOS install a current bash (e.g. "brew install bash") and run it explicitly.\n' >&2
	exit 3
fi

readonly SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="${0##*/}"
SCRIPT_DIR=""

# ------------------------------------------------------------------------------
# Resolve the real script directory (symlink-safe, no subshell side effects)
# ------------------------------------------------------------------------------
resolve_script_dir() {
	local src="${BASH_SOURCE[0]}" dir
	while [[ -L "${src}" ]]; do
		dir="$(cd -P -- "$(dirname -- "${src}")" >/dev/null 2>&1 && pwd)" || break
		src="$(readlink -- "${src}")"
		[[ "${src}" != /* ]] && src="${dir}/${src}"
	done
	dir="$(cd -P -- "$(dirname -- "${src}")" >/dev/null 2>&1 && pwd)" || dir="${PWD}"
	printf '%s' "${dir}"
}
SCRIPT_DIR="$(resolve_script_dir)"
readonly SCRIPT_NAME SCRIPT_DIR

# ------------------------------------------------------------------------------
# Defaults (override with environment variables)
# ------------------------------------------------------------------------------
readonly DEFAULT_OUTPUT_FILE="${SCRIPT_DIR}/wp-found.txt"
readonly DEFAULT_MAX_DEPTH="${WP_FINDER_MAX_DEPTH:-6}"

# Roots that are scanned when no SEARCH_DIRS are given. Non-existent roots are
# skipped silently — the list is intentionally a superset of common layouts.
readonly -a DEFAULT_SEARCH_DIRS=(
	/var/www
	/var/www/html
	/usr/share/nginx/html
	/usr/local/nginx/html
	/usr/local/var/www
	/srv
	/home
	/opt
)

# Directory NAMES that are never descended into. Deliberately conservative:
# a directory is skipped only when its own name matches, so legitimate sites
# such as /var/www/test.example.com or /var/www/oldboy.com are NOT skipped
# (this was a silent data-loss bug in v1.01, where '*/test*' and '*/old*'
# patterns were matched against the full site path).
readonly -a DEFAULT_PRUNE_NAMES=(
	.git
	.svn
	.hg
	.snapshot
	.trash
	node_modules
	bower_components
	vendor
	cache
	backups
	backup
	.@__thumb
)

# Additional prune patterns kept for backwards compatibility with v1.01 CLI
# usage. These are PATH patterns (they contain "/").
readonly -a DEFAULT_PRUNE_PATHS=()

# Directories that are never valid webroots even if they contain wp-config.php
readonly -a DEFAULT_EXTRA_EXCLUDES=(
	/proc
	/sys
	/dev
	/run
)

# ------------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------------
OUTPUT_FILE="${DEFAULT_OUTPUT_FILE}"
MAX_DEPTH="${DEFAULT_MAX_DEPTH}"
FOLLOW_LINKS=0
SHOW_DETAILS="auto"
JSON_OUTPUT=0
QUIET=0
VERBOSE=0
DRY_RUN=0
FAIL_IF_EMPTY=0
COLOR_MODE="auto"

declare -a SEARCH_DIRS=()
declare -a PRUNE_NAMES=()        # effective list (defaults + user)
declare -a PRUNE_PATHS=()        # effective list (defaults + user)
declare -a USER_PRUNE_NAMES=()   # from --exclude (name patterns)
declare -a USER_PRUNE_PATHS=()   # from --exclude (path patterns)

declare -a SITE_PATHS=()
declare -a SITE_USERS=()
declare -a SITE_GROUPS=()
declare -a SITE_MTIMES=()
declare -A SEEN_SITES=()

STAT_SCANNED_ROOTS=0
STAT_SKIPPED_MARKER=0
STAT_SKIPPED_DUPLICATE=0
STAT_INVALID=0
STAT_FIND_ERRORS=0

TMP_FILES=()

# ------------------------------------------------------------------------------
# Colours / logging (stderr only)
# ------------------------------------------------------------------------------
C_RED=""
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_DIM=""
C_RESET=""

setup_colors() {
	local enabled=0
	case "${COLOR_MODE}" in
		never) enabled=0 ;;
		always) enabled=1 ;;
		*)
			if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
				enabled=1
			fi
			;;
	esac
	if ((enabled)); then
		C_RED=$'\033[0;31m'
		C_GREEN=$'\033[0;32m'
		C_YELLOW=$'\033[1;33m'
		C_BLUE=$'\033[0;34m'
		C_DIM=$'\033[2m'
		C_RESET=$'\033[0m'
	fi
	return 0
}

log()  { ((QUIET)) || printf '%sINFO:%s %s\n'  "${C_BLUE}"   "${C_RESET}" "$*" >&2; return 0; }
ok()   { ((QUIET)) || printf '%sOK:%s %s\n'    "${C_GREEN}"  "${C_RESET}" "$*" >&2; return 0; }
warn() { printf '%sWARN:%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; return 0; }
err()  { printf '%sERROR:%s %s\n' "${C_RED}"   "${C_RESET}" "$*" >&2; return 0; }
vlog() { ((VERBOSE)) && { printf '%sDEBUG:%s %s\n' "${C_DIM}" "${C_RESET}" "$*" >&2; }; return 0; }

die() { local code="${2:-1}"; err "$1"; exit "${code}"; }

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
have() { command -v -- "$1" >/dev/null 2>&1; }

mktemp_file() {
	local tpl="${TMPDIR:-/tmp}/wp-finder.XXXXXXXX" f
	f="$(mktemp "${tpl}")" || return 1
	TMP_FILES+=("${f}")
	printf '%s' "${f}"
}

cleanup() {
	local rc=$?
	local f
	for f in "${TMP_FILES[@]:-}"; do
		[[ -n "${f}" && -e "${f}" ]] && rm -f -- "${f}"
	done
	return "${rc}"
}

json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\t'/\\t}"
	s="${s//$'\r'/\\r}"
	printf '%s' "${s}"
}

# Portable owner/group/mtime lookup: GNU stat first, BSD stat as fallback.
# Prints "user|group|mtime" or returns 1.
stat_meta() {
	local target="$1" out
	if out="$(stat -c '%U|%G|%y' -- "${target}" 2>/dev/null)"; then
		out="${out%%.*}"           # strip fractional seconds
		printf '%s' "${out}"
		return 0
	fi
	if out="$(stat -f '%Su|%Sg|%Sm' -t '%Y-%m-%d %H:%M:%S' -- "${target}" 2>/dev/null)"; then
		printf '%s' "${out}"
		return 0
	fi
	return 1
}

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
	cat <<EOF
WordPress Installation Discovery v${SCRIPT_VERSION}

Usage: ${SCRIPT_NAME} [OPTIONS] [SEARCH_DIRS...]

Default roots:
$(printf '  %s\n' "${DEFAULT_SEARCH_DIRS[@]}")

Options:
  -o, --output FILE      Output file (default: ${DEFAULT_OUTPUT_FILE}; "-" = stdout)
  -e, --exclude PATTERN  Exclude directory (repeatable):
                           no "/"  -> matches directory NAME ('backup*')
                           with "/" -> matches full PATH ('*/staging', '/srv/old')
  -m, --max-depth N      Maximum scan depth (default: ${DEFAULT_MAX_DEPTH})
  -L, --follow           Follow symlinks (and deduplicate by real path)
  -d, --details          Print the found sites table
      --no-details       Do not print the table
      --json             Print JSON to stdout
  -q, --quiet            Errors only
  -v, --verbose          Show skipped paths and reasons
      --dry-run          Do not write the output file
      --fail-if-empty    Exit 3 when nothing was found
      --no-color         Disable colours
  -V, --version          Print version
  -h, --help             Print this help

Per-site opt-out: create an empty ".no_wp_cli" file in the WordPress root.

Exit codes: 0 = success, 1 = runtime error, 2 = usage error, 3 = empty (--fail-if-empty)

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} /var/www /srv
  ${SCRIPT_NAME} -o /etc/wp-sites.txt --exclude '*/staging' --exclude 'backup*'
  ${SCRIPT_NAME} --max-depth 8 --follow --json
EOF
	return 0
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
usage_error() {
	err "$1"
	printf 'Try "%s --help" for more information.\n' "${SCRIPT_NAME}" >&2
	exit 2
}

need_value() {
	# $1 = option name, $2 = remaining argument count
	[[ "$2" -ge 2 ]] || usage_error "option '$1' requires a value"
	return 0
}

parse_args() {
	local arg
	while (($#)); do
		arg="$1"
		case "${arg}" in
			-o|--output)
				need_value "${arg}" "$#"; OUTPUT_FILE="$2"; shift 2 ;;
			--output=*)
				OUTPUT_FILE="${arg#*=}"; shift ;;
			-e|--exclude)
				need_value "${arg}" "$#"; add_exclude "$2"; shift 2 ;;
			--exclude=*)
				add_exclude "${arg#*=}"; shift ;;
			-m|--max-depth)
				need_value "${arg}" "$#"; set_max_depth "$2"; shift 2 ;;
			--max-depth=*)
				set_max_depth "${arg#*=}"; shift ;;
			-L|--follow)
				FOLLOW_LINKS=1; shift ;;
			-d|--details)
				SHOW_DETAILS="yes"; shift ;;
			--no-details)
				SHOW_DETAILS="no"; shift ;;
			--json)
				JSON_OUTPUT=1; shift ;;
			-q|--quiet)
				QUIET=1; shift ;;
			-v|--verbose)
				VERBOSE=1; shift ;;
			--dry-run)
				DRY_RUN=1; shift ;;
			--fail-if-empty)
				FAIL_IF_EMPTY=1; shift ;;
			--no-color)
				COLOR_MODE="never"; shift ;;
			--color)
				COLOR_MODE="always"; shift ;;
			-V|--version)
				printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit 0 ;;
			-h|--help)
				usage; exit 0 ;;
			--)
				shift
				while (($#)); do SEARCH_DIRS+=("$1"); shift; done
				break ;;
			-*)
				usage_error "unknown option: ${arg}" ;;
			*)
				SEARCH_DIRS+=("${arg}"); shift ;;
		esac
	done

	((${#SEARCH_DIRS[@]})) || SEARCH_DIRS=("${DEFAULT_SEARCH_DIRS[@]}")
	[[ -n "${OUTPUT_FILE}" ]] || usage_error "--output requires a non-empty value"
	return 0
}

add_exclude() {
	local pattern="$1"
	[[ -n "${pattern}" ]] || usage_error "--exclude requires a non-empty value"
	if [[ "${pattern}" == */* ]]; then
		USER_PRUNE_PATHS+=("${pattern}")
	else
		USER_PRUNE_NAMES+=("${pattern}")
	fi
	return 0
}

set_max_depth() {
	[[ "$1" =~ ^[0-9]+$ ]] || usage_error "--max-depth requires a non-negative integer (got: $1)"
	MAX_DEPTH="$1"
	return 0
}

# ------------------------------------------------------------------------------
# WordPress root resolution
#   A directory holding wp-config.php is not necessarily the WP root: WordPress
#   (and therefore WP-CLI) also accepts wp-config.php one level above the core
#   files, which is the default Bedrock layout.
# ------------------------------------------------------------------------------
resolve_wp_root() {
	local cfg_dir="$1" sub
	if [[ -f "${cfg_dir}/wp-includes/version.php" || -f "${cfg_dir}/wp-load.php" ]]; then
		printf '%s' "${cfg_dir}"
		return 0
	fi
	local -a candidates=(wp wordpress core htdocs public web/wp public/wp)
	for sub in "${candidates[@]}"; do
		if [[ -f "${cfg_dir}/${sub}/wp-load.php" || -f "${cfg_dir}/${sub}/wp-includes/version.php" ]]; then
			printf '%s' "${cfg_dir}/${sub}"
			return 0
		fi
	done
	return 1
}

# ------------------------------------------------------------------------------
# Site collection (dedupe + opt-out marker)
# ------------------------------------------------------------------------------
add_site() {
	local dir="$1" abs="$2"

	if [[ -f "${dir}/.no_wp_cli" || -f "$(dirname -- "${dir}")/.no_wp_cli" ]]; then
		((STAT_SKIPPED_MARKER++)) || true
		vlog "skip (marker .no_wp_cli): ${dir}"
		return 1
	fi
	if [[ -n "${SEEN_SITES["${abs}"]:-}" ]]; then
		((STAT_SKIPPED_DUPLICATE++)) || true
		vlog "skip (duplicate): ${dir}"
		return 1
	fi
	SEEN_SITES["${abs}"]=1
	SITE_PATHS+=("${dir}")
	return 0
}

# ------------------------------------------------------------------------------
# Build the find expression once, as an array (never as a string)
# ------------------------------------------------------------------------------
declare -a FIND_EXPR=()
build_find_expr() {
	local first name pattern
	FIND_EXPR=()

	# 1) prune junk directories by name
	if ((${#PRUNE_NAMES[@]})); then
		first=1
		FIND_EXPR+=( -type d '(' )
		for name in "${PRUNE_NAMES[@]}"; do
			((first)) || FIND_EXPR+=( -o )
			FIND_EXPR+=( -name "${name}" )
			first=0
		done
		FIND_EXPR+=( ')' -prune -o )
	fi

	# 2) prune subtrees matched by path pattern (absolute excludes included)
	if ((${#PRUNE_PATHS[@]})); then
		first=1
		FIND_EXPR+=( -type d '(' )
		for pattern in "${PRUNE_PATHS[@]}"; do
			((first)) || FIND_EXPR+=( -o )
			FIND_EXPR+=( -path "${pattern}" )
			first=0
		done
		FIND_EXPR+=( ')' -prune -o )
	fi

	# 3) report wp-config.php files (NUL separated)
	FIND_EXPR+=( -type f -name 'wp-config.php' -print0 )
	return 0
}

# ------------------------------------------------------------------------------
# Scan a single root. Runs in the current shell (no pipeline subshell), so all
# counters survive.
# ------------------------------------------------------------------------------
scan_root() {
	local root="$1"
	local -a cmd=(find)
	local abs_root tmp_out tmp_err rc=0 cfg dir resolved resolved_abs before

	[[ -d "${root}" ]] || { vlog "skip (not a directory): ${root}"; return 0; }
	abs_root="$(cd -P -- "${root}" >/dev/null 2>&1 && pwd)" || abs_root="${root}"

	((FOLLOW_LINKS)) && cmd+=( -L )
	cmd+=( "${abs_root}" -maxdepth "${MAX_DEPTH}" )
	cmd+=( "${FIND_EXPR[@]}" )

	tmp_out="$(mktemp_file)" || { warn "cannot create temp file"; return 1; }
	tmp_err="$(mktemp_file)" || { warn "cannot create temp file"; return 1; }

	((QUIET)) || log "Scanning: ${abs_root} (max-depth ${MAX_DEPTH})"
	before="${#SITE_PATHS[@]}"

	if ! "${cmd[@]}" >"${tmp_out}" 2>"${tmp_err}"; then
		rc=$?
		((STAT_FIND_ERRORS++)) || true
		warn "find exited with status ${rc} for ${abs_root}: $(head -n 1 -- "${tmp_err}" 2>/dev/null)"
	fi
	((STAT_SCANNED_ROOTS++)) || true

	while IFS= read -r -d '' cfg; do
		dir="$(dirname -- "${cfg}")"
		if ! resolved="$(resolve_wp_root "${dir}")"; then
			((STAT_INVALID++)) || true
			vlog "skip (no WordPress core next to ${cfg})"
			continue
		fi
		# Canonical path is used for duplicate detection only.
		resolved_abs="$(cd -P -- "${resolved}" >/dev/null 2>&1 && pwd)" || resolved_abs="${resolved}"
		add_site "${resolved}" "${resolved_abs}" || true
	done < "${tmp_out}"

	((VERBOSE)) && vlog "root ${abs_root}: $(( ${#SITE_PATHS[@]} - before )) site(s) added"
	return 0
}

# ------------------------------------------------------------------------------
# Metadata collection (owner/group/mtime)
# ------------------------------------------------------------------------------
collect_metadata() {
	local dir meta
	local -a paths=("$@")
	SITE_USERS=()
	SITE_GROUPS=()
	SITE_MTIMES=()
	for dir in "${paths[@]}"; do
		if meta="$(stat_meta "${dir}")"; then
			SITE_USERS+=("${meta%%|*}")
			meta="${meta#*|}"
			SITE_GROUPS+=("${meta%%|*}")
			SITE_MTIMES+=("${meta#*|}")
		else
			SITE_USERS+=("<unknown>")
			SITE_GROUPS+=("<unknown>")
			SITE_MTIMES+=("<unknown>")
		fi
	done
	return 0
}

# ------------------------------------------------------------------------------
# Output
# ------------------------------------------------------------------------------
print_table() {
	local i pad=0 len
	for ((i = 0; i < ${#SITE_PATHS[@]}; i++)); do
		len="${#SITE_PATHS[i]}"
		((len > pad)) && pad="${len}"
	done
	printf '%s%-*s  %-12s  %-12s  %s%s\n' "${C_BLUE}" "${pad}" "PATH" "USER" "GROUP" "LAST MODIFIED" "${C_RESET}" >&2
	for ((i = 0; i < ${#SITE_PATHS[@]}; i++)); do
		printf '%-*s  %-12s  %-12s  %s\n' \
			"${pad}" "${SITE_PATHS[i]}" "${SITE_USERS[i]}" "${SITE_GROUPS[i]}" "${SITE_MTIMES[i]}" >&2
	done
	return 0
}

print_json() {
	local i first=1
	printf '['
	for ((i = 0; i < ${#SITE_PATHS[@]}; i++)); do
		((first)) || printf ','
		first=0
		printf '\n  {"path": "%s", "user": "%s", "group": "%s", "mtime": "%s"}' \
			"$(json_escape "${SITE_PATHS[i]}")" \
			"$(json_escape "${SITE_USERS[i]}")" \
			"$(json_escape "${SITE_GROUPS[i]}")" \
			"$(json_escape "${SITE_MTIMES[i]}")"
	done
	((${#SITE_PATHS[@]})) && printf '\n'
	printf ']\n'
	return 0
}

write_output_file() {
	local target="$1" tmp out_dir
	out_dir="$(dirname -- "${target}")"
	[[ -d "${out_dir}" ]] || die "output directory does not exist: ${out_dir}" 1
	[[ -w "${out_dir}" ]] || die "output directory is not writable: ${out_dir}" 1

	tmp="$(mktemp "${out_dir}/.wp-found.XXXXXXXX")" || die "cannot create temp file in ${out_dir}" 1
	TMP_FILES+=("${tmp}")
	if ((${#SITE_PATHS[@]})); then
		printf '%s\n' "${SITE_PATHS[@]}" >"${tmp}"
	else
		: >"${tmp}"
	fi
	chmod 0644 "${tmp}" 2>/dev/null || true
	mv -f -- "${tmp}" "${target}" || die "cannot replace ${target}" 1
	return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
	parse_args "$@"
	setup_colors

	# Effective exclusions = built-in defaults + user supplied patterns.
	PRUNE_NAMES=("${DEFAULT_PRUNE_NAMES[@]}" ${USER_PRUNE_NAMES[@]+"${USER_PRUNE_NAMES[@]}"})
	PRUNE_PATHS=("${DEFAULT_PRUNE_PATHS[@]}" "${DEFAULT_EXTRA_EXCLUDES[@]}" ${USER_PRUNE_PATHS[@]+"${USER_PRUNE_PATHS[@]}"})
	build_find_expr

	((QUIET)) || {
		log "WordPress discovery v${SCRIPT_VERSION}"
		log "Roots: ${#SEARCH_DIRS[@]} | excludes: ${#PRUNE_NAMES[@]} names, ${#PRUNE_PATHS[@]} paths | max-depth: ${MAX_DEPTH}"
	}

	local root
	for root in "${SEARCH_DIRS[@]}"; do
		scan_root "${root}"
	done

	if ((${#SITE_PATHS[@]})); then
		# Stable, locale independent ordering and duplicate removal.
		local sorted
		sorted="$(mktemp_file)"
		printf '%s\n' "${SITE_PATHS[@]}" | LC_ALL=C sort -u >"${sorted}"
		SITE_PATHS=()
		while IFS= read -r line; do
			[[ -n "${line}" ]] && SITE_PATHS+=("${line}")
		done <"${sorted}"
	fi

	if ((${#SITE_PATHS[@]})); then
		collect_metadata "${SITE_PATHS[@]}"
	fi

	if ((JSON_OUTPUT)); then
		print_json
	fi

	if [[ "${SHOW_DETAILS}" == "yes" ]] || { [[ "${SHOW_DETAILS}" == "auto" ]] && [[ -t 2 ]] && ((!JSON_OUTPUT)); }; then
		if ((${#SITE_PATHS[@]})); then
			printf '\n' >&2
			print_table
		fi
	fi

	# "--output -" always prints to stdout, also in --dry-run mode (stdout is not
	# a file and is the natural way to preview the result).
	if [[ "${OUTPUT_FILE}" == "-" ]]; then
		if ((${#SITE_PATHS[@]})); then
			printf '%s\n' "${SITE_PATHS[@]}"
		fi
	elif ((DRY_RUN)); then
		((QUIET)) || warn "dry-run: output file not written (${OUTPUT_FILE})"
	else
		write_output_file "${OUTPUT_FILE}"
		if ((${#SITE_PATHS[@]})); then
			ok "Found ${#SITE_PATHS[@]} WordPress installation(s) -> ${OUTPUT_FILE}"
		else
			warn "No WordPress installations found; ${OUTPUT_FILE} was emptied"
		fi
	fi

	((QUIET)) || log "Summary: roots=${STAT_SCANNED_ROOTS} found=${#SITE_PATHS[@]} duplicates=${STAT_SKIPPED_DUPLICATE} marker-skipped=${STAT_SKIPPED_MARKER} non-wp=${STAT_INVALID} find-errors=${STAT_FIND_ERRORS}"

	if ((${#SITE_PATHS[@]} == 0)); then
		if ((FAIL_IF_EMPTY)); then
			exit 3
		fi
		if ((STAT_FIND_ERRORS > 0)); then
			exit 1
		fi
	fi
	return 0
}

trap cleanup EXIT

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi

#!/usr/bin/env bash
# shellcheck shell=bash
###############################################################################
# WordPress installation discovery
#
# File:        Find_WP_Senior.sh
# Project:     Bash WP-CLI Update
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# License:     MIT
# Version:     2.1.0
#
# Purpose
#   Scan one or more web roots for WordPress installations (a directory holding
#   wp-config.php and wp-load.php or wp-includes/version.php), honour per-site
#   opt-out markers and exclusion patterns, deduplicate, enrich with metadata
#   and write the result as the site list consumed by Bash_WP-CLI_Update.sh.
#
# Usage
#   Find_WP_Senior.sh [options] [SEARCH_ROOT ...]
#
# Design notes (read before changing anything)
#   1. Only the roots named on the command line are scanned. When none are
#      given, the built-in default roots are used -- and never "/". A previous
#      revision expanded an empty array with "${arr[@]:-}", which in bash 4.4+
#      yields one empty element; a later `[[ -n $r ]] || r='/'` turned that into
#      a full filesystem scan and silently added unrelated sites to the list.
#      Every array expansion in this file uses ${arr[@]+"${arr[@]}"} instead.
#   2. find output is read with -print0 / read -d '', so a path containing a
#      space, a quote or a newline survives.
#   3. In the prune expression `-type d` sits INSIDE the group. `-prune`
#      evaluates to true even for a plain file, so a group that ends up true
#      swallows the right-hand side of the `-o` and nothing is ever printed.
#      See build_find_args for the four variants that were measured.
#   4. Nothing is ever passed to a shell as a string. Metadata is read with
#      stat(1) and bash pattern matching; no eval, no command built by
#      concatenation.
#
# Exit codes
#   0  installations found and written
#   1  operational error (unreadable root, cannot write the output file)
#   2  usage error (bad command line)
#   3  environment error (bash too old, required tool missing)
#   5  no installation found (not a failure of the tool itself; --fail-empty
#      turns it into 1 for pipelines that must not continue)
###############################################################################

if [ -z "${BASH_VERSION:-}" ]; then
    printf 'ERROR: this script requires bash, but another shell started it.\n' >&2
    exit 3
fi
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
    printf 'ERROR: %s requires bash 4.2 or newer (found %s).\n' \
        "${0##*/}" "${BASH_VERSION:-unknown}" >&2
    exit 3
fi

set -uo pipefail
shopt -s inherit_errexit 2>/dev/null || true

PROG_NAME="${0##*/}"
SCRIPT_VERSION='2.1.0'

EXIT_OK=0
EXIT_ERROR=1
EXIT_USAGE=2
EXIT_ENV=3
EXIT_NOT_FOUND=5

usage_error() { printf '%s: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
env_error() { printf '%s: environment: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_ENV"; }

have() { command -v "$1" >/dev/null 2>&1; }

for tool in find sort stat mktemp dirname basename cut; do
    have "$tool" || env_error "required tool not found in PATH: ${tool}"
done

resolve_script_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [ -L "$src" ]; do
        dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
        src="$(readlink "$src")"
        [ "${src#/}" = "$src" ] && src="${dir}/${src}"
    done
    cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}
SCRIPT_DIR="$(resolve_script_dir)" || {
    printf 'ERROR: cannot resolve the script directory\n' >&2; exit "$EXIT_ENV"; }
unset -f resolve_script_dir
readonly SCRIPT_DIR PROG_NAME

###############################################################################
# 1. Defaults
###############################################################################

# Roots scanned when the command line names none. Deliberately a short list of
# conventional web roots: scanning "/" is never a default, because on a large
# host it costs hours of I/O and mixes unrelated sites into one list.
DEFAULT_SEARCH_ROOTS=(
    /var/www
    /srv/www
    /usr/share/nginx/html
    /srv
    /home
)

# Directory names that are never WordPress roots and are expensive to descend
# into. Matched against a single path component.
DEFAULT_EXCLUDE_NAMES=(
    .git .svn .hg node_modules vendor composer
    cache tmp temp backup backups old proc sys dev
)

DEFAULT_MAX_DEPTH=8
HARD_MAX_DEPTH=32
DEFAULT_OUTPUT_FILE="${SCRIPT_DIR}/wp-found.txt"
OPT_OUT_MARKER='.no_wp_cli'

###############################################################################
# 2. Runtime state
###############################################################################

OUTPUT_FILE="$DEFAULT_OUTPUT_FILE"
MAX_DEPTH="$DEFAULT_MAX_DEPTH"
OUTPUT_FORMAT='paths'          # paths | tsv | csv | json
DELIMITER=''                   # empty = tab for tsv, comma for csv
QUIET='false'
VERBOSE='false'
STATUS_ONLY='false'
SKIP_EXISTING='false'
FAIL_EMPTY='false'
USE_DEFAULT_EXCLUDES='true'
COLOR_MODE='auto'
CLI_ROOTS=()
EXCLUDE_NAMES=()
EXCLUDE_PATHS=()
SEARCH_ROOTS=()

RESULTS_FILE=''
SORTED_FILE=''
FOUND_COUNT=0
SKIPPED_OPTOUT=0
SKIPPED_INVALID=0
SKIPPED_EXCLUDED=0
SKIPPED_DUPLICATE=0
SKIPPED_UNREADABLE=0
START_TIME=0

C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_DIM=''

###############################################################################
# 3. Logging and colour
###############################################################################

color_resolve() {
    case "${1:-auto}" in
        always) return 0 ;;
        never) return 1 ;;
        auto)
            [ -n "${NO_COLOR:-}" ] && return 1
            [ "${TERM:-}" = 'dumb' ] && return 1
            [ -t 2 ] && return 0
            return 1
            ;;
    esac
    return 1
}

color_init() {
    if color_resolve "$COLOR_MODE"; then
        C_RESET=$'\033[0m' C_RED=$'\033[0;31m' C_GREEN=$'\033[0;32m'
        C_YELLOW=$'\033[1;33m' C_BLUE=$'\033[0;34m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
    fi
}

# Prose always goes to stderr: stdout carries the result when --format is not
# `paths` and the operator must be able to pipe it.
log() { # LEVEL MESSAGE
    local level="${1:-info}" msg="${2:-}" mark color
    [ "$QUIET" = 'true' ] && { case "$level" in warn | error) ;; *) return 0 ;; esac; }
    # Debug output is opt-in: a discovery run over a large host prints one line
    # per skipped directory, which buries the result the operator asked for.
    [ "$level" = 'debug' ] && [ "$VERBOSE" != 'true' ] && return 0
    case "$level" in
        debug) mark='DBG'; color="$C_DIM" ;;
        info) mark='INF'; color="$C_BLUE" ;;
        ok) mark=' OK'; color="$C_GREEN" ;;
        warn) mark='WRN'; color="$C_YELLOW" ;;
        error) mark='ERR'; color="$C_RED" ;;
        *) mark='LOG'; color='' ;;
    esac
    printf '%s%s%s %s\n' "$color" "$mark" "$C_RESET" "$msg" >&2
}
log_debug() { log debug "${1:-}"; }
log_info() { log info "${1:-}"; }
log_ok() { log ok "${1:-}"; }
log_warn() { log warn "${1:-}"; }
log_error() { log error "${1:-}"; }

###############################################################################
# 4. Cleanup
###############################################################################

# One EXIT trap for the whole script and one file-scope list of temporaries.
# A previous revision installed `trap 'rm -f "$results_file"' EXIT` from inside a
# function, where results_file was `local`: by the time the trap fired the
# variable was out of scope, `set -u` printed "unbound variable" on every
# successful run, the temporary file leaked, and the previous EXIT handler was
# replaced. Traps belong at file scope.
TMP_FILES=()

# shellcheck disable=SC2329  # invoked from the EXIT trap
cleanup() {
    local f
    for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
        [ -e "$f" ] && rm -f -- "$f" 2>/dev/null
    done
    TMP_FILES=()
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# make_tmp LABEL -> sets TMP_LAST to a new temporary file and registers it.
#
# It deliberately does NOT print the name for `$(...)` capture: a command
# substitution is a subshell, so the registration would be lost with it and the
# file would leak on every single run. The caller assigns from TMP_LAST.
TMP_LAST=''
make_tmp() { # LABEL
    local f
    f="$(mktemp "${TMPDIR:-/tmp}/${PROG_NAME}.${1:-tmp}.XXXXXX")" || {
        log_error "cannot create a temporary file in ${TMPDIR:-/tmp}"
        exit "$EXIT_ERROR"
    }
    TMP_FILES+=("$f")
    TMP_LAST="$f"
    return 0
}

###############################################################################
# 5. Classification helpers
###############################################################################

# A WordPress root must carry wp-config.php and one of the two markers that
# distinguish a real installation from a stray config file.
is_valid_wp() { # DIR
    local dir="${1:-}"
    [ -f "${dir}/wp-config.php" ] || return 1
    [ -f "${dir}/wp-load.php" ] && return 0
    [ -f "${dir}/wp-includes/version.php" ] && return 0
    return 1
}

name_is_excluded() { # NAME
    local name="${1:-}" pat
    for pat in ${EXCLUDE_NAMES[@]+"${EXCLUDE_NAMES[@]}"}; do
        [ -n "$pat" ] || continue
        # shellcheck disable=SC2254  # the pattern is the point: globs are wanted
        case "$name" in $pat) return 0 ;; esac
    done
    return 1
}

path_is_excluded() { # PATH
    local path="${1:-}" ex
    for ex in ${EXCLUDE_PATHS[@]+"${EXCLUDE_PATHS[@]}"}; do
        [ -n "$ex" ] || continue
        [ "$path" = "$ex" ] && return 0
        case "$path" in "$ex"/*) return 0 ;; esac
    done
    return 1
}

wp_version_of() { # DIR
    local f="${1:-}/wp-includes/version.php" line
    [ -r "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ \$wp_version[[:space:]]*=[[:space:]]*[\'\"]([^\'\"]+)[\'\"] ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"$f"
    return 1
}

db_name_of() { # DIR
    local f="${1:-}/wp-config.php" line
    [ -r "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ define\([[:space:]]*[\']DB_NAME[\'][[:space:]]*,[[:space:]]*[\']([^\']*)[\'] ]] ||
           [[ "$line" =~ define\([[:space:]]*[\"]DB_NAME[\"][[:space:]]*,[[:space:]]*[\"]([^\"]*)[\"] ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"$f"
    return 1
}

###############################################################################
# 6. Scanning
###############################################################################

# build_find_args ROOT -> argv on stdout, one element per line.
#
# The expression is:
#   \( -type d \( <name globs> \) -false \) -prune -o
#   \( <path prefixes> -false \) -prune -o
#   \( -type f -name wp-config.php \) -print0
#
# Two details matter. `-false` terminates each prune group so the group is false
# for anything that did not match -- a bare `-prune` inside the group evaluates
# to true even for a plain file and silently swallows the rest of the
# expression. And `-type d` in front keeps find from calling the prune action on
# every file it meets.
build_find_args() { # ROOT
    local root="$1" pat first
    printf '%s\n' "$root"
    printf '%s\n' -maxdepth "$MAX_DEPTH"
    # The shape below is the only one of the four plausible variants that works,
    # and the reason is worth writing down because every alternative fails
    # silently by simply not pruning:
    #
    #   \( -type d \( <names> \) \) -prune -o \( -type f -name wp-config.php \) -print0
    #
    # `-type d` has to be INSIDE the parenthesised group. GNU find evaluates
    # `-prune` to true for anything, including a plain file, so a group that ends
    # up true makes the whole left side of `-o` true and the right side -- the
    # actual search -- never runs. With `-type d` inside, a file makes the group
    # false, `-prune` is never reached, and the right side is evaluated. Putting
    # `-false` at the end of the group instead looks equivalent and is not: on
    # findutils 4.9.0 it still fails to prune. This was measured, not reasoned.
    if ((${#EXCLUDE_NAMES[@]} > 0)); then
        printf '%s\n' '(' -type d '('
        first=1
        for pat in "${EXCLUDE_NAMES[@]}"; do
            [ -n "$pat" ] || continue
            ((first)) || printf '%s\n' -o
            first=0
            printf '%s\n' -name "$pat"
        done
        printf '%s\n' ')' ')' -prune -o
    fi
    if ((${#EXCLUDE_PATHS[@]} > 0)); then
        printf '%s\n' '(' -type d '('
        first=1
        for pat in "${EXCLUDE_PATHS[@]}"; do
            [ -n "$pat" ] || continue
            ((first)) || printf '%s\n' -o
            first=0
            printf '%s\n' -path "$pat" -o -path "${pat%/}/*"
        done
        printf '%s\n' ')' ')' -prune -o
    fi
    printf '%s\n' '(' -type f -name wp-config.php ')' -print0
}

scan_root() { # ROOT
    local root="$1" config site base
    local -a fargs=()
    if [ ! -d "$root" ]; then
        log_debug "root is not a directory, skipped: ${root}"
        SKIPPED_UNREADABLE=$((SKIPPED_UNREADABLE + 1))
        return 0
    fi
    if [ ! -r "$root" ] || [ ! -x "$root" ]; then
        log_warn "root is not readable, skipped: ${root}"
        SKIPPED_UNREADABLE=$((SKIPPED_UNREADABLE + 1))
        return 0
    fi
    mapfile -t fargs < <(build_find_args "$root")
    log_debug "scanning ${root} (max depth ${MAX_DEPTH})"
    # -print0 / read -d '' is the only combination that survives every filename.
    while IFS= read -r -d '' config; do
        site="$(dirname -- "$config")"
        base="${site##*/}"
        if [ -e "${site}/${OPT_OUT_MARKER}" ]; then
            SKIPPED_OPTOUT=$((SKIPPED_OPTOUT + 1))
            log_debug "opt-out marker, skipped: ${site}"
            continue
        fi
        if name_is_excluded "$base" || path_is_excluded "$site"; then
            SKIPPED_EXCLUDED=$((SKIPPED_EXCLUDED + 1))
            log_debug "excluded, skipped: ${site}"
            continue
        fi
        if ! is_valid_wp "$site"; then
            SKIPPED_INVALID=$((SKIPPED_INVALID + 1))
            log_debug "not a WordPress root, skipped: ${site}"
            continue
        fi
        printf '%s\0' "$site"
    done < <(find "${fargs[@]}" 2>/dev/null)
    return 0
}

collect_results() {
    local root
    make_tmp results; RESULTS_FILE="$TMP_LAST"
    make_tmp sorted; SORTED_FILE="$TMP_LAST"
    : >"$RESULTS_FILE"
    for root in ${SEARCH_ROOTS[@]+"${SEARCH_ROOTS[@]}"}; do
        log_info "scanning: ${root}"
        scan_root "$root" >>"$RESULTS_FILE"
    done
    # Deduplicate and sort in one pass; NUL separated, so any filename survives.
    sort -z -u <"$RESULTS_FILE" >"$SORTED_FILE"
    FOUND_COUNT="$(tr -cd '\0' <"$SORTED_FILE" | wc -c)"
    FOUND_COUNT="${FOUND_COUNT//[^0-9]/}"
    FOUND_COUNT="${FOUND_COUNT:-0}"
    return 0
}

###############################################################################
# 7. Rendering
###############################################################################

json_escape() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

csv_escape() { # VALUE DELIMITER
    local v="${1-}" d="${2:-,}"
    case "$v" in
        *"$d"* | *'"'* | *$'\n'* | *$'\r'*) printf '"%s"' "${v//\"/\"\"}" ;;
        *) printf '%s' "$v" ;;
    esac
}

# emit_result: write the site list in the requested format.
# `paths` (the default) writes one absolute path per line, which is exactly what
# Bash_WP-CLI_Update.sh consumes; the other formats are for humans and tooling.
emit_result() { # < NUL-separated sorted list
    local site owner group mtime version dbname first=1 d cell out
    local -a row=() hdr=(path owner group modified wp_version db_name)
    case "$OUTPUT_FORMAT" in
        tsv) d=$'\t' ;;
        csv) d="${DELIMITER:-,}" ;;
        *) d=$'\t' ;;
    esac
    case "$OUTPUT_FORMAT" in
        json)
            printf '['
            ;;
        tsv | csv)
            out=''
            for cell in "${hdr[@]}"; do
                if [ "$OUTPUT_FORMAT" = 'csv' ]; then
                    out+="${out:+$d}$(csv_escape "$cell" "$d")"
                else
                    out+="${out:+$d}${cell}"
                fi
            done
            printf '%s\n' "$out"
            ;;
    esac
    while IFS= read -r -d '' site; do
        [ -n "$site" ] || continue
        owner="$(stat -c '%U' -- "$site" 2>/dev/null)" || owner='<unknown>'
        group="$(stat -c '%G' -- "$site" 2>/dev/null)" || group='<unknown>'
        mtime="$(stat -c '%y' -- "$site" 2>/dev/null)" || mtime='<unknown>'
        mtime="${mtime%%.*}"
        version="$(wp_version_of "$site")" || version=''
        dbname="$(db_name_of "$site")" || dbname=''
        case "$OUTPUT_FORMAT" in
            paths)
                printf '%s\n' "$site"
                ;;
            json)
                ((first)) || printf ','
                first=0
                printf '{"path":"%s","owner":"%s","group":"%s","modified":"%s","wp_version":"%s","db_name":"%s"}' \
                    "$(json_escape "$site")" "$(json_escape "$owner")" "$(json_escape "$group")" \
                    "$(json_escape "$mtime")" "$(json_escape "$version")" "$(json_escape "$dbname")"
                ;;
            *)
                row=("$site" "$owner" "$group" "$mtime" "$version" "$dbname")
                out=''
                for cell in "${row[@]}"; do
                    if [ "$OUTPUT_FORMAT" = 'csv' ]; then
                        out+="${out:+$d}$(csv_escape "$cell" "$d")"
                    else
                        out+="${out:+$d}${cell}"
                    fi
                done
                printf '%s\n' "$out"
                ;;
        esac
    done
    [ "$OUTPUT_FORMAT" = 'json' ] && printf ']\n'
    return 0
}

# write_output: atomic replace, so a reader never sees a half-written list.
# The list arrives on stdin; the destination is the global OUTPUT_FILE. Taking
# the destination as $1 looked tidier but silently produced an empty target,
# because a caller writing `write_output <"$SORTED_FILE"` passes no arguments.
write_output() { # < NUL-separated sorted list
    local target="$OUTPUT_FILE" tmp dir
    if [ "$target" = '-' ]; then
        emit_result
        return 0
    fi
    dir="$(dirname -- "$target")"
    if [ ! -d "$dir" ]; then
        mkdir -p -- "$dir" 2>/dev/null || {
            log_error "cannot create the output directory: ${dir}"
            return 1
        }
    fi
    make_tmp output || return 1
    tmp="$TMP_LAST"
    if ! emit_result >"$tmp"; then
        log_error "cannot render the result"
        return 1
    fi
    # Preserve the permissions of an existing list: cron may read it as another
    # user, and a fresh 0600 file would break that silently.
    if [ -f "$target" ]; then
        chmod --reference="$target" "$tmp" 2>/dev/null
        chown --reference="$target" "$tmp" 2>/dev/null
    else
        chmod 644 "$tmp" 2>/dev/null
    fi
    if ! mv -f -- "$tmp" "$target" 2>/dev/null; then
        log_error "cannot write the output file: ${target}"
        return 1
    fi
    return 0
}

# A human-readable table on stderr, so it never pollutes a piped result.
print_table() { # < NUL-separated sorted list
    [ "$QUIET" = 'true' ] && return 0
    local site owner mtime version
    printf '%s\n' "${C_BOLD}PATH                                        OWNER           WP VERSION  MODIFIED${C_RESET}" >&2
    printf '%s\n' "${C_DIM}-----------------------------------------------------------------------------------${C_RESET}" >&2
    while IFS= read -r -d '' site; do
        [ -n "$site" ] || continue
        owner="$(stat -c '%U' -- "$site" 2>/dev/null)" || owner='?'
        mtime="$(stat -c '%y' -- "$site" 2>/dev/null)" || mtime='?'
        version="$(wp_version_of "$site")" || version='-'
        printf '%-44s %-15s %-11s %s\n' "$site" "$owner" "${version:--}" "${mtime%%.*}" >&2
    done
    return 0
}

# --skip-existing: drop sites that are already in the current list. Used to grow
# an inventory without re-processing what is already there.
filter_existing() { # LIST_FILE < NUL list
    local list="${1:-}" site
    [ -f "$list" ] || { cat; return 0; }
    local -A seen=()
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"          # CR only: a trailing space is part of a path
        case "$line" in '' | '#'*) continue ;; esac
        seen["$line"]=1
    done <"$list"
    while IFS= read -r -d '' site; do
        if [ -n "${seen[$site]-}" ]; then
            SKIPPED_DUPLICATE=$((SKIPPED_DUPLICATE + 1))
            continue
        fi
        printf '%s\0' "$site"
    done
}

###############################################################################
# 8. --status: report on the list that already exists, without scanning
###############################################################################

status_report() {
    local list="${1:-}" site owner version count=0
    if [ ! -f "$list" ]; then
        log_info "no site list at ${list} yet"
        return 0
    fi
    printf '%s\n' "${C_BOLD}site list${C_RESET}  ${list}" >&2
    printf '%s\n' "${C_BOLD}size${C_RESET}       $(stat -c '%s bytes, modified %y' -- "$list" 2>/dev/null)" >&2
    printf '%s\n' "${C_BOLD}PATH                                        OWNER           WP VERSION${C_RESET}" >&2
    while IFS= read -r site || [ -n "$site" ]; do
        site="${site%$'\r'}"          # CR only: a trailing space is part of a path
        case "$site" in '' | '#'*) continue ;; esac
        count=$((count + 1))
        if [ ! -d "$site" ]; then
            printf '%-44s %s\n' "$site" "${C_RED}<missing>${C_RESET}" >&2
            continue
        fi
        owner="$(stat -c '%U' -- "$site" 2>/dev/null)" || owner='?'
        version="$(wp_version_of "$site")" || version='-'
        printf '%-44s %-15s %s\n' "$site" "$owner" "${version:--}" >&2
    done <"$list"
    printf '%s\n' "${C_BOLD}entries${C_RESET}    ${count}" >&2
    return 0
}

###############################################################################
# 9. Help
###############################################################################

usage() { # [EXIT_CODE]
    local rc="${1:-$EXIT_USAGE}" r
    cat <<EOF
${PROG_NAME} ${SCRIPT_VERSION} - find WordPress installations

Usage:
  ${PROG_NAME} [options] [SEARCH_ROOT ...]

Search roots:
  Only the roots named here are scanned. When none is given, these defaults are
  used -- and never "/":
EOF
    for r in "${DEFAULT_SEARCH_ROOTS[@]}"; do printf '    %s\n' "$r"; done
    cat <<EOF

Options:
  -o, --output FILE       write the site list to FILE ('-' = stdout,
                          default: ${DEFAULT_OUTPUT_FILE})
  -d, --depth N           maximum depth below each root (1..${HARD_MAX_DEPTH},
                          default: ${DEFAULT_MAX_DEPTH})
  -x, --exclude-name GLOB exclude directories whose NAME matches GLOB (repeatable)
  -X, --exclude-path PATH exclude this path and everything below it (repeatable)
      --no-default-excludes
                          start with an empty exclusion list
      --format FMT        paths | tsv | csv | json (default: paths)
      --delimiter CHAR    field delimiter for csv (default: ',')
      --skip-existing     drop sites already present in the output file
      --fail-empty        exit 1 instead of 5 when nothing was found
      --status            describe the existing site list, do not scan
      --color WHEN        auto | always | never (default: ${COLOR_MODE})
      --no-color          same as --color never
      --quiet             only warnings and errors on stderr
  -v, --verbose           explain every skipped directory
  -h, --help              this help, exit 0
  -V, --version           print the version, exit 0

Detection rule:
  a directory is a WordPress root when it holds wp-config.php and one of
  wp-load.php or wp-includes/version.php. A directory containing
  ${OPT_OUT_MARKER} is always skipped, which is how a site opts out of
  automated maintenance.

Output:
  prose goes to stderr; stdout carries the result. With --format paths (the
  default) stdout is one absolute path per line, ready for
  Bash_WP-CLI_Update.sh --sites FILE. The write is atomic: a temporary file is
  renamed over the target, and the permissions of an existing list are kept.

Exit codes:
  0 found   1 operational error   2 usage error   3 environment error
  5 nothing found (use --fail-empty to turn it into 1)

Examples:
  ${PROG_NAME}                                  # scan the default roots
  ${PROG_NAME} /var/www /srv                    # scan exactly these two
  ${PROG_NAME} --depth 4 -x 'node_modules' /var/www
  ${PROG_NAME} --format json -o - /var/www | jq -r '.[].path'
  ${PROG_NAME} --status
EOF
    exit "$rc"
}

version_info() { printf '%s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"; }

###############################################################################
# 10. Argument parsing
###############################################################################

# need_value OPTION [VALUE] -> sets OPT_VALUE.
#
# It does not print the value for `$(...)` capture on purpose: usage_error exits,
# and an exit inside a command substitution only leaves the subshell, so the
# caller would continue with an empty value. That single detail turned
# "--sites" with no argument into a run against the default paths.
OPT_VALUE=''
need_value() { # OPTION [VALUE]
    if [ -z "${2:-}" ]; then
        usage_error "${1} requires a value"
    fi
    OPT_VALUE="$2"
    return 0
}

parse_args() {
    local arg
    while (($# > 0)); do
        arg="$1"
        case "$arg" in
            -o | --output) need_value "$arg" "${2:-}"; OUTPUT_FILE="$OPT_VALUE"; shift ;;
            -d | --depth | --max-depth)
                need_value "$arg" "${2:-}"; MAX_DEPTH="$OPT_VALUE"; shift ;;
            -x | --exclude-name) need_value "$arg" "${2:-}"; EXCLUDE_NAMES+=("$OPT_VALUE"); shift ;;
            -X | --exclude-path) need_value "$arg" "${2:-}"; EXCLUDE_PATHS+=("$OPT_VALUE"); shift ;;
            -e | --exclude)
                # Compatibility with the historical single --exclude option:
                # an absolute path excludes a subtree, anything else is a name.
                need_value "$arg" "${2:-}"
                if [ "${OPT_VALUE#/}" = "$OPT_VALUE" ]; then
                    EXCLUDE_NAMES+=("$OPT_VALUE")
                else
                    EXCLUDE_PATHS+=("$OPT_VALUE")
                fi
                shift ;;
            --no-default-excludes) USE_DEFAULT_EXCLUDES='false' ;;
            --format) need_value "$arg" "${2:-}"; OUTPUT_FORMAT="${OPT_VALUE,,}"; shift ;;
            --delimiter) need_value "$arg" "${2:-}"; DELIMITER="$OPT_VALUE"; shift ;;
            --skip-existing) SKIP_EXISTING='true' ;;
            --fail-empty) FAIL_EMPTY='true' ;;
            --status) STATUS_ONLY='true' ;;
            --color) need_value "$arg" "${2:-}"; COLOR_MODE="${OPT_VALUE,,}"; shift ;;
            --no-color) COLOR_MODE='never' ;;
            --quiet | -q) QUIET='true' ;;
            -v | --verbose) VERBOSE='true'; QUIET='false' ;;
            -h | --help) usage "$EXIT_OK" ;;
            -V | --version) version_info; exit "$EXIT_OK" ;;
            --) shift; break ;;
            -*) usage_error "unknown option: ${arg} (try --help)" ;;
            *) CLI_ROOTS+=("$arg") ;;
        esac
        shift
    done
    # Everything after `--` is a search root, even when it looks like an option.
    while (($# > 0)); do
        CLI_ROOTS+=("$1")
        shift
    done
}

validate_args() {
    case "$OUTPUT_FORMAT" in
        paths | tsv | csv | json) ;;
        *) usage_error "--format must be one of: paths, tsv, csv, json (got '${OUTPUT_FORMAT}')" ;;
    esac
    case "$COLOR_MODE" in
        auto | always | never) ;;
        *) usage_error "--color must be one of: auto, always, never (got '${COLOR_MODE}')" ;;
    esac
    if ! [[ "$MAX_DEPTH" =~ ^[0-9]+$ ]] || ((MAX_DEPTH < 1)) || ((MAX_DEPTH > HARD_MAX_DEPTH)); then
        usage_error "--depth must be an integer between 1 and ${HARD_MAX_DEPTH} (got '${MAX_DEPTH}')"
    fi
    if [ "$OUTPUT_FILE" != '-' ]; then
        local dir
        dir="$(dirname -- "$OUTPUT_FILE")"
        if [ -e "$dir" ] && [ ! -d "$dir" ]; then
            usage_error "--output: ${dir} is not a directory"
        fi
    fi
    if [ -n "$DELIMITER" ] && ((${#DELIMITER} != 1)); then
        usage_error "--delimiter must be exactly one character (got '${DELIMITER}')"
    fi
    return 0
}

# resolve_roots: the effective scan list. Command-line roots replace the
# defaults; they are never merged with them, and "/" is never injected.
resolve_roots() {
    local r
    SEARCH_ROOTS=()
    if ((${#CLI_ROOTS[@]} > 0)); then
        for r in ${CLI_ROOTS[@]+"${CLI_ROOTS[@]}"}; do
            [ -n "$r" ] || continue
            r="${r%/}"
            # A root of exactly "/" stays "/" -- but it can only get here by
            # being typed explicitly, never by an empty-element accident.
            [ -n "$r" ] || r='/'
            SEARCH_ROOTS+=("$r")
        done
    else
        for r in ${DEFAULT_SEARCH_ROOTS[@]+"${DEFAULT_SEARCH_ROOTS[@]}"}; do
            [ -d "$r" ] && SEARCH_ROOTS+=("${r%/}")
        done
    fi
    if ((${#SEARCH_ROOTS[@]} == 0)); then
        log_error 'none of the search roots exists; name one explicitly'
        return 1
    fi
    return 0
}

resolve_excludes() {
    local ex
    if [ "$USE_DEFAULT_EXCLUDES" = 'true' ]; then
        EXCLUDE_NAMES=("${DEFAULT_EXCLUDE_NAMES[@]}" ${EXCLUDE_NAMES[@]+"${EXCLUDE_NAMES[@]}"})
    fi
    # An absolute --exclude path is normalised once, here, instead of inside the
    # find expression: `find -path` compares strings, not filesystem identity.
    local -a cleaned=()
    for ex in ${EXCLUDE_PATHS[@]+"${EXCLUDE_PATHS[@]}"}; do
        [ -n "$ex" ] || continue
        cleaned+=("${ex%/}")
    done
    EXCLUDE_PATHS=()
    if ((${#cleaned[@]} > 0)); then
        EXCLUDE_PATHS=("${cleaned[@]}")
    fi
    return 0
}

report_skipped() {
    local total=$((SKIPPED_OPTOUT + SKIPPED_INVALID + SKIPPED_EXCLUDED + SKIPPED_UNREADABLE + SKIPPED_DUPLICATE))
    ((total > 0)) || return 0
    log_info "skipped: ${SKIPPED_OPTOUT} opt-out, ${SKIPPED_INVALID} not a WordPress root, ${SKIPPED_EXCLUDED} excluded, ${SKIPPED_DUPLICATE} already listed, ${SKIPPED_UNREADABLE} unreadable root"
}

###############################################################################
# 11. main
###############################################################################

main() {
    parse_args "$@"
    validate_args
    color_init
    [ "$VERBOSE" = 'true' ] && QUIET='false'
    START_TIME="$(date +%s)"

    if [ "$STATUS_ONLY" = 'true' ]; then
        status_report "$OUTPUT_FILE"
        exit "$EXIT_OK"
    fi

    resolve_excludes
    resolve_roots || exit "$EXIT_ERROR"

    log_info "${PROG_NAME} ${SCRIPT_VERSION}: ${#SEARCH_ROOTS[@]} root(s), depth ${MAX_DEPTH}, format ${OUTPUT_FORMAT}"
    log_debug "excluded names: ${EXCLUDE_NAMES[*]:-<none>}"
    log_debug "excluded paths: ${EXCLUDE_PATHS[*]:-<none>}"

    collect_results

    if [ "$SKIP_EXISTING" = 'true' ] && [ "$OUTPUT_FILE" != '-' ]; then
        local filtered
        make_tmp filtered; filtered="$TMP_LAST"
        filter_existing "$OUTPUT_FILE" <"$SORTED_FILE" >"$filtered"
        SORTED_FILE="$filtered"
        FOUND_COUNT="$(tr -cd '\0' <"$SORTED_FILE" | wc -c)"
        FOUND_COUNT="${FOUND_COUNT//[^0-9]/}"
        FOUND_COUNT="${FOUND_COUNT:-0}"
    fi

    if ((FOUND_COUNT == 0)); then
        log_warn "no WordPress installation found under: ${SEARCH_ROOTS[*]}"
        report_skipped
        # Still write an empty list: a stale list from a previous run is far more
        # dangerous than an empty one, because the manager would happily work on
        # sites that are no longer there.
        if [ "$OUTPUT_FILE" != '-' ]; then
            write_output <"$SORTED_FILE" || exit "$EXIT_ERROR"
            log_info "empty site list written: ${OUTPUT_FILE}"
        fi
        if [ "$FAIL_EMPTY" = 'true' ]; then
            exit "$EXIT_ERROR"
        fi
        exit "$EXIT_NOT_FOUND"
    fi

    if ! write_output <"$SORTED_FILE"; then
        exit "$EXIT_ERROR"
    fi

    log_ok "found ${FOUND_COUNT} installation(s)"
    report_skipped
    if [ "$OUTPUT_FILE" = '-' ]; then
        log_info 'result written to stdout'
    else
        log_info "site list written: ${OUTPUT_FILE}"
        print_table <"$SORTED_FILE"
    fi
    log_info "finished in $(( $(date +%s) - START_TIME ))s"
    exit "$EXIT_OK"
}


main "$@"

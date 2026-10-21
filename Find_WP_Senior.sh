#!/usr/bin/env bash
# shellcheck shell=bash
###############################################################################
# WordPress installation discovery
#
# File:        Find_WP_Senior.sh
# Project:     Bash WP-CLI Update
# Repository:  https://github.com/paulmann/Bash_WP-CLI_Update
# License:     MIT
# Version:     2.0.0
#
# Scans one or more web roots for WordPress installations (a directory holding
# wp-config.php and wp-load.php), skips opt-outs and exclusions, deduplicates the
# result and writes it to the site list consumed by Bash_WP-CLI_Update.sh.
#
# Exit codes:
#   0  installations found and written
#   1  operational error (unreadable root, cannot write the output file)
#   2  usage error
#   3  environment error (bash too old, required tools missing)
#   5  no installations found (not an error of the tool itself)
###############################################################################

if [ -z "${BASH_VERSION:-}" ]; then
    printf 'ERROR: this script requires bash.\n' >&2
    exit 3
fi

# No 'set -e': the scan is a sequence of independent roots and a failing root must
# not abort the whole run. Statuses are checked explicitly.
set -uo pipefail
shopt -s inherit_errexit 2>/dev/null || true

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
    printf 'ERROR: bash 4.2 or newer is required, found %s\n' "${BASH_VERSION}" >&2
    exit 3
fi

export LC_ALL=C

readonly EXIT_OK=0
readonly EXIT_ERROR=1
readonly EXIT_USAGE=2
readonly EXIT_ENV=3
readonly EXIT_NOT_FOUND=5

readonly PROG_NAME="${0##*/}"
readonly SCRIPT_VERSION='2.0.0'

_resolve_script_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [ -L "$src" ]; do
        dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}
script_dir="$(_resolve_script_dir)" || { printf 'ERROR: cannot resolve script directory\n' >&2; exit "$EXIT_ENV"; }
readonly script_dir
unset -f _resolve_script_dir

# The default output sits next to the script, which is where the manager expects
# its site list. It is NOT derived from $PWD: the previous version wrote the file
# into the current directory, so './Find_WP_Senior.sh' from another directory
# produced a list the manager never saw.
readonly DEFAULT_OUTPUT_FILE="${script_dir}/wp-found.txt"
readonly DEFAULT_MAX_DEPTH=8
readonly MARKER_FILE='.no_wp_cli'

# Roots scanned when none are given on the command line.
readonly -a DEFAULT_SEARCH_DIRS=(
    /var/www
    /var/www/html
    /usr/share/nginx/html
    /usr/local/nginx/html
    /usr/local/var/www
    /srv
    /home
)

# Directory NAMES to prune, matched as whole path components. Substring globs
# ('*old*', '*test*', '*backup*') are deliberately gone: they silently dropped
# production sites such as oldtown.com, btest.example.com and contest.org.
# Consequences worth knowing: 'old' and 'backup-2025' are kept, because the name
# alone cannot tell a backup from a live site; use --exclude-name or
# --exclude-path for those.
readonly -a DEFAULT_EXCLUDE_NAMES=(
    .git
    .svn
    .hg
    node_modules
    bower_components
    vendor
    __pycache__
    cache
    caches
    tmp
    temp
    backups
    backup
    lost+found
    proc
    sys
    dev
    run
)

OUTPUT_FILE="$DEFAULT_OUTPUT_FILE"
MAX_DEPTH="$DEFAULT_MAX_DEPTH"
OUTPUT_FORMAT='paths'
DELIMITER=''
SKIP_EXISTS='false'
STATUS_ONLY='false'
QUIET='false'
VERBOSE='false'
COLOR_MODE='auto'
declare -a SEARCH_DIRS=()
declare -a EXCLUDE_NAMES=()
declare -a EXCLUDE_PATHS=()
declare -a EXCLUDE_PATHS_NORM=()

C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''

###############################################################################
# Output helpers
###############################################################################
_colors_init() {
    local use='no'
    if [ -n "${NO_COLOR:-}" ] || [ "$COLOR_MODE" = 'never' ]; then
        use='no'
    elif [ "$COLOR_MODE" = 'always' ]; then
        use='yes'
    elif [ "$COLOR_MODE" = 'auto' ] && [ -t 2 ]; then
        use='yes'
    fi
    if [ "$use" = 'yes' ]; then
        C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
        C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
    fi
}

# Every human message goes to stderr: stdout carries only the result, so
# 'Find_WP_Senior.sh | ...' is usable without filtering noise out.
log()     { [ "$QUIET" = 'true' ] || printf '%sINFO%s %s\n'  "$C_BLUE"   "$C_RESET" "$*" >&2; }
warn()    { printf '%sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error()   { printf '%sERROR%s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; }
success() { [ "$QUIET" = 'true' ] || printf '%sOK%s %s\n'    "$C_GREEN"  "$C_RESET" "$*" >&2; }
vlog()    { [ "$VERBOSE" = 'true' ] && printf '%sDEBUG%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2; return 0; }

usage() { # EXIT_CODE
    local rc="${1:-$EXIT_USAGE}"
    cat <<EOF
${PROG_NAME} v${SCRIPT_VERSION} - find WordPress installations

Usage:
  ${PROG_NAME} [options] [SEARCH_DIR...]

Options:
  -o, --output FILE       write the site list to FILE (default: ${DEFAULT_OUTPUT_FILE})
  -d, --depth N           maximum search depth below each root (default: ${DEFAULT_MAX_DEPTH})
  -x, --exclude-name NAME exclude directories with this NAME (repeatable)
      --exclude-path PATH exclude this path and everything below it (repeatable)
      --format FMT        result format: paths|tsv|json|csv (default: paths)
      --delimiter CHAR    field delimiter for tsv/csv (default: tab, comma for csv)
      --skip-existing     do not rewrite the output when its content is unchanged
      --status            print the state of the output file and exit
      --quiet             no progress messages
  -v, --verbose           show each root as it is scanned
      --color WHEN        auto|always|never (default: auto)
      --no-color          same as --color never
  -h, --help              show this help and exit with status 0
  -V, --version           print the version and exit

Opt-out:
  A directory containing ${MARKER_FILE} is skipped, together with everything below it.

Result format:
  paths  one absolute path per line (what Bash_WP-CLI_Update.sh reads)
  tsv    path, owner, group, last-modified
  csv    the same four columns, comma separated
  json   an array of objects with the same four fields

Exit codes:
  0 found   1 error   2 usage error   3 environment error   5 nothing found

Examples:
  ${PROG_NAME}
  ${PROG_NAME} /var/www /srv
  ${PROG_NAME} --exclude-name staging --format tsv
  ${PROG_NAME} --output /etc/wp-cli-update/sites.txt --depth 10
EOF
    exit "$rc"
}

version_info() { printf '%s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"; }

usage_error() {
    printf '%s: %s\n' "$PROG_NAME" "$1" >&2
    printf 'Try "%s --help".\n' "$PROG_NAME" >&2
    exit "$EXIT_USAGE"
}

###############################################################################
# Argument parsing
###############################################################################
_need_value() { # OPTION NEXT
    local opt="$1" next="${2:-}"
    if [ -z "$next" ] || [[ "$next" == -* ]]; then
        usage_error "option ${opt} requires a value"
    fi
    printf '%s' "$next"
}

parse_args() {
    local arg next
    while [ $# -gt 0 ]; do
        arg="$1"; shift
        case "$arg" in
            -o|--output)        next="$(_need_value "$arg" "${1:-}")"; OUTPUT_FILE="$next"; shift ;;
            -d|--depth)         next="$(_need_value "$arg" "${1:-}")"; MAX_DEPTH="$next"; shift ;;
            -x|--exclude-name)  next="$(_need_value "$arg" "${1:-}")"; EXCLUDE_NAMES+=("$next"); shift ;;
            --exclude-path)     next="$(_need_value "$arg" "${1:-}")"; EXCLUDE_PATHS+=("$next"); shift ;;
            --format)           next="$(_need_value "$arg" "${1:-}")"; OUTPUT_FORMAT="${next,,}"; shift ;;
            --delimiter)        next="$(_need_value "$arg" "${1:-}")"; DELIMITER="$next"; shift ;;
            --skip-existing)    SKIP_EXISTS='true' ;;
            --status)           STATUS_ONLY='true' ;;
            --quiet)            QUIET='true' ;;
            -v|--verbose)       VERBOSE='true' ;;
            --color)            next="$(_need_value "$arg" "${1:-}")"; COLOR_MODE="${next,,}"; shift ;;
            --no-color)         COLOR_MODE='never' ;;
            -h|--help)          usage "$EXIT_OK" ;;
            -V|--version)       version_info; exit "$EXIT_OK" ;;
            --)                 shift
                                while [ $# -gt 0 ]; do SEARCH_DIRS+=("$1"); shift; done ;;
            -*)                 usage_error "unknown option: ${arg}" ;;
            *)                  SEARCH_DIRS+=("$arg") ;;
        esac
    done
}

validate_options() {
    [[ "$MAX_DEPTH" =~ ^[0-9]+$ ]] || usage_error "invalid --depth: ${MAX_DEPTH}"
    case "$OUTPUT_FORMAT" in
        paths|tsv|csv|json) ;;
        *) usage_error "invalid --format: ${OUTPUT_FORMAT} (paths, tsv, csv, json)" ;;
    esac
    case "$COLOR_MODE" in
        auto|always|never) ;;
        *) usage_error "invalid --color: ${COLOR_MODE} (auto, always, never)" ;;
    esac
    if [ -z "$DELIMITER" ]; then
        case "$OUTPUT_FORMAT" in
            csv) DELIMITER=',' ;;
            *)   DELIMITER=$'\t' ;;
        esac
    fi
    have find || { error "'find' is not available"; exit "$EXIT_ENV"; }
    have stat || vlog "stat is missing: owner and date columns will be reported as unknown"
    return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

# 'grep -c' exits 1 when it matches nothing, which turns '$(... || printf 0)' into
# two values and breaks every later numeric test. Always return one number.
count_lines() { # FILE
    local n
    n="$(grep -c '' "$1" 2>/dev/null)" || n=0
    n="${n//[^0-9]/}"
    printf '%s' "${n:-0}"
}

###############################################################################
# Exclusions
###############################################################################
# Directory names are matched as whole components by 'find -name', and the same
# list is applied again after the walk for clarity. Whole-component matching is
# what keeps 'oldtown.com' in the result while 'old' is dropped.
build_exclude_names() {
    local -a merged=("${DEFAULT_EXCLUDE_NAMES[@]}")
    merged+=("${EXCLUDE_NAMES[@]+"${EXCLUDE_NAMES[@]}"}")
    printf '%s\n' "${merged[@]}" | awk 'NF && !seen[$0]++'
}

# Normalise an excluded path once, so the comparison in the hot loop is textual.
normalise_paths() {
    local p
    EXCLUDE_PATHS_NORM=()
    for p in "${EXCLUDE_PATHS[@]+"${EXCLUDE_PATHS[@]}"}"; do
        [ -n "$p" ] || continue
        if [ -d "$p" ]; then
            p="$(cd "$p" 2>/dev/null && pwd)" || p="${p%/}"
        else
            p="${p%/}"
        fi
        EXCLUDE_PATHS_NORM+=("$p")
    done
}

is_excluded_path() { # DIR
    local dir="$1" p
    for p in "${EXCLUDE_PATHS_NORM[@]+"${EXCLUDE_PATHS_NORM[@]}"}"; do
        [ -z "$p" ] && continue
        if [ "$dir" = "$p" ] || [[ "$dir" == "${p}/"* ]]; then
            return 0
        fi
    done
    return 1
}

###############################################################################
# Detection
###############################################################################
# A WordPress root has wp-config.php and one of wp-load.php / wp-includes/version.php.
# Requiring only wp-includes/version.php, as v1 did, rejected installations whose
# version.php lives behind a symlinked wp-includes.
is_wordpress_root() { # DIR
    local dir="$1"
    [ -f "${dir}/wp-config.php" ] || return 1
    [ -f "${dir}/wp-load.php" ] || [ -f "${dir}/wp-includes/version.php" ] || return 1
    return 0
}

metadata_of() { # DIR -> "user<TAB>group<TAB>mtime"
    local dir="$1" user='' group='' mtime=''
    if have stat; then
        user="$(stat -c '%U' "$dir" 2>/dev/null || true)"
        group="$(stat -c '%G' "$dir" 2>/dev/null || true)"
        mtime="$(stat -c '%y' "$dir" 2>/dev/null || true)"
        mtime="${mtime%%.*}"
    fi
    printf '%s\t%s\t%s' "${user:-unknown}" "${group:-unknown}" "${mtime:-unknown}"
}

csv_quote() {
    local s="$1"
    case "$s" in
        *[,\"]*|*$'\n'*) s="\"${s//\"/\"\"}\"" ;;
    esac
    printf '%s' "$s"
}

json_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

###############################################################################
# Scanning
###############################################################################
declare -a FOUND_DIRS=()

# Build the find expression as an ARRAY. v1 assembled the prune clause into a
# single string with 'printf', which merged '-path X -prune -o' into one invalid
# operand and silently disabled every exclusion.
scan_root() { # ROOT
    local root="$1"
    local -a names=()
    local name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        names+=("$name")
    done < <(build_exclude_names)

    vlog "scanning ${root} (depth ${MAX_DEPTH})"

    # The expression is built from two parts, and the file branch ends with its
    # own -print. In v1 the only -print came from the prune helper, so as soon as
    # an exclusion existed find printed directories instead of wp-config.php.
    local -a expr=()
    expr+=( '(' -type d '(' )
    local i first=1
    for (( i = 0; i < ${#names[@]}; i++ )); do
        [ "$first" -eq 1 ] || expr+=(-o)
        first=0
        expr+=(-name "${names[i]}")
    done
    expr+=( ')' -prune ')' -o )

    local p
    for p in "${EXCLUDE_PATHS_NORM[@]+"${EXCLUDE_PATHS_NORM[@]}"}"; do
        [ -n "$p" ] || continue
        expr+=( '(' -path "$p" -o -path "$p/*" ')' -prune ')' -o )
    done

    expr+=( '(' -type f -name 'wp-config.php' -print ')' )
    local config site_dir
    while IFS= read -r config; do
        [ -n "$config" ] || continue
        site_dir="${config%/wp-config.php}"
        if [ -f "${site_dir}/${MARKER_FILE}" ]; then
            vlog "skipped (${MARKER_FILE}): ${site_dir}"
            continue
        fi
        if is_excluded_path "$site_dir"; then
            vlog "skipped (excluded path): ${site_dir}"
            continue
        fi
        if is_wordpress_root "$site_dir"; then
            printf '%s\n' "$site_dir"
        else
            vlog "skipped (incomplete installation): ${site_dir}"
        fi
    done < <(find "$root" -maxdepth "$MAX_DEPTH" "${expr[@]}" 2>/dev/null)
}

dedupe() { # < stdin
    awk 'NF && !seen[$0]++'
}

###############################################################################
# Output
###############################################################################
render_result() { # < sorted unique dirs on stdin
    local format="$1" dir meta user group mtime first=1
    case "$format" in
        paths)
            cat
            ;;
        tsv|csv)
            if [ "$format" = 'csv' ]; then
                printf 'path%cowner%cgroup%cmtime\n' "$DELIMITER" "$DELIMITER" "$DELIMITER"
            fi
            while IFS= read -r dir; do
                [ -n "$dir" ] || continue
                meta="$(metadata_of "$dir")"
                IFS=$'\t' read -r user group mtime <<<"$meta"
                if [ "$format" = 'csv' ]; then
                    printf '%s%c%s%c%s%c%s\n' "$(csv_quote "$dir")" "$DELIMITER" "$(csv_quote "$user")" \
                        "$DELIMITER" "$(csv_quote "$group")" "$DELIMITER" "$(csv_quote "$mtime")"
                else
                    printf '%s%s%s%s%s%s%s\n' "$dir" "$DELIMITER" "$user" "$DELIMITER" \
                        "$group" "$DELIMITER" "$mtime"
                fi
            done
            ;;
        json)
            printf '['
            while IFS= read -r dir; do
                [ -n "$dir" ] || continue
                meta="$(metadata_of "$dir")"
                IFS=$'\t' read -r user group mtime <<<"$meta"
                [ "$first" -eq 1 ] || printf ','
                first=0
                printf '{"path":%s,"owner":%s,"group":%s,"mtime":%s}' \
                    "$(json_quote "$dir")" "$(json_quote "$user")" \
                    "$(json_quote "$group")" "$(json_quote "$mtime")"
            done
            printf ']\n'
            ;;
    esac
    return 0
}

# Write the result atomically: a partial file would be read by the manager as a
# truncated site list.
write_result() { # FILE < stdin
    local file="$1" tmp dir rc=0
    dir="$(dirname "$file")"
    if [ ! -d "$dir" ]; then
        error "output directory does not exist: ${dir}"
        cat >/dev/null
        return 1
    fi
    if [ ! -w "$dir" ]; then
        error "output directory is not writable: ${dir}"
        cat >/dev/null
        return 1
    fi
    tmp="$(mktemp "${dir}/.${PROG_NAME##*/}.XXXXXX")" || { cat >/dev/null; error "cannot create a temporary file in ${dir}"; return 1; }
    cat >"$tmp" || rc=1
    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp"
        error "failed to collect results"
        return 1
    fi
    if [ "$SKIP_EXISTS" = 'true' ] && [ -f "$file" ] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        vlog "output unchanged: ${file}"
        return 0
    fi
    if ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        error "cannot write ${file}"
        return 1
    fi
    return 0
}

show_status() {
    printf '%s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"
    printf 'output file: %s\n' "$OUTPUT_FILE"
    if [ -f "$OUTPUT_FILE" ]; then
        printf 'entries:     %s\n' "$(count_lines "$OUTPUT_FILE")"
        printf 'size:        %s bytes\n' "$(wc -c <"$OUTPUT_FILE" 2>/dev/null || printf '0')"
        printf 'modified:    %s\n' "$(date -r "$OUTPUT_FILE" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'unknown')"
        printf 'stale:       %s\n' "$(status_stale)"
    else
        printf 'entries:     0\nstale:       yes (file missing)\n'
    fi
    printf 'search roots: %s\n' "${SEARCH_DIRS[*]}"
    printf 'depth:       %s\n' "$MAX_DEPTH"
    return 0
}

# A site list is stale when the recorded modification time is older than a
# wp-config.php that appeared below one of the roots in the meantime.
status_stale() {
    local file="$1" root newer
    file="$OUTPUT_FILE"
    [ -f "$file" ] || { printf 'yes'; return 0; }
    for root in "${SEARCH_DIRS[@]}"; do
        [ -d "$root" ] || continue
        newer="$(find "$root" -maxdepth "$MAX_DEPTH" -type f -name 'wp-config.php' -newer "$file" -print 2>/dev/null | head -n1)"
        if [ -n "$newer" ]; then
            printf 'yes (%s is newer)' "$newer"
            return 0
        fi
    done
    printf 'no'
    return 0
}

###############################################################################
# Main
###############################################################################
main() {
    parse_args "$@"
    _colors_init
    validate_options

    [ "${#EXCLUDE_NAMES[@]}" -eq 0 ] && EXCLUDE_NAMES=()
    if [ "${#SEARCH_DIRS[@]}" -eq 0 ]; then
        SEARCH_DIRS=("${DEFAULT_SEARCH_DIRS[@]}")
    fi
    normalise_paths

    if [ "$STATUS_ONLY" = 'true' ]; then
        show_status
        exit "$EXIT_OK"
    fi

    local start_time end_time
    start_time="$(date +%s)"
    log "searching ${#SEARCH_DIRS[@]} root(s), depth ${MAX_DEPTH}"

    local -a existing=()
    local root
    for root in "${SEARCH_DIRS[@]}"; do
        if [ -d "$root" ]; then
            existing+=("$root")
        else
            warn "root does not exist, skipped: ${root}"
        fi
    done

    if [ "${#existing[@]}" -eq 0 ]; then
        error "none of the search roots exists"
        exit "$EXIT_ERROR"
    fi

    local results_file
    results_file="$(mktemp "${TMPDIR:-/tmp}/wp-found.XXXXXX")" || { error "cannot create a temporary file"; exit "$EXIT_ERROR"; }
    trap 'rm -f "$results_file" 2>/dev/null' EXIT INT TERM

    # Scan every existing root. The previous version only descended into roots
    # whose name matched its own exclusion globs by accident, and lost the whole
    # result whenever the file branch printed nothing.
    : >"$results_file"
    for root in "${existing[@]}"; do
        scan_root "$root" >>"$results_file"
    done

    local sorted_file
    sorted_file="$(mktemp "${TMPDIR:-/tmp}/wp-found-sorted.XXXXXX")" || { error "cannot create a temporary file"; exit "$EXIT_ERROR"; }
    dedupe <"$results_file" | sort >"$sorted_file"

    local count
    count="$(count_lines "$sorted_file")"

    if [ "$count" -eq 0 ]; then
        warn "no WordPress installation found under: ${existing[*]}"
        render_result "$OUTPUT_FORMAT" <"$sorted_file" | write_result "$OUTPUT_FILE" || exit "$EXIT_ERROR"
        end_time="$(date +%s)"
        log "finished in $((end_time - start_time))s"
        exit "$EXIT_NOT_FOUND"
    fi

    render_result "$OUTPUT_FORMAT" <"$sorted_file" | write_result "$OUTPUT_FILE" || exit "$EXIT_ERROR"

    success "found ${count} installation(s)"
    success "written to ${OUTPUT_FILE}"
    if [ "$OUTPUT_FORMAT" != 'paths' ]; then
        render_result "$OUTPUT_FORMAT" <"$sorted_file"
    fi

    end_time="$(date +%s)"
    log "finished in $((end_time - start_time))s"
    return 0
}

main "$@"

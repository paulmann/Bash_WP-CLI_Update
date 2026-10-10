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
  -i, --include-name GLOB only keep directories whose NAME matches GLOB
                          (repeatable; empty means "everything")
      --no-default-excludes
                          start with an empty exclusion list
      --min-depth N       ignore wp-config.php shallower than N below the root
      --follow-symlinks   follow symbolic links (off by default: a symlink loop
                          or a link to / would turn discovery into a full
                          filesystem walk)
      --format FMT        paths | tsv | csv | json (default: paths)
      --print0            with --format paths: NUL-separated, so a path that
                          contains a newline survives the pipe
      --delimiter CHAR    field delimiter for csv (default: ',')
      --manifest FILE     also write a rich inventory: owner, group, modes,
                          WP version, database name, multisite, opt-out, mtime
      --manifest-format F tsv | csv | json (default: tsv)
      --fields LIST       comma separated manifest columns (default: all of
                          ${MANIFEST_ALL_FIELDS})
      --audit             report permission and hygiene findings for every
                          installation: a world-readable wp-config.php, PHP
                          files inside uploads, root-owned sites
      --verify-list FILE  check an existing site list instead of scanning:
                          missing entries, non-WordPress roots, opt-outs
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
  ${PROG_NAME} --manifest /var/lib/wp-cli-update/inventory.tsv /var/www
  ${PROG_NAME} --audit --verify-list /var/lib/wp-cli-update/wp-found.txt
  ${PROG_NAME} --print0 /var/www | xargs -0 -n1 du -sh
  ${PROG_NAME} --status
EOF
    exit "$rc"
}

version_info() { printf '%s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"; }

version_detail() {
    printf '%s %s (build %s, %s)\n' "$PROG_NAME" "$SCRIPT_VERSION" "$BUILD_ID" "$BUILD_DATE"
    printf 'script directory : %s\n' "$SCRIPT_DIR"
    printf 'bash             : %s\n' "$BASH_VERSION"
    printf 'running as       : %s (uid %s)\n' "$(id -un)" "$(id -u)"
    printf 'find             : %s\n' "$(command -v find 2>/dev/null || printf 'not found')"
    printf 'stat             : %s\n' "$(command -v stat 2>/dev/null || printf 'not found')"
    printf 'default roots    : %s\n' "${DEFAULT_SEARCH_ROOTS[*]}"
    printf 'opt-out marker   : %s\n' "$OPT_OUT_MARKER"
    printf 'manifest fields  : %s\n' "$MANIFEST_ALL_FIELDS"
    return 0
}

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
            -i | --include-name) need_value "$arg" "${2:-}"; INCLUDE_NAMES+=("$OPT_VALUE"); shift ;;
            --format) need_value "$arg" "${2:-}"; OUTPUT_FORMAT="${OPT_VALUE,,}"; shift ;;
            --delimiter) need_value "$arg" "${2:-}"; DELIMITER="$OPT_VALUE"; shift ;;
            --print0) PRINT_NUL='true' ;;
            --manifest) need_value "$arg" "${2:-}"; MANIFEST_FILE="$OPT_VALUE"; shift ;;
            --manifest-format) need_value "$arg" "${2:-}"; MANIFEST_FORMAT="${OPT_VALUE,,}"; shift ;;
            --fields) need_value "$arg" "${2:-}"; FIELD_LIST="$OPT_VALUE"; shift ;;
            --min-depth) need_value "$arg" "${2:-}"; MIN_DEPTH="$OPT_VALUE"; shift ;;
            --follow-symlinks | --follow) FOLLOW_SYMLINKS='true' ;;
            --audit) AUDIT='true' ;;
            --verify-list) need_value "$arg" "${2:-}"; VERIFY_LIST="$OPT_VALUE"; shift ;;
            --skip-existing) SKIP_EXISTING='true' ;;
            --fail-empty) FAIL_EMPTY='true' ;;
            --status) STATUS_ONLY='true' ;;
            --color) need_value "$arg" "${2:-}"; COLOR_MODE="${OPT_VALUE,,}"; shift ;;
            --no-color) COLOR_MODE='never' ;;
            --quiet | -q) QUIET='true' ;;
            -v | --verbose) VERBOSE='true'; QUIET='false' ;;
            -h | --help) usage "$EXIT_OK" ;;
            -V | --version) version_info; exit "$EXIT_OK" ;;
            --version-detail) version_detail; exit "$EXIT_OK" ;;
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
    if ! [[ "$MIN_DEPTH" =~ ^[0-9]+$ ]]; then
        usage_error "--min-depth must be a non-negative integer (got '${MIN_DEPTH}')"
    fi
    if ((MIN_DEPTH > MAX_DEPTH)); then
        usage_error "--min-depth (${MIN_DEPTH}) must not be greater than --depth (${MAX_DEPTH})"
    fi
    case "$MANIFEST_FORMAT" in
        tsv | csv | json) ;;
        *) usage_error "--manifest-format must be one of: tsv, csv, json (got '${MANIFEST_FORMAT}')" ;;
    esac
    if [ -n "$FIELD_LIST" ]; then
        local f known=" ${MANIFEST_ALL_FIELDS} " saved="$IFS"
        IFS=','
        for f in $FIELD_LIST; do
            IFS="$saved"
            f="${f//[[:space:]]/}"
            if [ -n "$f" ]; then
                # A substring test on a space-padded list, so 'path' does not
                # match inside 'config_mode' and 'mode' does not match 'modified'.
                case "$known" in
                    *" ${f} "*) : ;;
                    *) usage_error "--fields: unknown column '${f}' (available: ${MANIFEST_ALL_FIELDS})" ;;
                esac
            fi
            IFS=','
        done
        IFS="$saved"
    fi
    if [ "$PRINT_NUL" = 'true' ] && [ "$OUTPUT_FORMAT" != 'paths' ]; then
        usage_error '--print0 only applies to --format paths'
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

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

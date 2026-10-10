###############################################################################
# Section 12 - secrets: resolution, redaction, hand-off
###############################################################################
#
# The Astra Pro licence is the one secret this tool handles. Three rules, in
# order of importance:
#
#   1. It is never an argument of *this* process. `ps`, `/proc/*/cmdline`, the
#      shell history, the cron log and the process accounting of the host all
#      capture argv; none of them capture stdin or the environment of a child.
#   2. It is never written to a log line, a report, a state file or an error
#      box. redact() runs on every outgoing string and knows the value.
#   3. It never touches the filesystem by default. The hand-off below uses
#      stdin, which is why LICENCE_HANDOFF=file exists only as a documented
#      fallback for the one setup where stdin does not survive the switch.
#
# What cannot be avoided, and is therefore stated plainly: the receiving
# `wp brainstormforce license activate <key>` process does get the value as an
# argument, because that is the interface the plugin offers. The exposure is one
# process, for the duration of one call, owned by the site user. Everything this
# tool controls is closed.

LICENCE_FILE=''
LICENCE_SOURCE=''

# licence_resolve STRICT(true|false)
#
# Sources, in order: the LICENCE variable (filled from --astra-key, from the
# config file or from WP_CLI_UPDATE_LICENCE / ASTRA_KEY / ASTRA_LICENSE_KEY by
# the configuration layers), then the key files. A key file is preferred over a
# value in a config file for the obvious reason: the file can be 0600, and the
# config file tends to become 0644 the day somebody needs to read it.
#
# The configuration layer stores the setting in the variable named after its key
# (LICENCE); the runtime works with LICENCE_VALUE. Bridging the two here -- and
# nowhere else -- is what keeps `LICENCE=` in a config file, the environment
# aliases and --astra-key working through one code path.
licence_resolve() { # [STRICT]
    local strict="${1:-false}" f
    if [ -z "$LICENCE_VALUE" ] && [ -n "${LICENCE:-}" ]; then
        LICENCE_VALUE="$LICENCE"
        LICENCE_SOURCE="${CONF_SRC[LICENCE]:-command line}"
    fi
    if [ -z "$LICENCE_VALUE" ]; then
        for f in "${SCRIPT_DIR}/astra.key" '/etc/wp-cli-update/astra.key' \
                 "${HOME:-/root}/.astra.key" "${HOME:-/root}/.config/astra.key"; do
            if [ -r "$f" ] && [ -f "$f" ]; then
                LICENCE_VALUE="$(head -n 1 -- "$f" 2>/dev/null)"
                # Strip ALL whitespace, which covers the trailing CR of a key
                # file edited on Windows along with the newline and any stray
                # space: a licence key never contains whitespace, so this
                # cannot destroy a real value.
                LICENCE_VALUE="${LICENCE_VALUE//[[:space:]]/}"
                if [ -n "$LICENCE_VALUE" ]; then
                    LICENCE_SOURCE="$f"
                    log_debug "licence read from ${f}"
                    break
                fi
            fi
        done
    fi
    # A placeholder that survived from an example file is not a licence. Acting
    # on one produces a confusing "invalid key" from the plugin; refusing it
    # produces a clear message here.
    case "$LICENCE_VALUE" in
        YOUR* | *HERE* | CHANGE* | 'xxx'* | '***'*)
            log_warn 'the configured Astra licence looks like a placeholder; ignoring it'
            LICENCE_VALUE=''
            ;;
    esac
    if [ -z "$LICENCE_VALUE" ]; then
        LICENCE_SOURCE=''
        if [ "$strict" = 'true' ]; then
            log_error 'mode --astra needs a licence: pass --astra-key, set WP_CLI_UPDATE_LICENCE, put LICENCE= in the config file, or create one of ./astra.key, /etc/wp-cli-update/astra.key, $HOME/.astra.key (chmod 600)'
            return 1
        fi
        return 1
    fi
    redact_register "$LICENCE_VALUE"
    return 0
}

# licence_open : prepare the hand-off. For the stdin mechanism there is nothing
# to prepare; for the file mechanism a temporary file is created and registered
# for cleanup.
licence_open() {
    [ -n "$LICENCE_VALUE" ] || return 0
    if [ "${LICENCE_HANDOFF:-stdin}" = 'stdin' ]; then
        return 0
    fi
    [ -n "$LICENCE_FILE" ] && return 0
    LICENCE_FILE="$(mktemp "${TMPDIR:-/tmp}/${PROG_NAME}.licence.XXXXXX")" || {
        log_error 'cannot create a temporary file for the licence hand-off'
        return 1
    }
    tmp_register "$LICENCE_FILE"
    # Write first, relax the mode second: the value is never present in a file
    # that is already readable by another account.
    if ! printf '%s' "$LICENCE_VALUE" >"$LICENCE_FILE"; then
        log_error "cannot write the licence hand-off file ${LICENCE_FILE}"
        LICENCE_FILE=''
        return 1
    fi
    # The file has to be readable by the site owner, because the command
    # substitution that reads it runs *after* the user switch. 0600 root does not
    # work at all: the child gets "Permission denied" and the licence arrives
    # empty. mktemp already gave it an unpredictable name inside a sticky
    # directory, and it is unlinked as soon as the call returns, so the exposure
    # window is one WP-CLI invocation.
    #
    # Every alternative is worse: `runuser -m` has no equivalent under sudo or
    # su, and putting the value in argv is exactly what this design refuses. If
    # the threat model includes other local users reading /tmp during a run, use
    # the default stdin hand-off, or feed WP_CLI_UPDATE_LICENCE per invocation
    # from a secrets manager instead of keeping a key file on disk.
    if ! chmod 644 "$LICENCE_FILE" 2>/dev/null; then
        log_warn "cannot relax the mode of ${LICENCE_FILE}; the site owner may not be able to read it"
    fi
    log_debug "licence hand-off file prepared (${LICENCE_FILE})"
    return 0
}

licence_close() {
    [ -n "$LICENCE_FILE" ] || return 0
    rm -f -- "$LICENCE_FILE" 2>/dev/null
    LICENCE_FILE=''
    return 0
}

# needs_licence_handoff ARGS... -> 0 when one argument is the licence marker
needs_licence_handoff() {
    local a
    for a in "$@"; do
        [ "$a" = "$LICENCE_MARKER" ] && return 0
    done
    return 1
}

# child_argv VAR PROGRAM [ARGS...]
#
# Normally this emits the argv unchanged, one element per line. When one
# argument equals the licence marker, the whole command is wrapped in
# `/bin/sh -c '<obtain the secret> exec env VAR=... PROGRAM ...' sh`, so the
# value is obtained at run time inside the child and never appears in the
# parent's argv, in a dry-run listing, in the error log or on the console.
#
# Two mechanisms:
#   stdin  (default) the wrapper reads one line from fd 0. Nothing on disk.
#   file             the wrapper cats a temporary path. Kept for setups where a
#                    wrapper between this tool and the site user consumes stdin
#                    (some sudo configurations with `use_pty`, a few PAM modules,
#                    and every shell that decides to read a script from stdin).
child_argv() { # VAR PROGRAM [ARGS...]
    local var="$1"; shift
    local prog="$1"; shift
    local a cmd='' prelude=''
    local -a found=()

    for a in "$prog" "$@"; do
        if [ "$a" = "$LICENCE_MARKER" ]; then
            found+=("$a")
            cmd+="${cmd:+ }\"\$${var}\""
        else
            cmd+="${cmd:+ }$(sh_quote "$a")"
        fi
    done
    if ((${#found[@]} == 0)); then
        printf '%s\n' "$prog" "$@"
        return 0
    fi
    if ((${#found[@]} > 1)); then
        log_error 'internal: the licence marker appears more than once in one command'
        return 1
    fi
    if ! [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        log_error "internal: refusing to build a wrapper for an invalid variable name"
        return 1
    fi

    case "${LICENCE_HANDOFF:-stdin}" in
        file)
            [ -n "$LICENCE_FILE" ] || { log_error 'internal: the licence hand-off file is not open'; return 1; }
            prelude="exec env ${var}=\"\$(cat -- $(sh_quote "$LICENCE_FILE"))\" "
            ;;
        stdin | *)
            # `read` gets an empty value rather than failing the command when
            # stdin is already at EOF, so a mis-wired wrapper produces a clear
            # "licence arrived empty" from the plugin instead of a shell error.
            prelude="IFS= read -r ${var} || ${var}=''; export ${var}; exec env ${var}=\"\$${var}\" "
            ;;
    esac
    printf '%s\n' '/bin/sh' '-c' "${prelude}${cmd}" 'sh'
    return 0
}

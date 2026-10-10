###############################################################################
# Section 7 - fatal error helpers
###############################################################################
#
# Three prefixes, three exit codes. The distinction is not cosmetic: a cron job
# that pages on 1 must not page on 2, and an operator who typo'd a flag should
# see "usage", not "environment".

usage_error() { printf '%s: usage: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_USAGE"; }
config_error() { printf '%s: config: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_CONFIG"; }
env_error() { printf '%s: environment: %s\n' "$PROG_NAME" "$*" >&2; exit "$EXIT_ENV"; }

###############################################################################
# Section 8 - value validation (one implementation, two exit codes)
###############################################################################
#
# The same rule set applies to a value that came from a config file, from the
# environment and from the command line. What differs is the exit code: a bad
# setting in a file is a configuration error (4), a bad flag is a usage error
# (2). validate_value therefore only *reports*; the caller decides how to die.

# validate_value TYPE NAME VALUE -> 0 when acceptable; on failure prints the
# reason on stdout and returns 1.
validate_value() { # TYPE NAME VALUE
    local type="${1-}" name="${2-}" value="${3-}" choices tok vshow vtok
    # Redact once, up front: the value being rejected may itself be the Astra
    # licence (LICENCE is validated like every other key), and an error message
    # that echoes it would put a secret into the terminal scrollback and the cron
    # mail. Doing it here rather than inside each branch also keeps the failure
    # path free of subshells.
    redact "$value"; vshow="$REDACTED"
    case "$type" in
        uint | sec | mib)
            is_uint "$value" || { printf 'must be a non-negative integer (got %s)' "$vshow"; return 1; }
            ;;
        pint)
            if ! is_uint "$value" || ((value < 1)); then
                printf 'must be a positive integer (got %s)' "$vshow"; return 1
            fi
            ;;
        bool)
            case "$value" in
                1 | true | TRUE | True | yes | YES | on | ON | 0 | false | FALSE | False | no | NO | off | OFF | '') ;;
                *) printf 'must be a boolean (got %s)' "$vshow"; return 1 ;;
            esac
            ;;
        choice:*)
            choices="${type#choice:}"
            if ! in_csv_list "$value" "$choices"; then
                printf 'must be one of: %s (got %s)' "${choices//,/ | }" "$vshow"; return 1
            fi
            ;;
        words)
            # Variable NAMES only. Values are read from this process's own
            # environment at run time, so neither a config file nor a command
            # line can inject a value into the environment of `wp`.
            fill_words "$value"
            for tok in ${SPLIT_RESULT[@]+"${SPLIT_RESULT[@]}"}; do
                if [[ ! "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                    redact "$tok"; vtok="$REDACTED"
                    printf 'must be a list of variable names (offending token %s)' "$vtok"
                    return 1
                fi
            done
            ;;
        tokens)
            # Whitespace separated command tokens. Each one becomes a separate
            # argv element and is never interpreted by a shell, but rejecting
            # metacharacters here keeps an operator from believing something
            # clever worked when it did not.
            fill_words "$value"
            for tok in ${SPLIT_RESULT[@]+"${SPLIT_RESULT[@]}"}; do
                if [[ ! "$tok" =~ ^[A-Za-z0-9._:/+-]+$ ]]; then
                    redact "$tok"; vtok="$REDACTED"
                    printf 'must be a list of plain command tokens (offending token %s)' "$vtok"
                    return 1
                fi
            done
            ;;
        csv)
            case "$value" in
                *$'\n'*) printf 'must not contain a newline'; return 1 ;;
            esac
            ;;
        globs)
            case "$value" in
                *$'\n'*) printf 'must not contain a newline'; return 1 ;;
                *"$BACKTICK"*) printf 'must not contain a backtick'; return 1 ;;
                *'$('*) printf 'must not contain a command substitution'; return 1 ;;
            esac
            ;;
        apath)
            if [ -n "$value" ] && [ "${value#/}" = "$value" ]; then
                printf 'must be an absolute path (got %s)' "$vshow"; return 1
            fi
            ;;
        exec)
            if [ -n "$value" ] && [ "${value#/}" = "$value" ]; then
                printf 'must be an absolute path to an executable (got %s)' "$vshow"; return 1
            fi
            ;;
        url)
            if [ -n "$value" ] && [[ ! "$value" =~ ^https?:// ]]; then
                printf 'must be an http(s) URL (got %s)' "$vshow"; return 1
            fi
            ;;
        str | *)
            case "$value" in
                *$'\n'*) printf 'must not contain a newline'; return 1 ;;
            esac
            ;;
    esac
    return 0
}

# normalise_bool VALUE -> sets BOOL_NORM to true|false and prints it.
# Both interfaces, because it is called once per boolean key per validation pass
# and the loop in config_apply can skip the subshell.
BOOL_NORM='false'
normalise_bool() {
    case "${1-}" in
        1 | true | TRUE | True | yes | YES | on | ON) BOOL_NORM='true' ;;
        *) BOOL_NORM='false' ;;
    esac
    printf '%s' "$BOOL_NORM"
}

# Lookup tables built once from CONFIG_SPEC.
#
# config_type_of used to walk the whole spec and re-split every entry, and it is
# called for every key in three separate passes (defaults, file validation,
# effective validation). On an 80-key table that is twenty-odd thousand string
# splits before the first site is touched -- measurable, and pure waste, because
# the answer never changes during a run.
declare -A CONFIG_TYPE=()
declare -A CONFIG_HELP=()
declare -A CONFIG_DEFAULT=()

config_index_build() {
    local entry key
    CONFIG_TYPE=(); CONFIG_HELP=(); CONFIG_DEFAULT=()
    for entry in ${CONFIG_SPEC[@]+"${CONFIG_SPEC[@]}"}; do
        key="${entry%%|*}"
        config_spec_field "$entry" 1 >/dev/null; CONFIG_TYPE["$key"]="$SPEC_FIELD"
        config_spec_field "$entry" 2 >/dev/null; CONFIG_DEFAULT["$key"]="$SPEC_FIELD"
        config_spec_field "$entry" 3 >/dev/null; CONFIG_HELP["$key"]="$SPEC_FIELD"
    done
    return 0
}

# config_type_of KEY -> the TYPE field of the spec entry
config_type_of() { printf '%s' "${CONFIG_TYPE[${1-}]-str}"; }

# config_help_of KEY -> the HELP field of the spec entry
config_help_of() { printf '%s' "${CONFIG_HELP[${1-}]-}"; }

# config_default_of KEY -> the built-in default, with @SCRIPT_DIR@ expanded.
# The index stores the raw spec value; expansion happens here so that changing
# SCRIPT_DIR (which no code path does, but a test might) cannot leave a stale map.
config_default_of() {
    local d="${CONFIG_DEFAULT[${1-}]-}"
    printf '%s' "${d//@SCRIPT_DIR@/$SCRIPT_DIR}"
}

###############################################################################
# Section 9 - configuration layers
###############################################################################
#
# Precedence, lowest to highest:
#   built-in defaults < /etc/wp-cli-update.conf < <script dir>/wp-cli-update.conf
#                     < WP_CLI_UPDATE_<KEY> environment < command line
#
# The command line is parsed *first* (section 17) and records which keys it
# fixed in CLI_SET; config_load then refuses to overwrite those. That order is
# what makes `--print-config` able to show the winning layer for every setting.

CONFIG_GLOBAL='/etc/wp-cli-update.conf'
CONFIG_LOCAL="${SCRIPT_DIR}/wp-cli-update.conf"
declare -A CONF=()
declare -A CONF_SRC=()
declare -A CLI_SET=()
CONFIG_FILE_USED=''
CONFIG_INSECURE_PERMS_WARNED='false'

config_key_is_known() {
    local key="${1-}" k
    for k in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        [ "$k" = "$key" ] && return 0
    done
    return 1
}

config_store() { # KEY VALUE SOURCE
    CONF["$1"]="$2"
    CONF_SRC["$1"]="$3"
    return 0
}

# config_line_is_unsafe LINE -> the reason, or empty when the line is fine.
#
# The file is parsed, never sourced, so these characters could not execute even
# if they were present. Rejecting them anyway is defence in depth with a second
# purpose: it stops an operator from writing `KEY=a; rm -rf /` into a config
# file, believing it will run, and then being surprised when a later revision of
# this tool does source it. A config file that cannot express code never
# becomes one.
config_line_is_unsafe() {
    local line="${1-}"
    # shellcheck disable=SC2016  # these patterns are literal on purpose
    case "$line" in
        *"$BACKTICK"*) printf 'a backtick' ;;
        *'$('*) printf 'a command substitution' ;;
        *'${'*) printf 'a variable expansion' ;;
        *'|'*) printf 'a pipe' ;;
        *';'*) printf 'a semicolon' ;;
        *'>'*) printf 'a redirection' ;;
        *'<'*) printf 'a redirection' ;;
        *'&'*) printf 'a shell operator' ;;
        *) printf '' ;;
    esac
    return 0
}

# config_check_perms FILE : refuse a file another account can write.
#
# The manager runs as root. A group-writable config file is a root shell for
# every member of that group, and the historical version of this check looked at
# the "other" nibble only -- so 0620 and 0660 sailed through. This one tests the
# mask, which catches group-write and world-write in a single comparison.
config_check_perms() { # FILE
    local file="${1-}" mode='' perms='' owner=''
    perms="$(file_mode "$file")"
    if [ -z "$perms" ]; then
        log_debug "cannot stat ${file}; permission check skipped"
        return 0
    fi
    if [[ "$perms" =~ ^[0-7]{3,4}$ ]]; then
        mode=$((8#${perms}))
        if ((mode & 8#022)); then
            config_error "${file}: refusing to read a group- or world-writable config file (mode ${perms}; run: chmod 0600 ${file})"
        fi
    fi
    if [ "$(id -u)" -eq 0 ]; then
        owner="$(stat -c '%u' -- "$file" 2>/dev/null)"
        if [ -n "$owner" ] && [ "$owner" != '0' ]; then
            if [ "$CONFIG_INSECURE_PERMS_WARNED" = 'false' ]; then
                log_warn "${file} is not owned by root while this run is; a local account can replace it (chown root:root ${file})"
                CONFIG_INSECURE_PERMS_WARNED='true'
            fi
        fi
    fi
    return 0
}

# config_parse_file FILE LABEL
config_parse_file() { # FILE LABEL
    local file="${1-}" label="${2-}" line no=0 key value reason type
    [ -f "$file" ] || return 0
    [ -r "$file" ] || config_error "${file}: not readable"
    config_check_perms "$file"
    while IFS= read -r line || [ -n "$line" ]; do
        no=$((no + 1))
        line="${line%$'\r'}"                    # tolerate a CRLF checkout
        case "$line" in '' | '#'*) continue ;; esac
        reason="$(config_line_is_unsafe "$line")"
        if [ -n "$reason" ]; then
            config_error "${file}:${no}: ${reason} in a config line; refusing to read this file (it is parsed as KEY=VALUE data, never as shell)"
        fi
        if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            log_warn "${file}:${no}: not a KEY=VALUE line, ignored"
            continue
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        # Strip one matching pair of quotes; nothing else is interpreted, so a
        # value may contain a literal backslash, a dollar sign or a space.
        if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
            value="${value:1:${#value} - 2}"
        elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
            value="${value:1:${#value} - 2}"
        fi
        value="${value%"${value##*[![:space:]]}"}"     # trailing whitespace only
        if ! config_key_is_known "$key"; then
            # An unknown key is a typo, and a typo in a maintenance tool means a
            # setting the operator believes is active is not. Warn loudly with
            # the nearest known name instead of ignoring it quietly.
            log_warn "${file}:${no}: unknown setting '${key}', ignored$(config_suggest "$key")"
            continue
        fi
        type="${CONFIG_TYPE[$key]-str}"
        if ! reason="$(validate_value "$type" "$key" "$value")"; then
            config_error "${file}:${no}: ${key} ${reason}"
        fi
        config_store "$key" "$value" "$label"
        CONFIG_FILE_USED="$file"
    done <"$file"
    return 0
}

# config_suggest KEY -> "; did you mean X?" using a cheap prefix/substring test.
# A Levenshtein distance in bash costs more than this whole file; a prefix match
# catches the typos that actually happen (SKIP_PLUGIN, JOBS_MAX, LOGFILE).
config_suggest() {
    local needle="${1-}" k best=''
    needle="${needle,,}"
    for k in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        local kl="${k,,}"
        if [ "$kl" = "$needle" ]; then best="$k"; break; fi
        case "$kl" in
            "$needle"*) best="$k"; break ;;
            *"$needle"*) [ -n "$best" ] || best="$k" ;;
        esac
    done
    [ -n "$best" ] && printf '; did you mean %s?' "$best"
    return 0
}

# config_load : files, then environment. The command line already happened.
config_load() {
    local key env_name type reason value
    if [ -n "$CONFIG_REQUESTED" ]; then
        [ -f "$CONFIG_REQUESTED" ] || config_error "${CONFIG_REQUESTED}: no such file"
        config_parse_file "$CONFIG_REQUESTED" "file:$(path_base "$CONFIG_REQUESTED")"
    else
        config_parse_file "$CONFIG_GLOBAL" 'file:/etc'
        config_parse_file "$CONFIG_LOCAL" 'file:local'
    fi
    for key in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        env_name="WP_CLI_UPDATE_${key}"
        [ -z "${CLI_SET[$key]-}" ] || continue
        is_set "$env_name" || continue
        value="$(env_value "$env_name")"
        type="${CONFIG_TYPE[$key]-str}"
        if ! reason="$(validate_value "$type" "$key" "$value")"; then
            env_error "${env_name} ${reason}"
        fi
        config_store "$key" "$value" 'env'
    done
    # The Astra licence has two historical environment names. They are read
    # here, and nowhere else, so that the alias list stays in one place.
    if [ -z "${CLI_SET[LICENCE]-}" ] && [ -z "${CONF[LICENCE]-}" ]; then
        if is_set 'ASTRA_KEY'; then
            config_store 'LICENCE' "$(env_value ASTRA_KEY)" 'env:ASTRA_KEY'
        elif is_set 'ASTRA_LICENSE_KEY'; then
            config_store 'LICENCE' "$(env_value ASTRA_LICENSE_KEY)" 'env:ASTRA_LICENSE_KEY'
        fi
    fi
    return 0
}

# config_apply : merge the file and environment layers into the variables, then
# validate every effective value. CLI_SET entries win and are validated too, so
# a bad `--timeout` fails with 2 and a bad TIMEOUT= in a file fails with 4.
config_apply() {
    local key type reason value
    for key in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        if [ -z "${CLI_SET[$key]-}" ] && [ -n "${CONF_SRC[$key]-}" ]; then
            printf -v "$key" '%s' "${CONF[$key]}"
        fi
    done
    # Booleans are normalised once, here, so the rest of the file can compare
    # against 'true' without repeating four spellings at every use site.
    for key in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        type="${CONFIG_TYPE[$key]-str}"
        value="${!key}"
        if ! reason="$(validate_value "$type" "$key" "$value")"; then
            if [ -n "${CLI_SET[$key]-}" ]; then
                usage_error "--${key,,} ${reason}"
            else
                config_error "${key} ${reason} (from ${CONF_SRC[$key]:-default})"
            fi
        fi
        if [ "$type" = 'bool' ]; then
            normalise_bool "$value" >/dev/null
            printf -v "$key" '%s' "$BOOL_NORM"
        fi
    done
    # Cross-field rules that no single type can express.
    if ((JOBS > 1)) && ((STAGGER > 0)); then
        log_warn '--stagger has no effect with --jobs > 1; batches start together by design'
    fi
    if [ "$BACKUP" = 'full' ] && ((KEEP_BACKUPS > 0)); then
        : # a full tree archive per site is the operator's choice, priced below
    fi
    return 0
}

# effective_source KEY -> which layer decided the value
effective_source() {
    local key="${1-}" src
    if [ -n "${CLI_SET[$key]-}" ]; then
        printf 'command line'
        return 0
    fi
    src="${CONF_SRC[$key]-default}"
    case "$src" in
        env | env:*) printf 'environment (%s)' "${src#env}" ;;
        default) printf 'default' ;;
        *) printf '%s' "$src" ;;
    esac
}

# print_config : the effective value of every setting next to the layer that
# produced it. Printing only the file layer -- the first attempt at this feature
# -- reads like a precedence bug even when the effective value is right, and
# nobody wants that ambiguity on a production host.
print_config() {
    local key value type src
    printf '\n%s%-26s %-40s %-9s %-22s %s%s\n' \
        "$C_BOLD" 'SETTING' 'EFFECTIVE VALUE' 'TYPE' 'FROM' 'CLI' "$C_RESET"
    printf -- '-------------------------------------------------------------------------------------------------------\n'
    for key in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        value="${!key}"
        type="${CONFIG_TYPE[$key]-str}"
        src="$(effective_source "$key")"
        if [ "$key" = 'LICENCE' ]; then
            if [ -n "$value" ]; then
                value="<set, ${#value} characters, redacted>"
            else
                value='<unset>'
            fi
        fi
        [ -n "$value" ] || value='<empty>'
        # A long value would destroy the columns; the full value is in the file.
        if ((${#value} > 40)); then value="${value:0:37}..."; fi
        printf '%-26s %-40s %-9s %-22s %s\n' \
            "$key" "$value" "${type%%:*}" "$src" \
            "$([ -n "${CLI_SET[$key]-}" ] && printf 'yes' || printf '-')"
    done
    printf -- '-------------------------------------------------------------------------------------------------------\n'
    printf 'config file used : %s\n' "${CONFIG_FILE_USED:-<none>}"
    printf 'searched         : %s, %s\n' "$CONFIG_GLOBAL" "$CONFIG_LOCAL"
    printf 'precedence       : defaults < file < environment (WP_CLI_UPDATE_*) < command line\n'
    printf 'mode             : %s\n' "${MODE:-<none>}"
    printf 'dry-run          : %s\n' "$DRY_RUN"
    printf 'lock             : %s\n' "$([ "$NO_LOCK" = 'true' ] && printf 'disabled by --no-lock' || printf '%s' "$LOCK_FILE")"
    printf '\n'
    return 0
}

# init_config [FILE] : emit a complete, commented configuration reference
# generated from CONFIG_SPEC. One table, so the example file, --print-config and
# docs/CONFIGURATION.md cannot disagree with the code.
init_config() { # [FILE]
    local dest entry key type def help
    dest="$(sink_of "${1-}")"
    {
        printf '# Configuration for %s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"
        printf '#\n'
        printf '# Install it as one of:\n'
        printf '#   /etc/wp-cli-update.conf            global, read by every invocation\n'
        printf '#   %s/wp-cli-update.conf   per installation, wins over the global one\n' "$SCRIPT_DIR"
        printf '# ...or point at any file with --config FILE.\n'
        printf '#\n'
        printf '# This file is DATA, not shell. Only plain KEY=VALUE lines are read and it is\n'
        printf '# never sourced. A line containing a backtick, $( , ${ , a pipe, a semicolon,\n'
        printf '# an ampersand or a redirection makes the whole file be rejected with exit\n'
        printf '# code 4. A group- or world-writable file is rejected for the same reason: the\n'
        printf '# manager runs as root, so whoever can write this file can run code as root.\n'
        printf '#\n'
        printf '#   chmod 0600 wp-cli-update.conf\n'
        printf '#\n'
        printf '# Precedence, lowest to highest:\n'
        printf '#   built-in defaults < /etc/wp-cli-update.conf < ./wp-cli-update.conf\n'
        printf '#                     < WP_CLI_UPDATE_<KEY> environment < command line\n'
        printf '#\n'
        printf '# Every setting can also be given as WP_CLI_UPDATE_<KEY> in the environment,\n'
        printf '# and almost every one has a command-line flag. Run with --help for the list,\n'
        printf '# and with --print-config to see what is in effect and which layer won.\n'
        printf '\n'
        for entry in ${CONFIG_SPEC[@]+"${CONFIG_SPEC[@]}"}; do
            key="${entry%%|*}"
            config_spec_field "$entry" 1 >/dev/null; type="$SPEC_FIELD"
            config_spec_field "$entry" 2 >/dev/null; def="$SPEC_FIELD"
            config_spec_field "$entry" 3 >/dev/null; help="$SPEC_FIELD"
            def="${def//@SCRIPT_DIR@/$SCRIPT_DIR}"
            printf '# %s\n' "$help"
            case "$type" in
                choice:*) printf '# values: %s\n' "${type#choice:}" ;;
                bool) printf '# values: 1|0 (also true/false, yes/no, on/off)\n' ;;
                uint | pint | sec | mib) printf '# an integer\n' ;;
                apath) printf '# an absolute path\n' ;;
                url) printf '# an http(s) URL\n' ;;
                csv | globs) printf '# a comma separated list\n' ;;
                words | tokens) printf '# a space separated list\n' ;;
            esac
            [ -n "$def" ] && printf '# default: %s\n' "$def"
            # Secrets and site-specific paths are commented out on purpose: an
            # uncommented line in /etc is a value somebody will forget about.
            case "$key" in
                LICENCE | URL | SITE_USER | INCLUDE_SITES | EXCLUDE_SITES | \
                    SKIP_PLUGINS | EXCLUDE_PLUGINS | NOTIFY_WEBHOOK_URL | \
                    NOTIFY_COMMAND | STATE_FILE | METRICS_FILE | \
                    WP_CLI_TARGET_VERSION | SECURITY_MIN_WP | CACHE_EXTRA | \
                    DISCOVER_ROOTS | USER_ENV)
                    printf '#%s=%s\n\n' "$key" "$def"
                    ;;
                *)
                    printf '%s=%s\n\n' "$key" "$def"
                    ;;
            esac
        done
    } | sink_write "$dest"
    if [ -n "$dest" ]; then
        chmod 600 "$dest" 2>/dev/null
        printf '%s: wrote %s (mode 0600)\n' "$PROG_NAME" "$dest" >&2
    fi
    return 0
}

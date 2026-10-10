###############################################################################
# Section 13 - user switching
###############################################################################
#
# Running WP-CLI as root creates files owned by root inside a site whose owner
# is www-data. The next `wp plugin update` run by that owner then fails on a
# directory it cannot write, and the failure surfaces as "the plugin did not
# update" three weeks later. The switch is therefore the point of this tool, not
# a detail of it.

# The command is handed to the target shell as *positional parameters*, so no
# quoting is needed at all: a site path may contain spaces, quotes, dollars or
# semicolons and still arrives as exactly one argument. This is the single most
# important line in the file -- do not "simplify" it into a command string.
# shellcheck disable=SC2016  # single quotes are the point: this is a snippet
RUNNER_SNIPPET='cd -- "$1" || exit 127; shift; exec "$@"'

# switch_mechanism -> the name of the mechanism that will be used, for --check
# and the banner. Resolved once and cached: probing for runuser on every site of
# a 200-site fleet is 200 pointless forks.
SWITCH_MECHANISM=''
switch_mechanism() {
    if [ -n "$SWITCH_MECHANISM" ]; then
        printf '%s' "$SWITCH_MECHANISM"
        return 0
    fi
    if [ "$NO_USER_SWITCH" = 'true' ]; then
        SWITCH_MECHANISM='disabled (--no-user-switch)'
    elif [ "$(id -u)" -ne 0 ]; then
        SWITCH_MECHANISM="none (running as $(id -un), no privilege to switch)"
    elif have runuser; then
        SWITCH_MECHANISM='runuser'
    elif have sudo; then
        SWITCH_MECHANISM='sudo -n'
    elif have su; then
        SWITCH_MECHANISM='su -s /bin/sh'
    else
        SWITCH_MECHANISM='UNAVAILABLE (no runuser, sudo or su)'
    fi
    printf '%s' "$SWITCH_MECHANISM"
    return 0
}

# user_switch_argv WORKDIR USER PROGRAM [ARGS...]
#
# Fills the global USER_SWITCH_ARGV with the exact argv that performs the switch.
# A global array rather than printed lines, because a site path may legally
# contain a newline and any serialisation would reintroduce the quoting bug this
# design exists to avoid.
#
# `--no-user-switch` runs everything as the invoking user. It exists for two
# reasons: single-site hosts where the operator already IS the site user, and
# test suites. The second reason matters more than it looks -- three independent
# suites in this project's history reported dozens of failures that were purely
# "the fixture is owned by root and there is no account to switch into". A
# switch that can be turned off makes a suite portable instead of
# environment-coupled.
USER_SWITCH_ARGV=()
user_switch_argv() { # WORKDIR USER PROGRAM [ARGS...]
    local workdir="$1" user="$2"
    shift 2
    USER_SWITCH_ARGV=()
    if [ "$NO_USER_SWITCH" = 'true' ] || [ "$user" = "$(id -un)" ]; then
        USER_SWITCH_ARGV=(/bin/sh -c "$RUNNER_SNIPPET" sh "$workdir" "$@")
        return 0
    fi
    if [ "$(id -u)" -eq 0 ] && have runuser; then
        USER_SWITCH_ARGV=(runuser -u "$user" -- /bin/sh -c "$RUNNER_SNIPPET" sh "$workdir" "$@")
        return 0
    fi
    if [ "$(id -u)" -eq 0 ] && have sudo; then
        USER_SWITCH_ARGV=(sudo -n -u "$user" -- /bin/sh -c "$RUNNER_SNIPPET" sh "$workdir" "$@")
        return 0
    fi
    if ! have su; then
        log_error "cannot switch to '${user}': none of runuser, sudo or su is available"
        return 1
    fi
    # su passes everything after the user name to the shell as positional
    # parameters, so even this last fallback needs no escaping.
    USER_SWITCH_ARGV=(su -s /bin/sh -c "$RUNNER_SNIPPET" "$user" sh "$workdir" "$@")
    return 0
}

# run_as_user WORKDIR USER PROGRAM [ARGS...]
run_as_user() {
    user_switch_argv "$@" || return 127
    "${USER_SWITCH_ARGV[@]}"
    return $?
}

###############################################################################
# Section 14 - site owner resolution
###############################################################################

# db_user_from_config FILE -> the DB_USER literal, or nothing.
# `define( 'DB_USER', 'x' );` is read with a bash regex. The value is only ever
# used as a *name* and is validated against the passwd database afterwards, so a
# hostile wp-config.php cannot smuggle shell syntax into a command line.
db_user_from_config() {
    local cfg="${1:-}" line value
    [ -r "$cfg" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ define\([[:space:]]*[\']DB_USER[\'][[:space:]]*,[[:space:]]*[\']([^\']*)\' ]] ||
           [[ "$line" =~ define\([[:space:]]*[\"]DB_USER[\"][[:space:]]*,[[:space:]]*[\"]([^\"]*)[\"] ]]; then
            value="${BASH_REMATCH[1]}"
            if [ -n "$value" ]; then printf '%s' "$value"; return 0; fi
        fi
    done <"$cfg"
    return 1
}

# usable_owner NAME -> 0 when NAME is an existing account with a real shell.
# A nologin account cannot run WP-CLI, and a name that is not in the passwd
# database cannot be switched into; both would fail later with a much less
# helpful message.
usable_owner() {
    local name="${1:-}" shell
    [ -n "$name" ] || return 1
    [ "$name" != 'root' ] || return 1
    is_valid_username "$name" || return 1
    id -u "$name" >/dev/null 2>&1 || return 1
    if have getent; then
        shell="$(getent passwd "$name" 2>/dev/null | cut -d: -f7)"
        case "$shell" in
            '' | */nologin | */false | */sync | */shutdown | */halt) return 1 ;;
        esac
    fi
    return 0
}

# site_user_candidates SITE -> candidate owners, best first.
# Kept as a list so the ordering is testable without a filesystem:
#   1. the owner of wp-config.php, which is the file the site user must be able
#      to write and is therefore the most reliable signal;
#   2. the owner of the site directory;
#   3. DB_USER from wp-config.php, which on a shared host is often also the
#      system account (and on a host with a central database server is not, so
#      it is last and is validated like the others).
# `root` is accepted only as a last resort: containers legitimately run
# everything as root, and refusing to work there is worse than warning.
site_user_candidates() { # SITE
    local site="${1-}" cfg="${1-}/wp-config.php" v
    if [ -f "$cfg" ]; then
        v="$(file_owner "$cfg")"
        [ -n "$v" ] && printf '%s\n' "$v"
    fi
    v="$(file_owner "$site")"
    [ -n "$v" ] && printf '%s\n' "$v"
    if [ -f "$cfg" ]; then
        v="$(db_user_from_config "$cfg")" && [ -n "$v" ] && printf '%s\n' "$v"
    fi
    return 0
}

SITE_USER_WARNINGS=0

# site_user_resolve SITE -> prints the user, non-zero when it cannot be found
site_user_resolve() { # SITE
    local site="${1-}" cand chosen='' root_fallback=''
    if [ "$NO_USER_SWITCH" = 'true' ]; then
        # Nothing is switched, so the only name that matters is the one used in
        # logs and in the child environment: report who will really run wp.
        id -un
        return 0
    fi
    if [ -n "${SITE_USER:-}" ]; then
        printf '%s' "$SITE_USER"
        return 0
    fi
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        if usable_owner "$cand"; then chosen="$cand"; break; fi
        [ "$cand" = 'root' ] && root_fallback='root'
    done < <(site_user_candidates "$site")
    if [ -n "$chosen" ]; then
        printf '%s' "$chosen"
        return 0
    fi
    if [ -n "$root_fallback" ] && [ "$(id -u)" -eq 0 ]; then
        # Warn three times and then stop repeating: on a container host every
        # site is root-owned and 200 identical warnings hide the real ones.
        if ((SITE_USER_WARNINGS < 3)); then
            log_warn "${site}: owned by root and no usable site user found; running wp as root"
            SITE_USER_WARNINGS=$((SITE_USER_WARNINGS + 1))
            ((SITE_USER_WARNINGS == 3)) &&
                log_warn 'further "owned by root" warnings are suppressed for this run'
        fi
        printf 'root'
        return 0
    fi
    return 1
}

# user_home NAME -> the home directory of NAME, empty when unknown
user_home() {
    local name="${1-}" home=''
    [ -n "$name" ] || return 0
    if have getent; then
        home="$(getent passwd "$name" 2>/dev/null | cut -d: -f6)"
    fi
    if [ -z "$home" ] && [ -n "${HOME:-}" ] && [ "$name" = "$(id -un)" ]; then
        home="$HOME"
    fi
    printf '%s' "$home"
}

# site_env_argv SITE USER -> one NAME=VALUE per line, for env(1).
#
# These are emitted as argv elements, never as a shell string, which is why a
# site path containing a quote cannot break anything here. The names are the
# historical contract of this project: a handful of hosting panels and custom
# mu-plugins read DOCUMENT_ROOT and HOMEDIR, and removing them silently broke
# sites, so they stay -- documented as legacy rather than presented as a
# recommendation.
site_env_argv() { # SITE USER
    local site="${1-}" user="${2-}" label parent home v
    label="$(path_base "$site")"
    parent="$(path_dir "$(path_dir "$site")")"
    home="$(user_home "$user")"
    if [ -z "$home" ] || [ ! -d "$home" ]; then home="$parent"; fi
    printf '%s\n' \
        "DOCUMENT_URI=${label}" \
        "DOCUMENT_ROOT=${site}" \
        "HOMEDIR=${parent}" \
        "HTTP_HOST=${label}" \
        "HOME=${home}" \
        "USER=${user}" \
        "LOGNAME=${user}"
    # Operator-selected pass-through, for example a proxy or an API endpoint.
    # Only NAMES are configured; the values are taken from this process's own
    # environment, so a config file cannot invent an environment for `wp`.
    for v in $USER_ENV; do
        if is_set "$v"; then
            printf '%s\n' "${v}=$(env_value "$v")"
        fi
    done
    return 0
}

# allow_root_flag -> '--allow-root' when the policy says to pass it.
# `auto` means: pass it only when this process is root, which is the only
# situation where WP-CLI would otherwise refuse to run.
allow_root_flag() {
    case "${ALLOW_ROOT:-auto}" in
        always) printf -- '--allow-root' ;;
        never) return 0 ;;
        auto | *) [ "$(id -u)" -eq 0 ] && printf -- '--allow-root' ;;
    esac
    return 0
}

# privilege_preflight : decide whether this run may proceed at all.
#
# The historical rule was "root or die", which is right for a multi-tenant host
# and wrong everywhere else: a container that runs everything as www-data, a
# single-site box where the operator IS the site owner, and every CI job. Those
# three are a large share of real deployments, and refusing them pushes people
# into `--no-user-switch`, which is the option that actually loses safety.
#
# The rule now: root may always switch. A non-root caller may run when every
# resolved owner is the caller, and is refused with a precise message when any
# site needs a switch that cannot happen.
privilege_preflight() {
    local i user need_switch=0 first_bad=''
    if [ "$(id -u)" -eq 0 ]; then
        if ! have runuser && ! have sudo && ! have su; then
            log_warn 'running as root but no runuser, sudo or su was found; WP-CLI will run as root'
        fi
        return 0
    fi
    if [ "$NO_USER_SWITCH" = 'true' ]; then
        log_warn "running as $(id -un) with --no-user-switch: WP-CLI runs as $(id -un) and files it creates will be owned by $(id -un)"
        return 0
    fi
    for ((i = 0; i < UNIT_COUNT; i++)); do
        user="${UNIT_USER[i]}"
        if [ "$user" != "$(id -un)" ] && [ "$user" != 'root' ]; then
            need_switch=1
            [ -n "$first_bad" ] || first_bad="${UNIT_PATH[i]} (owner ${user})"
        fi
    done
    if ((need_switch)); then
        log_error "this run needs to switch into a site owner but is not root: ${first_bad}"
        log_error 're-run with sudo, or pass --user NAME, --no-user-switch, or --dry-run / --check'
        exit "$EXIT_ENV"
    fi
    log_debug "running unprivileged as $(id -un); every resolved site owner is the caller"
    return 0
}

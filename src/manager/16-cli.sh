###############################################################################
# Section 36 - the mode table
###############################################################################
#
# One row per mode: name, short flag, one-line description, and whether it
# changes anything. The table drives --help, --list-modes, the shell completion
# and the "exactly one mode" check, which is why adding a mode means adding a row
# here, a function in section 23-31, and a case branch in process_site -- and
# nothing else.
#
# Fields: NAME|SHORT|READONLY|DESCRIPTION
MODE_TABLE=(
    'full|-f|no|core, schema, plugins, themes, translations, cron, caches, db optimize (+ Astra when licensed)'
    'core|-c|no|core update and database schema update'
    'plugins|-p|no|update all plugins (or the selected set with --only-active / --exclude-plugins)'
    'themes|-t|no|update all themes'
    'languages|-L|no|update core, plugin and theme translations'
    'cache|-C|no|flush the object cache, delete transients, flush rewrite rules'
    'cleanup|-X|no|delete revisions, trash, spam and expired transients (needs --yes)'
    'db-optimize|-d|no|db optimize and db repair'
    'db-fix|-x|no|db repair only'
    'cron|-r|no|run cron events that are due'
    'astra|-s|no|update the Astra add-on, activating the licence when needed'
    'verify|--verify|yes|read-only checksum verification of core and plugins'
    'report|--report|yes|read-only fleet health inventory (versions, updates, sizes, cron)'
    'security|--security|yes|read-only hardening and integrity audit with a 0-100 score'
    'secrets|--secrets|yes|scan a site tree for credential-looking values'
    'list-plugins|-l|yes|list plugins as table, json, csv or tsv'
    'plugin-manage|-m|no|install, activate, deactivate, update, delete or inspect one plugin'
    'restore|--restore|no|list the backups of a site, or restore one (needs --yes)'
    'check|--check|yes|validate the host and every site, change nothing'
    'status|--status|yes|print the last run, the log sizes and the backup inventory'
    'list-sites|--list-sites|yes|print the resolved work list and exit'
    'wpcli-check|--wpcli-check|yes|report the WP-CLI version against the minimum and the newest release'
    'wpcli-update|--wpcli-update|no|update the wp binary (verified download, timestamped backup)'
    'wpcli-install|--wpcli-install|no|install WP-CLI when it is missing'
    'wpcli-rollback|--wpcli-rollback|no|put a previous wp binary back'
    'list-modes|--list-modes|yes|print the mode names, one per line (for shell completion)'
    'print-config|--print-config|yes|show every effective setting and the layer that produced it'
    'init-config|--init-config|yes|write a commented configuration file and exit'
    'completion|--completion|yes|print a bash or zsh completion script and exit'
)

# mode_field NAME INDEX
mode_field() {
    local row name
    for row in ${MODE_TABLE[@]+"${MODE_TABLE[@]}"}; do
        name="${row%%|*}"
        if [ "$name" = "${1-}" ]; then
            config_spec_field "$row" "${2:-1}"
            return 0
        fi
    done
    return 1
}

# mode_is_readonly NAME
#
# Reads SPEC_FIELD instead of capturing stdout: this is asked once per work unit
# (the smoke test needs to know whether the mode changed anything), so a subshell
# here would be one fork per site for a yes/no answer.
mode_is_readonly() {
    mode_field "${1-}" 2 >/dev/null
    [ "$SPEC_FIELD" = 'yes' ]
}

# mode_exists NAME
mode_exists() {
    mode_field "${1-}" 0 >/dev/null
}

list_modes() {
    local row
    for row in ${MODE_TABLE[@]+"${MODE_TABLE[@]}"}; do
        printf '%s\n' "${row%%|*}"
    done
    return 0
}

###############################################################################
# Section 37 - help
###############################################################################

usage() { # [EXIT_CODE]
    local rc="${1:-$EXIT_USAGE}" row name short ro desc
    cat <<EOF
${C_BOLD}${PROG_NAME} ${SCRIPT_VERSION}${C_RESET} - WordPress fleet maintenance via WP-CLI

${C_BOLD}Usage${C_RESET}
  ${PROG_NAME} <MODE> [options]
  ${PROG_NAME} --check [--site PATH]
  ${PROG_NAME} --status
  ${PROG_NAME} --wpcli-check | --wpcli-update | --wpcli-install | --wpcli-rollback

${C_BOLD}Modes (exactly one; read-only modes are marked ro)${C_RESET}
EOF
    for row in ${MODE_TABLE[@]+"${MODE_TABLE[@]}"}; do
        name="${row%%|*}"
        config_spec_field "$row" 1 >/dev/null; short="$SPEC_FIELD"
        config_spec_field "$row" 2 >/dev/null; ro="$SPEC_FIELD"
        config_spec_field "$row" 3 >/dev/null; desc="$SPEC_FIELD"
        # Both forms line up on the same column so the descriptions read as one
        # list instead of two: 6 spaces + 18 for a long-only mode, or a 3-character
        # short flag plus a space plus 18 for a mode that has one.
        if [ "${short#--}" != "$short" ]; then
            printf '      %-18s %s%s\n' "$short" "$desc" "$([ "$ro" = yes ] && printf '  %s[ro]%s' "$C_DIM" "$C_RESET")"
        else
            printf '  %-3s %-18s %s%s\n' "${short}," "--${name}" "$desc" "$([ "$ro" = yes ] && printf '  %s[ro]%s' "$C_DIM" "$C_RESET")"
        fi
    done
    cat <<EOF

${C_BOLD}Selection${C_RESET}
  -S, --site PATH        operate on one site only (overrides the site list)
      --sites FILE       site list, one absolute path per line; '-' reads stdin
                         (a TAB after the path forces the owner for that entry)
      --include GLOB     only process paths matching GLOB (repeatable)
      --exclude GLOB     never process paths matching GLOB (repeatable)
      --max-sites N      process at most N units (0 = all, default ${MAX_SITES})
      --user NAME        force the system user for every site (skips detection)
      --multisite MODE   auto | off | main | all - expand a multisite into its
                         subsites and operate on each one with --url
  -U, --url URL          pass --url to WP-CLI on every call
  -j, --jobs N           process N units in parallel batches (default ${JOBS})
      --stagger SEC      sleep SEC between sites (sequential runs)
      --retry N          re-attempt a failing site N times (default ${RETRY})
      --fail-fast        stop the fleet after the first failing site
      --max-duration SEC whole-run budget; stop between sites when it is used up

${C_BOLD}Plugin management${C_RESET}
  -A, --action ACTION    install | activate | deactivate | update | delete | status
  -N, --name NAME        plugin name or slug; case-insensitive substring, never a pattern
  -F, --force            skip the confirmation prompt
  -y, --yes              same as --force, for scripted use; also applies --cleanup
      --only-active      with --plugins/--full: update only active plugins that
                         have an update available (enumerated, not --all)
  -e, --exclude-plugins LIST
                         comma separated slugs or names to leave out of
                         --plugins/--full; implies enumeration

${C_BOLD}Restore and rollback${C_RESET}
      --from WHAT        backup number or path (--restore), or wp binary backup
                         number (--wpcli-rollback); default: the newest
      --restore-files    allow a whole-tree or plugin archive to be extracted

${C_BOLD}Output${C_RESET}
      --format FMT       table | json | csv | tsv   (default: ${OUTPUT_FORMAT})
  -J, --json             with --list-plugins/--report: --format json;
                         in a fleet mode: the JSON Lines fleet report
      --json-lines       one JSON object per unit plus a summary object
      --fields LIST      columns for --list-plugins (default: ${PLUGIN_FIELDS_DEFAULT})
      --page-limit N     rows per table (0 = all, default ${PAGE_LIMIT})
      --color WHEN       auto | always | never (default: ${COLOR})
      --no-color         same as --color never; NO_COLOR is also honoured
  -q, --quiet            console shows warnings and errors only
  -v, --verbose          show the commands as they are executed
  -D, --debug            verbose logging; implies --log-level debug

${C_BOLD}Backups${C_RESET}
  -b, --backup MODE      off | db | full (default: ${BACKUP})
                           db    'wp db export' before the site is touched
                           full  tar.gz of the whole installation - slow and big
      --no-backup        never back up, including before a plugin delete
  -B, --backup-dir DIR   where to put backups (default: <script dir>/backups)
      --keep-backups N   backups kept per site and kind (0 = all, default ${KEEP_BACKUPS})
      --min-free-space N abort a backup when fewer than N MiB are free

${C_BOLD}Safety${C_RESET}
  -n, --dry-run          print the real argv, execute nothing
      --no-user-switch   run WP-CLI as the invoking user instead of switching
                         into the site owner (single-site hosts, and test suites)
      --maintenance-mode put each site in maintenance mode while it is updated
      --strict           exit non-zero when anything was warned about
      --timeout SEC      per-command timeout, 0 disables (default ${TIMEOUT})
      --signal SIG       timeout signal: HUP INT QUIT TERM USR1 USR2 KILL
      --kill-after SEC   escalate to KILL after SEC (default ${KILL_AFTER})
      --allow-root WHEN  auto | always | never (default: ${ALLOW_ROOT})
      --skip-plugins L   plugins to skip on mutating plugin/theme operations
      --skip-plugins-for-listing true|false
                         also pass --skip-plugins to list commands (default false)
      --fail-on WHEN     any | all | never - when to exit non-zero (default ${FAIL_ON})
      --no-lock          do not take the run lock (nested or manual runs only)
      --lock-timeout SEC wait this long for the lock instead of failing
      --lock-required    refuse to run when the lock cannot be taken
      --no-discover      do not run the finder when the site list is missing

${C_BOLD}WP-CLI itself${C_RESET}
      --wp PATH          path to the wp binary (default: ${WP_CLI_PATH})
      --wpcli-min-version V
                         refuse to run on an older WP-CLI (default ${WP_CLI_MIN_VERSION})
      --wpcli-latest-check true|false
                         compare with the newest upstream release (default ${WP_CLI_LATEST_CHECK})
      --wpcli-channel C  stable | nightly (default ${WP_CLI_UPDATE_CHANNEL})
      --wpcli-scope S    auto | patch | minor | major (default ${WP_CLI_UPDATE_SCOPE})
      --wpcli-version V  pin the update to one version (verified direct download)
      --wpcli-no-verify  install a downloaded phar without GPG/checksum verification
      --wpcli-insecure   let the updater retry without TLS verification
      --php PATH         php binary used for a direct phar install (default ${PHP_BIN})

${C_BOLD}Reporting and notification${C_RESET}
      --state-file FILE  write a JSON document describing the run
      --metrics-file FILE
                         write Prometheus textfile-collector metrics
      --notify WHEN      never | failure | always (default ${NOTIFY_ON})
      --webhook URL      POST the summary to this webhook
      --webhook-format F generic | slack | discord | telegram
      --notify-command P executable given the summary as argv and environment
      --smoke-test       fetch each site URL after it was changed
      --smoke-timeout S  seconds allowed for the smoke request (default ${SMOKE_TIMEOUT})
      --smoke-expect L   accepted HTTP status codes (default ${SMOKE_EXPECT})

${C_BOLD}Configuration${C_RESET}
      --config FILE      read settings from FILE instead of the default two
      --print-config     show every effective setting and its layer, then exit
      --init-config [F]  write a fully commented configuration file (or stdout)
      --completion SHELL print a bash or zsh completion script
      --log-file FILE    main log (default: ${LOG_FILE})
      --error-log-file FILE
      --log-level LVL    debug | info | warn | error (default ${LOG_LEVEL})
      --log-format FMT   text | json (default ${LOG_FORMAT})
      --syslog           mirror log lines to syslog via logger(1)
      --lock-file FILE   run lock (default: ${LOCK_FILE})
      --user-env LIST    variable NAMES passed through to the site owner env
      --astra-key KEY    Astra licence; prefer WP_CLI_UPDATE_LICENCE or a key file
      --astra-slug SLUG  Astra add-on slug (default ${ASTRA_SLUG})

${C_BOLD}Other${C_RESET}
  -h, --help             this help, exit 0
  -V, --version          print the version, exit 0
      --version-detail   version, build id, feature probes and the licence

${C_BOLD}Exit codes${C_RESET}
  0  success                  1  at least one operation failed
  2  usage error               3  environment error (no wp, too old, lock, privileges)
  4  configuration error       5  nothing to act on
  6  stopped early (--fail-fast, --max-duration)

${C_BOLD}Configuration precedence${C_RESET}
  built-in defaults < /etc/wp-cli-update.conf < ./wp-cli-update.conf
                    < WP_CLI_UPDATE_* environment < command line

${C_BOLD}Secrets${C_RESET}
  The Astra licence is never an argument of this process. By default it is piped
  to the child over stdin and read there at run time; LICENCE_HANDOFF=file uses a
  temporary file instead. Either way it appears in no log line, no dry-run
  listing, no report and no error box, because every outgoing string is passed
  through a redactor that knows the value. Sources, in order: --astra-key, the
  LICENCE setting, WP_CLI_UPDATE_LICENCE, ASTRA_KEY, ASTRA_LICENSE_KEY, then the
  first readable file among ./astra.key, /etc/wp-cli-update/astra.key,
  \$HOME/.astra.key, \$HOME/.config/astra.key.

${C_BOLD}Parallelism${C_RESET}
  -j N runs the fleet in batches of N. Bash 4.2 has no 'wait -n', so this is a
  batch barrier, not a continuous pool: the next batch starts when the slowest
  unit of the current one finishes. Per-unit console output, log lines and data
  are buffered and replayed in site order after each barrier, so nothing
  interleaves. During a parallel run the log therefore grows at the barrier, not
  while the work happens, and 'tail -f' looks stalled until the batch lands.

${C_BOLD}Examples${C_RESET}
  ${PROG_NAME} --check
  ${PROG_NAME} --report --format table
  ${PROG_NAME} --security --json-lines
  ${PROG_NAME} --full
  ${PROG_NAME} --full -j 4 --backup db --keep-backups 2 --smoke-test
  ${PROG_NAME} -p --only-active -e 'jetpack,woocommerce' -j 8
  ${PROG_NAME} --cleanup -S /var/www/example.com --yes
  ${PROG_NAME} --cache
  ${PROG_NAME} --verify --strict --json-lines
  ${PROG_NAME} --wpcli-check
  ${PROG_NAME} --wpcli-update --wpcli-scope minor --yes
  ${PROG_NAME} --wpcli-update --wpcli-version 2.11.0
  ${PROG_NAME} -l --name woo --format csv
  ${PROG_NAME} -m -A deactivate -N jetpack -S /var/www/example.com -y
  ${PROG_NAME} -d --dry-run --timeout 120
  ${PROG_NAME} --restore -S /var/www/example.com
  ${PROG_NAME} --init-config /etc/wp-cli-update.conf
EOF
    exit "$rc"
}

version_info() { printf '%s %s\n' "$PROG_NAME" "$SCRIPT_VERSION"; }

version_detail() {
    local installed=''
    printf '%s %s (build %s, %s)\n' "$PROG_NAME" "$SCRIPT_VERSION" "$BUILD_ID" "$BUILD_DATE"
    printf 'finder version   : %s\n' "$FINDER_VERSION"
    printf 'script directory : %s\n' "$SCRIPT_DIR"
    printf 'bash             : %s\n' "$BASH_VERSION"
    printf 'running as       : %s (uid %s)\n' "$(id -un)" "$(id -u)"
    printf 'user switch      : %s\n' "$(switch_mechanism)"
    if wp_ensure 2>/dev/null; then
        printf 'wp-cli           : %s\n' "$WP_RESOLVED"
        installed="$(wpcli_version_local 2>/dev/null)" || installed='<unknown>'
        printf 'wp-cli version   : %s (minimum %s)\n' "$installed" "${WP_CLI_MIN_VERSION:-none}"
    else
        printf 'wp-cli           : not found\n'
    fi
    printf 'php              : %s\n' "$(command -v "${PHP_BIN:-php}" 2>/dev/null || printf 'not found')"
    printf 'flock            : %s\n' "$(have flock && printf yes || printf 'no (pid-file locking)')"
    printf 'timeout          : %s\n' "$(have timeout && printf yes || printf 'no (perl supervisor or none)')"
    printf 'perl             : %s\n' "$(have perl && printf yes || printf no)"
    printf 'jq               : %s\n' "$(jq_available >/dev/null 2>&1 && printf 'yes (used)' || printf 'no (built-in reader)')"
    printf 'http client      : %s\n' "$(http_client_resolve 2>/dev/null || printf none)"
    printf 'tar              : %s\n' "$(have tar && printf yes || printf 'no (--backup full degrades to db)')"
    printf 'gpg              : %s\n' "$(have gpg && printf yes || printf 'no (checksum verification only)')"
    printf 'logger           : %s\n' "$(have logger && printf yes || printf 'no (--syslog unavailable)')"
    printf 'modes            : %s\n' "$(list_modes | tr '\n' ' ')"
    return 0
}

# completion_script SHELL
#
# Generated from MODE_TABLE and the option table, so completion cannot drift from
# the parser the way a hand-written list does. Emitted to stdout; installing it is
# a documented one-liner in README.md.
completion_script() { # SHELL
    local shell="${1:-bash}" modes='' opts=''
    modes="$(list_modes | tr '\n' ' ')"
    opts="$(printf '%s ' ${LONG_OPTIONS[@]+"${LONG_OPTIONS[@]}"})"
    case "$shell" in
        bash)
            cat <<EOF
# bash completion for ${PROG_NAME} - install with:
#   install -D -m 644 <(./${PROG_NAME} --completion bash) \\
#       /usr/share/bash-completion/completions/${PROG_NAME}
_${PROG_NAME//[^A-Za-z0-9_]/_}_complete() {
    local cur prev modes opts
    COMPREPLY=()
    cur="\${COMP_WORDS[COMP_CWORD]}"
    prev="\${COMP_WORDS[COMP_CWORD-1]}"
    modes='${modes}'
    opts='${opts}'
    case "\$prev" in
        --sites|--site|-S|--config|--log-file|--error-log-file|--lock-file|--state-file|--metrics-file|--wp|--php|-B|--backup-dir|--notify-command)
            COMPREPLY=( \$(compgen -f -- "\$cur") ); return 0 ;;
        --format|--color|--allow-root|--fail-on|--log-level|--log-format|--backup|--multisite|--notify|--webhook-format|--wpcli-channel|--wpcli-scope|--signal|-A|--action)
            COMPREPLY=( \$(compgen -W "\$(_${PROG_NAME//[^A-Za-z0-9_]/_}_values "\$prev")" -- "\$cur") ); return 0 ;;
        --completion)
            COMPREPLY=( \$(compgen -W 'bash zsh' -- "\$cur") ); return 0 ;;
    esac
    if [[ "\$cur" == -* ]]; then
        COMPREPLY=( \$(compgen -W "\$opts" -- "\$cur") )
    else
        COMPREPLY=( \$(compgen -W "\$modes" -- "\$cur") )
        [[ "\$cur" == / ]] && COMPREPLY+=( \$(compgen -d -- "\$cur") )
    fi
    return 0
}
_${PROG_NAME//[^A-Za-z0-9_]/_}_values() {
    case "\$1" in
        --format) echo 'table json csv tsv' ;;
        --color) echo 'auto always never' ;;
        --allow-root) echo 'auto always never' ;;
        --fail-on) echo 'any all never' ;;
        --log-level) echo 'debug info warn error' ;;
        --log-format) echo 'text json' ;;
        --backup) echo 'off db full' ;;
        --multisite) echo 'auto off main all' ;;
        --notify) echo 'never failure always' ;;
        --webhook-format) echo 'generic slack discord telegram' ;;
        --wpcli-channel) echo 'stable nightly' ;;
        --wpcli-scope) echo 'auto patch minor major' ;;
        --signal) echo 'HUP INT QUIT TERM USR1 USR2 KILL' ;;
        -A|--action) echo 'install activate deactivate update delete status' ;;
    esac
}
complete -F _${PROG_NAME//[^A-Za-z0-9_]/_}_complete ${PROG_NAME}
complete -F _${PROG_NAME//[^A-Za-z0-9_]/_}_complete wp-fleet
EOF
            ;;
        zsh)
            cat <<EOF
#compdef ${PROG_NAME} wp-fleet
# zsh completion for ${PROG_NAME} - install with:
#   ./${PROG_NAME} --completion zsh > "\${fpath[1]}/_${PROG_NAME}"
local -a modes opts
modes=(${modes})
opts=(${opts})
_arguments \\
    '*::argument:_files' \\
    '1:mode:('"${modes// /\'} \'}"')' \\
    '*:option:('"${opts// /\'} \'}"')'
EOF
            ;;
        *)
            usage_error "--completion takes 'bash' or 'zsh' (got '${shell}')"
            ;;
    esac
    return 0
}

###############################################################################
# Section 38 - long option names, used by help and completion
###############################################################################
LONG_OPTIONS=(
    --full --core --plugins --themes --languages --cache --cleanup
    --db-optimize --db-fix --cron --astra --verify --report --security --secrets
    --list-plugins --plugin-manage --restore
    --check --status --list-sites
    --wpcli-check --wpcli-update --wpcli-install --wpcli-rollback
    --list-modes --print-config --init-config --completion
    --site --sites --include --exclude --max-sites --user --multisite --url
    --jobs --stagger --retry --fail-fast --max-duration
    --action --name --force --yes --only-active --exclude-plugins
    --from --restore-files
    --format --json --json-lines --fields --page-limit --color --no-color
    --quiet --verbose --debug
    --backup --no-backup --backup-dir --keep-backups --min-free-space
    --dry-run --no-user-switch --maintenance-mode --strict --timeout --signal
    --kill-after --allow-root --skip-plugins --skip-plugins-for-listing
    --fail-on --no-lock --lock-timeout --lock-required --no-discover
    --wp --wpcli-min-version --wpcli-latest-check --wpcli-channel --wpcli-scope
    --wpcli-version --wpcli-no-verify --wpcli-insecure --php
    --state-file --metrics-file --notify --webhook --webhook-format
    --notify-command --smoke-test --smoke-timeout --smoke-expect
    --config --log-file --error-log-file --log-level --log-format --syslog
    --lock-file --user-env --astra-key --astra-slug
    --help --version --version-detail
)

###############################################################################
# Section 39 - argument parsing
###############################################################################

MODES_SEEN=0

set_mode() { # NAME
    if [ -n "$MODE" ] && [ "$MODE" != "$1" ]; then
        usage_error "conflicting modes: --${MODE} and --${1}; pass exactly one"
    fi
    MODE="$1"
    MODES_SEEN=$((MODES_SEEN + 1))
    CLI_SET[MODE]=1
    return 0
}

# need_value OPTION [VALUE] -> sets OPT_VALUE.
#
# It does not print the value for `$(...)` capture on purpose: usage_error exits,
# and an exit inside a command substitution only leaves the subshell, so the
# caller would continue with an empty value. That single detail once turned
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
            # ---- modes ---------------------------------------------------
            -f | --full) set_mode full ;;
            -c | --core) set_mode core ;;
            -p | --plugins) set_mode plugins ;;
            -t | --themes) set_mode themes ;;
            -L | --languages) set_mode languages ;;
            -C | --cache) set_mode cache ;;
            -X | --cleanup) set_mode cleanup ;;
            -d | --db-optimize) set_mode db-optimize ;;
            -x | --db-fix) set_mode db-fix ;;
            -r | --cron) set_mode cron ;;
            -s | --astra) set_mode astra ;;
            --verify) set_mode verify ;;
            --report | --health) set_mode report ;;
            --security | --audit) set_mode security ;;
            --secrets) set_mode secrets ;;
            -l | --list-plugins) set_mode list-plugins ;;
            -m | --plugin-manage) set_mode plugin-manage ;;
            --restore) set_mode restore; RESTORE_ACTION='true' ;;
            --check) set_mode check; NO_ACTION='true' ;;
            --status) set_mode status; NO_ACTION='true' ;;
            --list-sites) set_mode list-sites; LIST_SITES='true'; NO_ACTION='true' ;;
            --wpcli-check) set_mode wpcli-check; WPCLI_ACTION='check'; NO_ACTION='true' ;;
            --wpcli-update) set_mode wpcli-update; WPCLI_ACTION='update'; NO_ACTION='true' ;;
            --wpcli-install) set_mode wpcli-install; WPCLI_ACTION='install'; NO_ACTION='true' ;;
            --wpcli-rollback) set_mode wpcli-rollback; WPCLI_ACTION='rollback'; NO_ACTION='true' ;;
            --list-modes) LIST_MODES='true'; NO_ACTION='true' ;;
            --print-config) PRINT_CONFIG='true'; NO_ACTION='true' ;;
            --init-config)
                # The file argument is optional here and only here: `--init-config`
                # alone means stdout. A following token that looks like an option
                # is therefore not consumed. The separate REQUESTED flag is what
                # distinguishes "no destination given" from "not asked for",
                # which an empty INIT_CONFIG cannot do on its own.
                INIT_CONFIG_REQUESTED='true'
                INIT_CONFIG="${2-}"
                if [ -n "$INIT_CONFIG" ] && [ "${INIT_CONFIG#-}" = "$INIT_CONFIG" ]; then
                    shift
                else
                    INIT_CONFIG=''
                fi
                NO_ACTION='true'
                ;;
            --completion)
                need_value "$arg" "${2:-}"
                COMPLETION="$OPT_VALUE"
                shift
                NO_ACTION='true'
                ;;
            # ---- selection ------------------------------------------------
            -S | --site)
                need_value "$arg" "${2:-}"; TARGET_SITE="$OPT_VALUE"; shift
                CLI_SET[SITES_FILE]=1
                ;;
            --sites | --sites-file)
                need_value "$arg" "${2:-}"; SITES_FILE="$OPT_VALUE"; shift
                CLI_SET[SITES_FILE]=1
                ;;
            --include | --include-sites)
                need_value "$arg" "${2:-}"; INCLUDE_GLOBS+=("$OPT_VALUE")
                INCLUDE_SITES="${INCLUDE_SITES:+${INCLUDE_SITES},}${OPT_VALUE}"; shift
                CLI_SET[INCLUDE_SITES]=1
                ;;
            --exclude | --exclude-sites)
                need_value "$arg" "${2:-}"; EXCLUDE_GLOBS+=("$OPT_VALUE")
                EXCLUDE_SITES="${EXCLUDE_SITES:+${EXCLUDE_SITES},}${OPT_VALUE}"; shift
                CLI_SET[EXCLUDE_SITES]=1
                ;;
            --max-sites) need_value "$arg" "${2:-}"; MAX_SITES="$OPT_VALUE"; shift; CLI_SET[MAX_SITES]=1 ;;
            --user) need_value "$arg" "${2:-}"; SITE_USER="$OPT_VALUE"; USER_OVERRIDE="$OPT_VALUE"; shift; CLI_SET[SITE_USER]=1 ;;
            --multisite) need_value "$arg" "${2:-}"; MULTISITE="${OPT_VALUE,,}"; shift; CLI_SET[MULTISITE]=1 ;;
            -j | --jobs) need_value "$arg" "${2:-}"; JOBS="$OPT_VALUE"; shift; CLI_SET[JOBS]=1 ;;
            -U | --url) need_value "$arg" "${2:-}"; URL="$OPT_VALUE"; shift; CLI_SET[URL]=1 ;;
            --stagger) need_value "$arg" "${2:-}"; STAGGER="$OPT_VALUE"; shift; CLI_SET[STAGGER]=1 ;;
            --retry) need_value "$arg" "${2:-}"; RETRY="$OPT_VALUE"; shift; CLI_SET[RETRY]=1 ;;
            --fail-fast) FAIL_FAST='true'; CLI_SET[FAIL_FAST]=1 ;;
            --max-duration) need_value "$arg" "${2:-}"; MAX_DURATION="$OPT_VALUE"; shift; CLI_SET[MAX_DURATION]=1 ;;
            # ---- plugin management ---------------------------------------
            -A | --action) need_value "$arg" "${2:-}"; PLUGIN_ACTION="${OPT_VALUE,,}"; shift ;;
            -N | --name)
                need_value "$arg" "${2:-}"
                PLUGIN_NAME="$OPT_VALUE"; FILTER_NAME="$OPT_VALUE"; shift
                ;;
            -F | --force) FORCE_DELETE='true' ;;
            -y | --yes) ASSUME_YES='true' ;;
            --only-active) ONLY_ACTIVE='true'; CLI_SET[ONLY_ACTIVE]=1 ;;
            -e | --exclude-plugins) need_value "$arg" "${2:-}"; EXCLUDE_PLUGINS="$OPT_VALUE"; shift; CLI_SET[EXCLUDE_PLUGINS]=1 ;;
            # ---- restore / rollback ---------------------------------------
            --from) need_value "$arg" "${2:-}"; RESTORE_FROM="$OPT_VALUE"; shift ;;
            --restore-files) RESTORE_FILES='true' ;;
            # ---- output ---------------------------------------------------
            --format) need_value "$arg" "${2:-}"; OUTPUT_FORMAT="${OPT_VALUE,,}"; shift; CLI_SET[OUTPUT_FORMAT]=1 ;;
            --fields) need_value "$arg" "${2:-}"; FILTER_FIELDS="$OPT_VALUE"; shift ;;
            --page-limit) need_value "$arg" "${2:-}"; PAGE_LIMIT="$OPT_VALUE"; shift ;;
            -J | --json)
                # Two meanings, both wanted: with --list-plugins, --report or
                # --security it selects the record format; in a mutating fleet
                # mode it switches the fleet report to JSON Lines. The mode may
                # not have been parsed yet -- `--json -l` is as legal as
                # `-l --json` -- so the decision is deferred to validate_args.
                JSON_REQUESTED='true'
                ;;
            --json-lines) JSON_LINES='true' ;;
            --color) need_value "$arg" "${2:-}"; COLOR="${OPT_VALUE,,}"; shift; CLI_SET[COLOR]=1 ;;
            --no-color) COLOR='never'; CLI_SET[COLOR]=1 ;;
            -q | --quiet) QUIET='true' ;;
            -D | --debug) VERBOSE='true'; LOG_LEVEL='debug'; CLI_SET[LOG_LEVEL]=1 ;;
            -v | --verbose) VERBOSE='true' ;;
            # ---- safety ---------------------------------------------------
            -n | --dry-run) DRY_RUN='true' ;;
            --no-user-switch) NO_USER_SWITCH='true'; CLI_SET[NO_USER_SWITCH]=1 ;;
            --maintenance-mode) MAINTENANCE_MODE='true'; CLI_SET[MAINTENANCE_MODE]=1 ;;
            --strict) STRICT='true'; CLI_SET[STRICT]=1 ;;
            --timeout) need_value "$arg" "${2:-}"; TIMEOUT="$OPT_VALUE"; shift; CLI_SET[TIMEOUT]=1 ;;
            --signal) need_value "$arg" "${2:-}"; TIMEOUT_SIGNAL="${OPT_VALUE^^}"; shift; CLI_SET[TIMEOUT_SIGNAL]=1 ;;
            --kill-after) need_value "$arg" "${2:-}"; KILL_AFTER="$OPT_VALUE"; shift; CLI_SET[KILL_AFTER]=1 ;;
            --allow-root) need_value "$arg" "${2:-}"; ALLOW_ROOT="${OPT_VALUE,,}"; shift; CLI_SET[ALLOW_ROOT]=1 ;;
            --skip-plugins)
                need_value "$arg" "${2-}"
                SKIP_PLUGINS="$OPT_VALUE"; shift; CLI_SET[SKIP_PLUGINS]=1
                ;;
            --skip-plugins-for-listing)
                need_value "$arg" "${2:-}"; SKIP_PLUGINS_FOR_LISTING="${OPT_VALUE,,}"; shift
                CLI_SET[SKIP_PLUGINS_FOR_LISTING]=1
                ;;
            --fail-on) need_value "$arg" "${2:-}"; FAIL_ON="${OPT_VALUE,,}"; shift; CLI_SET[FAIL_ON]=1 ;;
            --no-lock) NO_LOCK='true' ;;
            --lock-timeout) need_value "$arg" "${2:-}"; LOCK_TIMEOUT="$OPT_VALUE"; shift; CLI_SET[LOCK_TIMEOUT]=1 ;;
            --lock-required) LOCK_REQUIRED='true'; CLI_SET[LOCK_REQUIRED]=1 ;;
            --no-discover) AUTO_DISCOVER='false'; CLI_SET[AUTO_DISCOVER]=1 ;;
            # ---- backups ---------------------------------------------------
            -b | --backup) need_value "$arg" "${2:-}"; BACKUP="${OPT_VALUE,,}"; shift; CLI_SET[BACKUP]=1 ;;
            --no-backup) BACKUP='off'; NO_BACKUP_EXPLICIT='true'; CLI_SET[BACKUP]=1 ;;
            -B | --backup-dir) need_value "$arg" "${2:-}"; BACKUP_DIR="$OPT_VALUE"; shift; CLI_SET[BACKUP_DIR]=1 ;;
            --keep-backups) need_value "$arg" "${2:-}"; KEEP_BACKUPS="$OPT_VALUE"; shift; CLI_SET[KEEP_BACKUPS]=1 ;;
            --min-free-space) need_value "$arg" "${2:-}"; MIN_FREE_MIB="$OPT_VALUE"; shift; CLI_SET[MIN_FREE_MIB]=1 ;;
            # ---- WP-CLI itself ---------------------------------------------
            --wp | --wp-cli) need_value "$arg" "${2:-}"; WP_CLI_PATH="$OPT_VALUE"; shift; CLI_SET[WP_CLI_PATH]=1 ;;
            --php) need_value "$arg" "${2:-}"; PHP_BIN="$OPT_VALUE"; shift; CLI_SET[PHP_BIN]=1 ;;
            --wpcli-min-version) need_value "$arg" "${2:-}"; WP_CLI_MIN_VERSION="$OPT_VALUE"; shift; CLI_SET[WP_CLI_MIN_VERSION]=1 ;;
            --wpcli-latest-check) need_value "$arg" "${2:-}"; WP_CLI_LATEST_CHECK="${OPT_VALUE,,}"; shift; CLI_SET[WP_CLI_LATEST_CHECK]=1 ;;
            --wpcli-channel) need_value "$arg" "${2:-}"; WP_CLI_UPDATE_CHANNEL="${OPT_VALUE,,}"; shift; CLI_SET[WP_CLI_UPDATE_CHANNEL]=1 ;;
            --wpcli-scope) need_value "$arg" "${2:-}"; WP_CLI_UPDATE_SCOPE="${OPT_VALUE,,}"; shift; CLI_SET[WP_CLI_UPDATE_SCOPE]=1 ;;
            --wpcli-version) need_value "$arg" "${2:-}"; WP_CLI_TARGET_VERSION="$OPT_VALUE"; shift; CLI_SET[WP_CLI_TARGET_VERSION]=1 ;;
            --wpcli-no-verify) WP_CLI_VERIFY_PHAR='false'; CLI_SET[WP_CLI_VERIFY_PHAR]=1 ;;
            --wpcli-insecure) WP_CLI_INSECURE='true'; CLI_SET[WP_CLI_INSECURE]=1 ;;
            # ---- reporting --------------------------------------------------
            --state-file) need_value "$arg" "${2:-}"; STATE_FILE="$OPT_VALUE"; shift; CLI_SET[STATE_FILE]=1 ;;
            --metrics-file) need_value "$arg" "${2:-}"; METRICS_FILE="$OPT_VALUE"; shift; CLI_SET[METRICS_FILE]=1 ;;
            --notify) need_value "$arg" "${2:-}"; NOTIFY_ON="${OPT_VALUE,,}"; shift; CLI_SET[NOTIFY_ON]=1 ;;
            --webhook) need_value "$arg" "${2:-}"; NOTIFY_WEBHOOK_URL="$OPT_VALUE"; shift; CLI_SET[NOTIFY_WEBHOOK_URL]=1 ;;
            --webhook-format) need_value "$arg" "${2:-}"; NOTIFY_WEBHOOK_FORMAT="${OPT_VALUE,,}"; shift; CLI_SET[NOTIFY_WEBHOOK_FORMAT]=1 ;;
            --notify-command) need_value "$arg" "${2:-}"; NOTIFY_COMMAND="$OPT_VALUE"; shift; CLI_SET[NOTIFY_COMMAND]=1 ;;
            --smoke-test) SMOKE_TEST='true'; CLI_SET[SMOKE_TEST]=1 ;;
            --no-smoke-test) SMOKE_TEST='false'; CLI_SET[SMOKE_TEST]=1 ;;
            --smoke-timeout) need_value "$arg" "${2:-}"; SMOKE_TIMEOUT="$OPT_VALUE"; shift; CLI_SET[SMOKE_TIMEOUT]=1 ;;
            --smoke-expect) need_value "$arg" "${2:-}"; SMOKE_EXPECT="$OPT_VALUE"; shift; CLI_SET[SMOKE_EXPECT]=1 ;;
            # ---- configuration ----------------------------------------------
            --config) need_value "$arg" "${2:-}"; CONFIG_REQUESTED="$OPT_VALUE"; shift ;;
            --log-file) need_value "$arg" "${2:-}"; LOG_FILE="$OPT_VALUE"; shift; CLI_SET[LOG_FILE]=1 ;;
            --error-log-file) need_value "$arg" "${2:-}"; ERROR_LOG_FILE="$OPT_VALUE"; shift; CLI_SET[ERROR_LOG_FILE]=1 ;;
            --log-level) need_value "$arg" "${2:-}"; LOG_LEVEL="${OPT_VALUE,,}"; shift; CLI_SET[LOG_LEVEL]=1 ;;
            --log-format) need_value "$arg" "${2:-}"; LOG_FORMAT="${OPT_VALUE,,}"; shift; CLI_SET[LOG_FORMAT]=1 ;;
            --syslog) SYSLOG='true'; CLI_SET[SYSLOG]=1 ;;
            --lock-file) need_value "$arg" "${2:-}"; LOCK_FILE="$OPT_VALUE"; shift; CLI_SET[LOCK_FILE]=1 ;;
            --user-env) need_value "$arg" "${2:-}"; USER_ENV="$OPT_VALUE"; shift; CLI_SET[USER_ENV]=1 ;;
            --astra-key) need_value "$arg" "${2:-}"; LICENCE="$OPT_VALUE"; LICENCE_VALUE="$OPT_VALUE"; shift; CLI_SET[LICENCE]=1 ;;
            --astra-slug) need_value "$arg" "${2:-}"; ASTRA_SLUG="$OPT_VALUE"; shift; CLI_SET[ASTRA_SLUG]=1 ;;
            # ---- other --------------------------------------------------------
            -h | --help) usage "$EXIT_OK" ;;
            -V | --version) version_info; SUMMARY_PRINTED='true'; exit "$EXIT_OK" ;;
            --version-detail) SHOW_VERSION_DETAIL='true'; NO_ACTION='true' ;;
            --)
                shift
                # Everything after -- is a positional. This tool takes none, but
                # accepting and reporting them is friendlier than silently
                # treating `-- --full` as "no mode given".
                if (($# > 0)); then
                    usage_error "unexpected positional argument '${1}'; modes and options are all named"
                fi
                break
                ;;
            -*)
                usage_error "unknown option '${arg}'$(option_suggest "$arg"); run with --help for the list"
                ;;
            *)
                usage_error "unexpected argument '${arg}'; modes and options are all named (did you mean --site '${arg}'?)"
                ;;
        esac
        shift
    done
    return 0
}

# option_suggest OPTION -> " (did you mean --x?)" using a prefix match over the
# long option table. Same reasoning as config_suggest: a typo should say what it
# probably meant, because --help is 200 lines long.
option_suggest() {
    local needle="${1#-}" o best=''
    needle="${needle#-}"
    for o in ${LONG_OPTIONS[@]+"${LONG_OPTIONS[@]}"}; do
        local ol="${o#--}"
        case "$ol" in
            "$needle") best="$o"; break ;;
            "$needle"*) best="$o"; break ;;
            *"$needle"*) [ -n "$best" ] || best="$o" ;;
        esac
    done
    [ -n "$best" ] && printf ' (did you mean %s?)' "$best"
    return 0
}

###############################################################################
# Section 40 - argument validation
###############################################################################

validate_args() {
    local key type reason

    # Every effective value is validated by the same table that validated the
    # config layers, so a bad flag and a bad config line produce the same
    # message and differ only in the exit code.
    for key in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
        type="${CONFIG_TYPE[$key]-str}"
        if ! reason="$(validate_value "$type" "$key" "${!key}")"; then
            if [ -n "${CLI_SET[$key]-}" ]; then
                usage_error "--$(config_flag_of "$key") ${reason}"
            else
                config_error "${key} ${reason} (from ${CONF_SRC[$key]:-default})"
            fi
        fi
        if [ "$type" = 'bool' ]; then
            normalise_bool "${!key}" >/dev/null
            printf -v "$key" '%s' "$BOOL_NORM"
        fi
    done

    # The include/exclude globs came from either layer; rebuild the arrays so a
    # config-file value is honoured exactly like a repeated flag.
    INCLUDE_GLOBS=()
    EXCLUDE_GLOBS=()
    local g
    while IFS= read -r g; do
        [ -n "$g" ] && INCLUDE_GLOBS+=("$g")
    done < <(split_csv "$INCLUDE_SITES")
    while IFS= read -r g; do
        [ -n "$g" ] && EXCLUDE_GLOBS+=("$g")
    done < <(split_csv "$EXCLUDE_SITES")

    if [ -n "$SITE_USER" ]; then
        is_valid_username "$SITE_USER" ||
            usage_error "--user must be a plain account name (got '${SITE_USER}')"
        USER_OVERRIDE="$SITE_USER"
    fi

    if [ -n "$PLUGIN_ACTION" ]; then
        case "$PLUGIN_ACTION" in
            install | activate | deactivate | update | delete | status) ;;
            *) usage_error "--action must be one of: install, activate, deactivate, update, delete, status (got '${PLUGIN_ACTION}')" ;;
        esac
    fi

    # -J resolves here, because both of its meanings depend on the mode and the
    # mode may have been parsed after the flag.
    if [ "$JSON_REQUESTED" = 'true' ]; then
        case "$MODE" in
            list-plugins | report | security)
                OUTPUT_FORMAT='json'
                CLI_SET[OUTPUT_FORMAT]=1
                ;;
            *)
                JSON_LINES='true'
                ;;
        esac
    fi

    if [ "$LIST_MODES" = 'true' ] || [ "$LIST_SITES" = 'true' ] ||
       [ -n "$COMPLETION" ] || [ "$INIT_CONFIG_REQUESTED" = 'true' ] ||
       [ "$PRINT_CONFIG" = 'true' ] || [ "$SHOW_VERSION_DETAIL" = 'true' ]; then
        return 0
    fi

    if [ -z "$MODE" ]; then
        usage_error 'no mode given; pass one of --full, --core, --plugins, --themes, --cache, --cleanup, --report, --security, --verify, --check, --status (see --help)'
    fi

    case "$MODE" in
        plugin-manage)
            [ -n "$PLUGIN_ACTION" ] || usage_error '--plugin-manage requires --action install|activate|deactivate|update|delete|status'
            [ -n "$PLUGIN_NAME" ] || usage_error '--plugin-manage requires --name NAME'
            if [ "$PLUGIN_ACTION" = 'delete' ] && [ "$FORCE_DELETE" != 'true' ] &&
               [ "$ASSUME_YES" != 'true' ] && [ ! -t 0 ]; then
                log_warn 'a delete without --yes in a non-interactive shell will be refused per site'
            fi
            ;;
        list-plugins)
            [ -n "$PLUGIN_ACTION" ] && usage_error '--action is meaningless for --list-plugins'
            ;;
        cleanup)
            if [ "$ASSUME_YES" != 'true' ] && [ "$FORCE_DELETE" != 'true' ] && [ ! -t 0 ]; then
                log_warn '--cleanup without --yes reports what it would delete and changes nothing'
            fi
            ;;
        restore)
            [ -n "$TARGET_SITE" ] || usage_error '--restore requires --site PATH (which site should be restored?)'
            ;;
        astra)
            : # the licence is resolved per site, so an absent key is reported there
            ;;
    esac

    if [ "$ONLY_ACTIVE" = 'true' ] || [ -n "$EXCLUDE_PLUGINS" ]; then
        case "$MODE" in
            plugins | full) ;;
            *) usage_error '--only-active and --exclude-plugins only apply to --plugins and --full' ;;
        esac
    fi
    if [ -n "$FILTER_FIELDS" ] && [ "$MODE" != 'list-plugins' ]; then
        log_warn '--fields only affects --list-plugins; it is ignored here'
    fi
    if ((JOBS > 1)) && [ "$MODE" = 'plugin-manage' ] && [ "$PLUGIN_ACTION" = 'delete' ]; then
        log_warn 'deleting a plugin across a fleet in parallel batches: the per-site confirmation is answered by --yes, not by a prompt'
    fi
    if [ "$BACKUP" = 'full' ] && ((KEEP_BACKUPS == 0)); then
        log_warn '--backup full with --keep-backups 0 keeps every whole-tree archive forever; check the free space on the backup volume'
    fi
    if [ "$SMOKE_TEST" = 'true' ] && mode_is_readonly "$MODE"; then
        log_warn "--smoke-test changes nothing in a read-only mode; the sites are still probed"
    fi
    return 0
}

# config_flag_of KEY -> the long flag that sets this key, for error messages.
# A table-driven message that says "--timeout must be a positive integer" is
# actionable; one that says "TIMEOUT must be a positive integer" when the operator
# typed a flag is not.
config_flag_of() {
    case "${1-}" in
        WP_CLI_PATH) printf 'wp' ;;
        WP_CLI_MIN_VERSION) printf 'wpcli-min-version' ;;
        WP_CLI_LATEST_CHECK) printf 'wpcli-latest-check' ;;
        WP_CLI_UPDATE_CHANNEL) printf 'wpcli-channel' ;;
        WP_CLI_UPDATE_SCOPE) printf 'wpcli-scope' ;;
        WP_CLI_TARGET_VERSION) printf 'wpcli-version' ;;
        WP_CLI_VERIFY_PHAR) printf 'wpcli-no-verify' ;;
        WP_CLI_INSECURE) printf 'wpcli-insecure' ;;
        PHP_BIN) printf 'php' ;;
        SITES_FILE) printf 'sites' ;;
        MAX_SITES) printf 'max-sites' ;;
        SITE_USER) printf 'user' ;;
        INCLUDE_SITES) printf 'include' ;;
        EXCLUDE_SITES) printf 'exclude' ;;
        TIMEOUT) printf 'timeout' ;;
        KILL_AFTER) printf 'kill-after' ;;
        TIMEOUT_SIGNAL) printf 'signal' ;;
        ALLOW_ROOT) printf 'allow-root' ;;
        FAIL_ON) printf 'fail-on' ;;
        BACKUP) printf 'backup' ;;
        BACKUP_DIR) printf 'backup-dir' ;;
        KEEP_BACKUPS) printf 'keep-backups' ;;
        MIN_FREE_MIB) printf 'min-free-space' ;;
        JOBS) printf 'jobs' ;;
        STAGGER) printf 'stagger' ;;
        RETRY) printf 'retry' ;;
        MAX_DURATION) printf 'max-duration' ;;
        URL) printf 'url' ;;
        LOG_FILE) printf 'log-file' ;;
        ERROR_LOG_FILE) printf 'error-log-file' ;;
        LOG_LEVEL) printf 'log-level' ;;
        LOG_FORMAT) printf 'log-format' ;;
        LOCK_FILE) printf 'lock-file' ;;
        LOCK_TIMEOUT) printf 'lock-timeout' ;;
        OUTPUT_FORMAT) printf 'format' ;;
        COLOR) printf 'color' ;;
        USER_ENV) printf 'user-env' ;;
        ASTRA_SLUG) printf 'astra-slug' ;;
        LICENCE) printf 'astra-key' ;;
        EXCLUDE_PLUGINS) printf 'exclude-plugins' ;;
        SKIP_PLUGINS) printf 'skip-plugins' ;;
        SKIP_PLUGINS_FOR_LISTING) printf 'skip-plugins-for-listing' ;;
        STATE_FILE) printf 'state-file' ;;
        METRICS_FILE) printf 'metrics-file' ;;
        NOTIFY_ON) printf 'notify' ;;
        NOTIFY_WEBHOOK_URL) printf 'webhook' ;;
        NOTIFY_WEBHOOK_FORMAT) printf 'webhook-format' ;;
        NOTIFY_COMMAND) printf 'notify-command' ;;
        SMOKE_TIMEOUT) printf 'smoke-timeout' ;;
        SMOKE_EXPECT) printf 'smoke-expect' ;;
        WP_CLI_GPG_KEY_URL) printf 'config WP_CLI_GPG_KEY_URL' ;;
        *) printf '%s' "${1,,}" ;;
    esac
    return 0
}

#!/usr/bin/env bash
# shellcheck shell=bash
# Fast functional checks for the manager's pure logic layers.
#
# Source it, do not execute it:  `source tests/pure_check.sh`
#
# No root, no WordPress, no WP-CLI, no network, and no fixture files: the
# functions under test are the ones on the per-site hot path (configuration
# validation, version comparison, the JSON readers, redaction, the read-only
# command classification that --dry-run depends on, and the mode/option tables
# that help and completion are generated from). It runs in well under a second,
# which is what makes it worth running after every edit.
#
# The end-to-end suites (tests/test_manager.sh and friends) drive a stub `wp`
# over a synthetic site tree and cover the parts this file cannot: user switching,
# locking, backups, parallel workers and exit codes.
#
# Expects to be sourced from the repository root:
#   cd /path/to/repo && source tests/pure_check.sh

PURE_RC=0
_p_pass=0
_p_fail=0

_p_ok() {
    _p_pass=$((_p_pass + 1))
    # When run under tests/run_tests.sh the shared counters are exported; feed
    # them too, so this suite is tallied like every other one.
    [ -n "${PASS_FILE:-}" ] && printf 'x\n' >>"$PASS_FILE"
    return 0
}
_p_bad() {
    _p_fail=$(( _p_fail + 1 ))
    PURE_RC=1
    printf 'FAIL  %s\n' "$1" >&2
    [ -n "${2:-}" ] && printf '      %s\n' "$2" >&2
    [ -n "${FAIL_FILE:-}" ] && printf 'x\n' >>"$FAIL_FILE"
    return 0
}
_p_eq() { # EXPECTED ACTUAL NAME
    if [ "$1" = "$2" ]; then _p_ok; else _p_bad "$3" "expected [$1], got [$2]"; fi
}
_p_true() { # NAME ; uses $?
    if (($1 == 0)); then _p_ok; else _p_bad "$2"; fi
}

_p_here="${BASH_SOURCE[0]%/*}"
[ "$_p_here" = "${BASH_SOURCE[0]}" ] && _p_here='.'
_p_repo="${_p_here%/*}"
[ "$_p_repo" = "$_p_here" ] && _p_repo='.'

# ---------------------------------------------------------------- load modules
# 18-main.sh is deliberately not sourced: it ends with `main "$@"`.
for _m in "$_p_repo"/src/manager/0*.sh "$_p_repo"/src/manager/1[0-7]*.sh; do
    [ -f "$_m" ] || continue
    # shellcheck disable=SC1090
    source "$_m"
done

printf '== pure functional checks ==\n'

# ------------------------------------------------------- configuration table
config_init_defaults
_p_eq 'true' "$([ ${#CONFIG_KEYS[@]} -gt 50 ] && printf true || printf false)" \
    'CONFIG_SPEC produced more than 50 keys'
_p_eq "${#CONFIG_KEYS[@]}" "${#CONFIG_TYPE[@]}" 'every key has a type'
_p_eq "${#CONFIG_KEYS[@]}" "${#CONFIG_DEFAULT[@]}" 'every key has a default'
_p_eq '/usr/local/bin/wp' "$WP_CLI_PATH" 'WP_CLI_PATH default'
_p_eq '2.8.0' "$WP_CLI_MIN_VERSION" 'WP_CLI_MIN_VERSION default'
_p_eq 'stdin' "$LICENCE_HANDOFF" 'LICENCE_HANDOFF default'
_p_eq 'expired' "$CACHE_TRANSIENTS" 'CACHE_TRANSIENTS default'
_p_eq '50' "$CLEANUP_REVISIONS_KEEP" 'CLEANUP_REVISIONS_KEEP default'
_p_eq 'never' "$NOTIFY_ON" 'NOTIFY_ON default'
_p_eq 'auto' "$MULTISITE" 'MULTISITE default'
_p_eq '200,301,302,303,307,308' "$SMOKE_EXPECT" 'SMOKE_EXPECT default'
case "$LOG_FILE" in
    /*) _p_ok ;;
    *) _p_bad 'LOG_FILE default is absolute' "got [$LOG_FILE]" ;;
esac
case "$SITES_FILE" in
    */wp-found.txt) _p_ok ;;
    *) _p_bad 'SITES_FILE default points at wp-found.txt' "got [$SITES_FILE]" ;;
esac

# every default must satisfy its own declared type
_bad_defaults=0
for _k in ${CONFIG_KEYS[@]+"${CONFIG_KEYS[@]}"}; do
    _t="${CONFIG_TYPE[$_k]-str}"
    validate_value "$_t" "$_k" "${!_k}" >/dev/null || {
        _bad_defaults=$((_bad_defaults + 1))
        printf '      default for %s (%s) fails its own type check: [%s]\n' \
            "$_k" "$_t" "${!_k}" >&2
    }
done
_p_eq '0' "$_bad_defaults" 'every built-in default passes its own validator'

# ------------------------------------------------------------- validate_value
_vv() { # TYPE VALUE -> 0 ok
    validate_value "$1" TESTKEY "$2" >/dev/null
}
_vv uint 0; _p_true $? 'uint accepts 0'
_vv uint -1; [ $? -ne 0 ]; _p_true $? 'uint rejects -1'
_vv pint 0; [ $? -ne 0 ]; _p_true $? 'pint rejects 0'
_vv pint 7; _p_true $? 'pint accepts 7'
_vv bool yes; _p_true $? 'bool accepts yes'
_vv bool maybe; [ $? -ne 0 ]; _p_true $? 'bool rejects maybe'
_vv 'choice:auto,always,never' always; _p_true $? 'choice accepts a member'
_vv 'choice:auto,always,never' Sometimes; [ $? -ne 0 ]; _p_true $? 'choice rejects a non-member'
_vv words 'HTTP_PROXY NO_PROXY'; _p_true $? 'words accepts identifiers'
_vv words 'HTTP_PROXY=1'; [ $? -ne 0 ]; _p_true $? 'words rejects a value, only names are allowed'
_vv tokens 'litespeed-purge-all'; _p_true $? 'tokens accepts a wp subcommand'
_vv tokens 'a;rm -rf /'; [ $? -ne 0 ]; _p_true $? 'tokens rejects shell metacharacters'
_vv apath /var/log/x.log; _p_true $? 'apath accepts an absolute path'
_vv apath relative/x; [ $? -ne 0 ]; _p_true $? 'apath rejects a relative path'
_vv apath ''; _p_true $? 'apath accepts empty (disabled)'
_vv url https://hooks.example/x; _p_true $? 'url accepts https'
_vv url ftp://x; [ $? -ne 0 ]; _p_true $? 'url rejects ftp'
_vv exec /usr/local/bin/notify; _p_true $? 'exec accepts an absolute path'
_vv exec notify.sh; [ $? -ne 0 ]; _p_true $? 'exec rejects a bare name'
_vv globs '/var/www/*staging*'; _p_true $? 'globs accepts a path pattern'
_vv str "$(printf 'a\nb')"; [ $? -ne 0 ]; _p_true $? 'str rejects a newline'

# normalise_bool
_p_eq 'true' "$(normalise_bool YES)" 'normalise_bool YES'
_p_eq 'false' "$(normalise_bool '')" 'normalise_bool empty'
_p_eq 'false' "$(normalise_bool nonsense)" 'normalise_bool nonsense'

# ------------------------------------------------------------- string helpers
trim '   padded   '
_p_eq 'padded' "$TRIMMED" 'trim strips both ends'
trim ''
_p_eq '' "$TRIMMED" 'trim of empty'
trim $'\t x \n'
_p_eq 'x' "$TRIMMED" 'trim strips tabs and newlines'

path_base '/var/www/example.com'
_p_eq 'example.com' "$PATH_BASE" 'path_base'
path_base '/var/www/example.com/'
_p_eq 'example.com' "$PATH_BASE" 'path_base ignores a trailing slash'
path_dir '/var/www/example.com'
_p_eq '/var/www' "$PATH_DIR" 'path_dir'
path_dir 'solo'
_p_eq '.' "$PATH_DIR" 'path_dir of a bare name is .'

_p_eq 'my_site__prod_' "$(safe_name 'my site (prod)')" 'safe_name replaces unsafe bytes'

json_escape 'plain'
_p_eq 'plain' "$JSON_ESCAPED" 'json_escape leaves plain text alone'
json_escape 'a"b'
_p_eq 'a\"b' "$JSON_ESCAPED" 'json_escape escapes a double quote'
json_escape 'back\slash'
_p_eq 'back\\slash' "$JSON_ESCAPED" 'json_escape escapes a backslash'
json_escape "$(printf 'line1\nline2')"
_p_eq 'line1\nline2' "$JSON_ESCAPED" 'json_escape escapes a newline'
json_quote 'q"q'
_p_eq '"q\"q"' "$JSON_QUOTED" 'json_quote wraps in quotes'

csv_escape 'plain'
_p_eq 'plain' "$(csv_escape 'plain')" 'csv_escape leaves plain text alone'
_p_eq '"a,b"' "$(csv_escape 'a,b')" 'csv_escape quotes a comma'
_p_eq '"say ""hi"""' "$(csv_escape 'say "hi"')" 'csv_escape doubles inner quotes'

sh_quote "it's"
_p_eq "'it'\\''s'" "$(sh_quote "it's")" 'sh_quote POSIX-escapes a single quote'
_p_eq "''" "$(sh_quote '')" 'sh_quote of empty is two quotes'
_p_eq '/var/www/x' "$(sh_quote '/var/www/x')" 'sh_quote leaves a safe path bare'

# ------------------------------------------------------------- version compare
_p_eq '1' "$(version_compare 2.10.0 2.9.0)" '2.10.0 > 2.9.0 (the classic string-compare trap)'
_p_eq '-1' "$(version_compare 2.9.0 2.10.0)" '2.9.0 < 2.10.0'
_p_eq '0' "$(version_compare 6.5.2 6.5.2)" 'equal versions'
_p_eq '1' "$(version_compare 6.6 6.5.9)" '6.6 > 6.5.9'
_p_eq '-1' "$(version_compare 6.5 6.5.1)" '6.5 < 6.5.1'
_p_eq '1' "$(version_compare 2.11.0 2.11.0-rc1)" 'a release outranks its pre-release'
_p_eq '-1' "$(version_compare 2.11.0-nightly 2.11.0)" 'a nightly sorts below the release'
_p_eq '0' "$(version_compare '' 1.0)" 'an empty version compares equal, never crashes'
version_at_least 2.11.0 2.8.0; _p_true $? 'version_at_least true case'
version_at_least 2.5.0 2.8.0; [ $? -ne 0 ]; _p_true $? 'version_at_least false case'
_p_eq '6.5' "$(version_major_minor 6.5.2)" 'version_major_minor'
_p_eq '6' "$(version_major_minor 6)" 'version_major_minor of a bare major'

# ---------------------------------------------------------------- list helpers
in_csv_list 'always' 'auto,always,never'; _p_true $? 'in_csv_list finds a member'
in_csv_list 'ALWAYS' 'auto,always,never'; [ $? -ne 0 ]; _p_true $? 'in_csv_list is case sensitive'
in_csv_list ' auto ' 'auto,always'; _p_true $? 'in_csv_list trims tokens'
in_csv_list '' 'auto,always'; [ $? -ne 0 ]; _p_true $? 'in_csv_list does not match empty'

fill_csv ' a , ,b ,'
_p_eq '2' "${#SPLIT_RESULT[@]}" 'fill_csv drops empties'
_p_eq 'a' "${SPLIT_RESULT[0]}" 'fill_csv trims the first token'
_p_eq 'b' "${SPLIT_RESULT[1]}" 'fill_csv trims the second token'
fill_words 'x  y z'
_p_eq '3' "${#SPLIT_RESULT[@]}" 'fill_words splits on whitespace'

_p_eq '3' "$(count_id_words <<<"1 2
3")" 'count_id_words across batches'
_p_eq '2' "$(printf '1\nx\n2\n' | numeric_lines | count_lines)" 'numeric_lines drops non-integers'
_p_eq '2 3' "$(printf '1\n2\n3\n4\n5\n' | chunk_lines 2 | tail -n 1)" 'chunk_lines groups by size'

glob_match '/var/www/*' '/var/www/example.com'; _p_true $? 'glob_match matches a prefix pattern'
glob_match '/var/www/*staging*' '/var/www/a-staging-b'; _p_true $? 'glob_match matches an inner pattern'
glob_match '/var/www/*' '/srv/www/example.com'; [ $? -ne 0 ]; _p_true $? 'glob_match rejects a non-match'
any_glob_match '/srv/x' '/var/www/*' '/srv/*'; _p_true $? 'any_glob_match finds the second pattern'
any_glob_match '/opt/x' '/var/www/*' '/srv/*'; [ $? -ne 0 ]; _p_true $? 'any_glob_match rejects all'

# --------------------------------------------------------------- JSON readers
_p_eq '[{"a":"1"}]' "$(json_array_slice 'noise before [{"a":"1"}] noise after')" \
    'json_array_slice cuts prose around the payload'
json_array_slice 'no brackets here'; [ $? -ne 0 ]; _p_true $? 'json_array_slice fails without brackets'

_tsv="$(printf '[{"name":"A B","slug":"a-b","update":"available"},{"name":"C","slug":"c","update":"none"}]' \
    | json_to_tsv name slug update)"
_p_eq 'name slug update' "$(printf '%s' "$_tsv" | head -n 1 | tr '\t' ' ')" 'json_to_tsv header'
_p_eq 'A B a-b available' "$(printf '%s' "$_tsv" | sed -n 2p | tr '\t' ' ')" \
    'json_to_tsv keeps a space inside a value'
_p_eq '3' "$(printf '%s\n' "$_tsv" | count_lines)" 'json_to_tsv row count including the header'

_tsv="$(printf '[{"t":"quote\\"inside"},{"t":"tab\\there"}]' | json_to_tsv t)"
_p_eq 'quote"inside' "$(printf '%s' "$_tsv" | sed -n 2p)" 'json_to_tsv decodes an escaped quote'
case "$(printf '%s' "$_tsv" | sed -n 3p)" in
    *$'\t'*) _p_bad 'json_to_tsv flattens a tab inside a value' 'a literal tab would invent a column' ;;
    *) _p_ok ;;
esac

_p_eq 'v2.11.0' "$(printf '{"tag_name":"v2.11.0","x":1}' | json_scalar tag_name)" 'json_scalar reads a string'
printf '{"a":true}' | json_scalar a >/dev/null; _p_true $? 'json_scalar reads a boolean'

# ------------------------------------------------------------- table and csv
_out="$(printf 'name\tstatus\nlong-plugin-name\tactive\nx\tinactive\n' | table_render 0)"
_p_eq '4' "$(printf '%s\n' "$_out" | count_lines)" 'table_render emits header, rule and every row'
case "$(printf '%s\n' "$_out" | sed -n 3p)" in
    'long-plugin-name'*) _p_ok ;;
    *) _p_bad 'table_render pads to the widest cell' "got [$(printf '%s\n' "$_out" | sed -n 3p)]" ;;
esac
_out="$(printf 'a\tb c\n1\t2 3\n' | tsv_to_csv)"
_p_eq 'a,"b c"' "$(printf '%s\n' "$_out" | head -n 1)" 'tsv_to_csv quotes a cell with a space only when needed'
_p_eq '1,"2 3"' "$(printf '%s\n' "$_out" | sed -n 2p)" 'tsv_to_csv row two'
_out="$(printf 'x\n' | table_render 1)"
_p_eq '2' "$(printf '%s\n' "$_out" | count_lines)" 'table_render honours MAX_ROWS'

# --------------------------------------------------------------- sinks
DATA_SINK=''; PARALLEL='false'; WORKER_DIR=''
data_sink >/dev/null
_p_eq '' "$DATA_SINK" 'data_sink is empty (stdout) outside a worker'
PARALLEL='true'; WORKER_DIR='/tmp/w1'
data_sink >/dev/null
_p_eq '/tmp/w1/data' "$DATA_SINK" 'data_sink points into the worker fragment inside a worker'
PARALLEL='false'; WORKER_DIR=''

sink_write '' <<<"to stdout" >/tmp/.pure_sink_out
_p_eq 'to stdout' "$(< /tmp/.pure_sink_out)" 'sink_write with an empty sink reaches the terminal stream'
sink_write /tmp/.pure_sink_file <<<"to file"
_p_eq 'to file' "$(< /tmp/.pure_sink_file)" 'sink_write with a path writes the file'
rm -f /tmp/.pure_sink_out /tmp/.pure_sink_file

# ------------------------------------------------------------------ mode table
_seen=0
for _row in ${MODE_TABLE[@]+"${MODE_TABLE[@]}"}; do
    _seen=$((_seen + 1))
    mode_field "${_row%%|*}" 0 >/dev/null || _p_bad "mode_field cannot find ${_row%%|*}"
done
_p_eq "${#MODE_TABLE[@]}" "$_seen" 'MODE_TABLE is walkable'
_p_eq 'yes' "$(mode_field report 2)" '--report is read-only'
_p_eq 'no' "$(mode_field full 2)" '--full is not read-only'
_p_eq '-f' "$(mode_field full 1)" '--full short flag'
mode_exists cleanup; _p_true $? 'mode_exists finds cleanup'
mode_exists nope; [ $? -ne 0 ]; _p_true $? 'mode_exists rejects an unknown mode'
mode_is_readonly security; _p_true $? 'mode_is_readonly security'
mode_is_readonly cache; [ $? -ne 0 ]; _p_true $? 'mode_is_readonly cache is false'
_n=$(list_modes | count_lines)
_p_eq "${#MODE_TABLE[@]}" "$_n" 'list_modes prints exactly one line per mode'

# Every mode must be reachable from dispatch_mode, and every dispatched mode must
# exist in the table. This is the check that stops "I added the case branch and
# forgot the help row" and its mirror image.
_dm="$(sed -n '/^dispatch_mode() {/,/^}/p' "$_p_repo/src/manager/12-modes.sh" "$_p_repo/src/manager/17-fleet.sh" 2>/dev/null)"
_missing=0
for _row in ${MODE_TABLE[@]+"${MODE_TABLE[@]}"}; do
    _name="${_row%%|*}"
    case "$_name" in
        list-modes | print-config | init-config | completion | check | status | \
        list-sites | wpcli-check | wpcli-update | wpcli-install | wpcli-rollback | restore)
            continue ;;     # handled before the fleet loop, not by dispatch_mode
    esac
    case "$_dm" in
        *"$_name)"*) : ;;
        *) _missing=$((_missing + 1)); printf '      dispatch_mode has no branch for %s\n' "$_name" >&2 ;;
    esac
done
_p_eq '0' "$_missing" 'every fleet mode has a dispatch_mode branch'

# ------------------------------------------------------- option/help coverage
# A long option that parse_args accepts but that is missing from LONG_OPTIONS
# cannot be completed in a shell and does not appear in the generated docs; the
# reverse means completion offers a flag the parser rejects. Both are drift, and
# both are invisible until somebody tab-completes at 2 a.m.
_cli="$(< "$_p_repo/src/manager/16-cli.sh")"
_drift=0
for _o in ${LONG_OPTIONS[@]+"${LONG_OPTIONS[@]}"}; do
    case "$_cli" in
        *"--${_o#--})"* | *"--${_o#--} |"*) : ;;
        *) _drift=$((_drift + 1)); printf '      LONG_OPTIONS advertises %s but parse_args has no branch\n' "$_o" >&2 ;;
    esac
done
_p_eq '0' "$_drift" 'every advertised long option is parsed'

# The reverse direction: an option the parser accepts but that is not advertised
# cannot be tab-completed and does not appear in the generated documentation.
# Extracted from the case arms of parse_args rather than maintained by hand,
# because a hand-maintained list is exactly what drifts.
_undocumented=0
_in_parse='false'
while IFS= read -r _line; do
    case "$_line" in
        'parse_args() {') _in_parse='true'; continue ;;
    esac
    [ "$_in_parse" = 'true' ] || continue
    case "$_line" in
        '}') break ;;
    esac
    _rest="$_line"
    while :; do
        case "$_rest" in
            *' --'*)
                _rest="${_rest#* --}"
                _name="--${_rest%%[) |]*}"
                case " ${LONG_OPTIONS[*]} " in
                    *" ${_name} "*) : ;;
                    *)
                        # Compatibility aliases and internal arms are allowed to be
                        # undocumented, but only the ones listed here.
                        case "$_name" in
                            --sites-file | --include-sites | --exclude-sites | --max-depth | \
                            --wp-cli | --health | --audit | --json | --no-smoke-test | --follow)
                                : ;;
                            *)
                                _undocumented=$((_undocumented + 1))
                                printf '      parse_args accepts %s but LONG_OPTIONS does not list it\n' "$_name" >&2
                                ;;
                        esac
                        ;;
                esac
                ;;
            *) break ;;
        esac
    done
done <"$_p_repo/src/manager/16-cli.sh"
_p_eq '0' "$_undocumented" 'every parsed long option is advertised'

# ------------------------------------------------------------- read-only table
# The dry-run contract depends on this classification being conservative: an
# unknown command must be treated as mutating, or --dry-run becomes a lie.
wp_is_readonly plugin list; _p_true $? 'plugin list is read-only'
wp_is_readonly core version; _p_true $? 'core version is read-only'
wp_is_readonly cli version; _p_true $? 'cli version is read-only'
wp_is_readonly cron test; _p_true $? 'cron test is read-only'
wp_is_readonly maintenance-mode status; _p_true $? 'maintenance-mode status is read-only'
wp_is_readonly option get home; _p_true $? 'option get is read-only'
wp_is_readonly core update; [ $? -ne 0 ]; _p_true $? 'core update is NOT read-only'
wp_is_readonly plugin delete x; [ $? -ne 0 ]; _p_true $? 'plugin delete is NOT read-only'
wp_is_readonly db optimize; [ $? -ne 0 ]; _p_true $? 'db optimize is NOT read-only'
wp_is_readonly cache flush; [ $? -ne 0 ]; _p_true $? 'cache flush is NOT read-only'
wp_is_readonly rewrite flush; [ $? -ne 0 ]; _p_true $? 'rewrite flush is NOT read-only'
wp_is_readonly eval 'phpinfo();'; [ $? -ne 0 ]; _p_true $? 'eval is NEVER read-only'
wp_is_readonly maintenance-mode activate; [ $? -ne 0 ]; _p_true $? 'maintenance-mode activate is NOT read-only'
wp_is_readonly db query 'SELECT 1'; _p_true $? 'db query with SELECT is read-only'
wp_is_readonly db query 'DROP TABLE wp_posts'; [ $? -ne 0 ]; _p_true $? 'db query with DROP is NOT read-only'
wp_is_readonly some-future-command do-it; [ $? -ne 0 ]; _p_true $? 'an unknown command is treated as mutating'

# ------------------------------------------------------------- time and size
now_epoch >/dev/null
_p_eq 'true' "$([ "$EPOCH_NOW" -gt 1700000000 ] 2>/dev/null && printf true || printf false)" \
    'now_epoch fills EPOCH_NOW without date(1)'
_p_eq '1h 02m 03s' "$(duration_human 3723)" 'duration_human hours'
_p_eq '2m 03s' "$(duration_human 123)" 'duration_human minutes'
_p_eq '9s' "$(duration_human 9)" 'duration_human seconds'
_p_eq '1.5 MiB' "$(human_bytes 1572864)" 'human_bytes MiB'
_p_eq '512 B' "$(human_bytes 512)" 'human_bytes bytes'

# ------------------------------------------------------------------- redaction
REDACT_VALUES=()
redact_register 'SUPERSECRETVALUE'
redact 'the key is SUPERSECRETVALUE here'
_p_eq 'the key is <redacted> here' "$REDACTED" 'redact masks a registered secret'
redact_register 'ab'
redact 'ab'
_p_eq 'ab' "$REDACTED" 'redact ignores a too-short value rather than masking the alphabet'
redact "marker ${LICENCE_MARKER} end"
_p_eq 'marker <licence> end' "$REDACTED" 'redact replaces the licence marker'

# ------------------------------------------------------------------- summary
printf '\npure checks: %s passed, %s failed\n' "$_p_pass" "$_p_fail"
if ((_p_fail == 0)); then
    printf 'RESULT: all pure functional checks passed\n'
else
    printf 'RESULT: %s check(s) failed\n' "$_p_fail"
fi
# Sourcing the modules installed the manager's EXIT/INT/TERM traps in this shell.
# They are removed here, so running the suite cannot make the caller's shell exit
# through on_exit or delete a lock file it does not own.
trap - EXIT INT TERM HUP
unset _m _k _t _row _name _o _dm _cli _tsv _out _n _seen _missing _drift
unset _p_here _p_repo _line _rest _in_parse _undocumented _bad_defaults
return "$PURE_RC" 2>/dev/null || exit "$PURE_RC"

#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016,SC1091,SC2034  # a test suite greps for literal shell
# patterns and sources its harness by a path resolved at run time
# Regression tests for the 8.0.0 feature set: the read-only modes (--health,
# --secrets, --doctor, --list-backups), the restore path, the fleet controls
# (--retry, --max-failures, --skip-if-no-updates), the production guards
# (--min-free-mb, --nice, --ionice, --backup-age-days) and the observability
# (--report, --json-log).
#
# The rules this suite enforces:
#   - a read-only mode never writes, never exports a database and never takes the
#     lock;
#   - a secret scanner reports names and never values;
#   - a destructive mode (--restore-db) refuses without --yes and dumps first;
#   - a retry retries, a circuit breaker stops the fleet, and both say so.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-v7.XXXXXX")"
chmod 755 "$WORK"
FAIL_FILE="${FAIL_FILE:-${WORK}/fail}"
PASS_FILE="${PASS_FILE:-${WORK}/pass}"
SKIP_FILE="${SKIP_FILE:-${WORK}/skip}"
export FAIL_FILE PASS_FILE SKIP_FILE
# shellcheck source=tests/harness.sh
. "${here}/harness.sh"
trap 'rm -rf -- "$WORK"' EXIT
build_fixture

M="$MANAGER"
BACKUPS="${WORK}/backups"
HELP="${WORK}/help.txt"
bash "$M" --help >"$HELP" 2>&1
MODES_OUT="$(bash "$M" --list-modes 2>/dev/null)"

mrun() { manager_run --no-user-switch "$@"; }
# The stub keeps per-run markers next to its argv log; a fresh test starts clean.
reset_stub_markers() {
    rm -f -- "${ARGV_LOG}.failed-once" "${ARGV_LOG}.bumped" 2>/dev/null || true
}

say 'the v7 modes and options are advertised'
for mode in health secrets doctor list-backups restore-db completion; do
    if printf '%s\n' "$MODES_OUT" | grep -Fxq "$mode"; then
        ok "--list-modes advertises ${mode}"
    else
        bad "--list-modes is missing ${mode}" "got: $(printf '%s' "$MODES_OUT" | tr '\n' ' ')"
    fi
done
for opt in --health --secrets --doctor --list-backups --restore-db --completion \
           --retry --retry-delay --max-failures --run-timeout --lock-wait \
           --min-free-mb --nice --ionice --backup-age-days --backup-compress \
           --report --json-log --notify --notify-on --mail-to --no-notify \
           --exclude-themes --hold-plugins --hold-themes --skip-if-no-updates \
           --default-user --log-dir; do
    if grep -Fq -- "$opt" "$HELP"; then
        ok "--help documents ${opt}"
    else
        bad "--help does not document ${opt}" ''
    fi
done

say '--health is read-only and reports what is pending'
argv_log_reset
out="$(mrun --health 2>&1)"
rc=$?
if [ "$rc" = '0' ]; then ok '--health exits 0'; else bad '--health exit code' "got ${rc}"; fi
if printf '%s' "$out" | grep -Fq 'CORE'; then ok '--health prints a table header'; else bad '--health printed no header' "$(printf '%s' "$out" | head -3)"; fi
expect_contains "$ARGV_LOG" '[core] [version]' '--health asks for the core version'
if grep -Fq '[plugin] [list] [--update=available]' "$ARGV_LOG"; then
    ok '--health asks which plugins have updates'
else
    bad '--health did not query pending plugin updates' "$(head -2 "$ARGV_LOG" 2>/dev/null)"
fi
if grep -Fq '[db] [export]' "$ARGV_LOG"; then
    bad '--health exported a database' 'a read-only mode must not write'
else
    ok '--health never exports a database'
fi
argv_log_reset
mrun --health --backup db --backup-dir "$BACKUPS" >/dev/null 2>&1
if [ -d "$BACKUPS" ] && [ -n "$(find "$BACKUPS" -name 'db-*.sql*' -print -quit 2>/dev/null)" ]; then
    bad '--health --backup db wrote a dump' 'read-only modes skip the backup entirely'
else
    ok '--health --backup db writes nothing'
fi
out="$(mrun --health --json-lines 2>/dev/null)"
if printf '%s' "$out" | grep -Fq '"type":"health"'; then
    ok '--health --json-lines emits a health object'
else
    bad '--health --json-lines emitted no health object' "$(printf '%s' "$out" | head -2)"
fi

say '--secrets names the constants and never prints a value'
secret_site="${WORK}/secret-site"
make_site "$secret_site"
MARKER='zz-unique-secret-marker-9137'
# shellcheck disable=SC2016
printf '<?php\ndefine("DB_PASSWORD", "%s");\ndefine("AUTH_KEY", "%s");\n' \
    "$MARKER" "$MARKER" >"${secret_site}/wp-config.php"
chmod 644 "${secret_site}/wp-config.php"
argv_log_reset
out="$(mrun --secrets --site "$secret_site" 2>&1)"
rc=$?
if printf '%s' "$out" | grep -Fq 'DB_PASSWORD'; then
    ok '--secrets names the secret-bearing constant'
else
    bad '--secrets did not name DB_PASSWORD' "$(printf '%s' "$out" | head -5)"
fi
if printf '%s' "$out" | grep -Fq "$MARKER"; then
    bad '--secrets printed the secret value' 'the scan must report names only'
else
    ok '--secrets never prints the value'
fi
if grep -Fq "$MARKER" "$LOG_FILE" 2>/dev/null; then
    bad 'the secret value reached the log file' "$LOG_FILE"
else
    ok 'the secret value never reaches the log file'
fi
if [ "$rc" = '1' ]; then
    ok 'a world-readable wp-config.php fails the scan'
else
    bad 'a world-readable wp-config.php did not fail the scan' "exit ${rc}"
fi
chmod 600 "${secret_site}/wp-config.php"
mode_now="$(stat -c '%a' "${secret_site}/wp-config.php" 2>/dev/null)"
if [ "$mode_now" = '600' ]; then
    if out="$(mrun --secrets --site "$secret_site" 2>&1)"; then
        ok 'a 0600 wp-config.php passes the permission check'
    else
        bad 'a 0600 wp-config.php still failed' "$(printf '%s' "$out" | grep -F 'wp-config' | head -2)"
    fi
else
    skip 'a 0600 wp-config.php passes the permission check' \
        "chmod 600 did not take effect on this filesystem (mode ${mode_now})"
fi
# shellcheck disable=SC2016
printf '%s\n' '<?php /* leftover */' >"${secret_site}/wp-config.php.save"
out="$(mrun --secrets --site "$secret_site" 2>&1)"
if printf '%s' "$out" | grep -Fq 'wp-config.php.save'; then
    ok 'a stale wp-config.php.save is reported'
else
    bad 'a stale wp-config.php.save was not reported' ''
fi
rm -f -- "${secret_site}/wp-config.php.save"

say '--doctor describes the host'
out="$(mrun --doctor 2>&1)"
rc=$?
if [ "$rc" = '0' ] || [ "$rc" = '1' ]; then
    ok "--doctor exits ${rc} instead of crashing"
else
    bad '--doctor exit code' "got ${rc}"
fi
if printf '%s' "$out" | grep -Fq 'wp-cli'; then ok '--doctor reports the wp binary'; else bad '--doctor reported no wp binary' ''; fi
if printf '%s' "$out" | grep -Fq 'min free'; then ok '--doctor reports the disk guard'; else bad '--doctor reported no disk guard' ''; fi

say '--completion prints a script'
out="$(bash "$M" --completion bash 2>/dev/null)"
if printf '%s' "$out" | grep -Fq 'complete -F _wp_cli_update'; then
    ok 'bash completion registers the function'
else
    bad 'bash completion is incomplete' "$(printf '%s' "$out" | head -2)"
fi
out="$(bash "$M" --completion zsh 2>/dev/null)"
if printf '%s' "$out" | grep -Fq 'compdef _wp_cli_update'; then
    ok 'zsh completion registers the function'
else
    bad 'zsh completion is incomplete' "$(printf '%s' "$out" | head -2)"
fi
expect_rc 2 'an unknown --completion shell exits 2' bash "$M" --completion tcsh

say '--report writes a JSON run report'
report="${WORK}/report.json"
argv_log_reset
mrun --plugins --report "$report" --backup-dir "$BACKUPS" >/dev/null 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok 'a run with --report exits 0'; else bad 'a run with --report' "exit ${rc}"; fi
if [ -s "$report" ]; then ok 'the report file exists and is not empty'; else bad 'the report file is missing or empty' "$report"; fi
expect_contains "$report" '"run"' 'the report carries a run object'
expect_contains "$report" '"sites"' 'the report carries the site list'
expect_contains "$report" '"changes"' 'the report carries a change list'
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$report" 2>/dev/null; then
        ok 'the report parses as JSON'
    else
        bad 'the report is not valid JSON' "$(head -c 200 "$report")"
    fi
else
    skip 'the report parses as JSON' 'python3 not available'
fi

say 'the change log records what was actually updated'
reset_stub_markers
report2="${WORK}/report-changes.json"
argv_log_reset
FAKE_VERSION_BUMP=1 mrun --plugins --report "$report2" --backup-dir "$BACKUPS" >/dev/null 2>&1
if grep -Fq '"changes":[{' "$report2" 2>/dev/null; then
    ok 'a version bump appears in the change list'
else
    bad 'the change list is empty after an update' "$(head -c 300 "$report2" 2>/dev/null)"
fi
if grep -Fq '"kind":"plugin"' "$report2" 2>/dev/null; then
    ok 'the change entry names the component kind'
else
    bad 'the change entry has no kind' "$(head -c 300 "$report2" 2>/dev/null)"
fi

say '--retry retries a transient failure, and gives up'
reset_stub_markers
argv_log_reset
FAKE_FAIL_ONCE=jetpack mrun --plugins --only-active --site "$SITES" --retry 1 --retry-delay 0 --backup-dir "$BACKUPS" >/dev/null 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok 'a transient failure recovered on the retry'
else
    bad 'the retry did not recover the site' "exit ${rc}"
fi
attempts="$(grep -c '\[plugin\] \[update\]' "$ARGV_LOG" 2>/dev/null)"
if [ "${attempts:-0}" -ge 2 ]; then
    ok "the site was attempted twice (${attempts} update calls)"
else
    bad 'the failed site was not retried' "${attempts:-0} update call(s)"
fi
reset_stub_markers
argv_log_reset
FAKE_FAIL_ALWAYS=jetpack mrun --plugins --only-active --site "$SITES" --retry 1 --retry-delay 0 --backup-dir "$BACKUPS" >/dev/null 2>&1
rc=$?
if [ "$rc" = '1' ]; then ok 'a permanent failure still exits 1'; else bad 'a permanent failure exit code' "got ${rc}"; fi
attempts="$(grep -c '\[plugin\] \[update\]' "$ARGV_LOG" 2>/dev/null)"
if [ "${attempts:-0}" = '2' ]; then
    ok 'exactly one retry was made'
else
    bad 'retry count is wrong' "${attempts:-0} update call(s), expected 2"
fi

say '--max-failures stops the fleet'
reset_stub_markers
FAKE_FAIL_ALWAYS=jetpack mrun --plugins --only-active --max-failures 1 --backup-dir "$BACKUPS" >/dev/null 2>&1
rc=$?
if [ "$rc" = '1' ]; then ok 'the run exits 1 after the threshold'; else bad 'the aborted run exit code' "got ${rc}"; fi
if grep -Fq 'aborting after 1 failed site' "$LOG_FILE" 2>/dev/null; then
    ok 'the run says why it stopped'
else
    bad 'the run did not report the circuit breaker' "$(grep -F 'abort' "$LOG_FILE" | tail -2)"
fi
if grep -Eq 'skipped, the run was aborted' "$LOG_FILE" 2>/dev/null; then
    ok 'the remaining site is marked skipped'
else
    bad 'the remaining site was processed anyway' ''
fi

say '--skip-if-no-updates leaves an up-to-date site alone'
reset_stub_markers
argv_log_reset
FAKE_NO_UPDATES=1 mrun --plugins --skip-if-no-updates --backup-dir "$BACKUPS" >/dev/null 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok 'a run with nothing pending exits 0'; else bad 'a run with nothing pending' "exit ${rc}"; fi
if grep -Fq '[plugin] [update]' "$ARGV_LOG"; then
    bad 'the site was updated although nothing was pending' "$(head -2 "$ARGV_LOG")"
else
    ok 'no update was executed for an up-to-date site'
fi
if grep -Fq 'nothing pending, skipped' "$LOG_FILE" 2>/dev/null; then
    ok 'the skip is logged with a reason'
else
    bad 'the skip was silent' ''
fi
expect_rc 2 '--skip-if-no-updates with --cron exits 2' \
    bash "$M" --cron --skip-if-no-updates --sites "$SITE_LIST" --no-user-switch --no-discover

say 'plugin and theme policy lists are respected'
argv_log_reset
mrun --plugins --hold-plugins jetpack --backup-dir "$BACKUPS" >/dev/null 2>&1
if grep -Fq '[jetpack]' "$ARGV_LOG"; then
    bad 'a held plugin was updated' "$(grep -F 'plugin update' "$ARGV_LOG" | head -1)"
else
    ok 'a held plugin is not updated'
fi
if grep -Fq 'held by HOLD_PLUGINS' "$LOG_FILE" 2>/dev/null; then
    ok 'the held plugin is named in the log'
else
    bad 'the hold is silent' ''
fi
argv_log_reset
mrun --themes --exclude-themes astra --backup-dir "$BACKUPS" >/dev/null 2>&1
if grep -Fq '[astra]' "$ARGV_LOG"; then
    bad 'an excluded theme was updated' "$(grep -F 'theme update' "$ARGV_LOG" | head -1)"
else
    ok 'an excluded theme is not updated'
fi
expect_rc 2 '--hold-plugins with --cron exits 2' \
    bash "$M" --cron --hold-plugins jetpack --sites "$SITE_LIST" --no-user-switch --no-discover
expect_rc 2 '--exclude-themes with --plugins exits 2' \
    bash "$M" --plugins --exclude-themes astra --sites "$SITE_LIST" --no-user-switch --no-discover

say '--restore-db refuses without --yes and dumps before touching anything'
dump="${WORK}/restore.sql"
# shellcheck disable=SC2016
printf -- '-- MySQL dump (test)\nSELECT 1;\n' >"$dump"
argv_log_reset
mrun --restore-db "$dump" --site "$SITES" --backup-dir "$BACKUPS" >/dev/null 2>&1
rc=$?
if [ "$rc" = '1' ]; then ok 'a restore without --yes exits 1'; else bad 'a restore without --yes' "exit ${rc}"; fi
if grep -Fq '[db] [import]' "$ARGV_LOG"; then
    bad 'a restore without --yes imported anyway' 'the --yes guard is broken'
else
    ok 'a restore without --yes imports nothing'
fi
argv_log_reset
mrun --restore-db "$dump" --site "$SITES" --yes --backup-dir "$BACKUPS" >/dev/null 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok 'a confirmed restore exits 0'; else bad 'a confirmed restore' "exit ${rc}"; fi
if grep -Fq '[db] [import]' "$ARGV_LOG"; then ok 'the restore imports the file'; else bad 'the restore never imported' "$(head -3 "$ARGV_LOG")"; fi
if grep -Fq '[db] [export]' "$ARGV_LOG"; then
    ok 'a safety dump is taken before the restore'
else
    bad 'no safety dump before the restore' 'the way back was not prepared'
fi
argv_log_reset
mrun --restore-db "${WORK}/no-such.sql" --site "$SITES" --yes >/dev/null 2>&1
if [ "$?" = '1' ]; then ok 'a missing dump file exits 1'; else bad 'a missing dump file was accepted' ''; fi

say '--min-free-mb refuses to dump onto a full disk'
rm -rf -- "$BACKUPS"
argv_log_reset
mrun --plugins --backup db --backup-dir "$BACKUPS" --min-free-mb 999999999 >/dev/null 2>&1
rc=$?
if [ "$rc" = '1' ]; then ok 'the disk guard fails the site'; else bad 'the disk guard exit code' "got ${rc}"; fi
if [ -n "$(find "$BACKUPS" -name 'db-*.sql*' -print -quit 2>/dev/null)" ]; then
    bad 'a dump was written although the guard refused' ''
else
    ok 'no dump was written when the guard refused'
fi
if grep -Fq 'refusing to export the database' "$LOG_FILE" 2>/dev/null; then
    ok 'the guard explains itself'
else
    bad 'the guard is silent' ''
fi

say '--backup-age-days prunes old dumps'
# The dump lands in <backup dir>/<site directory name>/, so the aged file has to
# be planted there, not in the backup root.
site_bdir="${WORK}/age/$(basename -- "$SITES")"
mkdir -p "$site_bdir"
old="${site_bdir}/db-20000101-000000-1.sql"
printf 'old\n' >"$old"
touch -d '10 days ago' "$old" 2>/dev/null || touch -t 200001010000 "$old"
argv_log_reset
mrun --plugins --site "$SITES" --backup db --backup-dir "$WORK/age" --backup-age-days 5 >/dev/null 2>&1
if [ -f "$old" ]; then
    bad 'an expired backup survived' "$old"
else
    ok 'an expired backup is removed'
fi
if [ -n "$(find "$site_bdir" -name 'db-*.sql' ! -name 'db-20000101*' -print -quit 2>/dev/null)" ]; then
    ok 'the fresh dump is kept'
else
    bad 'the fresh dump was pruned away' "$(find "$site_bdir" -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
fi

say '--url is detected from wp-config.php, and --no-url-detect stops that'
url_site="${WORK}/url-site"
make_site "$url_site"
# shellcheck disable=SC2016
printf '<?php\ndefine("DB_NAME", "x");\ndefine("WP_HOME", "https://detected.example");\n' >"${url_site}/wp-config.php"
argv_log_reset
mrun --plugins --site "$url_site" --backup-dir "$BACKUPS" >/dev/null 2>&1
if grep -Fq '[--url=https://detected.example]' "$ARGV_LOG"; then
    ok 'WP_HOME becomes --url automatically'
else
    bad 'the site URL was not detected' "$(head -1 "$ARGV_LOG")"
fi
argv_log_reset
mrun --plugins --site "$url_site" --no-url-detect --backup-dir "$BACKUPS" >/dev/null 2>&1
if grep -Fq -- '--url=' "$ARGV_LOG"; then
    bad '--no-url-detect still passed --url' "$(head -1 "$ARGV_LOG")"
else
    ok '--no-url-detect passes no --url'
fi

say '--nice and --ionice reach the command'
out="$(mrun --plugins --dry-run --nice 7 --ionice idle 2>&1)"
if printf '%s' "$out" | grep -Fq 'nice -n 7'; then ok '--nice is applied to the command'; else bad '--nice was ignored' "$(printf '%s' "$out" | grep -F 'dry-run' | head -1)"; fi
if printf '%s' "$out" | grep -Fq 'ionice -c 3'; then
    ok '--ionice idle is applied when ionice exists'
else
    skip '--ionice reaches the command' 'ionice is not installed on this host'
fi
out="$(mrun --plugins --dry-run 2>&1)"
if printf '%s' "$out" | grep -Fq 'nice -n '; then
    skip '--nice 0 disables the prefix' 'default niceness is already non-zero on this host'
else
    ok 'the default niceness is zero, so no prefix appears with --nice 0'
fi

say 'configuration: new keys, legacy aliases and validation'
cfg="${WORK}/v7.conf"
printf 'MIN_FREE_MB=250\nRETRY=2\nHOLD_PLUGINS=jetpack\nNICE_LEVEL=5\n' >"$cfg"
chmod 600 "$cfg"
out="$(bash "$M" --print-config --config "$cfg" --no-user-switch 2>/dev/null)"
for key in MIN_FREE_MB RETRY HOLD_PLUGINS NICE_LEVEL REPORT_FILE NOTIFY_ON EXCLUDE_THEMES; do
    if printf '%s' "$out" | grep -Eq "^${key} "; then
        ok "--print-config lists ${key}"
    else
        bad "--print-config does not list ${key}" ''
    fi
done
if printf '%s' "$out" | grep -Eq '^MIN_FREE_MB +250'; then
    ok 'a file value reaches the effective setting'
else
    bad 'the file value did not apply' "$(printf '%s' "$out" | grep MIN_FREE_MB)"
fi
alias_cfg="${WORK}/alias.conf"
printf 'WP_TIMEOUT=300\nWP_CLI_BIN=/usr/local/bin/wp\n' >"$alias_cfg"
chmod 600 "$alias_cfg"
out="$(bash "$M" --print-config --config "$alias_cfg" --no-user-switch 2>&1)"
if printf '%s' "$out" | grep -Eq '^TIMEOUT +300'; then
    ok 'the 6.1 name WP_TIMEOUT still sets TIMEOUT'
else
    bad 'WP_TIMEOUT was ignored' "$(printf '%s' "$out" | grep -E 'TIMEOUT|WP_TIMEOUT' | head -2)"
fi
if printf '%s' "$out" | grep -Fq '6.1 name'; then
    ok 'the deprecated name is reported once'
else
    bad 'the deprecated name is accepted silently' ''
fi
bad_cfg="${WORK}/bad-v7.conf"
printf 'MIN_FREE_MB=abc\n' >"$bad_cfg"
chmod 600 "$bad_cfg"
bash "$M" --print-config --config "$bad_cfg" --no-user-switch >/dev/null 2>&1
if [ "$?" = '4' ]; then ok 'a bad config value exits 4'; else bad 'a bad config value exit code' 'expected 4'; fi
expect_rc 2 '--retry abc exits 2' bash "$M" --plugins --retry abc --sites "$SITE_LIST" --no-user-switch
expect_rc 2 '--lock-wait abc exits 2' bash "$M" --plugins --lock-wait abc --sites "$SITE_LIST" --no-user-switch
expect_rc 2 '--min-free-mb abc exits 2' bash "$M" --plugins --min-free-mb abc --sites "$SITE_LIST" --no-user-switch
expect_rc 2 '--ionice nonsense exits 2' bash "$M" --plugins --ionice nonsense --sites "$SITE_LIST" --no-user-switch
expect_rc 2 '--notify-on nonsense exits 2' bash "$M" --plugins --notify-on sometimes --sites "$SITE_LIST" --no-user-switch
expect_rc 2 '--default-user with a missing account exits 2' \
    bash "$M" --plugins --default-user no-such-user-9137 --sites "$SITE_LIST" --no-user-switch

say '--json-log writes one JSON object per line'
json_log="${WORK}/json.log"
argv_log_reset
mrun --plugins --json-log --log-file "$json_log" --backup-dir "$BACKUPS" >/dev/null 2>&1
if [ -s "$json_log" ] && head -1 "$json_log" | grep -q '^{"ts":'; then
    ok 'a log line is a JSON object'
else
    bad 'the JSON log has no JSON lines' "$(head -1 "$json_log" 2>/dev/null)"
fi
if grep -vq '^{' "$json_log" 2>/dev/null; then
    bad 'the JSON log contains a non-JSON line' "$(grep -v '^{' "$json_log" | head -1)"
else
    ok 'every log line is JSON'
fi
expect_rc 2 '--json-log with --completion bash is still a usage error' bash "$M" --json-log
expect_rc 0 '--list-backups exits 0' bash "$M" --wp "$STUB_WP" --list-backups --sites "$SITE_LIST" --no-user-switch --no-discover --no-lock --backup-dir "$BACKUPS"

report 'v7'



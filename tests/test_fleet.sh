#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2016
# Fleet-level behaviour: parallel batches, filters, budgets, retries, backups,
# the machine-readable outputs (JSON Lines, state file, Prometheus metrics),
# notifications, locking, and multisite expansion.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="${TEST_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wpcli-fleet.XXXXXX")}"
chmod 755 "$WORK" 2>/dev/null
FAIL_FILE="${FAIL_FILE:-${WORK}/fail}"
PASS_FILE="${PASS_FILE:-${WORK}/pass}"
SKIP_FILE="${SKIP_FILE:-${WORK}/skip}"
export FAIL_FILE PASS_FILE SKIP_FILE
REPO="$repo"
export REPO
# shellcheck source=tests/harness.sh
. "${here}/harness.sh"
build_fixture
trap 'cleanup_work' EXIT

OUT="${WORK}/out.txt"
ERR="${WORK}/err.txt"
BACKUPS="${WORK}/backups"

mrun() {
    argv_log_reset
    manager_run --no-user-switch --backup-dir "$BACKUPS" "$@" >"$OUT" 2>"$ERR"
}

say 'parallel batches produce the same totals as a sequential run'
mrun --full
seq_ops="$(grep -Eo 'operations ok: +[0-9]+' "$ERR" | grep -Eo '[0-9]+')"
: >"$LOG_FILE"
mrun --full -j 2
par_ops="$(grep -Eo 'operations ok: +[0-9]+' "$ERR" | grep -Eo '[0-9]+')"
if [ -n "$seq_ops" ] && [ "$seq_ops" = "$par_ops" ]; then
    ok "-j 2 counts the same operations as -j 1 (${par_ops})"
else
    bad 'parallel operation count differs from sequential' "seq=${seq_ops:-?} par=${par_ops:-?}"
fi
expect_contains "$ERR" 'sites ok:' 'the parallel run prints a summary'
# every site's output survived the barrier
expect_grep_count "$ERR" 'finished in' 2 'both sites report completion after the barrier'

say 'parallel log fragments are appended in full'
loglines="$(grep -c "site ${SITES} " "$LOG_FILE" 2>/dev/null)" || loglines=0
[ "${loglines:-0}" -ge 1 ] && ok 'the log file received the parallel workers'"'"' lines' \
    || bad 'parallel run wrote nothing to the log file' ''

say '--include / --exclude filter the fleet'
mrun --cron --include "${SITE_ROOT}/example*"
expect_grep_count "$ARGV_LOG" '\[cron\] \[event\] \[run\]' 1 '--include narrows to one site'
grep -q -- "--path=${SITES2}" "$ARGV_LOG" && bad '--include let the other site through' '' \
    || ok 'the excluded site was not touched'
mrun --cron --exclude "${SITE_ROOT}/example*"
expect_grep_count "$ARGV_LOG" '\[cron\] \[event\] \[run\]' 1 '--exclude drops one site'
grep -Fq -- "--path=${SITES}]" "$ARGV_LOG" && bad '--exclude let the matched site through' '' \
    || ok 'the excluded pattern was not touched'

say '--max-sites caps the run'
mrun --cron --max-sites 1
expect_grep_count "$ARGV_LOG" '\[cron\] \[event\] \[run\]' 1 '--max-sites 1 processes one unit'
expect_contains "$ERR" 'max-sites' 'the cap is reported'

say 'a site path with spaces survives every layer'
mrun --cron -S "$SITES_SPACE"
rc=$?
[ "$rc" -eq 0 ] && ok 'a path with spaces runs' || bad 'path with spaces' "rc=$rc; $(tail -n 3 "$ERR")"
grep -Fq -- "[--path=${SITES_SPACE}]" "$ARGV_LOG" \
    && ok 'the spaced path arrived as ONE argv element' \
    || bad 'spaced path argv' "$(head -n 2 "$ARGV_LOG")"

say 'JSON Lines: one object per site plus a summary, on stdout only'
mrun --full --json-lines
site_objs="$(grep -c '"type":"site"' "$OUT")"
sum_objs="$(grep -c '"type":"summary"' "$OUT")"
[ "$site_objs" -eq 2 ] && ok 'two site objects' || bad 'site object count' "got $site_objs"
[ "$sum_objs" -eq 1 ] && ok 'one summary object' || bad 'summary object count' "got $sum_objs"
grep -q '"sites_total":2' "$OUT" && ok 'the summary counts the fleet' || bad 'summary sites_total' ''
grep -q '"sites_ok":2' "$OUT" && ok 'the summary counts successes' || bad 'summary sites_ok' ''
grep -q '"ops_ok":' "$OUT" && ok 'the summary carries operation counters' || bad 'summary ops_ok' ''
tail -n 1 "$OUT" | grep -q '"type":"summary"' && ok 'the summary is the last line (a stream stays parseable)' \
    || bad 'summary is not last' ''
while IFS= read -r line; do
    case "$line" in
        '{'*) ;;
        '') ;;
        *) bad 'a non-JSON line leaked into stdout' "${line:0:60}"; break ;;
    esac
done <"$OUT"

say 'state file and metrics file'
mrun --cron --state-file "$STATE_FILE" --metrics-file "$METRICS_FILE"
rc=$?
[ "$rc" -eq 0 ] && ok 'a run with state+metrics exits 0' || bad 'state/metrics run' "rc=$rc"
if [ -s "$STATE_FILE" ]; then
    ok 'the state file was written'
    grep -q '"type":"summary"' "$STATE_FILE" && ok 'the state file holds the run document' \
        || bad 'state file content' "$(head -c 120 "$STATE_FILE")"
    grep -q '"results":\[' "$STATE_FILE" && ok 'the state file has per-unit results' \
        || bad 'state file results' ''
else
    bad 'the state file was not written' ''
fi
if [ -s "$METRICS_FILE" ]; then
    ok 'the metrics file was written'
    for series in 'wpu_up 1' 'wpu_sites_total 2' 'wpu_sites_ok 2' 'wpu_exit_code 0' 'wpu_unit_status{' 'wpu_duration_seconds'; do
        grep -qF "$series" "$METRICS_FILE" && ok "metrics contain ${series%% *}" \
            || bad "metrics missing ${series%% *}" ''
    done
    grep -q '# TYPE wpu_sites_total gauge' "$METRICS_FILE" && ok 'metrics carry TYPE metadata' \
        || bad 'metrics TYPE lines' ''
else
    bad 'the metrics file was not written' ''
fi

say 'notification command receives the summary in argv and environment'
cat >"${WORK}/notify.sh" <<'NOTIFY'
#!/usr/bin/env bash
{
    printf 'ARGV:'
    for a in "$@"; do printf ' [%s]' "$a"; done
    printf '\nENV: exit=%s total=%s ok=%s failed=%s mode=%s\n' \
        "$WPU_EXIT" "$WPU_SITES_TOTAL" "$WPU_SITES_OK" "$WPU_SITES_FAILED" "$WPU_MODE"
    printf 'SUMMARY: %s\n' "$WPU_SUMMARY"
} >>"$NOTIFY_SINK"
NOTIFY
chmod 755 "${WORK}/notify.sh"
NOTIFY_SINK="${WORK}/notify.out"
export NOTIFY_SINK
: >"$NOTIFY_SINK"
mrun --cron --notify always --notify-command "${WORK}/notify.sh"
if [ -s "$NOTIFY_SINK" ]; then
    ok 'the notification command ran'
    expect_contains "$NOTIFY_SINK" '[--exit' 'argv carries the exit code'
    expect_contains "$NOTIFY_SINK" 'total=2' 'environment carries the fleet size'
    expect_contains "$NOTIFY_SINK" 'mode=cron' 'environment carries the mode'
else
    bad 'the notification command did not run' ''
fi
: >"$NOTIFY_SINK"
mrun --cron --notify failure --notify-command "${WORK}/notify.sh"
if [ -s "$NOTIFY_SINK" ]; then
    bad 'notify=failure must stay quiet on success' "$(cat "$NOTIFY_SINK")"
else
    ok 'notify=failure stays quiet when the run succeeded'
fi
: >"$NOTIFY_SINK"
WP_FAIL_CMD='cron event' mrun --cron --notify failure --notify-command "${WORK}/notify.sh" \
    --user-env 'FAKE_WP_LOG WP_FAIL_CMD'
expect_contains "$NOTIFY_SINK" 'exit=1' 'notify=failure fires on a failed run'

say '--fail-fast stops the fleet after the first failure'
WP_FAIL_CMD='core update' mrun --core --fail-fast --user-env 'FAKE_WP_LOG WP_FAIL_CMD'
rc=$?
[ "$rc" -ne 0 ] && ok '--fail-fast exits non-zero' || bad '--fail-fast exit code' "got $rc"
n="$(grep -Ec '\[core\] \[update\]' "$ARGV_LOG" 2>/dev/null)" || n=0
[ "${n:-0}" -eq 1 ] && ok '--fail-fast did not start the second site' \
    || bad '--fail-fast kept going' "core update ran ${n} times"
expect_contains "$ERR" 'fail-fast' 'the early stop is explained'

say '--retry re-attempts a failing site'
WP_FAIL_CMD='core update' mrun --core --retry 1 --user-env 'FAKE_WP_LOG WP_FAIL_CMD'
n="$(grep -Ec '\[core\] \[update\]' "$ARGV_LOG" 2>/dev/null)" || n=0
[ "${n:-0}" -eq 4 ] && ok '--retry 1 gives every site two attempts (2 sites x 2)' \
    || bad 'retry attempt count' "core update ran ${n} times, want 4"
expect_contains "$ERR" 'retrying' 'the retry is logged'

say '--max-duration stops between sites and exits 6'
WP_HANG=1 mrun --core --max-duration 1 --user-env 'FAKE_WP_LOG WP_HANG'
rc=$?
if [ "$rc" -eq 6 ]; then
    ok 'a used-up budget exits 6'
    expect_contains "$ERR" 'max-duration' 'the budget stop is explained'
    grep -q '"stopped_early":true\|stopped early' "$ERR" "$OUT" 2>/dev/null \
        && ok 'the stop is visible in the report' || bad 'stopped_early not reported' ''
elif [ "$rc" -eq 0 ]; then
    skip 'a used-up budget exits 6' 'the whole fleet finished inside the budget on this host'
else
    bad 'budget run exit code' "got $rc, want 6 (or 0 when very fast)"
fi

say '--backup db writes a per-site dump before the update'
mrun --core --backup db
rc=$?
[ "$rc" -eq 0 ] && ok '--backup db run exits 0' || bad '--backup db exit code' "got $rc"
dumps="$(ls "${BACKUPS}"/*/db-*.sql 2>/dev/null | grep -c '' 2>/dev/null)" || dumps=0
[ "${dumps:-0}" -ge 2 ] && ok "one dump per site (${dumps})" || bad 'dump count' "got ${dumps:-0}, want 2"
if tail -c 4096 "${BACKUPS}"/example.com/db-*.sql 2>/dev/null | grep -q 'Dump completed'; then
    ok 'the dump carries the completion marker'
else
    bad 'dump completion marker missing' ''
fi
first_dump="$(grep -n '\[db\] \[export\]' "$ARGV_LOG" | head -n 1 | cut -d: -f1)"
first_upd="$(grep -n '\[core\] \[update\]' "$ARGV_LOG" | head -n 1 | cut -d: -f1)"
if [ -n "$first_dump" ] && [ -n "$first_upd" ] && [ "$first_dump" -lt "$first_upd" ]; then
    ok 'the dump happens before the first mutation'
else
    bad 'backup must precede the update' "dump=$first_dump upd=$first_upd"
fi

say '--min-free-space refuses to back up onto a full volume'
mrun --core --backup db --min-free-space 999999999
rc=$?
[ "$rc" -eq 1 ] && ok 'an impossible space requirement fails the site' || bad 'min-free-space exit' "got $rc"
expect_contains "$ERR" 'MIN_FREE_MIB' 'the guard names the setting'
expect_contains "$ERR" 'backup failed' 'the site is skipped rather than updated unprotected'

say 'the run lock prevents a concurrent run'
if have_tool flock; then
    exec 9>>"$LOCK_FILE"
    if flock -n 9; then
        manager_run --no-user-switch --cron >"$OUT" 2>"$ERR"
        rc=$?
        [ "$rc" -eq 3 ] && ok 'a second run refuses while the lock is held (exit 3)' \
            || bad 'locked run exit code' "got $rc, want 3"
        expect_contains "$ERR" 'refusing to run concurrently' 'the refusal names the lock holder'
        manager_run --no-user-switch --cron --lock-timeout 2 >"$OUT" 2>"$ERR"
        rc=$?
        [ "$rc" -eq 3 ] && ok '--lock-timeout waits and then still refuses' \
            || bad '--lock-timeout exit code' "got $rc"
        exec 9>&-
        manager_run --no-user-switch --cron >"$OUT" 2>"$ERR"
        rc=$?
        [ "$rc" -eq 0 ] && ok 'after the lock is released the run proceeds' \
            || bad 'post-release run' "rc=$rc"
    else
        exec 9>&-
        skip 'run lock' 'flock could not be taken by the test itself'
    fi
else
    skip 'run lock' 'flock(1) not installed'
fi

say '--multisite all expands one installation into its subsites'
WP_MULTISITE=1 WP_CLI_UPDATE_MULTISITE=all mrun --cron \
    --user-env 'FAKE_WP_LOG WP_MULTISITE'
expect_grep_count "$ARGV_LOG" '\[cron\] \[event\] \[run\]' 4 'two sites x two subsites = four units'
expect_grep_count "$ARGV_LOG" '\[--url=https://example.test\]' 2 'subsite 1 is targeted on both installations'
expect_grep_count "$ARGV_LOG" '\[--url=https://two.example.test\]' 2 'subsite 2 is targeted on both installations'
expect_contains "$ERR" 'https://two.example.test' 'the second subsite is named in the log'
mrun --cron
grep -q -- '--url=' "$ARGV_LOG" && bad 'without MULTISITE=all no --url is injected' '' \
    || ok 'a single-site run passes no --url'

say 'the smoke test degrades cleanly without an HTTP client'
mrun --core --smoke-test
rc=$?
if have_tool curl || have_tool wget; then
    # example.test does not resolve here; the probe must fail the site, loudly.
    if [ "$rc" -eq 1 ]; then
        ok 'an unreachable site URL fails the smoke test'
        expect_contains "$ERR" 'smoke test' 'the smoke failure is reported'
    else
        skip 'smoke failure path' "the probe returned rc=$rc (network policy of this host)"
    fi
else
    [ "$rc" -eq 0 ] && ok 'without curl/wget the smoke test is skipped, not fatal' \
        || bad 'smoke degradation exit code' "got $rc"
    expect_contains "$ERR" 'smoke' 'the disabled smoke test is mentioned'
fi

report test_fleet

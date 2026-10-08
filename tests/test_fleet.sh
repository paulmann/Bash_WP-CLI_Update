#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016,SC1091,SC2034,SC2153
#   SC2016: the stub bodies are literal shell source, not expansions.
#   SC1091: the harness is sourced by a path resolved at run time.
#   SC2153/SC2034: SITES, SITES2 and friends come from the harness, and some
#   locals exist for the reader rather than for the shell.
# Tests for the features adopted from the SagaAI revision (see REFACTORING.md):
# parallel batches, backups, --verify, plugin selection, --strict, JSON Lines,
# --no-user-switch, --list-sites and --url.
#
# Two rules this suite follows, both learned from failures:
#
#   * Every run states its full configuration explicitly through `fleet_run`,
#     which resets the knobs it owns. Bash prefix assignments (`VAR=x cmd1 cmd2`)
#     stay in effect for the rest of the AND-OR list, which once made a backup
#     test run against a sleeping stub and report "database backup failed".
#   * Everything goes through --no-user-switch unless the check is specifically
#     about the switch, so the suite needs neither root nor a fixture owned by a
#     switchable account. Three suites in this project's history reported dozens
#     of failures that were purely ownership artifacts.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-fleet.XXXXXX")"
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

# Five sites: a batch of two over five is three barriers, which is enough to tell
# a real batch implementation from a sequential loop pretending to be one.
FLEET="${WORK}/fleet.txt"
S3="${SITE_ROOT}/third.example"
S4="${SITE_ROOT}/fourth.example"
S5="${SITE_ROOT}/fifth.example"
make_site "$S3"
make_site "$S4"
make_site "$S5"
printf '%s\n' "$SITES" "$SITES2" "$S3" "$S4" "$S5" >"$FLEET"
FLEET_N=5

# Both stubs log their argv to MOCK_LOG and answer like the real wp for the
# subcommands these checks need.
SLEEP_WP="${WORK}/bin/wp-sleep"
cat >"$SLEEP_WP" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >>"${MOCK_LOG:-/dev/null}"
sleep "${STUB_SLEEP:-1}"
echo 'Success: ok'
STUB
chmod 755 "$SLEEP_WP"

HALF_WP="${WORK}/bin/wp-half"
cat >"$HALF_WP" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >>"${MOCK_LOG:-/dev/null}"
for a in "$@"; do
    case "$a" in
        --path=*fourth.example*) echo 'Error: this one site is broken' >&2; exit 1 ;;
    esac
done
echo 'Success: ok'
STUB
chmod 755 "$HALF_WP"

KILL_WP="${WORK}/bin/wp-kill"
cat >"$KILL_WP" <<'STUB'
#!/usr/bin/env bash
kill -9 $$ 2>/dev/null
exit 1
STUB
chmod 755 "$KILL_WP"

# fleet_run WP SITES LOCK LOG EXTRA...
# Every knob the checks vary is a positional argument, so nothing can leak from a
# previous check.
fleet_run() {
    local wp="$1" sites="$2" lock="$3" log="$4"
    shift 4
    MOCK_LOG="$ARGV_LOG" FAKE_WP_LOG="$ARGV_LOG" bash "$M" \
        --wp "$wp" \
        --sites "$sites" \
        --lock-file "$lock" \
        --log-file "$log" \
        --error-log-file "${log}.err" \
        --backup-dir "${FLEET_BACKUP_DIR:-${WORK}/backups}" \
        --color never --no-user-switch \
        "$@"
}
L1="${WORK}/l1" L2="${WORK}/l2" L3="${WORK}/l3" L4="${WORK}/l4"
L5="${WORK}/l5" L6="${WORK}/l6" L7="${WORK}/l7" L8="${WORK}/l8"
L9="${WORK}/l9" L10="${WORK}/l10" L11="${WORK}/l11" L12="${WORK}/l12"
L13="${WORK}/l13" L14="${WORK}/l14" L15="${WORK}/l15" L16="${WORK}/l16"
L17="${WORK}/l17" L18="${WORK}/l18" L19="${WORK}/l19" L20="${WORK}/l20"
logn=0
next_lock() { logn=$((logn + 1)); printf '%s/lock%d' "$WORK" "$logn"; }
next_log() { logn=$((logn + 1)); printf '%s/run%d.log' "$WORK" "$logn"; }

say '--no-user-switch'
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$FLEET" "$lk" "$lg" --plugins >/dev/null 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok '--no-user-switch runs the fleet as the invoking user'; else bad '--no-user-switch' "exit ${rc}"; fi
calls="$(grep -c 'ARGV' "$ARGV_LOG" 2>/dev/null)"
if [ "${calls:-0}" = "$FLEET_N" ]; then
    ok "all ${FLEET_N} sites were processed without a user switch"
else
    bad 'not every site was processed' "${calls:-0} invocation(s), expected ${FLEET_N}"
fi
if grep -Fq "USER=$(id -un)" "$ARGV_LOG" 2>/dev/null; then
    ok "wp ran as $(id -un), as requested"
else
    bad 'the child did not run as the invoking user' "$(head -1 "$ARGV_LOG" 2>/dev/null | grep -o 'USER=[^ ]*')"
fi
lk="$(next_lock)"; lg="$(next_log)"
if fleet_run "$STUB_WP" "$FLEET" "$lk" "$lg" --list-sites 2>/dev/null | grep -q '^/'; then
    ok '--list-sites still reports paths under --no-user-switch'
else
    bad '--list-sites produced nothing under --no-user-switch' ''
fi

say 'parallel batches: -j N really overlaps'
# 5 sites x 1 s each. Sequential has to take >= 4 s; -j 5 about 1 s. If batching
# silently degrades to a loop, this is the check that says so.
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
start="$(date +%s)"
STUB_SLEEP=1 fleet_run "$SLEEP_WP" "$FLEET" "$lk" "$lg" --plugins >/dev/null 2>&1
seq_seconds=$(( $(date +%s) - start ))
if [ "$seq_seconds" -ge 4 ]; then
    ok "sequential baseline: ${seq_seconds}s for ${FLEET_N} sites of 1s each"
else
    bad 'the sequential baseline was suspiciously fast' "${seq_seconds}s -- is the stub sleeping?"
fi
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
start="$(date +%s)"
STUB_SLEEP=1 fleet_run "$SLEEP_WP" "$FLEET" "$lk" "$lg" --plugins -j "$FLEET_N" >/dev/null 2>&1
par_seconds=$(( $(date +%s) - start ))
if [ "$par_seconds" -le 3 ]; then
    ok "-j ${FLEET_N} took ${par_seconds}s instead of ${seq_seconds}s: the batch really ran concurrently"
else
    bad "-j ${FLEET_N} did not overlap" "took ${par_seconds}s, sequential was ${seq_seconds}s"
fi
par_calls="$(grep -ac 'ARGV:' "$ARGV_LOG" 2>/dev/null)"
par_calls="${par_calls//[^0-9]/}"
if [ "${par_calls:-0}" = "$FLEET_N" ]; then
    ok "all ${FLEET_N} sites were processed in the parallel run"
else
    bad 'the parallel run processed the wrong number of sites' "${par_calls:-0} invocation(s), expected ${FLEET_N}; log: $(head -2 "$ARGV_LOG" 2>/dev/null | tr '\n' '|')"
fi
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
start="$(date +%s)"
STUB_SLEEP=1 fleet_run "$SLEEP_WP" "$FLEET" "$lk" "$lg" --plugins -j 2 >/dev/null 2>&1
b2_seconds=$(( $(date +%s) - start ))
if [ "$b2_seconds" -ge 2 ] && [ "$b2_seconds" -le 5 ]; then
    ok "-j 2 over ${FLEET_N} sites took ${b2_seconds}s: three barriers of 1s"
else
    bad '-j 2 timing is off' "${b2_seconds}s; expected about 3s"
fi
expect_rc 2 '--jobs 0 is a usage error' bash "$M" --plugins --jobs 0
expect_rc 2 '--jobs abc is a usage error' bash "$M" --plugins --jobs abc

say 'parallel batches: counters are exact at every degree of parallelism'
# A forked worker inherits the parent's counters. Folding those inherited values
# back in double-counts every batch after the first, so the same fleet is run at
# four different widths and the totals must not move.
for j in 1 2 3 5; do
    argv_log_reset
    lk="$(next_lock)"; lg="$(next_log)"
    out="$(fleet_run "$STUB_WP" "$FLEET" "$lk" "$lg" --plugins -j "$j" 2>&1)"
    rc=$?
    ops="$(printf '%s' "$out" | sed -nE 's/.*operations ok:[[:space:]]+([0-9]+).*/\1/p' | head -1)"
    sites="$(printf '%s' "$out" | sed -nE 's/.*sites processed:[[:space:]]+([0-9]+).*/\1/p' | head -1)"
    if [ "$rc" = '0' ] && [ "$ops" = "$FLEET_N" ] && [ "$sites" = "$FLEET_N" ]; then
        ok "-j ${j}: sites=${sites} operations=${ops}, exit 0"
    else
        bad "-j ${j} reports wrong totals" "exit ${rc}, sites='${sites:-?}' operations='${ops:-?}', expected ${FLEET_N}/${FLEET_N}"
    fi
done

say 'parallel batches: output order and log integrity'
argv_log_reset
lk="$(next_lock)"; plog="${WORK}/par.log"
fleet_run "$STUB_WP" "$FLEET" "$lk" "$plog" --plugins -j "$FLEET_N" >"${WORK}/par.txt" 2>&1
order="$(grep -a 'INF site ' "${WORK}/par.txt" | sed -E 's#.*www/##; s# .*##' | tr '\n' ' ')"
expected="$(sed -E 's#.*www/##' "$FLEET" | tr '\n' ' ')"
if [ "$order" = "$expected" ]; then
    ok 'console output is replayed in site order, not in completion order'
else
    bad 'console output is out of order' "got [${order}] expected [${expected}]"
fi
lines="$(grep -acE '\[(INFO|ERROR|WARNING)\]' "$plog" 2>/dev/null)"
if [ "${lines:-0}" -ge "$FLEET_N" ]; then
    ok "the log file received the worker fragments (${lines} lines for ${FLEET_N} sites)"
else
    bad 'the log file looks empty after a parallel run' "${lines:-0} line(s); buffered lines were lost"
fi
if grep -aq $'\033' "$plog" 2>/dev/null; then
    bad 'ANSI escapes reached the log file' '--color never must hold in the fragments too'
else
    ok 'the log file holds no ANSI escapes'
fi
# lines of one site must stay together: that is the whole point of buffering
first_site_line="$(grep -anE '\[INFO\] site ' "$plog" 2>/dev/null | head -1 | cut -d: -f1)"
if [ -n "${first_site_line:-}" ]; then
    block="$(sed -n "${first_site_line},$((first_site_line + 2))p" "$plog" 2>/dev/null)"
    if [ "$(printf '%s' "$block" | grep -c 'example.com')" -ge 2 ]; then
        ok 'the lines of one site are contiguous in the log'
    else
        bad 'log lines from different sites are interleaved' "$(printf '%s' "$block" | head -3)"
    fi
fi

say 'parallel batches: a failing site is reported and does not stop the others'
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$HALF_WP" "$FLEET" "$lk" "$lg" --plugins -j "$FLEET_N" >"${WORK}/half.txt" 2>&1
rc=$?
if [ "$rc" = '1' ]; then ok 'one failing site makes a parallel run exit 1'; else bad 'parallel run with a failure' "expected exit 1, got ${rc}"; fi
calls="$(grep -c 'ARGV' "$ARGV_LOG" 2>/dev/null)"
if [ "${calls:-0}" = "$FLEET_N" ]; then
    ok "the other sites were still attempted (${calls} calls)"
else
    bad 'the batch stopped early' "${calls:-0} invocation(s), expected ${FLEET_N}"
fi
if grep -Eq 'sites failed:[[:space:]]+1' "${WORK}/half.txt"; then
    ok 'exactly one site is reported as failed'
else
    bad 'the failed-site count is wrong' "$(grep -E 'sites (ok|failed)' "${WORK}/half.txt" | tr -s ' ')"
fi
expect_contains "${WORK}/half.txt" 'fourth.example' 'the failing site is named'

say 'backups: --backup db'
rm -rf "${WORK}/backups"
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$FLEET" "$lk" "$lg" --plugins --backup db >"${WORK}/bk.txt" 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok '--backup db exits 0'; else bad '--backup db exit code' "got ${rc}; $(grep -aE 'WRN|ERR' "${WORK}/bk.txt" | head -2)"; fi
dumps="$(find "${WORK}/backups" -name 'db-*.sql' 2>/dev/null | wc -l)"
dumps="${dumps//[^0-9]/}"
if [ "${dumps:-0}" = "$FLEET_N" ]; then
    ok "--backup db produced one dump per site (${dumps})"
else
    bad '--backup db produced the wrong number of dumps' "got ${dumps:-0}, expected ${FLEET_N}"
fi
first_dump="$(find "${WORK}/backups" -name 'db-*.sql' 2>/dev/null | head -1)"
if [ -n "$first_dump" ] && [ -s "$first_dump" ]; then
    ok 'the dump is not empty'
else
    bad 'the dump is empty' 'a truncated dump is worse than none: it looks like a backup'
fi
expect_contains "${WORK}/bk.txt" 'database backup' 'the backup is reported'

say 'backups: the directory is writable by the site owner, not only by root'
# The manager creates the backup directory, but `wp db export` writes into it as
# the site owner after the user switch. A plain mkdir gives it the manager's
# umask -- 0755 root -- and every export then dies with "Permission denied",
# which the operator reads as "the database backup failed". The directory is
# therefore 0777 with the sticky bit, exactly like /tmp.
rm -rf "${WORK}/perm"
lk="$(next_lock)"; lg="$(next_log)"
FLEET_BACKUP_DIR="${WORK}/perm" \
    fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugins --backup db -S "$SITES" >/dev/null 2>&1
d="${WORK}/perm/$(basename -- "$SITES")"
if [ -d "$d" ]; then
    perm="$(stat -c '%a' "$d" 2>/dev/null)"
    if [ "$perm" = '1777' ]; then
        ok "the per-site backup directory is 1777 (sticky, world-writable), got ${perm}"
    else
        bad 'the backup directory is not writable by the site owner' "mode ${perm:-?}; a non-root site user could not write a dump"
    fi
    if [ -w "$d" ]; then
        ok 'the directory accepts writes'
    else
        bad 'the directory is not writable' ''
    fi
else
    bad 'no per-site backup directory was created' "$d"
fi
dump="$(find "${WORK}/perm" -name 'db-*.sql' 2>/dev/null | head -1)"
if [ -n "$dump" ]; then
    dperm="$(stat -c '%a' "$dump" 2>/dev/null)"
    if [ "$dperm" = '640' ]; then
        ok "the dump itself is 0640, not world-readable (got ${dperm})"
    else
        bad 'the dump permissions are looser than intended' "mode ${dperm:-?}"
    fi
else
    bad 'no dump to check permissions on' ''
fi

say 'backups: a failed backup is not swallowed'
# A 0500 directory would not stop root, so that is not a failing backup at all.
# A regular file in the place of the backup directory fails for every uid.
printf 'not a directory\n' >"${WORK}/blocked"
lk="$(next_lock)"; lg="$(next_log)"
# The second argument of fleet_run is a SITE LIST FILE, not a site directory --
# passing $SITES here made the manager report "site list not found" and the check
# measured its own mistake.
FLEET_BACKUP_DIR="${WORK}/blocked" \
    fleet_run "$STUB_WP" "$FLEET" "$lk" "$lg" --plugins --backup db >"${WORK}/bkfail.txt" 2>&1
rc=$?
if [ "$rc" != '0' ]; then
    ok 'an impossible backup destination fails the site instead of updating it unprotected'
else
    bad 'a failed backup was swallowed' "exit ${rc}; output: $(grep -aE 'WRN|ERR|backup' "${WORK}/bkfail.txt" | head -3 | tr '\n' '|')"
fi
expect_contains "${WORK}/bkfail.txt" 'backup' 'the backup failure is explained'
# The invocation log accumulates across checks unless it is reset, so an update
# recorded three sections ago would look like "the site was updated anyway".
argv_log_reset
FLEET_BACKUP_DIR="${WORK}/blocked" \
    fleet_run "$STUB_WP" "$FLEET" "$lk" "$lg" --plugins --backup db >/dev/null 2>&1
if grep -Eq '\[(plugin|core|theme|db|cron)\] \[update' "$ARGV_LOG" 2>/dev/null; then
    bad 'the site was updated despite the failed backup' ''
else
    ok 'no mutation happened on the site whose backup failed'
fi

say 'backups: --backup full archives the tree'
if command -v tar >/dev/null 2>&1; then
    rm -rf "${WORK}/backups"
    lk="$(next_lock)"; lg="$(next_log)"
    FLEET_BACKUP_DIR="${WORK}/backups" \
    fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugins --backup full -S "$SITES" >/dev/null 2>&1
    archives="$(find "${WORK}/backups" -name 'site-*.tar.gz' 2>/dev/null | wc -l)"
    archives="${archives//[^0-9]/}"
    if [ "${archives:-0}" = '1' ]; then
        ok '--backup full produced one archive'
    else
        bad '--backup full' "${archives:-0} archive(s), expected 1"
    fi
    first="$(find "${WORK}/backups" -name 'site-*.tar.gz' 2>/dev/null | head -1)"
    if [ -n "$first" ] && tar -tzf "$first" >/dev/null 2>&1; then
        ok 'the archive is a readable tar.gz'
    else
        bad 'the archive is not readable' "${first:-none}"
    fi
    if [ -n "$first" ] && tar -tzf "$first" 2>/dev/null | grep -Fq 'wp-config.php'; then
        ok 'the archive contains the installation'
    else
        bad 'the archive does not contain wp-config.php' ''
    fi
else
    skip '--backup full' 'tar(1) not installed'
fi

say 'backups: rotation'
rm -rf "${WORK}/rot"
for i in 1 2 3 4 5; do
    lk="$(next_lock)"; lg="$(next_log)"
    FLEET_BACKUP_DIR="${WORK}/rot" \
        fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugins --backup db \
        --keep-backups 2 -S "$SITES" >/dev/null 2>&1
    sleep 1.1
done
kept="$(find "${WORK}/rot" -name 'db-*.sql' 2>/dev/null | wc -l)"
kept="${kept//[^0-9]/}"
if [ "${kept:-0}" = '2' ]; then
    ok '--keep-backups 2 kept exactly two dumps after five runs'
else
    bad '--keep-backups did not prune' "${kept:-0} dump(s) left, expected 2"
fi
rm -rf "${WORK}/rot2"
for i in 1 2 3; do
    lk="$(next_lock)"; lg="$(next_log)"
    FLEET_BACKUP_DIR="${WORK}/rot2" \
        fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugins --backup db \
        --keep-backups 0 -S "$SITES" >/dev/null 2>&1
    sleep 1.1
done
kept2="$(find "${WORK}/rot2" -name 'db-*.sql' 2>/dev/null | wc -l)"
kept2="${kept2//[^0-9]/}"
if [ "${kept2:-0}" = '3' ]; then
    ok '--keep-backups 0 keeps everything'
else
    bad '--keep-backups 0 pruned anyway' "${kept2:-0} dump(s), expected 3"
fi

say 'a plugin deletion is backed up and deactivated first'
rm -rf "${WORK}/del"
plugin_dir="${SITES}/wp-content/plugins/jetpack"
mkdir -p "$plugin_dir"
printf '<?php // Plugin Name: Jetpack\n' >"${plugin_dir}/jetpack.php"
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
FLEET_BACKUP_DIR="${WORK}/del" \
    fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugin-manage -A delete -N jetpack \
    -S "$SITES" --yes >"${WORK}/del.txt" 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok 'delete exits 0'; else bad 'delete exit code' "got ${rc}; $(grep -aE 'ERR|WRN' "${WORK}/del.txt" | head -2)"; fi
pbackups="$(find "${WORK}/del" -name 'plugin-jetpack-*.tar.gz' 2>/dev/null | wc -l)"
pbackups="${pbackups//[^0-9]/}"
if [ "${pbackups:-0}" = '1' ]; then
    ok 'the plugin files were archived before deletion'
else
    bad 'no plugin archive before deletion' "${pbackups:-0} archive(s)"
fi
if grep -Fq '[plugin] [deactivate] [jetpack]' "$ARGV_LOG" 2>/dev/null; then
    ok 'the plugin was deactivated before being deleted'
else
    bad 'no deactivation before deletion' 'it would leave its options and cron events behind'
fi
if grep -Fq '[plugin] [delete] [jetpack]' "$ARGV_LOG" 2>/dev/null; then
    ok 'the deletion itself was issued'
else
    bad 'the deletion was not issued' "$(tail -2 "$ARGV_LOG" 2>/dev/null)"
fi
expect_contains "${WORK}/del.txt" 'plugin backup' 'the operator is told where the archive is'
rm -rf "${WORK}/del2"
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
FLEET_BACKUP_DIR="${WORK}/del2" \
    fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugin-manage -A delete -N jetpack \
    -S "$SITES" --yes --no-backup >"${WORK}/del2.txt" 2>&1
if [ "$(find "${WORK}/del2" -type f 2>/dev/null | wc -l)" = '0' ]; then
    ok '--no-backup really skips the archive'
else
    bad '--no-backup was ignored' ''
fi
expect_contains "${WORK}/del2.txt" 'without a backup' '--no-backup warns that it is doing so'
rm -rf -- "$plugin_dir"

say '--verify is read-only'
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --verify -S "$SITES" >"${WORK}/ver.txt" 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok '--verify exits 0 on a healthy site'; else bad '--verify exit code' "got ${rc}"; fi
if grep -Fq '[core] [verify-checksums]' "$ARGV_LOG" 2>/dev/null; then
    ok '--verify checks the core checksums'
else
    bad 'core verify-checksums was not issued' "$(head -2 "$ARGV_LOG" 2>/dev/null)"
fi
if grep -Fq '[plugin] [verify-checksums] [--all]' "$ARGV_LOG" 2>/dev/null; then
    ok '--verify checks every plugin'
else
    bad 'plugin verify-checksums was not issued' ''
fi
if grep -Eq '\[(plugin|theme|core|db|cron)\] \[(update|optimize|repair|run)\]' "$ARGV_LOG" 2>/dev/null; then
    bad '--verify issued a mutating command' "$(grep -E 'update|optimize|repair' "$ARGV_LOG" | head -2)"
else
    ok '--verify issued no mutating command'
fi

say 'plugin selection: --only-active and --exclude-plugins'
# The stub reports: akismet active/none, woocommerce inactive/available,
# all-in-one-seo active/none, jetpack active/available, old-plugin inactive/available.
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugins --only-active -S "$SITES" >"${WORK}/oa.txt" 2>&1
if grep -Fq '[plugin] [update] [jetpack]' "$ARGV_LOG" 2>/dev/null; then
    ok '--only-active selected the one plugin that is active AND has an update'
else
    bad '--only-active selection' "$(grep -F 'plugin] [update' "$ARGV_LOG" 2>/dev/null | head -2)"
fi
if grep -Fq -- '[--all]' "$ARGV_LOG" 2>/dev/null; then
    bad '--only-active still used plugin update --all' 'the point of the flag is to enumerate'
else
    ok '--only-active does not use --all'
fi
if grep -Fq '[woocommerce]' "$ARGV_LOG" 2>/dev/null; then
    bad '--only-active picked an inactive plugin' ''
else
    ok 'an inactive plugin with an update was left alone'
fi
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugins --only-active --exclude-plugins jetpack \
    -S "$SITES" >"${WORK}/ex.txt" 2>&1
if grep -Fq '[plugin] [update]' "$ARGV_LOG" 2>/dev/null; then
    bad '--exclude-plugins left something to update' "$(grep -F 'plugin] [update' "$ARGV_LOG" | head -1)"
else
    ok '--exclude-plugins removed the only candidate and nothing ran'
fi
expect_contains "${WORK}/ex.txt" 'nothing to update' 'an empty selection is reported, not silent'
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugins --exclude-plugins 'akismet,jetpack' -S "$SITES" >/dev/null 2>&1
if grep -Fq '[jetpack]' "$ARGV_LOG" 2>/dev/null || grep -Fq '[akismet]' "$ARGV_LOG" 2>/dev/null; then
    bad 'an excluded plugin was still updated' "$(grep -F 'plugin] [update' "$ARGV_LOG" | head -1)"
else
    ok 'both excluded plugins were left out'
fi
lk="$(next_lock)"
expect_rc 2 '--only-active with --themes is a usage error' \
    fleet_run "$STUB_WP" "$SITES" "$lk" "${lg}.t1" --themes --only-active
lk="$(next_lock)"
expect_rc 2 '--exclude-plugins with --cron is a usage error' \
    fleet_run "$STUB_WP" "$SITES" "$lk" "${lg}.t2" --cron --exclude-plugins x

say '--strict turns a warning into a failure'
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugins -S "$SITES" >/dev/null 2>&1
printf '%s\n%s\n' "${WORK}/no-such-site" "$SITES" >"${WORK}/warns.txt"
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "${WORK}/warns.txt" "$lk" "$lg" --plugins --strict >"${WORK}/str.txt" 2>&1
rc=$?
if [ "$rc" != '0' ]; then
    ok "--strict exits non-zero when something was warned about (rc=${rc})"
else
    bad '--strict exited 0 despite warnings' ''
fi
expect_contains "${WORK}/str.txt" '--strict' 'the operator is told why a warning became a failure'
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugins --strict -S "$SITES" >/dev/null 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok '--strict on a clean run still exits 0'
else
    bad '--strict failed a clean run' "exit ${rc}"
fi

say 'JSON Lines fleet report'
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$FLEET" "$lk" "$lg" --plugins -j 3 --json-lines >"${WORK}/jl.txt" 2>/dev/null
rc=$?
if [ "$rc" = '0' ]; then ok '--json-lines exits 0'; else bad '--json-lines exit code' "got ${rc}"; fi
parsed=0
if command -v python3 >/dev/null 2>&1; then
    python3 - "${WORK}/jl.txt" "$FLEET_N" <<'PY' 2>/dev/null && parsed=1
import json, sys
path, n = sys.argv[1], int(sys.argv[2])
objs = [json.loads(l) for l in open(path) if l.strip()]
sites = [o for o in objs if o.get('type') == 'site']
summ = [o for o in objs if o.get('type') == 'summary']
assert len(sites) == n, (len(sites), n)
assert len(summ) == 1, len(summ)
assert summ[0]['sites'] == n and summ[0]['ops_ok'] == n, summ[0]
assert [s['status'] for s in sites] == ['OK'] * n, sites
assert len(summ[0]['results']) == n, summ[0]['results']
PY
elif command -v node >/dev/null 2>&1; then
    node -e '
const fs=require("fs");
const [p,n]=[process.argv[1],Number(process.argv[2])];
const o=fs.readFileSync(p,"utf8").split("\n").filter(Boolean).map(JSON.parse);
const s=o.filter(x=>x.type==="site"), m=o.filter(x=>x.type==="summary");
if(s.length!==n||m.length!==1||m[0].sites!==n||m[0].ops_ok!==n)process.exit(1);
' "${WORK}/jl.txt" "$FLEET_N" 2>/dev/null && parsed=1
fi
if [ "$parsed" = '1' ]; then
    ok "--json-lines emits one object per site plus a summary, all valid JSON (${FLEET_N}+1)"
else
    if command -v python3 >/dev/null 2>&1 || command -v node >/dev/null 2>&1; then
        bad 'the JSON Lines stream does not parse or has the wrong shape' "$(head -c 300 "${WORK}/jl.txt")"
    else
        skip 'JSON Lines validation' 'neither python3 nor node installed'
    fi
fi
if grep -Eq '^(INF|OK |WRN|ERR|DBG|=)' "${WORK}/jl.txt"; then
    bad 'prose leaked into the JSON Lines stream' "$(grep -E '^(INF|OK |WRN|ERR)' "${WORK}/jl.txt" | head -2)"
else
    ok 'the JSON Lines stream on stdout carries no prose'
fi
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$FLEET" "$lk" "$lg" --plugins -J >"${WORK}/j2.txt" 2>/dev/null
if grep -Fq '"type":"summary"' "${WORK}/j2.txt"; then
    ok '-J in a fleet mode selects JSON Lines'
else
    bad '-J in a fleet mode did not select JSON Lines' "$(head -c 200 "${WORK}/j2.txt")"
fi
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --list-plugins -J -S "$SITES" >"${WORK}/j3.txt" 2>/dev/null
if grep -Fq '"type":"summary"' "${WORK}/j3.txt"; then
    bad '-J with --list-plugins produced a fleet report instead of the plugin list' ''
else
    ok '-J with --list-plugins still means the plugin list'
fi
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$HALF_WP" "$FLEET" "$lk" "$lg" --plugins -j "$FLEET_N" --json-lines >"${WORK}/jl2.txt" 2>/dev/null
if grep -Fq '"status":"FAILED"' "${WORK}/jl2.txt"; then
    ok 'a failed site is marked in its own JSON object'
else
    bad 'no site object carried the FAILED status' "$(head -c 300 "${WORK}/jl2.txt")"
fi

say '--list-sites resolves without touching anything'
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
# --list-sites resolves and, when the list is missing, lets the finder create it.
# Give it its own file: an earlier revision pointed it at $SITE_LIST and the
# finder rewrote the fixture that every later check depends on.
LS_LIST="${WORK}/ls-list.txt"
printf '%s\n' "$SITES" "$SITES2" "$S3" "$S4" "$S5" >"$LS_LIST"
fleet_run "$STUB_WP" "$LS_LIST" "$lk" "$lg" --list-sites >"${WORK}/ls.txt" 2>/dev/null
rc=$?
if [ "$rc" = '0' ]; then ok '--list-sites exits 0'; else bad '--list-sites exit code' "got ${rc}"; fi
rows="$(grep -c '^/' "${WORK}/ls.txt" 2>/dev/null)"
if [ "${rows:-0}" = "$FLEET_N" ]; then
    ok "--list-sites printed ${rows} absolute paths on stdout"
else
    bad '--list-sites row count' "got ${rows:-0}, expected ${FLEET_N}"
fi
if [ "$(grep -c 'ARGV' "$ARGV_LOG" 2>/dev/null)" = '0' ]; then
    ok '--list-sites invoked wp zero times'
else
    bad '--list-sites invoked wp' "$(grep -c 'ARGV' "$ARGV_LOG" 2>/dev/null) call(s)"
fi
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$LS_LIST" "$lk" "$lg" --list-sites --json >"${WORK}/lsj.txt" 2>/dev/null
lsj_rc=$?
if head -1 "${WORK}/lsj.txt" | grep -Fq '"path"'; then
    ok '--list-sites --json emits one JSON object per site'
else
    bad '--list-sites --json' "rc=${lsj_rc}, stdout: $(head -c 200 "${WORK}/lsj.txt")"
fi

say '--url reaches WP-CLI'
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$SITES" "$lk" "$lg" --plugins -S "$SITES" --url 'https://shop.example.com' >/dev/null 2>&1
if grep -Fq -- '--url=https://shop.example.com' "$ARGV_LOG" 2>/dev/null; then
    ok '--url is passed to every wp call'
else
    bad '--url did not reach wp' "$(head -1 "$ARGV_LOG" 2>/dev/null)"
fi

say 'the new settings participate in the configuration layers'
cfg="${WORK}/fleet.conf"
cat >"$cfg" <<EOF
JOBS=3
BACKUP=db
KEEP_BACKUPS=2
ONLY_ACTIVE=1
STRICT=1
EXCLUDE_PLUGINS=akismet
EOF
out="$(bash "$M" --print-config --config "$cfg" --no-user-switch 2>/dev/null)"
for pair in 'JOBS:3' 'BACKUP:db' 'KEEP_BACKUPS:2' 'ONLY_ACTIVE:true' 'STRICT:true' 'EXCLUDE_PLUGINS:akismet'; do
    key="${pair%%:*}"; want="${pair#*:}"
    if printf '%s' "$out" | grep -E "^${key}[[:space:]]" | grep -Fq "$want"; then
        ok "the config file sets ${key}=${want}"
    else
        bad "the config file did not set ${key}" "$(printf '%s' "$out" | grep -E "^${key}[[:space:]]" | head -1)"
    fi
done
# The manager reads WP_CLI_UPDATE_<KEY>, not <KEY>: a bare JOBS=7 prefix is an
# unexported shell variable and was never part of the contract.
out="$(WP_CLI_UPDATE_JOBS=7 bash "$M" --print-config --config "$cfg" --no-user-switch 2>/dev/null)"
if printf '%s' "$out" | grep -E '^JOBS[[:space:]]' | grep -Fq '7'; then
    ok 'the environment beats the config file for JOBS'
else
    bad 'the environment did not beat the file' "$(printf '%s' "$out" | grep -E '^JOBS' | head -1)"
fi
out="$(WP_CLI_UPDATE_JOBS=7 bash "$M" --print-config --config "$cfg" --no-user-switch -j 2 2>/dev/null)"
if printf '%s' "$out" | grep -E '^JOBS[[:space:]]' | grep -Fq '2'; then
    ok 'the command line beats the environment for JOBS'
else
    bad 'the command line did not win' "$(printf '%s' "$out" | grep -E '^JOBS' | head -1)"
fi
printf 'BACKUP=everywhere\n' >"${WORK}/bad.conf"
expect_rc 4 'an invalid BACKUP in the config file exits 4' \
    bash "$M" --print-config --config "${WORK}/bad.conf" --no-user-switch
lk="$(next_lock)"
expect_rc 2 'an invalid --backup on the command line exits 2' \
    fleet_run "$STUB_WP" "$SITES" "$lk" "${WORK}/badbl.log" --plugins --backup everywhere

say 'every shell metacharacter in a config file is refused'
# This deserves its own loop: the guard is a case pattern built from a variable,
# and a quoting mistake there turns the strongest metacharacter into the one that
# slips through. A backtick did exactly that once -- BACKTICK was written as
# "$'\140'", which is the seven-character literal $'\140' and not a backtick.
for payload in 'SKIP_PLUGINS=a`id`b' 'SKIP_PLUGINS=a;id' 'SKIP_PLUGINS=a|id' \
               'SKIP_PLUGINS=$(id)' 'SKIP_PLUGINS=a>id' 'SKIP_PLUGINS=a&id' 'SKIP_PLUGINS=a<id'; do
    printf '%s\n' "$payload" >"${WORK}/evil.conf"
    bash "$M" --print-config --config "${WORK}/evil.conf" --no-user-switch >/dev/null 2>&1
    rc=$?
    if [ "$rc" = '4' ]; then
        ok "refused: ${payload}"
    else
        bad "not refused: ${payload}" "exit ${rc}"
    fi
done
printf 'SKIP_PLUGINS=plain,value\nJOBS=2\n' >"${WORK}/good.conf"
expect_rc 0 'an ordinary config file is accepted' \
    bash "$M" --print-config --config "${WORK}/good.conf" --no-user-switch

say 'dry run still executes nothing, in parallel too'
argv_log_reset
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$STUB_WP" "$FLEET" "$lk" "$lg" --full --dry-run -j "$FLEET_N" >"${WORK}/dry.txt" 2>&1
calls="$(grep -c 'ARGV' "$ARGV_LOG" 2>/dev/null)"
if [ "${calls:-0}" = '0' ]; then
    ok 'a parallel dry run invoked wp zero times'
else
    bad 'a parallel dry run invoked wp' "${calls} call(s)"
fi
expect_contains "${WORK}/dry.txt" 'dry-run' 'the parallel dry run shows the plan'
if grep -Eq "sites processed:[[:space:]]+${FLEET_N}" "${WORK}/dry.txt"; then
    ok "the parallel dry run still counted ${FLEET_N} sites"
else
    bad 'the parallel dry run counted the wrong number of sites' "$(grep -E 'sites processed' "${WORK}/dry.txt" | tr -s ' ')"
fi

say 'parallel mode leaves no worker directories behind'
leftovers="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'Bash_WP-CLI_Update.sh.workers.*' -newermt '-5 minutes' 2>/dev/null | wc -l)"
leftovers="${leftovers//[^0-9]/}"
if [ "${leftovers:-0}" = '0' ]; then
    ok 'no worker directory survived the run'
else
    bad 'worker directories leaked' "${leftovers} in ${TMPDIR:-/tmp}"
fi

say 'the lock still protects a parallel run'
if command -v flock >/dev/null 2>&1; then
    plk="${WORK}/lock.par"
    (
        flock -x 9
        sleep 3
    ) 9>"$plk" &
    holder=$!
    sleep 1
    lg="$(next_log)"
    fleet_run "$STUB_WP" "$FLEET" "$plk" "$lg" --plugins -j 3 >"${WORK}/conc.txt" 2>&1
    rc=$?
    if [ "$rc" = '3' ]; then
        ok 'a parallel run is refused while the lock is held (exit 3)'
    else
        bad 'a parallel run ignored the lock' "exit ${rc}"
    fi
    expect_contains "${WORK}/conc.txt" 'refusing to run concurrently' 'the refusal is explained'
    wait "$holder" 2>/dev/null
else
    skip 'lock under parallelism' 'flock(1) not installed'
fi

say 'a worker that dies without a result is not counted as a success'
# A killed worker leaves no result file. The parent has to notice, because the
# alternative is a summary that reports "5 sites ok" after the machine ate three.
lk="$(next_lock)"; lg="$(next_log)"
fleet_run "$KILL_WP" "$SITES" "$lk" "$lg" --plugins -j 2 -S "$SITES" >"${WORK}/kill.txt" 2>&1
rc=$?
if [ "$rc" != '0' ]; then
    ok "a worker killed with SIGKILL fails the run (exit ${rc})"
else
    bad 'a killed worker was reported as a success' ''
fi

report 'fleet'

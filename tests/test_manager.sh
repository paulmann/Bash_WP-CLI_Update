#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2016
# Mode behaviour against the stub WP-CLI: which wp commands each mode runs, in
# which order, with which flags, and what happens when one of them fails.
# The stub records its own argv, so every assertion here is about the real
# command line the product built -- not about a message it printed.
#
# Stream discipline: stdout carries data (tables, JSON, CSV), stderr carries
# prose (logs, warnings, the summary). The assertions below check each stream
# for what belongs to it, which is itself part of the contract.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="${TEST_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wpcli-mgr.XXXXXX")}"
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

OUT="${WORK}/out.txt"     # stdout: data only
ERR="${WORK}/err.txt"     # stderr: prose only
BACKUPS="${WORK}/backups"

# mrun: the standard hermetic invocation for behaviour tests.
mrun() {
    argv_log_reset
    manager_run --no-user-switch --backup-dir "$BACKUPS" "$@" >"$OUT" 2>"$ERR"
}

say '--full runs the WordPress update order, and not db repair'
mrun --full; rc=$?
[ "$rc" -eq 0 ] && ok '--full exits 0 on a healthy fleet' || bad '--full exit code' "got $rc; tail: $(tail -n 5 "$ERR")"
expect_grep_count "$ARGV_LOG" '\[core\] \[update\]' 2 '--full: core update once per site'
expect_grep_count "$ARGV_LOG" '\[core\] \[update-db\] \[--skip-plugins\]' 2 '--full: schema update skips plugins'
expect_grep_count "$ARGV_LOG" '\[plugin\] \[update\] \[--all\]' 2 '--full: plugin update --all'
expect_grep_count "$ARGV_LOG" '\[theme\] \[update\] \[--all\]' 2 '--full: theme update --all'
expect_grep_count "$ARGV_LOG" '\[language\] \[core\] \[update\]' 2 '--full: core translations'
expect_grep_count "$ARGV_LOG" '\[language\] \[plugin\] \[update\] \[--all\]' 2 '--full: plugin translations'
expect_grep_count "$ARGV_LOG" '\[cron\] \[event\] \[run\] \[--due-now\]' 2 '--full: due cron events'
expect_grep_count "$ARGV_LOG" '\[cache\] \[flush\]' 2 '--full: object cache flushed'
expect_grep_count "$ARGV_LOG" '\[transient\] \[delete\] \[--expired\]' 2 '--full: expired transients'
expect_grep_count "$ARGV_LOG" '\[rewrite\] \[flush\]' 2 '--full: rewrite rules flushed'
expect_grep_count "$ARGV_LOG" '\[db\] \[optimize\]' 2 '--full: db optimize'
expect_grep_count "$ARGV_LOG" '\[db\] \[repair\]' 0 '--full does NOT run db repair by default'
expect_grep_count "$ARGV_LOG" 'brainstormforce' 0 'no Astra step without a licence'
# core files before schema: the update line must precede update-db per site
first_upd="$(grep -n '\[core\] \[update\]' "$ARGV_LOG" | head -n 1 | cut -d: -f1)"
first_db="$(grep -n '\[core\] \[update-db\]' "$ARGV_LOG" | head -n 1 | cut -d: -f1)"
if [ -n "$first_upd" ] && [ -n "$first_db" ] && [ "$first_upd" -lt "$first_db" ]; then
    ok 'core update runs before core update-db'
else
    bad 'core update must run before the schema update' "upd=$first_upd db=$first_db"
fi
expect_contains "$ERR" 'sites ok:' 'the summary is printed on stderr'
expect_contains "$ERR" 'run finished without errors' 'a healthy fleet reports success'
if [ -s "$OUT" ]; then
    bad '--full keeps stdout clean (it is all prose)' "$(head -n 3 "$OUT")"
else
    ok '--full writes nothing to stdout: prose stays on stderr'
fi

say 'FULL_DB_REPAIR=1 puts db repair back'
WP_CLI_UPDATE_FULL_DB_REPAIR=1 mrun --full
expect_grep_count "$ARGV_LOG" '\[db\] \[repair\]' 2 'db repair runs when the operator asks for it'

say '--core does the core pair only'
mrun --core
expect_grep_count "$ARGV_LOG" '\[core\] \[update\]' 2 '--core: core update'
expect_grep_count "$ARGV_LOG" '\[plugin\] \[update\]' 0 '--core touches no plugin'
expect_grep_count "$ARGV_LOG" '\[db\] \[optimize\]' 0 '--core does not optimize'

say '--plugins: --all by default, enumeration with selectors'
mrun --plugins
expect_grep_count "$ARGV_LOG" '\[plugin\] \[update\] \[--all\]' 2 '--plugins uses --all'
mrun --plugins --only-active
expect_grep_count "$ARGV_LOG" '\[plugin\] \[update\] \[jetpack\]' 2 '--only-active updates exactly the active plugin with an update'
expect_grep_count "$ARGV_LOG" '\[plugin\] \[update\] \[--all\]' 0 '--only-active does not use --all'
if grep -q '\[plugin\] \[update\].*\[woocommerce\]' "$ARGV_LOG"; then
    bad '--only-active must not update an inactive plugin' ''
else
    ok 'an inactive plugin is not updated by --only-active'
fi
mrun --plugins -e jetpack
expect_grep_count "$ARGV_LOG" '\[plugin\] \[update\] \[akismet\] \[woocommerce\] \[all-in-one-seo-pack\] \[old-plugin\]' 2 \
    '--exclude-plugins enumerates the rest by slug'

say '--themes, --db-optimize, --db-fix, --cron, --cache, --languages'
mrun --themes
expect_grep_count "$ARGV_LOG" '\[theme\] \[update\] \[--all\]' 2 '--themes'
mrun --db-optimize
expect_grep_count "$ARGV_LOG" '\[db\] \[optimize\]' 2 '--db-optimize optimizes'
expect_grep_count "$ARGV_LOG" '\[db\] \[repair\]' 2 '--db-optimize repairs'
mrun --db-fix
expect_grep_count "$ARGV_LOG" '\[db\] \[repair\]' 2 '--db-fix repairs'
expect_grep_count "$ARGV_LOG" '\[db\] \[optimize\]' 0 '--db-fix does not optimize'
mrun --cron
expect_grep_count "$ARGV_LOG" '\[cron\] \[event\] \[run\]' 2 '--cron runs due events'
mrun --cache
expect_grep_count "$ARGV_LOG" '\[cache\] \[flush\]' 2 '--cache flushes the object cache'
expect_grep_count "$ARGV_LOG" '\[rewrite\] \[flush\]' 2 '--cache flushes rewrite rules'
expect_grep_count "$ARGV_LOG" '\[core\] \[update\]' 0 '--cache updates nothing'
mrun --languages
expect_grep_count "$ARGV_LOG" '\[language\] \[theme\] \[update\] \[--all\]' 2 '--languages covers themes'

say '--skip-plugins lands on mutating plugin commands only'
mrun --plugins --skip-plugins foo,bar
expect_grep_count "$ARGV_LOG" '\[plugin\] \[update\] \[--all\] \[--skip-plugins=foo,bar\]' 2 \
    '--skip-plugins is attached to plugin update'
mrun --db-optimize --skip-plugins foo
expect_grep_count "$ARGV_LOG" 'skip-plugins' 0 '--skip-plugins is not attached to db commands'

say '--url reaches every call'
mrun --cron -U https://sub.example.test
expect_grep_count "$ARGV_LOG" '\[--url=https://sub.example.test\]' 2 '--url is passed through'

say 'the environment contract reaches the child'
mrun --cron
grep -q "DOCUMENT_ROOT=${SITES} " "$ARGV_LOG" && ok 'DOCUMENT_ROOT is exported to the child' \
    || bad 'DOCUMENT_ROOT missing from the child environment' "$(head -n 1 "$ARGV_LOG")"
grep -q 'HOME=' "$ARGV_LOG" && ok 'HOME is set for the child' || bad 'HOME missing' ''

say 'a failing operation fails the site, the fleet continues, exit 1'
WP_FAIL_CMD='core update' mrun --core --user-env 'FAKE_WP_LOG WP_FAIL_CMD'
rc=$?
[ "$rc" -eq 1 ] && ok 'a failing operation exits 1' || bad 'failure exit code' "got $rc"
expect_contains "$ERR" 'sites failed:' 'the summary counts failures'
expect_contains "$ERR" 'run finished with errors' 'the run reports the failure'
expect_grep_count "$ARGV_LOG" '\[core\] \[update\]' 2 'the second site was still attempted'
grep -q 'ERROR DETAIL' "$ERR_FILE" 2>/dev/null && ok 'the error log holds the failure detail' \
    || bad 'no ERROR DETAIL block in the error log' "$(head -n 3 "$ERR_FILE" 2>/dev/null)"

say '--verify is read-only and reports tampering'
mrun --verify
rc=$?
[ "$rc" -eq 0 ] && ok '--verify exits 0 on a clean fleet' || bad '--verify exit code' "got $rc"
expect_grep_count "$ARGV_LOG" '\[core\] \[verify-checksums\]' 2 '--verify checks core checksums'
expect_grep_count "$ARGV_LOG" '\[plugin\] \[verify-checksums\] \[--all\]' 2 '--verify checks plugin checksums'
expect_grep_count "$ARGV_LOG" '\[core\] \[update\]' 0 '--verify changes nothing'
WP_BAD_CHECKSUMS=1 mrun --verify --user-env 'FAKE_WP_LOG WP_BAD_CHECKSUMS'
rc=$?
[ "$rc" -eq 1 ] && ok 'tampered checksums fail the site' || bad 'tampered --verify exit code' "got $rc"
expect_contains "$ERR" 'checksums do not match' 'the mismatch is reported'

say '--cleanup is safe without --yes and effective with it'
mrun --cleanup
expect_grep_count "$ARGV_LOG" '\[comment\] \[delete\]' 0 '--cleanup without --yes deletes nothing'
expect_grep_count "$ARGV_LOG" '\[post\] \[delete\]' 0 '--cleanup without --yes touches no post'
expect_contains "$ERR" 'nothing was deleted' '--cleanup without --yes says so'
expect_contains "$ERR" 'spam comment' '--cleanup reports what it found'
mrun --cleanup --yes
expect_grep_count "$ARGV_LOG" '\[comment\] \[delete\] \[--force\] \[201\] \[202\]' 4 \
    '--cleanup --yes deletes the enumerated spam and trash comments (2 statuses x 2 sites)'
expect_grep_count "$ARGV_LOG" '\[transient\] \[delete\] \[--expired\]' 2 '--cleanup --yes clears expired transients'
expect_grep_count "$ARGV_LOG" '\[db\] \[optimize\]' 2 'a cleanup is followed by db optimize'
mrun --cleanup --yes --dry-run
expect_grep_count "$ARGV_LOG" '\[comment\] \[delete\]' 0 '--dry-run enumeration deletes nothing'
expect_contains "$ERR" 'would run: wp comment delete' '--dry-run shows the delete it would run'
WP_CLI_UPDATE_CLEANUP_REVISIONS_KEEP=1 mrun --cleanup --yes
expect_grep_count "$ARGV_LOG" '\[post\] \[delete\] \[--force\] \[102\]' 2 \
    'keep=1 per post deletes exactly the surplus revision'

say '--list-plugins renders every format'
mrun --list-plugins
expect_contains "$OUT" 'WooCommerce' 'the table lists a plugin by name'
expect_contains "$OUT" 'Akismet Anti-Spam' 'a name with spaces survives the table'
mrun --list-plugins --format csv
head -n 1 "$OUT" | grep -Eq '^name,status,update,version' && ok 'csv starts with the header row on stdout' \
    || bad 'csv header' "$(head -n 1 "$OUT")"
mrun --list-plugins -N woo --format csv
rows="$(grep -c 'WooCommerce' "$OUT")"
[ "$rows" -eq 2 ] && ok '-N woo matches exactly one plugin on each of the two sites' \
    || bad '-N woo row count' "got $rows, want 2"
mrun --list-plugins --fields name,slug --format tsv
head -n 1 "$OUT" | grep -Eq '^name.slug' && ok '--fields selects the columns' \
    || bad '--fields header' "$(head -n 1 "$OUT")"

say '--plugin-manage resolves a fuzzy name to one slug'
mrun -m -A deactivate -N woo -y
expect_grep_count "$ARGV_LOG" '\[plugin\] \[deactivate\] \[woocommerce\]' 2 'woo resolves to woocommerce'
mrun -m -A install -N hello-dolly -y
expect_grep_count "$ARGV_LOG" '\[plugin\] \[install\] \[hello-dolly\]' 2 'install passes the slug through'
mrun -m -A install -N 'evil;slug' -y
rc=$?
[ "$rc" -eq 1 ] && ok 'a shell-metacharacter slug is refused per site' || bad 'evil slug exit' "got $rc"
expect_contains "$ERR" 'wordpress.org slug' 'the refusal explains the rule'
mrun -m -A delete -N nosuchplugin -y
rc=$?
[ "$rc" -eq 1 ] && ok 'deleting an unknown plugin fails the site' || bad 'unknown plugin delete' "got $rc"
expect_contains "$ERR" 'no plugin matching' 'the unknown name is reported'

say '--plugin-manage delete backs the plugin up first, then deactivates, then deletes'
mkdir -p "${SITES}/wp-content/plugins/jetpack"
printf '<?php // stub plugin\n' >"${SITES}/wp-content/plugins/jetpack/jetpack.php"
mrun -m -A delete -N jetpack -y -S "$SITES"
if ls "${BACKUPS}"/*/plugin-jetpack-*.tar.gz >/dev/null 2>&1; then
    ok 'the deleted plugin was archived before deletion'
else
    bad 'no plugin archive was created' "looked in ${BACKUPS}/*/plugin-jetpack-*.tar.gz"
fi
deact="$(grep -n '\[plugin\] \[deactivate\] \[jetpack\]' "$ARGV_LOG" | head -n 1 | cut -d: -f1)"
del="$(grep -n '\[plugin\] \[delete\] \[jetpack\]' "$ARGV_LOG" | head -n 1 | cut -d: -f1)"
if [ -n "$deact" ] && [ -n "$del" ] && [ "$deact" -lt "$del" ]; then
    ok 'deactivate runs before delete'
else
    bad 'delete must be preceded by deactivate' "deact=$deact del=$del"
fi

say '--maintenance-mode wraps the update'
mrun --core --maintenance-mode
expect_grep_count "$ARGV_LOG" '\[maintenance-mode\] \[activate\]' 2 'maintenance mode is activated per site'
expect_grep_count "$ARGV_LOG" '\[maintenance-mode\] \[deactivate\]' 2 'maintenance mode is deactivated per site'
act="$(grep -n '\[maintenance-mode\] \[activate\]' "$ARGV_LOG" | head -n 1 | cut -d: -f1)"
upd="$(grep -n '\[core\] \[update\]' "$ARGV_LOG" | head -n 1 | cut -d: -f1)"
dea="$(grep -n '\[maintenance-mode\] \[deactivate\]' "$ARGV_LOG" | head -n 1 | cut -d: -f1)"
if [ -n "$act" ] && [ -n "$upd" ] && [ -n "$dea" ] && [ "$act" -lt "$upd" ] && [ "$upd" -lt "$dea" ]; then
    ok 'the update happens between activate and deactivate'
else
    bad 'maintenance mode ordering' "act=$act upd=$upd dea=$dea"
fi

say '--dry-run executes queries but no mutation'
mrun --full --dry-run
rc=$?
[ "$rc" -eq 0 ] && ok '--dry-run exits 0' || bad '--dry-run exit code' "got $rc"
expect_grep_count "$ARGV_LOG" '\[core\] \[update\]' 0 'dry-run performs no core update'
expect_grep_count "$ARGV_LOG" '\[plugin\] \[update\]' 0 'dry-run performs no plugin update'
expect_grep_count "$ARGV_LOG" '\[db\] \[optimize\]' 0 'dry-run performs no optimize'
expect_contains "$ERR" 'would run:' 'dry-run prints the real argv it would execute'

say '--report is a read-only fleet inventory'
mrun --report
rc=$?
[ "$rc" -eq 0 ] && ok '--report exits 0' || bad '--report exit code' "got $rc"
expect_contains "$OUT" 'PLUGIN_UPDATES' 'the report table has the update column'
expect_contains "$OUT" '6.5.2' 'the report shows the core version from wp'
expect_grep_count "$ARGV_LOG" '\[core\] \[update\]' 0 '--report changes nothing'
mrun --report --format json
json_lines="$(grep -c '"type":"report"' "$OUT")"
[ "$json_lines" -eq 2 ] && ok '--report --format json emits one object per site on stdout' \
    || bad '--report json object count' "got $json_lines, want 2"
grep -q '"php_version":"8.2.14"' "$OUT" && ok 'the report includes the PHP version from wp cli info' \
    || bad 'php_version missing from the report json' ''
WP_CORE_UPDATE=6.5.3 WP_CORE_UPDATE_TYPE=minor mrun --report --format json \
    --user-env 'FAKE_WP_LOG WP_CORE_UPDATE WP_CORE_UPDATE_TYPE'
grep -q '"core_update":true' "$OUT" && ok 'a pending core update shows in the report' \
    || bad 'core_update flag' "$(grep -o '"core_update":[a-z]*' "$OUT" | head -n 1)"

say '--security audits without touching anything'
mrun --security
rc=$?
[ "$rc" -eq 0 ] && ok '--security exits 0 on the fixture (warnings only)' || bad '--security exit code' "got $rc"
expect_contains "$OUT" 'score' 'the audit prints a score table on stdout'
expect_contains "$OUT" 'DISALLOW_FILE_EDIT' 'the audit checks the file-edit constant'
expect_grep_count "$ARGV_LOG" '\[core\] \[update\]' 0 '--security changes nothing'
WP_CORE_UPDATE=6.5.3 WP_CORE_UPDATE_TYPE=minor mrun --security \
    --user-env 'FAKE_WP_LOG WP_CORE_UPDATE WP_CORE_UPDATE_TYPE'
rc=$?
[ "$rc" -eq 1 ] && ok 'a pending security (minor) release is a critical finding' \
    || bad 'pending minor release should fail the audit' "got $rc"
expect_contains "$OUT" 'security release' 'the critical finding names the reason'

say 'per-command timeout is enforced when the host can enforce it'
if have_tool timeout || have_tool perl; then
    WP_HANG=6 mrun --core --timeout 1 --kill-after 1 --user-env 'FAKE_WP_LOG WP_HANG'
    rc=$?
    [ "$rc" -eq 1 ] && ok 'a hung wp process fails the site instead of hanging the run' \
        || bad 'hung wp exit code' "got $rc"
    expect_contains "$ERR" 'timed out' 'the timeout is reported'
else
    skip 'timeout enforcement' 'neither timeout(1) nor perl(1) installed'
fi

say 'a vanished site is skipped, the fleet continues'
printf '%s\n%s\n%s\n' "$SITES" "${SITE_ROOT}/ghost.example" "$SITES2" >"${WORK}/ghost.txt"
manager_run --no-user-switch --no-discover --sites "${WORK}/ghost.txt" --cron \
    --backup-dir "$BACKUPS" >"$OUT" 2>"$ERR"
rc=$?
expect_contains "$ERR" 'not a directory' 'the vanished entry is reported'
[ "$rc" -eq 0 ] && ok 'a skipped entry does not fail the run' || bad 'skip exit code' "got $rc"
manager_run --no-user-switch --no-discover --strict --sites "${WORK}/ghost.txt" --cron \
    --backup-dir "$BACKUPS" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && ok '--strict turns the skip warning into a failure' || bad '--strict with a skip' "got $rc"

report test_manager

#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016,SC1091,SC2034  # a test suite greps for literal shell
# patterns and sources its harness by a path resolved at run time
# Behavioural tests for Bash_WP-CLI_Update.sh.
#
# The stub `wp` records its own argv, cwd, user and the environment contract, so
# every assertion below is about what would really be executed -- not about what
# the script printed.
#
# Portability rules this suite follows (learned the hard way, see CHANGELOG):
#   * the working directory is chmod 755, because a 0700 root-owned mktemp
#     directory makes every user-switch test fail before the script runs;
#   * the stub never *requires* an environment variable, because the manager
#     deliberately builds a clean environment for the child;
#   * checks that need `su`/`runuser`, `flock`, `timeout`, `node` or `python`
#     announce themselves as SKIP instead of FAIL when the tool is absent.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-manager.XXXXXX")"
chmod 755 "$WORK"
# Counters: honour the ones a parent runner exported (tests/run_tests.sh tallies
# every suite from them) and fall back to a private set when the suite runs alone.
# Overwriting them unconditionally is what made run_tests.sh report 0/0/0 while
# the suite itself printed a correct total.
FAIL_FILE="${FAIL_FILE:-${WORK}/fail}"
PASS_FILE="${PASS_FILE:-${WORK}/pass}"
SKIP_FILE="${SKIP_FILE:-${WORK}/skip}"
export FAIL_FILE PASS_FILE SKIP_FILE
# shellcheck source=tests/harness.sh
. "${here}/harness.sh"
trap 'rm -rf -- "$WORK"' EXIT
build_fixture

M="$MANAGER"
CAN_SWITCH=0
if [ -n "$SU_USER" ]; then CAN_SWITCH=1; fi
need_switch() { # NAME
    if [ "$CAN_SWITCH" = '1' ]; then return 0; fi
    skip "$1" "no switchable test user (need root and an account with a real shell)"
    return 1
}

say 'help, version, machine-readable modes'
expect_rc 0 '--help exits 0' bash "$M" --help
expect_rc 0 '--version exits 0' bash "$M" --version
expect_rc 0 '--list-modes exits 0' bash "$M" --list-modes
expect_rc 2 'no mode exits 2' bash "$M"
expect_rc 2 'an unknown option exits 2' bash "$M" --nonsense
expect_rc 2 'an unexpected positional argument exits 2' bash "$M" frobnicate
expect_rc 2 'conflicting modes exit 2' bash "$M" --full --core
expect_rc 2 '--plugin-manage without --action exits 2' bash "$M" --plugin-manage --name x
expect_rc 2 '--plugin-manage without --name exits 2' bash "$M" --plugin-manage -A deactivate
expect_rc 2 'a bad --action exits 2' bash "$M" -m -A frobnicate -N x
expect_rc 2 'a bad --format exits 2' bash "$M" -l --format yaml
expect_rc 2 'a bad --color exits 2' bash "$M" --plugins --color rainbow
expect_rc 2 'a bad --timeout exits 2' bash "$M" --plugins --timeout soon
expect_rc 2 'an option without its value exits 2' bash "$M" --plugins --sites
# Capture once: running the script ten times in a loop also hides the reason
# when it produces nothing at all.
modes_out="$(bash "$M" --list-modes 2>&1)"
modes_rc=$?
if [ "$modes_rc" != '0' ] || [ -z "$modes_out" ]; then
    bad '--list-modes produced nothing' "rc=${modes_rc}, output: $(printf '%s' "$modes_out" | head -3 | tr '\n' '|')"
fi
for mode in full core plugins themes db-optimize db-fix cron astra list-plugins plugin-manage verify; do
    if printf '%s\n' "$modes_out" | grep -Fxq "$mode"; then
        ok "--list-modes advertises ${mode}"
    else
        bad "--list-modes is missing ${mode}" "got: $(printf '%s' "$modes_out" | tr '\n' ' ')"
    fi
done

say 'a missing wp binary is an environment error'
expect_rc 3 'a nonexistent --wp exits 3' \
    bash "$M" --plugins --sites "$SITE_LIST" --wp "${WORK}/no-such-wp" \
        --log-file "$LOG_FILE" --error-log-file "$ERR_FILE" --lock-file "$LOCK_FILE" --color never

say 'the operations of every mode'
# The stub records argv one bracketed element per argument, so an expectation is
# written the same way: [plugin] [update], not "plugin update".
check_mode() { # MODE EXPECTED_ARGV NAME
    argv_log_reset
    manager_run "$1" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" = '0' ]; then ok "$3 exits 0"; else bad "$3 exit code" "expected 0, got ${rc}"; fi
    if grep -Fq "$2" "$ARGV_LOG" 2>/dev/null; then
        ok "$3 ran: $2"
    else
        if need_switch "$3 ran: $2"; then
            bad "$3 did not run" "no invocation matching '$2'; log: $(head -2 "$ARGV_LOG" 2>/dev/null)"
        fi
    fi
}
check_mode --plugins   '[plugin] [update]' 'plugins mode'
check_mode --themes    '[theme] [update]'  'themes mode'
check_mode --db-fix    '[db] [repair]'     'db-fix mode'
check_mode --cron      '[cron] [event]'    'cron mode'
check_mode --core      '[core] [update]'   'core mode'
argv_log_reset
manager_run --db-optimize >/dev/null 2>&1
if grep -Fq '[db] [optimize]' "$ARGV_LOG" && grep -Fq '[db] [repair]' "$ARGV_LOG"; then
    ok 'db-optimize runs both optimize and repair'
else
    bad 'db-optimize' "$(head -4 "$ARGV_LOG" 2>/dev/null)"
fi
argv_log_reset
manager_run --full >/dev/null 2>&1
for step in '[core] [update]' '[plugin] [update]' '[theme] [update]' '[db] [optimize]' '[db] [repair]' '[cron] [event]'; do
    if grep -Fq "$step" "$ARGV_LOG" 2>/dev/null; then ok "full mode ran: ${step}"; else bad "full mode missed: ${step}" ''; fi
done
invocations="$(grep -c 'ARGV' "$ARGV_LOG" 2>/dev/null)"
if [ "${invocations:-0}" -ge 12 ]; then
    ok "full mode over two sites issued ${invocations} calls"
else
    bad 'full mode issued too few calls' "got ${invocations:-0} for 2 sites"
fi

say 'the exact argv handed to wp'
argv_log_reset
manager_run --plugins >/dev/null 2>&1
if grep -Fqx 'ARGV: [--path='"$SITES"'] [--allow-root] [plugin] [update] [--all] | CWD='"$SITES"' USER='"${SU_USER:-$(id -un)}"' | ASTRFAIL=<unset> | DOCUMENT_ROOT='"$SITES"' HOMEDIR='"$(dirname "$(dirname "$SITES")")"' HTTP_HOST='"$(basename "$SITES")"' DOCUMENT_URI='"$(basename "$SITES")"' HOME='"$(getent passwd "${SU_USER:-$(id -un)}" | cut -d: -f6)"' LOGNAME='"${SU_USER:-$(id -un)}"' | LICENCE=<unset>' "$ARGV_LOG" 2>/dev/null; then
    ok 'argv, cwd, user and environment are all exactly right'
else
    if need_switch 'exact argv'; then
        bad 'unexpected argv line' "$(head -1 "$ARGV_LOG" 2>/dev/null)"
    fi
fi

say '--skip-plugins goes only where it belongs'
argv_log_reset
manager_run --plugins --skip-plugins 'alpha,beta' >/dev/null 2>&1
if grep -Fq -- '--skip-plugins=alpha,beta' "$ARGV_LOG" 2>/dev/null; then
    ok 'plugin update received --skip-plugins'
else
    bad 'plugin update did not receive --skip-plugins' "$(head -1 "$ARGV_LOG" 2>/dev/null)"
fi
argv_log_reset
manager_run --db-fix --skip-plugins 'alpha,beta' >/dev/null 2>&1
if grep -Fq -- '--skip-plugins' "$ARGV_LOG" 2>/dev/null; then
    bad 'db repair received --skip-plugins' 'it is meaningless there and WP-CLI warns about it'
else
    ok 'db repair did not receive --skip-plugins'
fi
argv_log_reset
manager_run --core --skip-plugins 'alpha,beta' >/dev/null 2>&1
if grep -F '[core] [update-db]' "$ARGV_LOG" 2>/dev/null | grep -Fq -- '[--skip-plugins]'; then
    ok 'core update-db received --skip-plugins (matches what WordPress does during an upgrade)'
else
    bad 'core update-db did not receive --skip-plugins' "$(grep -F 'update-db' "$ARGV_LOG" 2>/dev/null | head -1)"
fi
argv_log_reset
manager_run -l --skip-plugins 'alpha,beta' >/dev/null 2>&1
if grep -Fq -- '--skip-plugins' "$ARGV_LOG" 2>/dev/null; then
    bad 'list-plugins received --skip-plugins by default' 'that hides the very plugins one lists'
else
    ok 'list-plugins did not receive --skip-plugins by default'
fi
argv_log_reset
manager_run -l --skip-plugins 'alpha,beta' --skip-plugins-for-listing on >/dev/null 2>&1
if grep -Fq -- '--skip-plugins=alpha,beta' "$ARGV_LOG" 2>/dev/null; then
    ok '--skip-plugins-for-listing on adds it to list commands'
else
    bad '--skip-plugins-for-listing on had no effect' "$(head -1 "$ARGV_LOG" 2>/dev/null)"
fi

say '--allow-root policy'
argv_log_reset
manager_run --plugins --allow-root never >/dev/null 2>&1
if grep -Fq -- '--allow-root' "$ARGV_LOG" 2>/dev/null; then
    bad '--allow-root never still passed the flag' "$(head -1 "$ARGV_LOG" 2>/dev/null)"
else
    ok '--allow-root never suppresses the flag'
fi
argv_log_reset
manager_run --plugins --allow-root always >/dev/null 2>&1
if grep -Fq -- '--allow-root' "$ARGV_LOG" 2>/dev/null; then
    ok '--allow-root always passes the flag'
else
    bad '--allow-root always dropped the flag' ''
fi

say 'dry run executes nothing'
argv_log_reset
manager_run --full --dry-run >"${WORK}/dry.txt" 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok '--dry-run exits 0'; else bad '--dry-run exit code' "got ${rc}"; fi
calls="$(grep -c 'ARGV' "$ARGV_LOG" 2>/dev/null)"
if [ "${calls:-0}" = '0' ]; then
    ok '--dry-run invoked wp zero times'
else
    bad '--dry-run invoked wp' "${calls} call(s)"
fi
expect_contains "${WORK}/dry.txt" 'dry-run' 'the dry run says what it would do'
expect_contains "${WORK}/dry.txt" 'plugin update --all' 'the planned command is shown'
expect_contains "${WORK}/dry.txt" 'DRY RUN' 'the banner warns about the dry run'

say 'plugin listing: table, json, csv, tsv'
# Number of plugins the stub reports. Derived, not hardcoded: the stub grew from
# three rows to five when the --only-active checks needed an inactive plugin with
# an update available, and every hardcoded count in this section went stale.
STUB_PLUGINS="$(grep -c '^    "' "${repo}/tests/stub/wp" 2>/dev/null)"
STUB_PLUGINS="${STUB_PLUGINS//[^0-9]/}"
[ -n "$STUB_PLUGINS" ] && [ "$STUB_PLUGINS" -gt 0 ] || STUB_PLUGINS=5
STUB_ROWS=$((STUB_PLUGINS + 1))
one_site="${WORK}/one.txt"
printf '%s\n' "$SITES" >"$one_site"
list_run() { manager_run --sites "$one_site" -l "$@"; }
argv_log_reset
table_out="$(list_run 2>/dev/null)"
if printf '%s' "$table_out" | grep -Fq 'WooCommerce'; then
    ok 'the table lists a plugin by name'
else
    bad 'the table is missing plugin names' "$(printf '%s' "$table_out" | head -5)"
fi
if printf '%s' "$table_out" | grep -Fq 'name'; then
    ok 'the table has a header row'
else
    bad 'the table has no header' ''
fi
list_run --format json >"${WORK}/plugins.json" 2>/dev/null
json_out="$(cat "${WORK}/plugins.json")"
parsed=0
if command -v python3 >/dev/null 2>&1; then
    # The expectation is passed as argv, not embedded in the program text, so the
    # check cannot drift away from the stub when the stub grows another plugin.
    python3 - "${WORK}/plugins.json" "$STUB_PLUGINS" <<'PYCHECK' 2>/dev/null && parsed=1
import json, sys
path, n = sys.argv[1], int(sys.argv[2])
d = json.load(open(path))
assert isinstance(d, list) and len(d) == n, ('rows', len(d), n)
by_slug = {row['slug']: row for row in d}
assert 'woocommerce' in by_slug, sorted(by_slug)
assert by_slug['woocommerce']['update'] == 'available', by_slug['woocommerce']
assert by_slug['akismet']['update'] == 'none', by_slug['akismet']
PYCHECK
elif command -v node >/dev/null 2>&1; then
    node -e '
const fs=require("fs");
const [p,n]=[process.argv[1],Number(process.argv[2])];
const d=JSON.parse(fs.readFileSync(p,"utf8"));
if(!Array.isArray(d)||d.length!==n)process.exit(1);
const w=d.find(x=>x.slug==="woocommerce");
if(!w||w.update!=="available")process.exit(1);
' "${WORK}/plugins.json" "$STUB_PLUGINS" 2>/dev/null && parsed=1
fi
if [ "$parsed" = '1' ]; then
    ok "--format json is valid JSON with ${STUB_PLUGINS} rows and a correct update flag"
else
    if command -v python3 >/dev/null 2>&1 || command -v node >/dev/null 2>&1; then
        bad '--format json is not the plugin list' "$(printf '%s' "$json_out" | head -c 200)"
    else
        skip '--format json validation' 'neither python3 nor node installed'
    fi
fi
csv_out="$(list_run --format csv 2>/dev/null)"
if printf '%s' "$csv_out" | head -1 | grep -Fq 'name,status,update,version'; then
    ok '--format csv has a CSV header'
else
    bad '--format csv header' "$(printf '%s' "$csv_out" | head -1)"
fi
if printf '%s' "$csv_out" | grep -c '' | grep -qx "$STUB_ROWS"; then
    ok "--format csv has a header and ${STUB_PLUGINS} rows"
else
    bad '--format csv row count' "$(printf '%s' "$csv_out" | grep -c '')"
fi
tsv_out="$(list_run --format tsv 2>/dev/null)"
if printf '%s' "$tsv_out" | grep -c '' | grep -qx "$STUB_ROWS"; then
    ok "--format tsv has ${STUB_ROWS} lines"
else
    bad '--format tsv line count' "$(printf '%s' "$tsv_out" | grep -c '')"
fi
custom="$(list_run --format tsv --fields slug,update,update_version 2>/dev/null)"
if printf '%s' "$custom" | head -1 | grep -Fxq $'slug\tupdate\tupdate_version'; then
    ok '--fields selects the columns'
else
    bad '--fields' "$(printf '%s' "$custom" | head -1)"
fi
if printf '%s' "$custom" | sed -n 3p | grep -Fxq $'woocommerce\tavailable\t9.0.0'; then
    ok '--fields carries the right values'
else
    bad '--fields values' "$(printf '%s' "$custom" | sed -n 3p)"
fi

say 'stdout stays parseable in a data format'
mixed="$(list_run --format csv 2>/dev/null)"
if printf '%s' "$mixed" | grep -Eq '^(INF|OK |WRN|ERR|=)'; then
    bad 'prose leaked into stdout' "$(printf '%s' "$mixed" | grep -E '^(INF|OK |WRN|ERR|=)' | head -2)"
else
    ok 'no log line, banner or summary on stdout in csv mode'
fi
if printf '%s' "$mixed" | sed -n 1p | grep -Fq 'name,status'; then
    ok 'the first stdout line is the CSV header'
else
    bad 'the first stdout line is not the header' "$(printf '%s' "$mixed" | sed -n 1p)"
fi

say 'filtering by name'
filtered="$(list_run --format csv --name woo 2>/dev/null)"
rows="$(printf '%s' "$filtered" | grep -c '')"
if [ "$rows" = '2' ]; then
    ok '--name woo selects exactly one plugin'
else
    bad '--name woo row count' "expected 2 lines (header + row), got ${rows}"
fi
# The default columns are name,status,update,version, so the CSV carries the
# display name; the slug only appears when --fields asks for it.
if printf '%s' "$filtered" | grep -Fq 'WooCommerce'; then
    ok 'the selected plugin is WooCommerce'
else
    bad '--name woo selected the wrong plugin' "$(printf '%s' "$filtered")"
fi
slugged="$(list_run --format csv --fields slug --name woo 2>/dev/null)"
if printf '%s' "$slugged" | grep -Fxq 'woocommerce'; then
    ok '--name woo resolves to the slug woocommerce'
else
    bad '--name woo did not resolve to the slug' "$(printf '%s' "$slugged")"
fi
# A jq-style payload in --name must be inert: it is a substring, never a pattern.
hostile="$(list_run --format csv --name 'woo") | .[] | select(true) | .(["' 2>/dev/null)"
if [ "$(printf '%s' "$hostile" | grep -c '')" = '1' ]; then
    ok 'a jq-style --name yields an empty result and no error'
else
    bad 'a jq-style --name was interpreted' "$(printf '%s' "$hostile" | head -3)"
fi
none="$(list_run --format csv --name definitely-not-installed 2>/dev/null)"
if [ "$(printf '%s' "$none" | grep -c '')" = '1' ]; then
    ok 'an unmatched --name yields only the header'
else
    bad 'an unmatched --name' "$(printf '%s' "$none" | head -3)"
fi

say 'plugin management'
argv_log_reset
manager_run --sites "$one_site" -m -A deactivate -N 'Akismet Anti-Spam' --yes >/dev/null 2>&1
if grep -Fxq 'ARGV: [--path='"$SITES"'] [--allow-root] [plugin] [deactivate] [akismet] | CWD='"$SITES"' USER='"${SU_USER:-$(id -un)}"' | ASTRFAIL=<unset> | DOCUMENT_ROOT='"$SITES"' HOMEDIR='"$(dirname "$(dirname "$SITES")")"' HTTP_HOST='"$(basename "$SITES")"' DOCUMENT_URI='"$(basename "$SITES")"' HOME='"$(getent passwd "${SU_USER:-$(id -un)}" | cut -d: -f6)"' LOGNAME='"${SU_USER:-$(id -un)}"' | LICENCE=<unset>' "$ARGV_LOG" 2>/dev/null; then
    ok 'the slug, not the display name, is passed to wp'
elif need_switch 'plugin manage argv'; then
    bad 'unexpected argv for deactivate' "$(tail -1 "$ARGV_LOG" 2>/dev/null)"
fi
argv_log_reset
manager_run --sites "$one_site" -m -A deactivate -N woo --yes >/dev/null 2>&1
if grep -Fq '[deactivate] [woocommerce]' "$ARGV_LOG" 2>/dev/null; then
    ok 'a unique partial name resolves to one plugin'
else
    bad 'partial name resolution' "$(tail -1 "$ARGV_LOG" 2>/dev/null)"
fi
argv_log_reset
manager_run --sites "$one_site" -m -A deactivate -N a --yes >"${WORK}/amb.txt" 2>&1
rc=$?
if [ "$rc" != '0' ] && ! grep -Fq '[deactivate]' "$ARGV_LOG" 2>/dev/null; then
    ok 'an ambiguous name performs nothing and exits non-zero'
else
    bad 'an ambiguous name was acted upon' "rc=${rc}, log: $(tail -1 "$ARGV_LOG" 2>/dev/null)"
fi
expect_contains "${WORK}/amb.txt" 'ambiguous' 'the ambiguity is explained'
argv_log_reset
manager_run --sites "$one_site" -m -A deactivate -N 'Akismet Anti-Spam' --yes >/dev/null 2>&1
if grep -Fq -- '--skip-plugins' "$ARGV_LOG" 2>/dev/null; then
    bad 'a manage call received --skip-plugins' 'it must not: it names the plugin explicitly'
else
    ok 'no --skip-plugins on a manage call'
fi

say 'a destructive action needs an explicit yes'
rm -f "${WORK}/DELETED"
argv_log_reset
manager_run --sites "$one_site" -m -A delete -N woo </dev/null >"${WORK}/del.txt" 2>&1
rc=$?
if grep -Fq '[delete]' "$ARGV_LOG" 2>/dev/null; then
    bad 'delete ran without confirmation' "$(tail -1 "$ARGV_LOG" 2>/dev/null)"
else
    ok 'delete without --yes in a non-interactive shell is refused'
fi
if [ "$rc" != '0' ]; then ok "refusing to delete exits non-zero (${rc})"; else bad 'refusing to delete exited 0' ''; fi
expect_contains "${WORK}/del.txt" '--yes' 'the refusal tells the operator what to pass'
argv_log_reset
manager_run --sites "$one_site" -m -A delete -N woo --yes >/dev/null 2>&1
if grep -Fq '[delete] [woocommerce]' "$ARGV_LOG" 2>/dev/null; then
    ok 'delete --yes runs'
else
    bad 'delete --yes did not run' "$(tail -1 "$ARGV_LOG" 2>/dev/null)"
fi

say 'no injection through a plugin name or a site path'
rm -f /tmp/INJECTED_wpcli_test
argv_log_reset
manager_run --sites "$one_site" -m -A deactivate --yes \
    -N 'zz"; touch /tmp/INJECTED_wpcli_test; echo "' >/dev/null 2>&1
if [ -f /tmp/INJECTED_wpcli_test ]; then
    bad 'command injection through --name' 'the payload ran'
    rm -f /tmp/INJECTED_wpcli_test
else
    ok 'a shell payload in --name is inert'
fi
if [ "$CAN_SWITCH" = '1' ]; then
    evil="${SITE_ROOT}/evil; touch ${WORK}/PWNED; echo "
    make_site "$evil"
    printf '%s\n' "$evil" >"${WORK}/evil.txt"
    argv_log_reset
    manager_run --plugins --sites "${WORK}/evil.txt" >/dev/null 2>&1
    if [ -f "${WORK}/PWNED" ]; then
        bad 'command injection through a site path' 'the payload ran'
    else
        ok 'a shell payload in a site path is inert'
    fi
    if grep -Fq -- "--path=${evil}" "$ARGV_LOG" 2>/dev/null; then
        ok 'the hostile path arrived as one --path argument'
    else
        bad 'the hostile path was not passed verbatim' "$(tail -1 "$ARGV_LOG" 2>/dev/null)"
    fi
    rm -rf -- "$evil"
else
    skip 'injection through a site path' 'no switchable test user available'
fi

say 'the licence never reaches argv, the log or the console'
SECRET='sup3r-secret-licence-value-0001'
argv_log_reset
ASTRA_FAIL_SLUG=astra-addon manager_run --sites "$one_site" --astra \
    --astra-key "$SECRET" --user-env ASTRA_FAIL_SLUG >"${WORK}/astra.txt" 2>&1
if grep -Fq '[brainstormforce] [license] [activate]' "$ARGV_LOG" 2>/dev/null; then
    ok 'the licence activation was attempted'
else
    if need_switch 'licence activation'; then
        bad 'the licence activation never ran' "$(tail -2 "$ARGV_LOG" 2>/dev/null)"
    fi
fi
if grep -Fq "LICENCE=<set,len=${#SECRET}" "$ARGV_LOG" 2>/dev/null; then
    ok 'the licence reached the wp process'
else
    bad 'the licence did not reach wp' "$(grep -o 'LICENCE=[^ ]*' "$ARGV_LOG" 2>/dev/null | tail -1)"
fi
if grep -Fq "$SECRET" "$ARGV_LOG" 2>/dev/null; then
    bad 'the licence value appears in the recorded argv' ''
else
    ok 'the licence value is not in argv'
fi
for f in "$LOG_FILE" "$ERR_FILE" "${WORK}/astra.txt"; do
    if grep -Fq "$SECRET" "$f" 2>/dev/null; then
        bad "the licence value appears in ${f##*/}" "$(grep -F "$SECRET" "$f" | head -1)"
    else
        ok "the licence value is absent from ${f##*/}"
    fi
done
if grep -Fq 'astra-addon @@WP_CLI_UPDATE_LICENCE@@' "${WORK}/astra.txt" 2>/dev/null; then
    bad 'the internal marker leaked into an operator-facing message' ''
else
    ok 'the internal marker is never shown to the operator'
fi
leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'Bash_WP-CLI_Update.sh.licence.*' -newermt '-2 minutes' 2>/dev/null | wc -l)"
leftover="${leftover//[^0-9]/}"
if [ "${leftover:-0}" = '0' ]; then
    ok 'the licence handoff file was removed'
else
    bad 'licence handoff files leaked' "${leftover} file(s) in ${TMPDIR:-/tmp}"
fi

say 'the licence can also come from a key file'
keyfile="${WORK}/astra.key"
printf '%s\n' 'FILE-SECRET-0002' >"$keyfile"
chmod 600 "$keyfile"
argv_log_reset
# The manager looks for astra.key next to itself, so run it from a copy of the
# repository layout rather than moving the real script.
sandbox="${WORK}/sb"
mkdir -p "$sandbox"
cp "$M" "${sandbox}/Bash_WP-CLI_Update.sh"
cp "$keyfile" "${sandbox}/astra.key"
ASTRA_FAIL_SLUG=astra-addon FAKE_WP_LOG="$ARGV_LOG" bash "${sandbox}/Bash_WP-CLI_Update.sh" \
    --astra --sites "$one_site" --wp "$STUB_WP" --log-file "$LOG_FILE" \
    --error-log-file "$ERR_FILE" --lock-file "$LOCK_FILE" --color never \
    --user-env ASTRA_FAIL_SLUG >/dev/null 2>&1
if grep -Fq 'LICENCE=<set,len=16' "$ARGV_LOG" 2>/dev/null; then
    ok 'astra.key next to the script is used'
else
    if need_switch 'astra.key'; then
        bad 'astra.key was not used' "$(grep -o 'LICENCE=[^ ]*' "$ARGV_LOG" 2>/dev/null | tail -1)"
    fi
fi
if grep -Fq 'FILE-SECRET-0002' "$LOG_FILE" "$ERR_FILE" "$ARGV_LOG" 2>/dev/null; then
    bad 'the key file value leaked' ''
else
    ok 'the key file value did not leak'
fi

say '--check validates without changing anything'
argv_log_reset
check_out="${WORK}/check.txt"
manager_run --check >"$check_out" 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok '--check on a good tree exits 0'; else bad '--check exit code' "got ${rc}"; fi
calls="$(grep -c 'ARGV' "$ARGV_LOG" 2>/dev/null)"
if [ "${calls:-0}" = '0' ]; then
    ok '--check invoked wp zero times'
else
    bad '--check invoked wp' "${calls} call(s)"
fi
expect_contains "$check_out" 'wp-cli' '--check reports the wp binary'
expect_contains "$check_out" 'user switch' '--check reports the switching mechanism'
expect_contains "$check_out" "$SITES" '--check reports each site'
expect_contains "$check_out" 'owner' '--check reports the owner of each site'

say '--check notices a broken site'
broken_list="${WORK}/broken.txt"
printf '%s\n%s\n' "$SITES" "${WORK}/not-here" >"$broken_list"
manager_run --check --sites "$broken_list" >"${WORK}/check2.txt" 2>&1
expect_contains "${WORK}/check2.txt" 'not a directory' '--check flags a missing site'

say '--status reports the previous run'
manager_run --plugins >/dev/null 2>&1
status_out="${WORK}/status.txt"
manager_run --status >"$status_out" 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok '--status exits 0'; else bad '--status exit code' "got ${rc}"; fi
expect_contains "$status_out" 'mode' '--status names the mode of the last run'
expect_contains "$status_out" 'sites processed' '--status reports the site count'
expect_contains "$status_out" 'exit code' '--status reports the exit code'
expect_contains "$status_out" "$LOG_FILE" '--status names the log file'

say 'a failing site is reported and counted'
fail_stub="${WORK}/bin/wp-fail"
cat >"$fail_stub" <<'STUB'
#!/usr/bin/env bash
echo "Error: simulated failure" >&2
exit 1
STUB
chmod 755 "$fail_stub"
FAKE_WP_LOG="$ARGV_LOG" bash "$M" --plugins --sites "$SITE_LIST" --wp "$fail_stub" \
    --log-file "$LOG_FILE" --error-log-file "$ERR_FILE" --lock-file "$LOCK_FILE" \
    --color never --user-env FAKE_WP_LOG >"${WORK}/fail.txt" 2>&1
rc=$?
if [ "$rc" = '1' ]; then ok 'a failing site makes the run exit 1'; else bad 'exit code with a failing site' "expected 1, got ${rc}"; fi
if grep -Eq 'sites failed:[[:space:]]+2' "${WORK}/fail.txt"; then
    ok 'both sites are reported as failed'
else
    bad 'the failed-site count is wrong' "$(grep -E 'sites (ok|failed)' "${WORK}/fail.txt" | tr -s ' ')"
fi
expect_contains "${WORK}/fail.txt" 'simulated failure' 'the wp error text reaches the operator'
if [ -s "$ERR_FILE" ]; then ok 'the error log holds the detail'; else bad 'the error log is empty' ''; fi
expect_contains "$ERR_FILE" 'ERROR DETAIL' 'the error log is structured'

say 'the loop continues after a failing site'
half_stub="${WORK}/bin/wp-half"
cat >"$half_stub" <<STUB
#!/usr/bin/env bash
{ printf 'HALF:'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >>"${LOG_DIR}/half.log"
for a in "\$@"; do
    case "\$a" in --path=*second.org*) echo "Error: only the second site fails" >&2; exit 1 ;; esac
done
echo ok
STUB
chmod 755 "$half_stub"
rm -f "${LOG_DIR}/half.log"
FAKE_WP_LOG="$ARGV_LOG" bash "$M" --plugins --sites "$SITE_LIST" --wp "$half_stub" \
    --log-file "$LOG_FILE" --error-log-file "$ERR_FILE" --lock-file "$LOCK_FILE" \
    --color never --user-env FAKE_WP_LOG >"${WORK}/half.txt" 2>&1
rc=$?
calls="$(grep -c 'HALF:' "${LOG_DIR}/half.log" 2>/dev/null)"
calls="${calls//[^0-9]/}"
if [ "${calls:-0}" = '2' ]; then
    ok 'the second site was still attempted after the first failure'
else
    bad 'the loop stopped early' "${calls:-0} invocation(s), expected 2"
fi
if [ "$rc" = '1' ]; then ok 'one failing site still exits 1'; else bad 'exit code with one failing site' "got ${rc}"; fi

say '--fail-on policy'
run_failon() { bash "$M" --plugins --sites "$SITE_LIST" --wp "$half_stub" --fail-on "$1" \
    --log-file "$LOG_FILE" --error-log-file "$ERR_FILE" --lock-file "$LOCK_FILE" --color never >/dev/null 2>&1; }
run_failon any; rc=$?
if [ "$rc" = '1' ]; then ok '--fail-on any exits 1 when one site failed'; else bad '--fail-on any' "got ${rc}"; fi
run_failon all; rc=$?
if [ "$rc" = '0' ]; then ok '--fail-on all exits 0 when only some sites failed'; else bad '--fail-on all' "got ${rc}"; fi
run_failon never; rc=$?
if [ "$rc" = '0' ]; then ok '--fail-on never exits 0 despite failures'; else bad '--fail-on never' "got ${rc}"; fi
FAKE_WP_LOG="$ARGV_LOG" bash "$M" --plugins --sites "$SITE_LIST" --wp "$fail_stub" --fail-on all \
    --log-file "$LOG_FILE" --error-log-file "$ERR_FILE" --lock-file "$LOCK_FILE" --color never >/dev/null 2>&1
rc=$?
if [ "$rc" = '1' ]; then ok '--fail-on all exits 1 when every site failed'; else bad '--fail-on all (total failure)' "got ${rc}"; fi

say 'timeouts'
if command -v timeout >/dev/null 2>&1; then
    sleep_stub="${WORK}/bin/wp-sleep"
    cat >"$sleep_stub" <<'STUB'
#!/usr/bin/env bash
sleep 10
STUB
    chmod 755 "$sleep_stub"
    start="$(date +%s)"
    FAKE_WP_LOG="$ARGV_LOG" bash "$M" --plugins --sites "$one_site" --wp "$sleep_stub" \
        --timeout 1 --kill-after 1 --log-file "$LOG_FILE" --error-log-file "$ERR_FILE" \
        --lock-file "$LOCK_FILE" --color never >"${WORK}/to.txt" 2>&1
    rc=$?
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -le 6 ]; then
        ok "--timeout 1 returned after ${elapsed}s instead of 10s"
    else
        bad '--timeout did not bound the call' "took ${elapsed}s"
    fi
    if [ "$rc" = '1' ]; then ok 'a timed-out site exits 1'; else bad 'timeout exit code' "got ${rc}"; fi
    expect_contains "${WORK}/to.txt" 'timed out' 'the timeout is reported as such'
else
    skip 'timeout tests' 'timeout(1) not installed'
fi

say 'concurrent runs are refused'
if command -v flock >/dev/null 2>&1; then
    (
        flock -x 9
        sleep 4
    ) 9>"$LOCK_FILE" &
    holder=$!
    sleep 1
    manager_run --plugins >"${WORK}/conc.txt" 2>&1
    rc=$?
    if [ "$rc" = '3' ]; then
        ok 'a second run exits 3 while the lock is held'
    else
        bad 'a second run did not exit 3' "got ${rc}"
    fi
    expect_contains "${WORK}/conc.txt" 'refusing to run concurrently' 'the refusal is explained'
    expect_contains "${WORK}/conc.txt" "$LOCK_FILE" 'the refusal names the lock file'
    wait "$holder" 2>/dev/null
    manager_run --plugins >/dev/null 2>&1
    rc=$?
    if [ "$rc" = '0' ]; then ok 'the run succeeds once the lock is released'; else bad 'after the lock was released' "got ${rc}"; fi
else
    skip 'concurrency' 'flock(1) not installed'
fi
manager_run --plugins --no-lock >/dev/null 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok '--no-lock bypasses the lock'; else bad '--no-lock' "got ${rc}"; fi

say 'a stale lock is removed'
if command -v flock >/dev/null 2>&1; then
    printf '999999999\n' >"$LOCK_FILE"
    manager_run --plugins >"${WORK}/stale.txt" 2>&1
    rc=$?
    if [ "$rc" = '0' ]; then ok 'a lock held by a dead pid does not block the run'; else bad 'stale lock' "got ${rc}"; fi
else
    skip 'stale lock' 'flock(1) not installed'
fi

say 'configuration precedence'
cfg="${WORK}/test.conf"
cat >"$cfg" <<EOF
# a test configuration
SKIP_PLUGINS=from-file
LOG_LEVEL=warn
EOF
out="$(bash "$M" --print-config --config "$cfg" 2>/dev/null)"
if printf '%s' "$out" | grep -F 'SKIP_PLUGINS' | grep -Fq 'from-file'; then
    ok 'a config file value is applied'
else
    bad 'config file value ignored' "$(printf '%s' "$out" | grep -F SKIP_PLUGINS | head -1)"
fi
out="$(WP_CLI_UPDATE_SKIP_PLUGINS=from-env bash "$M" --print-config --config "$cfg" 2>/dev/null)"
if printf '%s' "$out" | grep -F 'SKIP_PLUGINS' | grep -Fq 'from-env'; then
    ok 'the environment beats the config file'
else
    bad 'environment did not beat the file' "$(printf '%s' "$out" | grep -F SKIP_PLUGINS | head -1)"
fi
out="$(WP_CLI_UPDATE_SKIP_PLUGINS=from-env bash "$M" --print-config --config "$cfg" --skip-plugins from-cli 2>/dev/null)"
if printf '%s' "$out" | grep -F 'SKIP_PLUGINS' | grep -Fq 'from-cli'; then
    ok 'the command line beats the environment'
else
    bad 'CLI did not win' "$(printf '%s' "$out" | grep -F SKIP_PLUGINS | head -1)"
fi
if printf '%s' "$out" | grep -F 'SKIP_PLUGINS' | grep -Fq 'command line'; then
    ok '--print-config names the winning layer'
else
    bad '--print-config does not name the winning layer' "$(printf '%s' "$out" | grep -F SKIP_PLUGINS | head -1)"
fi
argv_log_reset
WP_CLI_UPDATE_SKIP_PLUGINS=alpha,beta manager_run --plugins --sites "$one_site" >/dev/null 2>&1
if grep -Fq -- '--skip-plugins=alpha,beta' "$ARGV_LOG" 2>/dev/null; then
    ok 'an environment-provided --skip-plugins reaches wp'
else
    bad 'environment --skip-plugins ignored' "$(head -1 "$ARGV_LOG" 2>/dev/null)"
fi

say 'a config file is data, never code'
evil_cfg="${WORK}/evil.conf"
printf 'SKIP_PLUGINS=a; touch %s/EVIL\n' "$WORK" >"$evil_cfg"
rm -f "${WORK}/EVIL"
bash "$M" --print-config --config "$evil_cfg" >/dev/null 2>&1
rc=$?
if [ "$rc" = '4' ]; then ok 'a config line with a metacharacter exits 4'; else bad 'metacharacter config' "expected exit 4, got ${rc}"; fi
if [ -f "${WORK}/EVIL" ]; then
    bad 'a config file was executed' 'the payload ran'
    rm -f "${WORK}/EVIL"
else
    ok 'nothing from an unsafe config was applied'
fi
for payload in 'SKIP_PLUGINS=a|b' 'SKIP_PLUGINS=$(id)' 'SKIP_PLUGINS=a>b' 'SKIP_PLUGINS=`id`'; do
    printf '%s\n' "$payload" >"$evil_cfg"
    bash "$M" --print-config --config "$evil_cfg" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = '4' ]; then ok "rejected: ${payload}"; else bad "not rejected: ${payload}" "exit ${rc}"; fi
done
unk_cfg="${WORK}/unk.conf"
printf 'NOT_A_SETTING=1\nSKIP_PLUGINS=fine\n' >"$unk_cfg"
out="$(bash "$M" --print-config --config "$unk_cfg" 2>&1)"
if printf '%s' "$out" | grep -Fq 'unknown setting'; then
    ok 'an unknown key is reported and ignored'
else
    bad 'an unknown key passed silently' ''
fi
bad_cfg="${WORK}/bad.conf"
printf 'LOG_MAX_BYTES=abc\n' >"$bad_cfg"
bash "$M" --print-config --config "$bad_cfg" >/dev/null 2>&1
rc=$?
if [ "$rc" = '4' ]; then ok 'a non-numeric LOG_MAX_BYTES exits 4'; else bad 'bad LOG_MAX_BYTES' "got ${rc}"; fi

say 'log rotation'
small_log="${WORK}/small.log"
: >"$small_log"
# LOG_MAX_BYTES comes from the config layer; 200 bytes forces a rotation at once
rot_cfg="${WORK}/rot.conf"
printf 'LOG_MAX_BYTES=200\nLOG_KEEP=2\n' >"$rot_cfg"
head -c 400 /dev/urandom | tr -cd '[:alnum:]' >"$small_log"
printf '\n' >>"$small_log"
manager_run --plugins --sites "$one_site" --config "$rot_cfg" --log-file "$small_log" >/dev/null 2>&1
if [ -f "${small_log}.1" ]; then
    ok 'the oversized log was rotated to .1'
else
    bad 'no rotation happened' "LOG_MAX_BYTES=200, file is $(stat -c '%s' "$small_log" 2>/dev/null) bytes"
fi

say 'the log file is plain text'
if grep -q $'\033' "$LOG_FILE" 2>/dev/null; then
    bad 'ANSI escapes ended up in the log file' 'colour must follow the --color policy'
else
    ok 'the log file holds no ANSI escapes'
fi
if grep -Fq 'SUMMARY' "$LOG_FILE" 2>/dev/null; then
    bad 'the console summary was copied into the log file' ''
else
    ok 'the console summary stays out of the log file'
fi
if grep -Fq 'summary:' "$LOG_FILE" 2>/dev/null; then
    ok 'the log file holds a machine-greppable summary line'
else
    bad 'no summary line in the log file' ''
fi

say 'a missing site list triggers discovery'
fresh="${WORK}/fresh"
mkdir -p "$fresh"
# $FINDER, not $F: this suite never defined $F, and under `set -u` the typo
# aborted the whole run after 142 checks with "F: unbound variable" while the
# runner reported "0 failed". A suite that dies part-way must not look green.
cp "$M" "$FINDER" "$fresh/"
mkdir -p "${fresh}/logs"
argv_log_reset
FAKE_WP_LOG="$ARGV_LOG" bash "${fresh}/Bash_WP-CLI_Update.sh" --plugins \
    --sites "${fresh}/wp-found.txt" --wp "$STUB_WP" --log-file "${fresh}/logs/m.log" \
    --error-log-file "${fresh}/logs/e.log" --lock-file "${fresh}/lock" --color never \
    >"${WORK}/disc.txt" 2>&1
rc=$?
if [ -f "${fresh}/wp-found.txt" ]; then
    ok 'the missing list was created by running the finder'
else
    bad 'discovery did not create the list' "exit ${rc}; $(head -3 "${WORK}/disc.txt")"
fi
manager_run --plugins --sites "${WORK}/definitely-missing.txt" --no-discover >"${WORK}/nd.txt" 2>&1
rc=$?
if [ "$rc" = '3' ]; then ok '--no-discover turns a missing list into exit 3'; else bad '--no-discover' "got ${rc}"; fi
expect_contains "${WORK}/nd.txt" 'AUTO_DISCOVER' 'the refusal explains the setting'

say 'an empty site list is not an error'
: >"${WORK}/empty.txt"
manager_run --plugins --sites "${WORK}/empty.txt" >"${WORK}/empty.out" 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok 'an empty list exits 0'; else bad 'empty list exit code' "got ${rc}"; fi
# The message is a warning on stderr; manager_run merges both streams into the
# file the caller redirects, so capture it here explicitly.
manager_run --plugins --sites "${WORK}/empty.txt" >"${WORK}/empty.out" 2>&1
expect_contains "${WORK}/empty.out" 'nothing to do' 'an empty list says so'

say 'a site that is not a directory is skipped, not fatal'
printf '%s\n%s\n' "${WORK}/does-not-exist" "$SITES" >"${WORK}/mixed.txt"
argv_log_reset
manager_run --plugins --sites "${WORK}/mixed.txt" >"${WORK}/mixed.out" 2>&1
rc=$?
if [ "$rc" = '0' ]; then ok 'a nonexistent entry does not fail the run'; else bad 'nonexistent entry' "exit ${rc}"; fi
expect_contains "${WORK}/mixed.out" 'not a directory' 'the skip is reported'
expect_contains "${WORK}/mixed.out" 'sites skipped:         1' 'the skip is counted'

say '--max-sites bounds the run'
argv_log_reset
manager_run --plugins --max-sites 1 >"${WORK}/max.txt" 2>&1
calls="$(grep -c 'ARGV' "$ARGV_LOG" 2>/dev/null)"
if [ "${calls:-0}" = '1' ]; then ok '--max-sites 1 processed one site'; else bad '--max-sites' "${calls:-0} call(s)"; fi
expect_contains "${WORK}/max.txt" '--max-sites=1 reached' 'the bound is reported'

say '--user forces the account'
if [ "$CAN_SWITCH" = '1' ]; then
    argv_log_reset
    manager_run --plugins --sites "$one_site" --user "$SU_USER" >/dev/null 2>&1
    if grep -Fq "USER=${SU_USER}" "$ARGV_LOG" 2>/dev/null; then
        ok "--user ${SU_USER} was honoured"
    else
        bad '--user ignored' "$(head -1 "$ARGV_LOG" 2>/dev/null)"
    fi
    expect_rc 3 '--user with a nonexistent account exits 3' \
        bash "$M" --plugins --sites "$one_site" --user no-such-user-xyz \
            --wp "$STUB_WP" --log-file "$LOG_FILE" --error-log-file "$ERR_FILE" \
            --lock-file "$LOCK_FILE" --color never
else
    skip '--user' 'no switchable test user available'
fi

say 'colour policy'
if printf 'x' | bash "$M" --help --color always 2>/dev/null | grep -q $'\033'; then
    ok '--color always emits escapes even when redirected'
else
    bad '--color always produced no escapes' ''
fi
if bash "$M" --help --color never 2>/dev/null | grep -q $'\033'; then
    bad '--color never still emitted escapes' ''
else
    ok '--color never emits no escapes'
fi
if NO_COLOR=1 bash "$M" --help --color auto 2>/dev/null | grep -q $'\033'; then
    bad 'NO_COLOR was ignored' ''
else
    ok 'NO_COLOR is honoured in auto mode'
fi

say 'the run does not write into the repository'
before="$(cd "$repo" && find . -newer "$M" -type f -not -path './.git/*' 2>/dev/null | sort)"
manager_run --plugins >/dev/null 2>&1
after="$(cd "$repo" && find . -newer "$M" -type f -not -path './.git/*' 2>/dev/null | sort)"
if [ "$before" = "$after" ]; then
    ok 'no new file appeared in the repository during a run'
else
    bad 'a run wrote into the repository' "$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -5)"
fi

report 'manager'

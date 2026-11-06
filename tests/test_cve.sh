#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016,SC1091,SC2034  # a test suite greps for literal shell
# patterns and sources its harness by a path resolved at run time
# Regression tests for the 8.1.0 security feature set:
#   --security   the CVE-2026-119977 assessment (read-only, exit 1 when exposed);
#   --harden     the wp-content/upgrade/ deny block appended to .htaccess;
#   --harden-upgrade-dir / HARDEN_UPGRADE_DIR   the same block during a writing mode;
#   --health     the CVE column, still read-only.
#
# The rules this suite enforces:
#   - a read-only mode never writes .htaccess, never exports a database and never
#     takes the lock;
#   - --security exits 1 exactly when a site's core is below the fixed release, and
#     0 when it is at or above it;
#   - --harden is idempotent, keeps the original file, and backs it up once;
#   - nginx cannot be fixed from .htaccess, so the directive is printed.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-cve.XXXXXX")"
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
HELP="${WORK}/help.txt"
bash "$M" --help >"$HELP" 2>&1
MODES_OUT="$(bash "$M" --list-modes 2>/dev/null)"
CVE_VERSION_FILE="${ARGV_LOG}.core-version"

# mrun_rc: run the manager against the fixture and keep its exit status. The
# user switch is off so the suite is meaningful without root; the switch itself
# is exercised by the suites that ask for root explicitly.
mrun_rc() { manager_run --no-user-switch "$@"; }

clear_core_version() { rm -f -- "$CVE_VERSION_FILE"; }
set_core_version() { printf '%s\n' "$1" >"$CVE_VERSION_FILE"; }

say 'the security modes and options are advertised'
for mode in security harden; do
    if printf '%s\n' "$MODES_OUT" | grep -Fxq "$mode"; then
        ok "--list-modes advertises ${mode}"
    else
        bad "--list-modes is missing ${mode}" "got: $(printf '%s' "$MODES_OUT" | tr '\n' ' ')"
    fi
done
for opt in --security --harden --harden-upgrade-dir --no-harden-upgrade-dir; do
    if grep -Fq -- "$opt" "$HELP"; then
        ok "--help documents ${opt}"
    else
        bad "--help does not document ${opt}" ''
    fi
done
if grep -Fq -- 'CVE-2026-119977' "$HELP"; then
    ok '--help names the CVE the modes are about'
else
    bad '--help does not name the CVE' ''
fi

say '--security reports an exposed site and exits 1'
clear_core_version
out="${WORK}/sec-exposed.txt"
mrun_rc --security --site "$SITES" >"$out" 2>&1
rc=$?
if [ "$rc" = '1' ]; then
    ok '--security exits 1 for core 6.4.3 (below the fixed releases)'
else
    bad '--security exit code for an exposed site' "expected 1, got ${rc}"
fi
expect_contains "$out" 'CVE-2026-119977' 'the report names the CVE'
expect_contains "$out" 'UPDATE' 'the row marks the site as needing an update'
expect_contains "$out" '7.1.4' 'the row names the fixed release to install'
if [ -e "${SITES}/.htaccess" ]; then
    bad '--security wrote .htaccess' 'a read-only mode must not modify a site'
else
    ok '--security never writes .htaccess'
fi
if grep -Fq '[db] [export]' "$ARGV_LOG"; then
    bad '--security exported a database' 'a read-only mode must not write'
else
    ok '--security never exports a database'
fi

say '--security exits 0 when the site is on a fixed release'
set_core_version '7.1.4'
out="${WORK}/sec-safe.txt"
mrun_rc --security --site "$SITES" >"$out" 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok '--security exits 0 for core 7.1.4'
else
    bad '--security exit code for a fixed site' "expected 0, got ${rc}"
fi
expect_contains "$out" 'safe' 'the row marks the site as safe'
clear_core_version

say '--security --json-lines is parseable and carries the verdict'
out="${WORK}/sec-json.txt"
mrun_rc --security --json-lines --site "$SITES" >"$out" 2>/dev/null
rc=$?
expect_contains "$out" '"type":"security"' 'a security object is emitted'
expect_contains "$out" '"status":"needs-update"' 'the object carries the verdict'
expect_contains "$out" '"fix":"7.1.4"' 'the object names the fixed release'
expect_contains "$out" '"type":"summary"' 'the run summary is emitted'
python_ok=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
    python_ok=1
fi
if [ "$python_ok" = '1' ]; then
    if python3 -c 'import json,sys
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if line:
        json.loads(line)' "$out" 2>/dev/null; then
        ok 'every JSON Lines record parses'
    else
        bad 'a JSON Lines record does not parse' "$(head -2 "$out")"
    fi
else
    skip 'JSON Lines parse check' 'python3 is not available'
fi
if [ "$rc" = '1' ]; then
    ok 'the JSON Lines run still exits 1 for an exposed site'
else
    bad 'JSON Lines exit code' "expected 1, got ${rc}"
fi

say '--health carries the CVE column and stays read-only'
out="${WORK}/health.txt"
mrun_rc --health --site "$SITES" >"$out" 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok '--health exits 0 even when a site is exposed'
else
    bad '--health exit code' "expected 0, got ${rc}"
fi
expect_contains "$out" 'CVE' '--health prints a CVE column'
expect_contains "$out" 'UPDATE' '--health marks the exposed site'
if [ -e "${SITES}/.htaccess" ]; then
    bad '--health wrote .htaccess' 'a read-only mode must not modify a site'
else
    ok '--health never writes .htaccess'
fi

say '--harden appends one marked block and keeps the original file'
hard_site="${WORK}/harden-a"
make_site "$hard_site"
printf 'Options -Indexes\n' >"${hard_site}/.htaccess"
chmod 644 "${hard_site}/.htaccess"
cp -p "${hard_site}/.htaccess" "${WORK}/htaccess-orig"
out="${WORK}/harden.txt"
mrun_rc --harden --site "$hard_site" >"$out" 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok '--harden exits 0'
else
    bad '--harden exit code' "expected 0, got ${rc}"
fi
expect_contains "${hard_site}/.htaccess" 'BEGIN Bash WP-CLI Update' 'the block has a begin marker'
expect_contains "${hard_site}/.htaccess" 'RewriteRule ^wp-content/upgrade/ - [F,L]' 'the rewrite rule denies the upgrade directory'
expect_contains "${hard_site}/.htaccess" 'Options -Indexes' 'the existing content is preserved'
if [ -f "${hard_site}/.htaccess.wp-cli-update.bak" ]; then
    ok 'the original .htaccess is backed up'
    if cmp -s "${WORK}/htaccess-orig" "${hard_site}/.htaccess.wp-cli-update.bak"; then
        ok 'the backup is byte-identical to the original'
    else
        bad 'the backup differs from the original' ''
    fi
else
    bad 'no .htaccess backup was written' ''
fi
expect_contains "$out" 'nginx does not read .htaccess' 'the nginx directive is printed for nginx hosts'

say '--harden is idempotent'
mrun_rc --harden --site "$hard_site" >/dev/null 2>&1
n="$(grep -c 'BEGIN Bash WP-CLI Update' "${hard_site}/.htaccess" 2>/dev/null)"
n="${n//[^0-9]/}"
if [ "${n:-0}" = '1' ]; then
    ok 'a second run does not duplicate the block'
else
    bad 'the block was duplicated' "found ${n:-0} marker(s)"
fi

say '--harden --dry-run writes nothing'
dry_site="${WORK}/harden-dry"
make_site "$dry_site"
mrun_rc --harden --dry-run --site "$dry_site" >"${WORK}/harden-dry.txt" 2>&1
if [ -e "${dry_site}/.htaccess" ]; then
    bad '--harden --dry-run created .htaccess' ''
else
    ok '--harden --dry-run leaves the site untouched'
fi
expect_contains "${WORK}/harden-dry.txt" 'dry-run' 'the dry run says what it would do'

say 'a writing mode applies the block when asked'
flag_site="${WORK}/harden-flag"
make_site "$flag_site"
mrun_rc --cron --harden-upgrade-dir --site "$flag_site" >"${WORK}/harden-flag.txt" 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok 'a writing mode with --harden-upgrade-dir exits 0'
else
    bad 'the writing mode failed' "expected 0, got ${rc}"
fi
expect_contains "${flag_site}/.htaccess" 'BEGIN Bash WP-CLI Update' 'the block is applied during the writing mode'
expect_contains "${flag_site}/.htaccess" 'RewriteRule ^wp-content/upgrade/ - [F,L]' 'the rule is applied during the writing mode'

say 'HARDEN_UPGRADE_DIR in the config file does the same'
conf_site="${WORK}/harden-conf"
make_site "$conf_site"
conf="${WORK}/harden.conf"
printf '%s\n' 'HARDEN_UPGRADE_DIR=1' >"$conf"
chmod 600 "$conf"
mrun_rc --cron --config "$conf" --site "$conf_site" >"${WORK}/harden-conf.txt" 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok 'the config key does not break the run'
else
    bad 'the config key broke the run' "expected 0, got ${rc}"
fi
expect_contains "${conf_site}/.htaccess" 'BEGIN Bash WP-CLI Update' 'HARDEN_UPGRADE_DIR=1 applies the block'
expect_contains "${WORK}/harden-conf.txt" 'nginx does not read .htaccess' 'the nginx directive is printed when the key is on'

say 'the hardening block is not added unless asked'
plain_site="${WORK}/harden-plain"
make_site "$plain_site"
mrun_rc --cron --site "$plain_site" >/dev/null 2>&1
if [ -e "${plain_site}/.htaccess" ]; then
    bad 'a plain writing mode wrote .htaccess' 'hardening must be opt-in'
else
    ok 'a plain writing mode does not write .htaccess'
fi

say 'a core update reports a site that stays below the fixed release'
core_site="${WORK}/core-site"
make_site "$core_site"
out="${WORK}/core.txt"
mrun_rc --core --site "$core_site" >"$out" 2>&1
expect_contains "$out" 'still below 7.1.4' 'the run says another core update is required'
expect_contains "$out" 'CVE-2026-119977' 'the message names the CVE'

say 'read-only and security modes refuse the hardening flag'
expect_rc 2 '--security refuses --harden-upgrade-dir' bash "$M" --security --harden-upgrade-dir --site "$SITES"
expect_rc 2 '--health refuses --harden-upgrade-dir' bash "$M" --health --harden-upgrade-dir --site "$SITES"

report 'cve'

#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2016,SC2034  # the harness is sourced by a run-time path;
# a test writes literal PHP through single quotes and keeps variables for clarity
# Regression tests for the 9.1.0 additions, all of them found on a live fleet
# (176.99.5.35, 2026-11-18):
#
#   - --check asked only about files, so a site whose theme killed WordPress
#     answered ✓ while every WP-CLI command on it died. --check now probes the
#     site with `wp core is-installed`, and --no-wp-probe turns that off.
#   - an aborted upgrader (a plugin hook) makes WP-CLI print a bare "-1", exit 0
#     and leave .maintenance behind: the run reported success while the site
#     served 503. The output is now read as a failure, the update is retried once
#     with --skip-plugins --skip-themes, and the leftover flag is cleared.
#   - --health counted every non-empty line of `plugin list` as a plugin, so a
#     site with WP_DEBUG and deprecation notices reported 20 pending updates when
#     nothing was pending.
#   - the finder listed dated copies (.wp-YYYYMMDD) and a second tree on the same
#     database as if they were separate sites.
#
# The rules this suite enforces:
#   - a check that cannot load WordPress is a failure, not a silent ✓;
#   - "nothing was applied" is never reported as success;
#   - a site left in maintenance mode is noticed and cleared, in the log;
#   - counts come from rows, not from any line that happens to be non-empty.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-ops.XXXXXX")"
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
# The stub keeps its hooks next to the argv log, which the fixture makes writable
# for the account the stub runs as.
HOOK_BASE="$ARGV_LOG"

marker_set() { : >"${HOOK_BASE}.${1}"; }
marker_clear() { rm -f "${HOOK_BASE}.${1}"; }

mrun() { manager_run --no-user-switch "$@"; }

say '--check notices a site whose WordPress does not load'
out="$(mrun --check --site "$SITES" 2>&1)"
case "$out" in
    *'wp loads'*) ok '--check reports a site that loads as healthy' ;;
    *) bad '--check reports a site that loads as healthy' "$out" ;;
esac
marker_set broken
out="$(mrun --check --site "$SITES" 2>&1)"
rc=$?
case "$out" in
    *'✗ wp: PHP Parse error'*) ok '--check names the parse error instead of a silent tick' ;;
    *) bad '--check names the parse error instead of a silent tick' "$out" ;;
esac
if [ "$rc" -ne 0 ]; then
    ok "--check exits non-zero for a site that cannot load (rc=$rc)"
else
    bad '--check exits non-zero for a site that cannot load' "exit 0"
fi
out="$(mrun --check --no-wp-probe --site "$SITES" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'wp:'; then
    ok '--no-wp-probe skips the probe and the site passes on files alone'
else
    bad '--no-wp-probe skips the probe and the site passes on files alone' "$out"
fi
marker_clear broken

say 'an aborted upgrader is a failure, and the retry unloads plugin code'
marker_set abort-update
: >"$ARGV_LOG"
out="$(mrun --plugins --backup off 2>&1)"
rc=$?
case "$out" in
    *aborted*|*'retrying once with --skip-plugins'*)
        ok 'the run says the upgrader aborted' ;;
    *) bad 'the run says the upgrader aborted' "$out" ;;
esac
if grep -q -- '--skip-plugins' "$ARGV_LOG"; then
    ok 'the retry passed --skip-plugins'
else
    bad 'the retry passed --skip-plugins' "$(cat "$ARGV_LOG")"
fi
if [ "$rc" -eq 0 ]; then
    ok 'a successful retry leaves the site OK'
else
    bad 'a successful retry leaves the site OK' "exit $rc"
fi
marker_clear abort-update

say 'an upgrader that keeps aborting fails the site'
marker_set abort-update-always
out="$(mrun --plugins --backup off 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    ok "--a permanently aborted update fails the site (rc=$rc)"
else
    bad '--a permanently aborted update fails the site' "exit 0: $out"
fi
case "$out" in
    *'nothing was applied'*) ok 'the log says nothing was applied' ;;
    *) bad 'the log says nothing was applied' "$out" ;;
esac
marker_clear abort-update-always

say 'a site left in maintenance mode is cleared and reported'
: >"${SITES}/.maintenance"
printf '<?php $upgrading = 1; ?>\n' >"${SITES}/.maintenance"
out="$(mrun --core --backup off 2>&1)"
rc=$?
if [ -f "${SITES}/.maintenance" ]; then
    bad 'the leftover .maintenance flag is removed' 'the file is still there'
else
    ok 'the leftover .maintenance flag is removed'
fi
case "$out" in
    *'leftover .maintenance'*) ok 'the removal is reported as a warning' ;;
    *) bad 'the removal is reported as a warning' "$out" ;;
esac
if [ "$rc" -eq 0 ]; then
    ok 'a cleared flag does not by itself fail the site'
else
    bad 'a cleared flag does not by itself fail the site' "exit $rc"
fi

say 'a dry run never removes the flag'
printf '<?php $upgrading = 1; ?>\n' >"${SITES}/.maintenance"
out="$(mrun --core --backup off --dry-run 2>&1)"
if [ -f "${SITES}/.maintenance" ]; then
    ok 'dry run leaves the flag alone'
else
    bad 'dry run leaves the flag alone' 'the file was removed'
fi
case "$out" in
    *'would remove'*) ok 'dry run says what it would do' ;;
    *) bad 'dry run says what it would do' "$out" ;;
esac
rm -f "${SITES}/.maintenance"

say 'deprecation noise does not inflate the pending counts'
plain="$(mrun --health --site "$SITES" 2>&1)"
marker_set noise
noisy="$(mrun --health --site "$SITES" 2>&1)"
marker_clear noise
col_plugins() { printf '%s\n' "$1" | awk '/^example\.com/ { print $3 }'; }
if [ -n "$(col_plugins "$plain")" ] && [ "$(col_plugins "$plain")" = "$(col_plugins "$noisy")" ]; then
    ok "--health counts the same with and without site noise ($(col_plugins "$plain") plugins)"
else
    bad '--health counts the same with and without site noise' \
        "plain='$(col_plugins "$plain")' noisy='$(col_plugins "$noisy")'"
fi

say 'the finder does not list a dated copy of an installation'
OUT="${WORK}/found.txt"
cp -a "$SITES" "${SITE_ROOT}/example.com.wp-20261018"
finder_run --output "$OUT" "$SITE_ROOT" >"${WORK}/found-copy.log" 2>&1
if grep -q 'example.com.wp-20261018' "$OUT" 2>/dev/null; then
    bad 'a dated copy is not listed as a site' "$(cat "$OUT")"
else
    ok 'a dated copy is not listed as a site'
fi
if grep -q 'example.com$' "$OUT" 2>/dev/null; then
    ok 'the real site next to the copy is still listed'
else
    bad 'the real site next to the copy is still listed' "$(cat "$OUT" 2>/dev/null)"
fi
rm -rf "${SITE_ROOT}/example.com.wp-20261018"

say 'the finder does not list a second tree on the same database'
mkdir -p "${SITE_ROOT}/twin-a/wp-includes" "${SITE_ROOT}/twin-b/wp-includes"
for d in twin-a twin-b; do
    printf '<?php\ndefine("DB_NAME", "shared_db");\ndefine("DB_USER", "siteuser");\ndefine("DB_HOST", "localhost");\n$table_prefix = "wp_";\n' \
        >"${SITE_ROOT}/${d}/wp-config.php"
    printf '<?php\n$wp_version = "6.6.2";\n' >"${SITE_ROOT}/${d}/wp-includes/version.php"
    printf '<?php // wp-load\n' >"${SITE_ROOT}/${d}/wp-load.php"
    chmod -R a+rX "${SITE_ROOT}/${d}"
done
finder_run --output "$OUT" "$SITE_ROOT" >"${WORK}/found-shared.log" 2>&1
twins="$(grep -c 'twin-' "$OUT" 2>/dev/null || printf 0)"
if [ "$twins" = '1' ]; then
    ok 'only the first of two roots on one database is listed'
else
    bad 'only the first of two roots on one database is listed' "found ${twins} of 2"
fi
case "$(cat "${WORK}/found-shared.log")" in
    *'same database as'*) ok 'the skipped twin is reported with the winner path' ;;
    *) bad 'the skipped twin is reported with the winner path' "$(cat "${WORK}/found-shared.log")" ;;
esac
finder_run --allow-shared-db --output "$OUT" "$SITE_ROOT" >/dev/null 2>&1
twins="$(grep -c 'twin-' "$OUT" 2>/dev/null || printf 0)"
if [ "$twins" = '2' ]; then
    ok '--allow-shared-db keeps both roots'
else
    bad '--allow-shared-db keeps both roots' "found ${twins} of 2"
fi
rm -rf "${SITE_ROOT}/twin-a" "${SITE_ROOT}/twin-b"

say 'the new option is documented, completed and configurable'
help_out="$(bash "$M" --help 2>&1)"
case "$help_out" in
    *'--no-wp-probe'*) ok '--no-wp-probe is documented in --help' ;;
    *) bad '--no-wp-probe is documented in --help' '' ;;
esac
comp_out="$(bash "$M" --completion bash 2>&1)"
case "$comp_out" in
    *'--no-wp-probe'*) ok '--no-wp-probe is offered by the completion' ;;
    *) bad '--no-wp-probe is offered by the completion' '' ;;
esac
printf 'WP_PROBE=false\n' >"${WORK}/probe-off.conf"
out="$(mrun --config "${WORK}/probe-off.conf" --print-config 2>&1)"
case "$out" in
    *'WP_PROBE'*'false'*) ok 'WP_PROBE=false is accepted from the config file' ;;
    *) bad 'WP_PROBE=false is accepted from the config file' "$out" ;;
esac
printf 'WP_PROBE=maybe\n' >"${WORK}/probe-bad.conf"
mrun --config "${WORK}/probe-bad.conf" --check >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    ok 'an invalid WP_PROBE is rejected'
else
    bad 'an invalid WP_PROBE is rejected' 'exit 0'
fi

report 'ops'

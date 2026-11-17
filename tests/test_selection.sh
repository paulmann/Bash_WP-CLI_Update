#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016,SC1091
# Regression suite for the selective update path: --only-active, --exclude-plugins,
# --hold-plugins, --exclude-themes, --hold-themes and --plugin-manage.
#
# Every check here exists because of a real failure on a host running WP-CLI
# 2.12.0, and none of them could have been caught before the stub `wp` was made
# to refuse fields the real binary refuses:
#
#   * `wp plugin list --fields=name,slug,status,update` is a hard error
#     ("Invalid field: slug.", exit 1). There is no `slug` field: `name` *is* the
#     slug, and the display name is `title`. Asking for `slug` made every site
#     log "cannot enumerate plugins ... nothing was updated" and count as failed,
#     which is what broke the nightly --full run.
#   * mu-plugins and dropins appear in `plugin list` but cannot be updated:
#     `wp plugin update <them>` answers "could not be found" and fails the site.
#   * the documented match "by slug or display name" needs both fields, so the
#     enumeration asks for `name,title` in one call rather than guessing.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-selection.XXXXXX")"
chmod 755 "$WORK"
FAIL_FILE="${FAIL_FILE:-${WORK}/fail}"
PASS_FILE="${PASS_FILE:-${WORK}/pass}"
SKIP_FILE="${SKIP_FILE:-${WORK}/skip}"
export FAIL_FILE PASS_FILE SKIP_FILE
# shellcheck source=tests/harness.sh
. "${here}/harness.sh"
trap 'rm -rf -- "$WORK"' EXIT
build_fixture

OUT="${WORK}/run.txt"

# update_line: the recorded `plugin update` / `theme update` invocation, if any.
update_line() { grep -F -- "[$1] [update]" "$ARGV_LOG" 2>/dev/null | head -1; }

say 'the selection path asks for fields WP-CLI 2.x actually has'
argv_log_reset
manager_run --plugins --exclude-plugins akismet >"$OUT" 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok '--plugins --exclude-plugins exits 0'
else
    bad '--plugins --exclude-plugins failed' "exit ${rc}: $(tail -3 "$OUT")"
fi
if grep -Fq '[--fields=name,title,status,update]' "$ARGV_LOG" 2>/dev/null; then
    ok 'plugin list asks for name,title,status,update in one call'
else
    bad 'plugin list field set' "$(grep -F '[plugin] [list]' "$ARGV_LOG" 2>/dev/null | head -1)"
fi
if grep -Fq '[slug]' "$ARGV_LOG" 2>/dev/null || grep -Fq 'name,slug' "$ARGV_LOG" 2>/dev/null; then
    bad 'a field WP-CLI does not have was requested' "$(grep -F 'slug' "$ARGV_LOG" | head -1)"
else
    ok 'no request mentions the nonexistent `slug` field'
fi
if grep -Fq 'Invalid field' "$OUT" 2>/dev/null; then
    bad 'wp rejected the field set' "$(grep -F 'Invalid field' "$OUT" | head -1)"
else
    ok 'no "Invalid field" answer from wp'
fi
line="$(update_line plugin)"
if printf '%s' "$line" | grep -Fq '[woocommerce]' && printf '%s' "$line" | grep -Fq '[jetpack]'; then
    ok 'the plugins that need it are passed to a single plugin update'
else
    bad 'plugin update did not receive the selected slugs' "${line:-no update call}"
fi
if printf '%s' "$line" | grep -Fq '[akismet]'; then
    bad 'an excluded plugin was still updated' "$line"
else
    ok 'the excluded plugin is not in the update command'
fi

say 'mu-plugins and dropins never reach plugin update'
if printf '%s' "$line" | grep -Fq '[zbs-support]'; then
    bad 'a mu-plugin was passed to plugin update' "$line"
else
    ok 'the mu-plugin is left out'
fi
if printf '%s' "$line" | grep -Fq '[object-cache.php]'; then
    bad 'a dropin was passed to plugin update' "$line"
else
    ok 'the dropin is left out'
fi
# The filter must survive --only-active, where the fixture's mu-plugin and dropin
# both carry an available update and would otherwise be the only candidates.
argv_log_reset
manager_run --plugins --only-active >"$OUT" 2>&1
line="$(update_line plugin)"
if printf '%s' "$line" | grep -Fq '[jetpack]' &&
    ! printf '%s' "$line" | grep -Fq '[zbs-support]' &&
    ! printf '%s' "$line" | grep -Fq '[object-cache.php]'; then
    ok '--only-active selects the active updatable plugin only'
else
    bad '--only-active selection' "${line:-no update call}"
fi

say 'a display name matches as well as a slug'
argv_log_reset
manager_run --plugins --exclude-plugins 'All in One SEO (AIOSEO)' >"$OUT" 2>&1
rc=$?
line="$(update_line plugin)"
if [ "$rc" = '0' ] && ! printf '%s' "$line" | grep -Fq '[all-in-one-seo-pack]' &&
    printf '%s' "$line" | grep -Fq '[woocommerce]'; then
    ok 'excluding by display name (with spaces) leaves that plugin out'
else
    bad 'display-name exclusion' "exit ${rc}: ${line:-no update call}"
fi
argv_log_reset
manager_run --plugins --hold-plugins 'Akismet Anti-Spam' >"$OUT" 2>&1
if grep -Fq 'held by HOLD_PLUGINS, not updated: akismet' "$LOG_FILE" 2>/dev/null; then
    ok '--hold-plugins accepts the display name and names the slug'
else
    bad 'hold by display name' "$(grep -F 'HOLD_PLUGINS' "$LOG_FILE" | tail -1)"
fi

say 'themes use the same field set'
argv_log_reset
manager_run --themes --exclude-themes astra >"$OUT" 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok '--themes --exclude-themes exits 0'
else
    bad '--themes --exclude-themes failed' "exit ${rc}: $(tail -3 "$OUT")"
fi
if grep -Fq '[--fields=name,title,status,update]' "$ARGV_LOG" 2>/dev/null; then
    ok 'theme list asks for name,title,status,update'
else
    bad 'theme list field set' "$(grep -F '[theme] [list]' "$ARGV_LOG" 2>/dev/null | head -1)"
fi
line="$(update_line theme)"
if printf '%s' "$line" | grep -Fq '[astra]'; then
    bad 'an excluded theme was updated' "$line"
else
    ok 'the excluded theme is not in the update command'
fi

say 'the --all path is unchanged'
argv_log_reset
manager_run --plugins >"$OUT" 2>&1
if grep -Fq '[plugin] [update] [--all]' "$ARGV_LOG" 2>/dev/null; then
    ok '--plugins without policy flags still runs plugin update --all'
else
    bad 'the --all path changed' "$(grep -F '[plugin] [update]' "$ARGV_LOG" | head -1)"
fi
if grep -Fq '[plugin] [list]' "$ARGV_LOG" 2>/dev/null; then
    bad 'the --all path enumerated plugins' 'nothing should be listed when --all is used'
else
    ok 'no enumeration on the --all path'
fi

say 'an older WP-CLI without the title field still works'
: >"${ARGV_LOG}.no-title"
argv_log_reset
manager_run --plugins --only-active >"$OUT" 2>&1
rc=$?
line="$(update_line plugin)"
if [ "$rc" = '0' ] && printf '%s' "$line" | grep -Fq '[jetpack]'; then
    ok 'the fallback field set keeps the selection working'
else
    bad 'fallback on a WP-CLI without title' "exit ${rc}: ${line:-no update call}"
fi
if grep -Fq '[--fields=name,status,update]' "$ARGV_LOG" 2>/dev/null; then
    ok 'the retry asks for name,status,update'
else
    bad 'the retry did not drop the title field' "$(grep -F '[plugin] [list]' "$ARGV_LOG" | head -2)"
fi
rm -f -- "${ARGV_LOG}.no-title"

say '--debug does not corrupt the helpers that return a value'
# pending_count and site_core_version return their answer on stdout. A console
# echo captured by $(...) used to make them return "DBG ..." and kill the run
# with "DBG: unbound variable" -- reachable on any host that sets
# SKIP_IF_NO_UPDATES=1 and debugs a problem.
argv_log_reset
manager_run --plugins --skip-if-no-updates --debug >"$OUT" 2>&1
rc=$?
if [ "$rc" = '0' ]; then
    ok '--debug --skip-if-no-updates exits 0'
else
    bad 'a debug run with the pending check failed' "exit ${rc}: $(grep -F -m1 'unbound' "$OUT") $(tail -2 "$OUT")"
fi
if grep -Fq 'unbound variable' "$OUT" 2>/dev/null; then
    bad 'a captured helper returned a log line' "$(grep -F -m1 'unbound' "$OUT")"
else
    ok 'no helper returned its own log line'
fi

say '--plugin-manage resolves the slug from the name'
argv_log_reset
manager_run -m -A deactivate -N 'Akismet Anti-Spam' --yes >"$OUT" 2>&1
rc=$?
if [ "$rc" = '0' ] && grep -Fq '[plugin] [deactivate] [akismet]' "$ARGV_LOG" 2>/dev/null; then
    ok 'the display name resolves to the slug akismet'
else
    bad 'plugin-manage could not resolve the display name' "exit ${rc}: $(grep -F '[plugin] [deactivate]' "$ARGV_LOG" | head -1)"
fi

report 'test_selection.sh'

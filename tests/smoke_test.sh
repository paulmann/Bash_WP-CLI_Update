#!/usr/bin/env bash
# ==============================================================================
# Smoke tests for Bash_WP-CLI_Update.sh and Find_WP_Senior.sh
#
# Self-contained: builds a fake WordPress tree and a mock WP-CLI binary, then
# exercises every mode and asserts the exact WP-CLI commands that were issued.
# No root, no real WordPress and no network access required.
#
# Usage:
#   ./tests/smoke_test.sh            # run all cases
#   BASH_BIN=/usr/local/bin/bash ./tests/smoke_test.sh
#
# Exit code: 0 = all cases passed, 1 = at least one failure.
# ==============================================================================

set -uo pipefail

BASH_BIN="${BASH_BIN:-bash}"
TEST_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -P -- "${TEST_DIR}/.." && pwd)"
MAIN="${PROJECT_DIR}/Bash_WP-CLI_Update.sh"
FINDER="${PROJECT_DIR}/Find_WP_Senior.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpmaint-tests.XXXXXXXX")"
BIN="${WORK}/bin"
SITES_DIR="${WORK}/sites"
WP_MOCK_LOG="${WORK}/wp-argv.log"

C_GREEN=""; C_RED=""; C_DIM=""; C_RESET=""
if [[ -t 1 ]]; then
	C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
fi

ok()   { PASS=$((PASS + 1)); printf '%s  ok  %s%s\n' "${C_GREEN}" "$1" "${C_RESET}"; }
bad()  { FAIL=$((FAIL + 1)); printf '%sFAIL  %s%s\n' "${C_RED}" "$1" "${C_RESET}"; }
note() { printf '%s      %s%s\n' "${C_DIM}" "$1" "${C_RESET}"; }

cleanup() { rm -rf -- "${WORK}"; }
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------
make_site() {
	local dir="$1"
	mkdir -p "${dir}/wp-includes" "${dir}/wp-content/plugins" "${dir}/wp-content/themes"
	cat >"${dir}/wp-config.php" <<'PHP'
<?php
define( 'DB_NAME', 'wp' );
define( 'DB_USER', 'wpuser' );
define( 'WP_HOME', 'http://example.test' );
define( 'WP_SITEURL', 'http://example.test' );
PHP
	printf '<?php $wp_version = "6.5.2";\n' >"${dir}/wp-includes/version.php"
	printf '<?php\n' >"${dir}/wp-settings.php"
	mkdir -p "${dir}/wp-content/plugins/akismet" "${dir}/wp-content/plugins/jetpack" "${dir}/wp-content/plugins/old-plugin"
}

write_mock_wp() {
	mkdir -p "${BIN}"
	cat >"${BIN}/wp" <<MOCK
#!${BASH_BIN}
# Mock WP-CLI used by tests/smoke_test.sh
printf '%s\n' "\$*" >>"${WP_MOCK_LOG}"

SITE=""
FORMAT=""
FIELDS=""
ARGS=()
while ((\$#)); do
	case "\$1" in
		--path=*) SITE="\${1#*=}" ;;
		--format=*) FORMAT="\${1#*=}" ;;
		--fields=*) FIELDS="\${1#*=}" ;;
		--url=*|--skip-plugins=*|--no-color|--allow-root|--quiet|--dry-run) ;;
		*) ARGS+=("\$1") ;;
	esac
	shift
done
BASE="\$(basename -- "\${SITE:-unknown}")"

plugins_json() {
	case "\${BASE}" in
		site2) cat <<'JSON'
[{"name":"hello-dolly.php","title":"Hello Dolly","status":"active","version":"1.7.2","update":"none","update_version":""},
 {"name":"woocommerce.php","title":"WooCommerce","status":"inactive","version":"8.0.0","update":"available","update_version":"9.1.0"}]
JSON
		;;
		evilsite) cat <<'JSON'
[{"name":"totally-safe.php","title":"Safe; \$(touch /tmp/wpmaint-pwned-title) \"quoted\"","status":"active","version":"1.0","update":"none","update_version":""},
 {"name":"evil-plugin.php","title":"Evil","status":"active","version":"1.0","update":"none","update_version":""}]
JSON
		;;
		*) cat <<'JSON'
[{"name":"akismet.php","title":"Akismet Anti-Spam","status":"active","version":"5.3","update":"none","update_version":""},
 {"name":"jetpack.php","title":"Jetpack","status":"active","version":"13.0","update":"available","update_version":"13.5"},
 {"name":"jetpack-boost.php","title":"Jetpack Boost","status":"active","version":"2.0","update":"none","update_version":""},
 {"name":"old-plugin.php","title":"Old Plugin","status":"inactive","version":"1.0","update":"none","update_version":""}]
JSON
		;;
	esac
}

plugins_csv() {
	case "\${BASE}" in
		site2) printf 'name,title,status,version,update,update_version\nhello-dolly.php,Hello Dolly,active,1.7.2,none,\nwoocommerce.php,"WooCommerce, Inc.",inactive,8.0.0,available,9.1.0\n' ;;
		*)     printf 'name,title,status,version,update,update_version\nakismet.php,Akismet Anti-Spam,active,5.3,none,\njetpack.php,Jetpack,active,13.0,available,13.5\njetpack-boost.php,Jetpack Boost,active,2.0,none,\nold-plugin.php,Old Plugin,inactive,1.0,none,\n' ;;
	esac
}

CMD="\${ARGS[0]:-} \${ARGS[1]:-}"
case "\${CMD}" in
	"plugin list")
		if [[ "\${FORMAT}" == "csv" ]]; then plugins_csv; else plugins_json; fi
		exit 0 ;;
	"plugin update")
		if [[ "\${BASE}" == "failsite" ]]; then echo "Error: update failed" >&2; exit 1; fi
		echo "Success: Updated plugins."; exit 0 ;;
	"core update"|"core update-db"|"db optimize"|"db repair"|"cron event run"|"cache flush"|"rewrite flush")
		echo "Success: \${CMD}"; exit 0 ;;
	"plugin activate"|"plugin deactivate"|"plugin delete")
		if [[ "\${BASE}" == "failsite" ]]; then echo "Error: cannot write" >&2; exit 1; fi
		echo "Success: \${CMD}"; exit 0 ;;
	"theme update"|"theme list")
		if [[ "\${FORMAT}" == "count" ]]; then echo "1"; fi
		exit 0 ;;
	"core version") echo "6.5.2"; exit 0 ;;
	"db size") echo "42"; exit 0 ;;
	"option get") echo "http://\${BASE}.example.test"; exit 0 ;;
	"db export")
		OUT="\${ARGS[2]:-}"
		printf -- '-- fake dump\n' >"\${OUT}" 2>/dev/null || exit 1
		exit 0 ;;
	"core verify-checksums")
		if [[ "\${BASE}" == "badsum" ]]; then echo "Error: checksum mismatch" >&2; exit 1; fi
		exit 0 ;;
	"plugin verify-checksums") exit 0 ;;
	"brainstormforce license") echo "Success: licence activated"; exit 0 ;;
	*) echo "[mock wp] \${CMD} \$*"; exit 0 ;;
esac
MOCK
	chmod +x "${BIN}/wp"
}

# ------------------------------------------------------------------------------
# Runners
# ------------------------------------------------------------------------------
run_main() { # run_main <name> <expected-rc> -- <args...>
	local name="$1" expected="$2"
	shift 2
	[[ "$1" == "--" ]] && shift
	: >"${WP_MOCK_LOG}"
	local out rc=0
	out="$("${BASH_BIN}" "${MAIN}" --wp-bin "${BIN}/wp" --no-user-switch --no-color \
		--log-dir "${WORK}/logs" -B "${WORK}/backups" --quiet "$@" 2>&1)" || rc=$?
	LAST_OUT="${out}"
	LAST_RC="${rc}"
	if [[ "${rc}" == "${expected}" ]]; then
		ok "${name} (rc=${rc})"
	else
		bad "${name}: expected rc=${expected}, got rc=${rc}"
		printf '%s\n' "${out}" | tail -20 | sed 's/^/      | /'
	fi
}

assert_log_contains() {
	local name="$1" needle="$2"
	if grep -qF -- "${needle}" "${WP_MOCK_LOG}"; then
		ok "${name}"
	else
		bad "${name}: '${needle}' not found in mock WP-CLI log"
		sed 's/^/      | /' "${WP_MOCK_LOG}" | head -20
	fi
}

assert_log_lacks() {
	local name="$1" needle="$2"
	if grep -qF -- "${needle}" "${WP_MOCK_LOG}"; then
		bad "${name}: unexpected '${needle}' in the mock log"
		sed 's/^/      | /' "${WP_MOCK_LOG}" | head -20
	else
		ok "${name}"
	fi
}

assert_out_contains() {
	local name="$1" needle="$2"
	if grep -qF -- "${needle}" <<<"${LAST_OUT}"; then
		ok "${name}"
	else
		bad "${name}: '${needle}' not found in output"
		printf '%s\n' "${LAST_OUT}" | tail -15 | sed 's/^/      | /'
	fi
}

assert_out_lacks() {
	local name="$1" needle="$2"
	if grep -qF -- "${needle}" <<<"${LAST_OUT}"; then
		bad "${name}: unexpected '${needle}' in output"
	else
		ok "${name}"
	fi
}

# ------------------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------------------
printf 'Bash: %s\n' "$("${BASH_BIN}" -c 'printf "%s" "$BASH_VERSION"')"
printf 'Work dir: %s\n\n' "${WORK}"

make_site "${SITES_DIR}/site1"
make_site "${SITES_DIR}/site2"
make_site "${SITES_DIR}/failsite"
make_site "${SITES_DIR}/badsum"
make_site "${SITES_DIR}/evilsite"
# A directory name that would break any shell string interpolation.
EVIL_DIR="${SITES_DIR}/evil; touch ${WORK}/pwned-dir; #"
make_site "${EVIL_DIR}"
printf '%s\n' "${SITES_DIR}/site1" "${SITES_DIR}/site2" >"${WORK}/sites.txt"

write_mock_wp

printf '%s\n' "── Finder (Find_WP_Senior.sh) ─────────────────────────────"

FIND_OUT="$("${BASH_BIN}" "${FINDER}" -q -o - --dry-run "${SITES_DIR}" 2>&1)"
if grep -q "site1" <<<"${FIND_OUT}" && grep -q "site2" <<<"${FIND_OUT}"; then
	ok "finder discovers sites"
else
	bad "finder discovers sites"; printf '%s\n' "${FIND_OUT}" | sed 's/^/      | /'
fi
if grep -q "badsum" <<<"${FIND_OUT}"; then
	ok "finder reports every WordPress root"
else
	bad "finder reports every WordPress root"
fi

rc=0
"${BASH_BIN}" "${FINDER}" -q -o "${WORK}/found.txt" "${SITES_DIR}" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" == "0" && -s "${WORK}/found.txt" ]]; then
	ok "finder writes the output file atomically (--output works)"
else
	bad "finder --output failed (rc=${rc})"
fi

rc=0
"${BASH_BIN}" "${FINDER}" --exclude >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "2" ]] && ok "finder: missing option value exits 2" || bad "finder: missing value returned rc=${rc} (expected 2)"

rc=0
"${BASH_BIN}" "${FINDER}" --help >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "0" ]] && ok "finder: --help exits 0" || bad "finder: --help returned rc=${rc}"

printf '\n%s\n' "── Main script: inventory ─────────────────────────────────"

run_main "list-plugins (table)" 0 -- --list-plugins -S "${SITES_DIR}/site1"
assert_out_contains "table lists Akismet" "Akismet"
assert_out_contains "table lists Jetpack update" "13.5"
assert_out_lacks "table does not show N/A slug" "N/A"

run_main "list-plugins (json)" 0 -- --list-plugins -S "${SITES_DIR}/site1" -J
if command -v python3 >/dev/null 2>&1; then
	if printf '%s\n' "${LAST_OUT}" | python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]' 2>/dev/null; then
		ok "json output is valid JSON Lines"
	else
		bad "json output is not valid JSON"; printf '%s\n' "${LAST_OUT}" | sed 's/^/      | /'
	fi
else
	note "python3 not available — JSON validation skipped"
fi
assert_out_contains "json contains plugin slug" '"slug":"jetpack"'

run_main "list-plugins (filter)" 0 -- --list-plugins -S "${SITES_DIR}/site1" -N jetpack
assert_out_contains "filter keeps Jetpack" "Jetpack"
assert_out_lacks "filter drops Akismet" "Akismet"

# CSV fallback: hide jq from PATH
mkdir -p "${WORK}/nojq"
for tool in bash sh env awk sed grep cat printf mkdir rm ls head tail cut tr sort date id basename dirname stat mktemp find chmod; do
	[[ -x "$(command -v "${tool}" 2>/dev/null)" ]] && ln -sf "$(command -v "${tool}")" "${WORK}/nojq/${tool}" 2>/dev/null
done
cp "${BIN}/wp" "${WORK}/nojq/wp"
CSV_OUT="$(PATH="${WORK}/nojq" "${BASH_BIN}" "${MAIN}" --wp-bin "${WORK}/nojq/wp" --no-user-switch --no-color \
	--log-dir "${WORK}/logs" --list-plugins -S "${SITES_DIR}/site1" 2>&1)"
if grep -q "Jetpack" <<<"${CSV_OUT}" && grep -q "13.5" <<<"${CSV_OUT}"; then
	ok "CSV fallback works without jq"
else
	bad "CSV fallback without jq failed"
	printf '%s\n' "${CSV_OUT}" | tail -10 | sed 's/^/      | /'
fi
if grep -q 'WooCommerce, Inc.' <<<"$(PATH="${WORK}/nojq" "${BASH_BIN}" "${MAIN}" --wp-bin "${WORK}/nojq/wp" \
	--no-user-switch --no-color --log-dir "${WORK}/logs" --list-plugins -S "${SITES_DIR}/site2" 2>&1)"; then
	ok "CSV parser handles quoted fields with commas"
else
	bad "CSV parser mishandles quoted fields"
fi

printf '\n%s\n' "── Main script: updates ───────────────────────────────────"

run_main "plugins update" 0 -- --plugins -S "${SITES_DIR}/site1"
assert_log_contains "issued 'plugin update --all'" "plugin update --all"
assert_log_contains "passes --skip-plugins" "--skip-plugins=saphali-woocommerce-lite,jet-compare-wishlist,jet-data-importer"

run_main "plugins update (only-active)" 0 -- --plugins -S "${SITES_DIR}/site1" --only-active
assert_log_contains "only-active updates jetpack" "plugin update jetpack"
assert_log_lacks "only-active skips inactive plugins" "plugin update old-plugin"

run_main "themes update" 0 -- --themes -S "${SITES_DIR}/site1"
assert_log_contains "issued 'theme update --all'" "theme update --all"

run_main "core update" 0 -- --core -S "${SITES_DIR}/site1"
assert_log_contains "issued 'core update'" "core update"
assert_log_contains "issued 'core update-db'" "core update-db"

run_main "db optimize" 0 -- --db-optimize -S "${SITES_DIR}/site1"
assert_log_contains "issued 'db optimize'" "db optimize"
assert_log_contains "issued 'db repair'" "db repair"

run_main "cron" 0 -- --cron -S "${SITES_DIR}/site1"
assert_log_contains "issued 'cron event run --due-now'" "cron event run --due-now"

run_main "full update" 0 -- --full -S "${SITES_DIR}/site1"
assert_log_contains "full: core update" "core update"
assert_log_contains "full: plugin update" "plugin update --all"
assert_log_contains "full: theme update" "theme update --all"
assert_log_contains "full: cron" "cron event run --due-now"

run_main "status" 0 -- --status -S "${SITES_DIR}/site1"
assert_out_contains "status reports the core version" "6.5.2"
assert_out_contains "status reports plugin updates" "plugin updates : 1"

run_main "verify" 0 -- --verify -S "${SITES_DIR}/site1"
assert_log_contains "verify: core checksums" "core verify-checksums"
assert_log_contains "verify: plugin checksums" "plugin verify-checksums --all"

printf '\n%s\n' "── Main script: plugin management ─────────────────────────"

run_main "exact slug wins over partial matches" 0 -- --plugin-manage -A deactivate -N jetpack -S "${SITES_DIR}/site1" --yes
assert_log_contains "deactivates the exact slug" "plugin deactivate jetpack"
assert_log_lacks "no ambiguity error for an exact slug" "matches 2 plugins"

run_main "plugin deactivate (already inactive)" 0 -- --plugin-manage -A deactivate -N old-plugin -S "${SITES_DIR}/site1" --yes
assert_log_lacks "no-op when already inactive" "plugin deactivate old-plugin"

run_main "plugin activate" 0 -- --plugin-manage -A activate -N old-plugin -S "${SITES_DIR}/site1" --yes
assert_log_contains "activates the exact slug" "plugin activate old-plugin"

run_main "plugin delete (active plugin: deactivate + backup)" 0 -- --plugin-manage -A delete -N jetpack -S "${SITES_DIR}/site1" --yes
assert_log_contains "deactivates before delete" "plugin deactivate jetpack"
assert_log_contains "deletes the plugin" "plugin delete jetpack"
if ls "${WORK}"/backups/site1/plugin-jetpack-*.tar.gz >/dev/null 2>&1; then
	ok "plugin files backed up before deletion"
else
	bad "no plugin backup archive found"
	ls -la "${WORK}/backups" 2>&1 | sed 's/^/      | /'
fi

run_main "plugin delete (inactive plugin: no deactivate)" 0 -- --plugin-manage -A delete -N old-plugin -S "${SITES_DIR}/site1" --yes
assert_log_contains "deletes the inactive plugin" "plugin delete old-plugin"
assert_log_lacks "no needless deactivate" "plugin deactivate old-plugin"

run_main "plugin delete with --no-backup" 0 -- --plugin-manage -A delete -N akismet -S "${SITES_DIR}/site1" --yes --no-backup
assert_log_contains "still deletes the plugin" "plugin delete akismet"
if ls "${WORK}"/backups/site1/plugin-akismet-*.tar.gz >/dev/null 2>&1; then
	bad "--no-backup still created an archive"
else
	ok "--no-backup skips the file backup"
fi

run_main "plugin delete without --yes is refused (no TTY)" 1 -- --plugin-manage -A delete -N jetpack -S "${SITES_DIR}/site1"
assert_log_lacks "nothing deleted without confirmation" "plugin delete jetpack"

run_main "ambiguous plugin name is refused" 1 -- --plugin-manage -A deactivate -N jet -S "${SITES_DIR}/site1" --yes
assert_log_lacks "nothing deactivated on ambiguity" "plugin deactivate"

run_main "no plugin found" 1 -- --plugin-manage -A deactivate -N doesnotexist -S "${SITES_DIR}/site1" --yes

printf '\n%s\n' "── Main script: dry-run, failures, parallelism ────────────"

run_main "dry-run full" 0 -- --full -S "${SITES_DIR}/site1" --dry-run
assert_log_contains "dry-run: core update --dry-run" "core update --dry-run"
assert_log_lacks "dry-run: db optimize not executed" "db optimize"

run_main "failed update propagates rc" 1 -- --plugins -S "${SITES_DIR}/failsite"
assert_out_contains "failure is reported" "failed"

run_main "checksum mismatch fails --verify" 1 -- --verify -S "${SITES_DIR}/badsum"

run_main "missing site directory" 0 -- --plugins -S "${SITES_DIR}/nope"
assert_out_contains "missing site is skipped" "skipping (not a directory)"

printf '%s\n' "${SITES_DIR}/site1" "${SITES_DIR}/site2" >"${WORK}/sites.txt"
rc=0
PAR_OUT="$("${BASH_BIN}" "${MAIN}" --wp-bin "${BIN}/wp" --no-user-switch --no-color --log-dir "${WORK}/logs" \
	-B "${WORK}/backups" --sites-file "${WORK}/sites.txt" --plugins -j 2 2>&1)" || rc=$?
if [[ "${rc}" == "0" ]] && grep -q "site1" <<<"${PAR_OUT}" && grep -q "site2" <<<"${PAR_OUT}"; then
	ok "parallel run over the sites file (--jobs 2)"
else
	bad "parallel run failed (rc=${rc})"
	printf '%s\n' "${PAR_OUT}" | tail -20 | sed 's/^/      | /'
fi

printf '\n%s\n' "── Security: adversarial input ────────────────────────────"

run_main "list-plugins on a hostile plugin title" 0 -- --list-plugins -S "${SITES_DIR}/evilsite"
if [[ -e /tmp/wpmaint-pwned-title ]]; then
	bad "SECURITY: command substitution from a plugin title was executed"
	rm -f /tmp/wpmaint-pwned-title
else
	ok "plugin title metacharacters are not executed"
fi
assert_out_contains "hostile title is displayed literally" 'Safe; $(touch'

run_main "site path containing shell metacharacters" 0 -- --plugins -S "${EVIL_DIR}"
if [[ -e "${WORK}/pwned-dir" ]]; then
	bad "SECURITY: command injection through the site path"
else
	ok "site path metacharacters are not executed"
fi

run_main "plugin name containing shell metacharacters" 1 -- --plugin-manage -A delete -N 'x; touch /tmp/wpmaint-pwned-name; #' -S "${SITES_DIR}/site1" --yes
assert_log_lacks "no WP-CLI call is made for an unmatched hostile name" "plugin delete x"
if [[ -e /tmp/wpmaint-pwned-name ]]; then
	bad "SECURITY: command injection through --name"
	rm -f /tmp/wpmaint-pwned-name
else
	ok "--name metacharacters are not executed"
fi

printf '\n%s\n' "── Usage / configuration ──────────────────────────────────"

rc=0
"${BASH_BIN}" "${MAIN}" --log-dir "${WORK}/logs" --help >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "0" ]] && ok "--help exits 0" || bad "--help returned rc=${rc}"

rc=0
"${BASH_BIN}" "${MAIN}" --log-dir "${WORK}/logs" >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "2" ]] && ok "no mode exits 2" || bad "no mode returned rc=${rc} (expected 2)"

rc=0
"${BASH_BIN}" "${MAIN}" --log-dir "${WORK}/logs" --plugins --themes >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "2" ]] && ok "conflicting modes exit 2" || bad "conflicting modes returned rc=${rc} (expected 2)"

rc=0
"${BASH_BIN}" "${MAIN}" --log-dir "${WORK}/logs" --plugins --backup nonsense >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "2" ]] && ok "invalid --backup value exits 2" || bad "invalid --backup returned rc=${rc} (expected 2)"

rc=0
"${BASH_BIN}" "${MAIN}" --log-dir "${WORK}/logs" --plugins --wp-bin /nonexistent/wp >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "3" ]] && ok "missing WP-CLI exits 3" || bad "missing WP-CLI returned rc=${rc} (expected 3)"

printf '%s' '{"WP_TIMEOUT":"abc"}' >"${WORK}/badconf"
rc=0
"${BASH_BIN}" "${MAIN}" --log-dir "${WORK}/logs" --plugins -S "${SITES_DIR}/site1" -C "${WORK}/badconf" >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "2" ]] && ok "invalid config value exits 2" || bad "invalid config returned rc=${rc} (expected 2)"

printf '%s\n' ': "${WP_TIMEOUT:=120}"' >"${WORK}/good.conf"
rc=0
"${BASH_BIN}" "${MAIN}" --wp-bin "${BIN}/wp" --no-user-switch --no-color --log-dir "${WORK}/logs" \
	-q --cron -S "${SITES_DIR}/site1" -C "${WORK}/good.conf" >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "0" ]] && ok "config file is loaded" || bad "config file run returned rc=${rc}"

chmod 0666 "${WORK}/good.conf"
rc=0
"${BASH_BIN}" "${MAIN}" --log-dir "${WORK}/logs" --plugins -S "${SITES_DIR}/site1" -C "${WORK}/good.conf" >/dev/null 2>&1 || rc=$?
[[ "${rc}" == "2" ]] && ok "world-writable config file is refused" || bad "world-writable config returned rc=${rc} (expected 2)"

# --log-dir must also be honoured by usage errors (regression guard).
LOGDIR="${WORK}/logdir-test"
rm -rf -- "${LOGDIR}"
rc=0
"${BASH_BIN}" "${MAIN}" --log-dir "${LOGDIR}" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" == "2" && -f "${LOGDIR}/wp_cli_manager.log" ]]; then
	ok "--log-dir is honoured on usage errors"
else
	bad "--log-dir not honoured on usage errors (rc=${rc})"
fi

printf '\n───────────────────────────────────────────────────────────\n'
printf 'passed: %d, failed: %d\n' "${PASS}" "${FAIL}"
((FAIL == 0)) || exit 1
exit 0

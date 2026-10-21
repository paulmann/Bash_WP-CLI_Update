#!/usr/bin/env bash
# ==============================================================================
# Scenario tests for Bash_WP-CLI_Update.sh (v5.0.0)
#
# Run: bash tests/scenarios/test_main_update.sh <project_dir>
#
# The suite injects fake system binaries (stat, id, wp, runuser, su) into PATH
# and exercises the main script end-to-end:
#   * runuser argv logging proves argv-safe command construction
#   * failure-pattern file allows scenario-controlled command failures
#   * WPCLI_UPDATE_SKIP_ROOT_CHECK=1 + FORCE_RUNUSER=1 enable unprivileged runs
# ==============================================================================

PROJ="${1:?usage: test_main_update.sh <project_dir>}"
SCRIPT="${PROJ}/Bash_WP-CLI_Update.sh"

TOTAL=0
FAILED=0

pass() { TOTAL=$(( TOTAL + 1 )); printf 'PASS: %s\n' "$*"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL: %s\n' "$*" >&2; }

assert_eq() {
    if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected='$1' actual='$2')"; fi
}
assert_contains() {
    if grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3 ('$2' not found in $1)"; fi
}
assert_not_contains() {
    if ! grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3 ('$2' unexpectedly found in $1)"; fi
}

# ------------------------------------------------------------------------------
# Fixture: fake system binaries
# ------------------------------------------------------------------------------
T="$(mktemp -d /tmp/mainwp_test.XXXXXX)"
FAKEBIN="${T}/fakebin"
mkdir -p "${FAKEBIN}"

cat > "${FAKEBIN}/stat" <<'EOF'
#!/usr/bin/env bash
fmt=""; path=""
while [ $# -gt 0 ]; do
    case "$1" in
        -c) fmt="$2"; shift 2 ;;
        *)  path="$1"; shift ;;
    esac
done
case "${fmt}" in
    *%s*) echo 123 ;;
    *%U*) if echo "${path}" | grep -q baduser; then echo nosuchuser; else echo wpuser; fi ;;
    *%G*) echo wpgroup ;;
    *)    echo wpuser ;;
esac
exit 0
EOF

cat > "${FAKEBIN}/id" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-u" ]; then
    case "$2" in
        wpuser) echo 1234; exit 0 ;;
        *)      exit 1 ;;
    esac
fi
exit 1
EOF

cat > "${FAKEBIN}/wp" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${FAKEBIN}/runuser" <<'EOF'
#!/usr/bin/env bash
LOG="${RUNUSER_LOG:?RUNUSER_LOG not set}"
for a in "$@"; do printf '<%s>\n' "${a}" >> "${LOG}"; done
printf '%s\n' '---' >> "${LOG}"
if [ -n "${RUNUSER_FAIL_PATTERNS:-}" ] && [ -s "${RUNUSER_FAIL_PATTERNS}" ]; then
    pat="$(head -n 1 "${RUNUSER_FAIL_PATTERNS}")"
    if [[ " $* " == *" ${pat}"* ]]; then
        tail -n +2 "${RUNUSER_FAIL_PATTERNS}" > "${RUNUSER_FAIL_PATTERNS}.tmp"
        mv -f "${RUNUSER_FAIL_PATTERNS}.tmp" "${RUNUSER_FAIL_PATTERNS}"
        exit 1
    fi
fi
exit 0
EOF

cat > "${FAKEBIN}/su" <<'EOF'
#!/usr/bin/env bash
LOG="${RUNUSER_LOG:-/dev/null}"
echo "SU_USED" >> "${LOG}"
for a in "$@"; do printf '<%s>\n' "${a}" >> "${LOG}"; done
printf '%s\n' '---' >> "${LOG}"
if [ -n "${RUNUSER_FAIL_PATTERNS:-}" ] && [ -s "${RUNUSER_FAIL_PATTERNS}" ]; then
    pat="$(head -n 1 "${RUNUSER_FAIL_PATTERNS}")"
    if [[ " $* " == *" ${pat}"* ]]; then
        tail -n +2 "${RUNUSER_FAIL_PATTERNS}" > "${RUNUSER_FAIL_PATTERNS}.tmp"
        mv -f "${RUNUSER_FAIL_PATTERNS}.tmp" "${RUNUSER_FAIL_PATTERNS}"
        exit 1
    fi
fi
exit 0
EOF

chmod +x "${FAKEBIN}/stat" "${FAKEBIN}/id" "${FAKEBIN}/wp" "${FAKEBIN}/runuser" "${FAKEBIN}/su"
chmod +x "${PROJ}/Find_WP_Senior.sh"

# ------------------------------------------------------------------------------
# Isolate logs via the optional config file (script-dir local).
# ------------------------------------------------------------------------------
LOG="${T}/wp_cli_manager.log"
ERRLOG="${T}/wp_cli_errors.log"
CONF="${PROJ}/Bash_WP-CLI_Update.conf"
cat > "${CONF}" <<EOF
LOG_FILE="${LOG}"
ERROR_LOG_FILE="${ERRLOG}"
MAX_LOG_SIZE=999999999
EOF

RUNUSER_LOG="${T}/runuser.log"
FAIL_PATS="${T}/failpats.txt"

export PATH="${FAKEBIN}:${PATH}"

cleanup() {
    rm -rf "${T}"
    rm -f "${CONF}" "${PROJ}/wp-found.txt"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
run_script() {
    local out="$1"; shift
    env WPCLI_UPDATE_SKIP_ROOT_CHECK=1 \
        WPCLI_UPDATE_FORCE_RUNUSER=1 \
        WPCLI_UPDATE_LOCK_TIMEOUT=5 \
        RUNUSER_LOG="${RUNUSER_LOG}" \
        RUNUSER_FAIL_PATTERNS="${FAIL_PATS}" \
        bash "${SCRIPT}" "$@" > "${out}" 2>&1
}

make_site() {
    mkdir -p "$1"
    printf '%s\n' '<?php' > "$1/wp-config.php"
}

make_site "${T}/sites/siteA"
make_site "${T}/sites/baduser"
mkdir -p "${T}/sites/space dir"
printf '%s\n' '<?php' > "${T}/sites/space dir/wp-config.php"

# ------------------------------------------------------------------------------
# Scenario 1: CLI surface
# ------------------------------------------------------------------------------
run_script "${T}/s1.out" --version
assert_eq 0 "$?" "cli: --version exits 0"
assert_eq "Bash_WP-CLI_Update.sh v5.0.0" "$(cat "${T}/s1.out")" "cli: version string"

run_script "${T}/s2.out" --help
assert_eq 0 "$?" "cli: --help exits 0"
assert_contains "${T}/s2.out" "--dry-run" "cli: help documents --dry-run"
assert_contains "${T}/s2.out" "--astra-key" "cli: help documents --astra-key"

run_script "${T}/s3.out" --bogus
assert_eq 1 "$?" "cli: unknown option exits 1"

run_script "${T}/s4.out"
assert_eq 1 "$?" "cli: no mode exits 1"

run_script "${T}/s5.out" --core --sites-file
assert_eq 1 "$?" "cli: --sites-file without value exits 1"

# ------------------------------------------------------------------------------
# Scenario 2: plugins mode; duplicates+comments skipped; spaces-safe argv
# ------------------------------------------------------------------------------
: > "${RUNUSER_LOG}"
SITES2="${T}/sites2.txt"
cat > "${SITES2}" <<EOF
# comment line
${T}/sites/siteA
${T}/sites/siteA
${T}/sites/space dir

EOF
run_script "${T}/s2main.out" --plugins --sites-file "${SITES2}"
assert_eq 0 "$?" "plugins: exit 0"
assert_contains "${T}/s2main.out" "Sites processed: 2" "plugins: duplicate site not reprocessed"
assert_contains "${T}/s2main.out" "Successful ops:  2" "plugins: two ops succeed"
assert_contains "${RUNUSER_LOG}" "<--path=${T}/sites/siteA>" "plugins: --path arg correct"
assert_contains "${RUNUSER_LOG}" "<--path=${T}/sites/space dir>" "plugins: spaced path passed as single argv"
assert_contains "${RUNUSER_LOG}" "--skip-plugins=" "plugins: skip-plugins applied"
assert_contains "${RUNUSER_LOG}" "<env>" "plugins: env command present"
assert_contains "${RUNUSER_LOG}" "<DOCUMENT_ROOT=${T}/sites/siteA>" "plugins: DOCUMENT_ROOT env set"
assert_contains "${RUNUSER_LOG}" "--allow-root" "plugins: --allow-root applied"
assert_contains "${RUNUSER_LOG}" "--quiet" "plugins: --quiet applied"

# ------------------------------------------------------------------------------
# Scenario 3: core mode gets NO --skip-plugins
# ------------------------------------------------------------------------------
: > "${RUNUSER_LOG}"
SITES3="${T}/sites3.txt"
printf '%s\n' "${T}/sites/siteA" > "${SITES3}"
run_script "${T}/s3main.out" --core --sites-file "${SITES3}"
assert_eq 0 "$?" "core: exit 0"
assert_contains "${T}/s3main.out" "Successful ops:  2" "core: core update + update-db"
assert_not_contains "${RUNUSER_LOG}" "--skip-plugins=" "core: no skip-plugins for core commands"
assert_contains "${RUNUSER_LOG}" "<core>" "core: subcommand core passed"

# ------------------------------------------------------------------------------
# Scenario 4: unresolvable user -> site skipped, other sites processed, exit 1
# ------------------------------------------------------------------------------
: > "${RUNUSER_LOG}"
SITES4="${T}/sites4.txt"
cat > "${SITES4}" <<EOF
${T}/sites/baduser
${T}/sites/siteA
EOF
run_script "${T}/s4main.out" --plugins --sites-file "${SITES4}"
assert_eq 1 "$?" "baduser: final exit 1"
assert_contains "${T}/s4main.out" "user resolution failed" "baduser: resolution failure reported"
assert_contains "${T}/s4main.out" "Failed sites:    1" "baduser: one failed site"
assert_contains "${T}/s4main.out" "Successful ops:  1" "baduser: second site still processed"
assert_eq 1 "$(grep -c '^---$' "${RUNUSER_LOG}")" "baduser: exactly one runuser call"

# ------------------------------------------------------------------------------
# Scenario 5: dry-run reports and executes nothing
# ------------------------------------------------------------------------------
: > "${RUNUSER_LOG}"
run_script "${T}/s5main.out" --plugins --dry-run --sites-file "${SITES3}"
assert_eq 0 "$?" "dryrun: exit 0"
assert_contains "${T}/s5main.out" "(dry-run)" "dryrun: commands reported as dry-run"
assert_not_contains "${RUNUSER_LOG}" "<--path=" "dryrun: runuser never invoked"

# ------------------------------------------------------------------------------
# Scenario 6: failing plugin update -> error log detail, exit 1
# ------------------------------------------------------------------------------
: > "${RUNUSER_LOG}"
printf '%s\n' 'plugin update' > "${FAIL_PATS}"
run_script "${T}/s6main.out" --plugins --sites-file "${SITES3}"
assert_eq 1 "$?" "failop: exit 1"
assert_contains "${T}/s6main.out" "Failed ops:      1" "failop: one failed op counted"
assert_contains "${ERRLOG}" "ERROR DETAIL" "failop: error detail written"
: > "${FAIL_PATS}"

# ------------------------------------------------------------------------------
# Scenario 7: Astra happy path with license activation (first update fails)
# ------------------------------------------------------------------------------
: > "${RUNUSER_LOG}"
printf '%s\n' 'plugin update' > "${FAIL_PATS}"
run_script "${T}/s7main.out" --astra --astra-key K-123456 --sites-file "${SITES3}"
assert_eq 0 "$?" "astra: exit 0 after activation+retry"
assert_contains "${RUNUSER_LOG}" "<status>" "astra: status command invoked"
assert_contains "${RUNUSER_LOG}" "<astra-addon>" "astra: astra-addon targeted"
assert_contains "${RUNUSER_LOG}" "brainstormforce" "astra: license command invoked"
assert_contains "${RUNUSER_LOG}" "<K-123456>" "astra: license key passed as singular argv"
assert_contains "${T}/s7main.out" "Successful ops:  1" "astra: one successful update"
: > "${FAIL_PATS}"

# ------------------------------------------------------------------------------
# Scenario 8: Astra without key -> hard error, exit 1, no wp calls
# ------------------------------------------------------------------------------
: > "${RUNUSER_LOG}"
run_script "${T}/s8main.out" --astra --sites-file "${SITES3}"
assert_eq 1 "$?" "astranokey: exit 1"
assert_contains "${T}/s8main.out" "license key not configured" "astranokey: clear error message"
assert_not_contains "${RUNUSER_LOG}" "<--path=" "astranokey: no wp invocation attempted"

# ------------------------------------------------------------------------------
# Scenario 9: full mode runs all seven ops, astra tolerant, failure propagates
# ------------------------------------------------------------------------------
: > "${RUNUSER_LOG}"
printf '%s\n' 'core update' > "${FAIL_PATS}"
run_script "${T}/s9main.out" --full --sites-file "${SITES3}"
assert_eq 1 "$?" "full: hard failure propagates exit 1"
assert_contains "${T}/s9main.out" "Failed ops:      1" "full: exactly one failed op"
assert_contains "${T}/s9main.out" "Successful ops:  7" "full: six core ops + astra update"
assert_contains "${RUNUSER_LOG}" "<--due-now>" "full: cron ran after failure (loop continues)"
assert_contains "${RUNUSER_LOG}" "<db>" "full: db ops ran"
assert_contains "${RUNUSER_LOG}" "<repair>" "full: db repair ran"
assert_contains "${RUNUSER_LOG}" "<astra-addon>" "full: astra update attempted"
: > "${FAIL_PATS}"

# ------------------------------------------------------------------------------
# Scenario 10: lock - live lock dir blocks a concurrent run
# ------------------------------------------------------------------------------
LOCKDIR="${PROJ}/.Bash_WP-CLI_Update.sh.lock"
rm -rf "${LOCKDIR}"
mkdir -p "${LOCKDIR}"
printf '%s\n' "$$" > "${LOCKDIR}/pid"
run_script "${T}/s10.out" --plugins --sites-file "${SITES3}"
assert_eq 1 "$?" "lock: concurrent run rejected"
assert_contains "${T}/s10.out" "Another instance is running" "lock: clear lock message"
rm -rf "${LOCKDIR}"

# ------------------------------------------------------------------------------
# Scenario 11: missing sites file triggers discovery; file gets created
# ------------------------------------------------------------------------------
AUTO="${T}/auto-sites.txt"
run_script "${T}/s11.out" --plugins --sites-file "${AUTO}"
RC=$?
assert_eq 0 "${RC}" "discover: exit 0"
if [[ -f "${AUTO}" ]]; then
    pass "discover: missing sites file created by discovery"
else
    fail "discover: sites file not created"
fi

# ------------------------------------------------------------------------------
# Scenario 12: log rotation (small MAX_LOG_SIZE in conf)
# ------------------------------------------------------------------------------
cat > "${CONF}" <<EOF
LOG_FILE="${LOG}.rot"
ERROR_LOG_FILE="${ERRLOG}.rot"
MAX_LOG_SIZE=100
EOF
: > "${RUNUSER_LOG}"
run_script "${T}/s12.out" --core --sites-file "${SITES3}"
if [[ -f "${LOG}.rot.1" ]]; then
    pass "rotation: rotated log present"
else
    fail "rotation: rotated log missing"
fi
rm -f "${LOG}.rot" "${LOG}.rot.1"

# ------------------------------------------------------------------------------
# Scenario 13: su fallback (runuser absent) - argv properly escaped
# ------------------------------------------------------------------------------
: > "${RUNUSER_LOG}"
rm -f "${FAKEBIN}/runuser"
SITES13="${T}/sites13.txt"
printf '%s\n' "${T}/sites/space dir" > "${SITES13}"
run_script "${T}/s13.out" --core --sites-file "${SITES13}"
assert_eq 0 "$?" "sufallback: exit 0"
assert_contains "${RUNUSER_LOG}" "SU_USED" "sufallback: su invoked"
if grep -F -- '--path=' "${RUNUSER_LOG}" | grep -Fq -- 'space\ dir'; then
    pass "sufallback: escaped path passed via su -c"
else
    fail "sufallback: escaped path not found in su log"
fi
# Recreate runuser for subsequent scenarios
cat > "${FAKEBIN}/runuser" <<'EOF'
#!/usr/bin/env bash
LOG="${RUNUSER_LOG:?RUNUSER_LOG not set}"
for a in "$@"; do printf '<%s>\n' "${a}" >> "${LOG}"; done
printf '%s\n' '---' >> "${LOG}"
if [ -n "${RUNUSER_FAIL_PATTERNS:-}" ] && [ -s "${RUNUSER_FAIL_PATTERNS}" ]; then
    pat="$(head -n 1 "${RUNUSER_FAIL_PATTERNS}")"
    if [[ " $* " == *" ${pat}"* ]]; then
        tail -n +2 "${RUNUSER_FAIL_PATTERNS}" > "${RUNUSER_FAIL_PATTERNS}.tmp"
        mv -f "${RUNUSER_FAIL_PATTERNS}.tmp" "${RUNUSER_FAIL_PATTERNS}"
        exit 1
    fi
fi
exit 0
EOF
chmod +x "${FAKEBIN}/runuser"

# ------------------------------------------------------------------------------
# Scenario 14: empty sites file & non-directory entry - no crash
# ------------------------------------------------------------------------------
SITES14="${T}/sites14.txt"
: > "${SITES14}"
run_script "${T}/s14a.out" --plugins --sites-file "${SITES14}"
assert_eq 0 "$?" "empty: exit 0"

SITES15="${T}/sites15.txt"
cat > "${SITES15}" <<EOF
${T}/does_not_exist
EOF
run_script "${T}/s15.out" --plugins --sites-file "${SITES15}"
assert_eq 0 "$?" "nondir: exit 0 (skipped)"
assert_contains "${T}/s15.out" "not a directory" "nondir: warning present"
assert_contains "${T}/s15.out" "Sites processed: 0" "nondir: zero processed"

# ------------------------------------------------------------------------------
# Scenario 15: stale lock auto-removed (pid dead)
# ------------------------------------------------------------------------------
LOCKDIR="${PROJ}/.Bash_WP-CLI_Update.sh.lock"
rm -rf "${LOCKDIR}"
mkdir -p "${LOCKDIR}"
printf '%s\n' "999999999" > "${LOCKDIR}/pid"
run_script "${T}/s16.out" --core --sites-file "${SITES3}"
assert_eq 0 "$?" "stalelock: run proceeds without dead lock"
assert_contains "${RUNUSER_LOG}" "<core>" "stalelock: command executed after lock removal"
rm -rf "${LOCKDIR}"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
printf '\n%d assertions, %d failed\n' "${TOTAL}" "${FAILED}"
[[ "${FAILED}" -eq 0 ]]

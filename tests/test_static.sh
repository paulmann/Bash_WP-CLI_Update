#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016,SC1091,SC2034  # a test suite greps for literal shell
# patterns and sources its harness by a path resolved at run time
# Static checks: syntax, lint, line endings, permissions, versions, doc drift.
# No root, no WordPress, no WP-CLI, no network.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-static.XXXXXX")"
chmod 755 "$WORK"
FAIL_FILE="${FAIL_FILE:-${WORK}/fail}"
PASS_FILE="${PASS_FILE:-${WORK}/pass}"
SKIP_FILE="${SKIP_FILE:-${WORK}/skip}"
export FAIL_FILE PASS_FILE SKIP_FILE
# shellcheck source=tests/harness.sh
. "${here}/harness.sh"
trap 'rm -rf -- "$WORK"' EXIT

PRODUCT_SCRIPTS=("${repo}/Bash_WP-CLI_Update.sh" "${repo}/Find_WP_Senior.sh")
ALL_SCRIPTS=("${PRODUCT_SCRIPTS[@]}" "${repo}/tools/build.sh" "${repo}/tools/scan-secrets.sh")
while IFS= read -r -d '' f; do ALL_SCRIPTS+=("$f"); done < <(find "${repo}/src" -name '*.sh' -print0 2>/dev/null | sort -z)
while IFS= read -r -d '' f; do ALL_SCRIPTS+=("$f"); done < <(find "$here" -maxdepth 1 -name '*.sh' -print0 | sort -z)
ALL_SCRIPTS+=("${repo}/tests/stub/wp")

say 'bash syntax on every shell file'
for f in "${ALL_SCRIPTS[@]}"; do
    [ -f "$f" ] || { bad "missing file: ${f#"$repo"/}" ''; continue; }
    if out="$(bash -n "$f" 2>&1)"; then
        ok "syntax ok: ${f#"$repo"/}"
    else
        bad "syntax FAIL: ${f#"$repo"/}" "$out"
    fi
done

say 'shellcheck'
SHELLCHECK=''
for c in shellcheck "${SHELLCHECK_BIN:-}"; do
    [ -n "$c" ] && command -v "$c" >/dev/null 2>&1 && { SHELLCHECK="$c"; break; }
done
if [ -z "$SHELLCHECK" ]; then
    skip 'shellcheck clean' 'shellcheck not installed'
else
    # The artifacts carry file-wide disables for SC2329/SC2034 with a written
    # justification; the src modules are fragments that reference variables
    # defined in sibling modules, so SC2154/SC2034/SC2329 cannot apply to them.
    for f in "${ALL_SCRIPTS[@]}"; do
        [ -f "$f" ] || continue
        case "$f" in
            */src/*) excl='-e,SC2154,-e,SC2034,-e,SC2329' ;;
            *) excl='' ;;
        esac
        # shellcheck disable=SC2086  # $excl is a fixed word list
        out="$("$SHELLCHECK" -f gcc $excl -- "$f" 2>&1)" || true
        case "$out" in
            *': error:'* | *': warning:'*)
                bad "shellcheck findings in ${f#"$repo"/}" "$(printf '%s' "$out" | head -5)"
                ;;
            *) ok "shellcheck clean (errors/warnings): ${f#"$repo"/}" ;;
        esac
    done
fi

say 'line endings, shebang, permissions'
for f in "${ALL_SCRIPTS[@]}"; do
    [ -f "$f" ] || continue
    cr="$(tr -cd '\r' <"$f" | wc -c)"
    cr="${cr//[^0-9]/}"
    if [ "${cr:-0}" -eq 0 ]; then
        ok "no CR bytes: ${f#"$repo"/}"
    else
        bad "CRLF found: ${f#"$repo"/}" "${cr} CR byte(s) would break pattern matching"
    fi
done
for f in "${PRODUCT_SCRIPTS[@]}" "${repo}/tests/stub/wp"; do
    [ -f "$f" ] || { bad "missing: ${f#"$repo"/}" ''; continue; }
    if [ -x "$f" ]; then
        ok "executable: ${f#"$repo"/}"
    else
        bad "not executable: ${f#"$repo"/}" 'run chmod +x'
    fi
done
# Tools and suites are documented to run as `bash <file>`; a missing exec bit
# after a fresh checkout on a filesystem without mode bits is a warning, not a
# failure. `git update-index --chmod=+x` fixes it in the repository.
for f in "${repo}/tools/build.sh" "${repo}/tools/install.sh" "${repo}/tools/scan-secrets.sh" "${here}/run_tests.sh"; do
    [ -f "$f" ] || { bad "missing: ${f#"$repo"/}" ''; continue; }
    if [ -x "$f" ]; then
        ok "executable: ${f#"$repo"/}"
    else
        printf '  NOTE  %s is not executable (runs fine as: bash %s)\n' "${f#"$repo"/}" "${f#"$repo"/}"
    fi
done
for f in "${PRODUCT_SCRIPTS[@]}"; do
    first="$(head -n 1 "$f")"
    if [ "$first" = '#!/usr/bin/env bash' ]; then
        ok "shebang is byte one: ${f#"$repo"/}"
    else
        bad "shebang must be the first line: ${f#"$repo"/}" "got: ${first}"
    fi
done

say 'no command substitution with backticks, no eval of config data'
for f in "${PRODUCT_SCRIPTS[@]}" "${repo}/tools/scan-secrets.sh"; do
    if grep -n '`' "$f" | grep -v '140' | grep -v '^\s*#' | grep -qv '\\`'; then
        bad "backtick found in ${f#"$repo"/}" "$(grep -n '`' "$f" | head -3)"
    else
        ok "no backticks: ${f#"$repo"/}"
    fi
done

say 'versions agree everywhere'
mgr_ver="$(sed -n "s/^SCRIPT_VERSION='\(.*\)'$/\1/p" "${repo}/Bash_WP-CLI_Update.sh" | head -n 1)"
src_ver="$(sed -n "s/^SCRIPT_VERSION='\(.*\)'$/\1/p" "${repo}/src/manager/01-bootstrap.sh" | head -n 1)"
fnd_ver="$(sed -n "s/^SCRIPT_VERSION='\(.*\)'$/\1/p" "${repo}/Find_WP_Senior.sh" | head -n 1)"
fnd_src_ver="$(sed -n "s/^SCRIPT_VERSION='\(.*\)'$/\1/p" "${repo}/src/finder/01-bootstrap.sh" | head -n 1)"
[ "$mgr_ver" = "$src_ver" ] && ok "manager artifact version matches src (${mgr_ver})" \
    || bad 'manager artifact version drifted from src/manager/01-bootstrap.sh' "${src_ver} vs ${mgr_ver}"
[ "$fnd_ver" = "$fnd_src_ver" ] && ok "finder artifact version matches src (${fnd_ver})" \
    || bad 'finder artifact version drifted from src/finder/01-bootstrap.sh' "${fnd_src_ver} vs ${fnd_ver}"
if [ -f "${repo}/README.md" ]; then
    if grep -Fq "$mgr_ver" "${repo}/README.md"; then
        ok "README mentions the manager version ${mgr_ver}"
    else
        bad "README.md does not mention version ${mgr_ver}" 'update the version table'
    fi
fi
if [ -f "${repo}/CHANGELOG.md" ]; then
    if grep -Fq "$mgr_ver" "${repo}/CHANGELOG.md"; then
        ok "CHANGELOG has an entry for ${mgr_ver}"
    else
        bad "CHANGELOG.md has no entry for ${mgr_ver}" ''
    fi
fi

say 'built artifacts match src/ (no drift)'
if out="$(cd "$repo" && WPU_BUILD_ID="${WPU_BUILD_ID:-driftcheck}" bash tools/build.sh --check 2>&1)"; then
    ok 'artifacts are up to date with src/'
else
    bad 'artifact drift: the committed scripts do not match src/' "$(printf '%s' "$out" | head -4)"
fi

say 'exit-code contract is documented in both the help and the README'
for code in '0' '1' '2' '3' '4' '5' '6'; do :; done
if grep -q '6  stopped early' "${repo}/Bash_WP-CLI_Update.sh"; then
    ok 'exit code 6 is documented in --help'
else
    bad 'exit code 6 missing from --help' ''
fi
if [ -f "${repo}/README.md" ] && grep -Fq '| `6`' "${repo}/README.md"; then
    ok 'exit code 6 is documented in the README'
else
    bad 'exit code 6 missing from the README exit-code table' ''
fi

say 'documentation present'
for d in README.md CHANGELOG.md LICENSE wp-cli-update.conf.example \
         docs/CONFIGURATION.md docs/OPERATIONS.md docs/SECURITY.md \
         docs/TROUBLESHOOTING.md docs/ARCHITECTURE.md docs/MIGRATION.md; do
    if [ -s "${repo}/${d}" ]; then
        ok "present: ${d}"
    else
        bad "missing or empty: ${d}" ''
    fi
done

report test_static

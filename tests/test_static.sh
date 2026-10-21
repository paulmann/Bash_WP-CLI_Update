#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016,SC1091,SC2034  # a test suite greps for literal shell
# patterns and sources its harness by a path resolved at run time
# Static checks: syntax, lint, line endings, permissions, documentation.
# No root, no WordPress, no WP-CLI, no network.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wpcli-static.XXXXXX")"
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

PRODUCT_SCRIPTS=("${repo}/Bash_WP-CLI_Update.sh" "${repo}/Find_WP_Senior.sh")
ALL_SCRIPTS=("${PRODUCT_SCRIPTS[@]}" "${repo}/tools/scan-secrets.sh")
while IFS= read -r -d '' f; do ALL_SCRIPTS+=("$f"); done < <(find "$here" -maxdepth 1 -name '*.sh' -print0)

say 'bash -n on every shell file'
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
    for f in "${ALL_SCRIPTS[@]}"; do
        [ -f "$f" ] || continue
        out="$("$SHELLCHECK" -f gcc "$f" 2>&1)"
        if [ -z "$out" ]; then
            ok "shellcheck clean: ${f#"$repo"/}"
        else
            bad "shellcheck findings in ${f#"$repo"/}" "$(printf '%s' "$out" | head -5)"
        fi
    done
fi

say 'line endings and permissions'
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
for f in "${PRODUCT_SCRIPTS[@]}" "${repo}/tools/scan-secrets.sh" "${here}/run_tests.sh"; do
    [ -f "$f" ] || continue
    if [ -x "$f" ]; then
        ok "executable: ${f#"$repo"/}"
    else
        bad "not executable: ${f#"$repo"/}" 'run chmod +x'
    fi
done

say 'shebang and safety switches'
for f in "${PRODUCT_SCRIPTS[@]}"; do
    first="$(head -n 1 "$f")"
    if [ "$first" = '#!/usr/bin/env bash' ]; then
        ok "portable shebang: ${f#"$repo"/}"
    else
        bad "shebang: ${f#"$repo"/}" "got '${first}'"
    fi
    if grep -q '^set -uo pipefail' "$f"; then
        ok "set -uo pipefail: ${f#"$repo"/}"
    else
        bad "missing strict-ish mode: ${f#"$repo"/}" 'expected `set -uo pipefail`'
    fi
    if grep -q 'BASH_VERSINFO' "$f"; then
        ok "bash version guard: ${f#"$repo"/}"
    else
        bad "no bash version guard: ${f#"$repo"/}" ''
    fi
done

say 'no banned constructs in the product scripts'
# These are how this project has historically broken itself. Comments are
# stripped first: both scripts document the banned pattern in prose, and a lint
# that fires on its own explanation is a lint nobody will keep.
code_only() { grep -vE '^\s*#' "$1" | sed -E 's/[[:space:]]#.*$//'; }
for f in "${PRODUCT_SCRIPTS[@]}"; do
    name="${f#"$repo"/}"
    code="${WORK}/code.$(basename "$f")"
    code_only "$f" >"$code"
    if grep -nE '(^|[^\\])\beval\b' "$code" | grep -q .; then
        bad "eval used: ${name}" "$(grep -nE '\beval\b' "$code" | head -3)"
    else
        ok "no eval: ${name}"
    fi
    # A backtick *character constant* -- the metacharacter list the config
    # parser rejects -- is data, not a command substitution. Build every banned
    # token from its octal code so that this file does not contain the thing it
    # searches for and therefore cannot match itself.
    bt="$(printf '\140')"          # backtick
    ds="$(printf '\044')"          # dollar sign
    # The line that defines the backtick variable is excluded, otherwise the
    # check matches its own subject -- a lint that reports itself is a lint that
    # gets disabled, and then it reports nothing at all.
    if grep -Fv 'printf ' "$code" | grep -Fq "$bt"; then
        bad "backticks used: ${name}" "$(grep -Fv 'printf ' "$code" | grep -Fn "$bt" | head -3)"
    else
        ok "no backticks: ${name}"
    fi
    if grep -qE "\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]:-" "$code"; then
        bad 'empty-array expansion: '"${name}" \
            'in bash 4.4+ "${arr[@]:-}" yields one empty element and once caused a full scan of /'
    else
        ok 'no empty-array expansion: '"${name}"
    fi
    if grep -qE "su +-[a-zA-Z]*c" "$code"; then
        bad 'su -c without -s: '"${name}" 'printf %q output is bash-only; force the shell'
    else
        ok 'no bare `su -c`: '"${name}"
    fi
    if grep -qE "printf +'%q'" "$code"; then
        bad 'printf %q used: '"${name}" 'not understood by POSIX sh'
    else
        ok 'no printf %q: '"${name}"
    fi
    if grep -qE '^\s*source |^\s*\. +"?\$' "$code"; then
        bad 'sources an external file: '"${name}" 'configuration must be data, not code'
    else
        ok 'sources nothing: '"${name}"
    fi
done

say 'no personal data in the shipped code'
for f in "${PRODUCT_SCRIPTS[@]}" "${repo}/tools/scan-secrets.sh"; do
    [ -f "$f" ] || { bad "missing file: ${f#"$repo"/}" ''; continue; }
    name="${f#"$repo"/}"
    if grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f"; then
        bad "e-mail address in ${name}" "$(grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f" | head -3)"
    else
        ok "no e-mail address: ${name}"
    fi
    if grep -qE 'saphali-woocommerce-lite|jet-compare-wishlist|jet-data-importer' "$f"; then
        bad "author-specific plugin list hardcoded in ${name}" \
            'ship an empty default and document the list in wp-cli-update.conf.example'
    else
        ok "no hardcoded site-specific plugin list: ${name}"
    fi
done

say 'documentation is present and consistent'
for d in README.md CHANGELOG.md AGENT.md PROJECT_MAP.md wp-cli-update.conf.example .gitignore .gitattributes; do
    if [ -f "${repo}/${d}" ]; then
        ok "present: ${d}"
    else
        bad "missing: ${d}" ''
    fi
done
# The version string must agree everywhere it is printed.
version="$(sed -n "s/^SCRIPT_VERSION='\(.*\)'.*/\1/p" "${repo}/Bash_WP-CLI_Update.sh" | head -1)"
if [ -n "$version" ]; then
    ok "manager version: ${version}"
    if grep -q "$version" "${repo}/CHANGELOG.md"; then
        ok "CHANGELOG mentions ${version}"
    else
        bad "CHANGELOG does not mention ${version}" 'add a release entry'
    fi
    if grep -q "$version" "${repo}/README.md"; then
        ok "README mentions ${version}"
    else
        bad "README does not mention ${version}" ''
    fi
else
    bad 'cannot read SCRIPT_VERSION from the manager' ''
fi
fversion="$(sed -n "s/^SCRIPT_VERSION='\(.*\)'.*/\1/p" "${repo}/Find_WP_Senior.sh" | head -1)"
if [ -n "$fversion" ]; then
    ok "finder version: ${fversion}"
    if grep -q "$fversion" "${repo}/CHANGELOG.md"; then
        ok "CHANGELOG mentions finder ${fversion}"
    else
        bad "CHANGELOG does not mention finder ${fversion}" ''
    fi
else
    bad 'cannot read SCRIPT_VERSION from the finder' ''
fi

say 'PROJECT_MAP.md is not stale'
map="${repo}/PROJECT_MAP.md"
if [ -f "$map" ]; then
    # PROJECT_MAP.md declares its own count on a line of its own; accept both
    # "**Files: N**" and "- Files: **N**" so the wording can evolve.
    declared="$(sed -nE 's/^[^0-9]*\*\*Files: ([0-9]+)\*\*.*/\1/p' "$map" | head -1)"
    [ -n "$declared" ] || declared="$(sed -nE 's/^- Files: \*\*([0-9]+)\*\*.*/\1/p' "$map" | head -1)"
    actual="$(cd "$repo" && git ls-files 2>/dev/null | wc -l)"
    actual="${actual//[^0-9]/}"
    if [ -z "$declared" ]; then
        skip 'PROJECT_MAP file count' 'no declared count found'
    elif [ "$actual" -gt 0 ] && [ "$declared" = "$actual" ]; then
        ok "PROJECT_MAP declares ${declared} files, git lists ${actual}"
    elif [ "$actual" -eq 0 ]; then
        skip 'PROJECT_MAP file count' 'not a git checkout'
    else
        bad 'PROJECT_MAP is stale' "declares ${declared} files, git lists ${actual}; regenerate it"
    fi
fi

report 'static'

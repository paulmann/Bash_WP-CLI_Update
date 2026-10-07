#!/usr/bin/env bash
# Tests for tools/scan-secrets.sh.
#
# A guard that has never caught anything is not evidence. These tests plant a
# credential-shaped literal in a temporary sandbox repository, confirm the guard
# reports it, and confirm the guard stays silent on the real tree.
#
# All planted names are assembled from parts, so this file itself never contains
# an assignment-shaped literal.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/secretstest.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail_file="$work/fails"; : >"$fail_file"
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; printf 'x\n' >>"$fail_file"; }
count_fails() { local n; n="$(grep -c '' "$fail_file" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }
say() { printf '\n=== %s ===\n' "$1"; }

part_a='API'
part_b='token'
planted_name="${part_a}_${part_b}"
planted_value='k9Q2mZ7pX4vB8nL3wR6tY1'

# A sandbox repository that looks like the real one to the guard: the guard
# resolves its repository from its own location, so tools/ must sit inside it.
sandbox="$work/sandbox"
mkdir -p "$sandbox/tools" "$sandbox/tests"
cp "$repo/tools/scan-secrets.sh" "$sandbox/tools/"
cp "$repo/tools/secret-allowlist.txt" "$sandbox/tools/"
cp "$repo/Bash_WP-CLI_Update.sh" "$sandbox/"
cp "$repo/tests/test_manager.sh" "$sandbox/tests/" 2>/dev/null || true
printf '#!/usr/bin/env bash\nset -uo pipefail\necho hello\n' >"$sandbox/plain.sh"
( cd "$sandbox" && git init -q . && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1

guard_run() { # DIR ARGS...
    local dir="$1"; shift
    ( cd "$dir" && bash tools/scan-secrets.sh "$@" ) 2>&1
}

say 'baseline: the real repository with the allowlist in place'
out="$(guard_run "$repo" --verbose)"
if printf '%s' "$out" | grep -q '0 finding(s)'; then ok 'no findings on the real tree'; else bad 'unexpected findings'; printf '%s\n' "$out"; fi
if printf '%s' "$out" | grep -q 'known-benign'; then ok 'the allowlist is consulted'; else bad 'allowlist not consulted'; fi

say 'the guard catches a value in a file that is not yet committed'
printf '%s=%s\n' "$planted_name" "$planted_value" >"$sandbox/planted.sh"
out="$(guard_run "$sandbox" --verbose)"
if printf '%s' "$out" | grep -q 'FINDING'; then ok 'an uncommitted file is scanned and reported'; else bad 'the uncommitted literal was missed'; printf '%s\n' "$out"; fi

say 'the guard catches a committed value'
( cd "$sandbox" && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm 'plant a value' ) >/dev/null 2>&1
out="$(guard_run "$sandbox" --verbose)"
if printf '%s' "$out" | grep -q 'FINDING'; then ok 'a planted literal is reported as a finding'; else bad 'the planted literal was missed'; printf '%s\n' "$out"; fi
if printf '%s' "$out" | grep -q 'planted.sh'; then ok 'the finding names the file'; else bad 'the finding does not name the file'; fi
if printf '%s' "$out" | grep -q "$planted_value"; then bad 'the guard printed the value'; else ok 'the value stays masked by default'; fi

say '--strict turns a finding into a non-zero exit'
( cd "$sandbox" && bash tools/scan-secrets.sh --strict >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 1 ]; then ok 'exit 1 on a finding with --strict'; else bad "strict exit was $rc, expected 1"; fi
( cd "$sandbox" && bash tools/scan-secrets.sh >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then ok 'exit 0 without --strict'; else bad "non-strict exit was $rc, expected 0"; fi

say 'comments, placeholders and settings are not findings'
rm -f "$sandbox/planted.sh"
printf '# %s=%s\n' "$planted_name" "$planted_value" >"$sandbox/commented.sh"
printf '%s=<key>\n' "$planted_name" >"$sandbox/placeholder.sh"
printf 'ASTRA_SLUG=astra-addon\n' >"$sandbox/setting.sh"
( cd "$sandbox" && git add -A ) >/dev/null 2>&1
out="$(guard_run "$sandbox" --verbose)"
if printf '%s' "$out" | grep -q 'FINDING'; then
    bad 'a comment, a placeholder or a setting was reported as a finding'
    printf '%s\n' "$out"
else
    ok 'comments, placeholders and settings produce no findings'
fi

say 'the guard does not report a pattern definition'
printf 'PATTERN_ERE=(^|[^A-Za-z0-9_])pass\n' >"$sandbox/tools/looks-like-pattern.sh"
( cd "$sandbox" && git add -A ) >/dev/null 2>&1
out="$(guard_run "$sandbox" --verbose)"
if printf '%s' "$out" | grep -q 'FINDING'; then bad 'pattern definition reported'; printf '%s\n' "$out"; else ok 'a pattern definition is not a finding'; fi

say '--help, --version and bad options'
( cd "$sandbox" && bash tools/scan-secrets.sh --help >/dev/null 2>&1 )
[ $? -eq 0 ] && ok '--help exits 0' || bad '--help exit code'
( cd "$sandbox" && bash tools/scan-secrets.sh --version >/dev/null 2>&1 )
[ $? -eq 0 ] && ok '--version exits 0' || bad '--version exit code'
( cd "$sandbox" && bash tools/scan-secrets.sh --nonsense >/dev/null 2>&1 )
[ $? -eq 2 ] && ok 'an unknown option exits 2' || bad 'unknown option exit code'

say 'history mode finds a value that was later removed'
printf '%s=%s\n' "${part_a}_secret" "$planted_value" >"$sandbox/was-here.sh"
( cd "$sandbox" && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm 'add then remove' ) >/dev/null 2>&1
rm -f "$sandbox/was-here.sh"
( cd "$sandbox" && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm 'remove it' ) >/dev/null 2>&1
out="$(guard_run "$sandbox")"
if printf '%s' "$out" | grep -q '0 finding(s)'; then ok 'the value is gone from the working tree'; else bad 'the removed value still matches'; printf '%s\n' "$out"; fi
out="$(guard_run "$sandbox" --history)"
if printf '%s' "$out" | grep -q 'FINDING'; then ok '--history finds the value that was removed'; else bad '--history missed the removed value'; printf '%s\n' "$out"; fi

printf '\n=== %s ===\n' "$([ "$(count_fails)" -eq 0 ] && echo 'ALL SECRET GUARD CHECKS PASSED' || echo "$(count_fails) CHECK(S) FAILED")"
test "$(count_fails)" -eq 0

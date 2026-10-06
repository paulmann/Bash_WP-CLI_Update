# AGENT.md - Agent Guide (Bash_WP-CLI_Update)

## Project

Two standalone GNU/Linux bash 4.2+ scripts for WordPress maintenance:

- `Bash_WP-CLI_Update.sh` (v5.0.0) - per-site WP-CLI maintenance run as each site's system user.
- `Find_WP_Senior.sh` (v2.0.0) - WordPress root discovery; writes the sites list atomically.

## Conventions (MANDATORY)

- `set -euo pipefail` + `shopt -s inherit_errexit` in both scripts.
- Commands are bash arrays - NEVER shell strings (no eval, no string concatenation for command lines).
- User switching: runuser -u USER -- env ... wp ...; fallback: su -s /bin/bash USER -c with printf %q escaping.
- --skip-plugins is applied ONLY to plugin/theme/astra operations (cmd_skips_plugins).
- All comments in English; UI strings plain English.
- Files keep LF line endings (CRLF silently breaks pattern matching under Git Bash).
- Style: shfmt-compatible (tabs); shfmt -d is the advisory check.

## Testing

- `pytest tests/test_suite.py` runs: bash -n checks, both scenario suites, shfmt advisory.
- Scenario suites use synthetic WP trees plus fake binaries (stat/id/wp/runuser/su) - no root, no real WP-CLI.
- CI hooks (env): WPCLI_UPDATE_SKIP_ROOT_CHECK, WPCLI_UPDATE_FORCE_RUNUSER, WPCLI_UPDATE_LOCK_TIMEOUT.
- On Windows: Git Bash is required; BASH_BIN may point to bash.exe manually.
- Isolation: the scenario suite redirects logs via a temporary Bash_WP-CLI_Update.conf; never leave stray logs in the repo root.

## Constraints

- Config files (*.conf next to the scripts) are trusted bash snippets - keep overridable variables documented in README.
- Discovery output is written atomically (temp file + rename); the main script locks via .Bash_WP-CLI_Update.sh.lock/ + pid with stale detection.
- Exit codes: 0 = success, 1 = at least one failed op/site.
- Keep docs in sync: README.md, PROJECT_MAP.md (generated), AGENT.md (this file), CHANGELOG.md.

## Key implementation facts

- Mode constants (MODE_FULL, MODE_CORE, ...) live at the top of Bash_WP-CLI_Update.sh.
- Astra logic exists in ONE place; strict=true for --astra, strict=false inside --full.
- Discovery criteria: wp-config.php next to wp-includes/version.php.

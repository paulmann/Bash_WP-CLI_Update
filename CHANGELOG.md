# Bash_WP-CLI_Update Changelog

Automatically maintained by DevAgent.

## v5.0.0 / v2.0.0 (2026-10-06)

- Bash_WP-CLI_Update.sh rewritten to v5.0.0:
  strict mode (set -euo pipefail), argv-based command execution via runuser/env
  with a su + printf %q fallback (no shell-string commands), --skip-plugins scoped
  only to plugin/theme/astra operations, single unified Astra handler, mkdir+pid
  lock with stale detection, log rotation (MAX_LOG_SIZE), correct exit-code
  capture, new options (--dry-run, --quiet, --sites-file, --wp-cli, --astra-key,
  --skip-plugins, --help, --version), config file support, deduplication and
  comment handling in the sites file, exit 1 when any operation fails.
- Find_WP_Senior.sh rewritten to v2.0.0:
  one correct find -prune expression, NUL-safe traversal, deduplicated and sorted
  output, atomic output write next to the script, new options (--output,
  --exclude, --max-depth, --quiet, --no-defaults, --help, --version), config
  file support.
- Added scenario test suites (tests/scenarios/) and the pytest pipeline
  (tests/test_suite.py: syntax checks, both scenario suites, advisory shfmt).
- Added AGENT.md, PROJECT_MAP.md and .gitignore; README rewritten for the new CLI.
- [2026-10-06T21:32:26] CHANGELOG.md (backup v1)

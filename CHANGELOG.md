# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This is a user-facing document. An internal agent log is not a changelog: entries
of the form “script (backup v3) - refactor” were published by two earlier
revisions and told the reader nothing they could act on.

## [6.1.0 / 2.1.0] - 2026-10-07

Consolidated release. It merges the four 2026 revisions
(`rewrite-v5.0.0`, `v6.0.0-ragraf`, `v6.0.0-deepseek`,
`AutoClaw-GLM-5.3-RAGRAF`) into one tree, taking the strongest part of each and
fixing the defects that a comparative study of those four branches found. The
study is the reason this release exists; every “Fixed” entry below names the
branch where the defect was observed.

### Added

- `--check`: validates the environment, the wp binary, the switching mechanism,
  the lock, the licence state and every listed site, and changes nothing.
- `--status`: prints the recorded summary of the last run and the log sizes.
- `--print-config`: prints every effective setting, the layer that produced it
  (`default`, `file:…`, `environment`, `command line`) and whether the command
  line overrode it.
- `--list-modes`: machine-readable mode list for shell completion.
- `--timeout SEC`, `--signal SIG`, `--kill-after SEC`: bound a hung `wp`
  process. `-k` is probed for, not assumed, because it is a GNU extension.
- `--allow-root auto|always|never` as an explicit policy instead of a hardcoded
  flag.
- `--fail-on any|all|never`: choose when a partially failing fleet run should
  exit non-zero.
- `--max-sites N`: process a fleet in batches.
- `--user NAME`: force the account, skipping owner detection (containers, or a
  host where every site is root-owned).
- `--user-env LIST`: pass named variables through into the site owner's
  environment.
- `--no-discover`: never run the finder implicitly.
- `--fields LIST` and `--page-limit N` for `--list-plugins`.
- Finder: `--format paths|tsv|csv|json`, `--delimiter`, `--exclude-name`,
  `--exclude-path`, `--no-default-excludes`, `--skip-existing`, `--fail-empty`,
  `--status`, `--verbose`, `--color`, `-o -` for stdout.
- Finder: metadata enrichment (`owner`, `group`, `modified`, `wp_version`,
  `db_name`) read with `stat` and a bash regex — no `eval`, no PHP.
- `tools/scan-secrets.sh` 1.1.0 with `--history`, `--strict`, `--show-values`,
  `--min-length`, `--allowlist`, `--verbose`, `--quiet`, value masking and a
  fingerprint per finding, plus `tools/secret-allowlist.txt`.
- Configuration files `/etc/wp-cli-update.conf` and `./wp-cli-update.conf`,
  environment variables `WP_CLI_UPDATE_<KEY>`, and
  `wp-cli-update.conf.example` documenting every setting.
- Log rotation for both logs (`LOG_MAX_BYTES`, `LOG_KEEP`).
- Locking with `flock`, a pid-file fallback, stale-lock detection and
  `--no-lock`.
- `trap` on EXIT/INT/TERM/HUP that prints a partial summary, so an interrupted
  fleet run still reports how far it got.
- Five test suites and a recording `wp` stub (`tests/`), plus `AGENT.md`,
  `PROJECT_MAP.md`, `.gitignore` and `.gitattributes`.

### Changed

- **BREAKING for callers that parsed stdout**: in a data format (`--format
  json|csv|tsv`) stdout now carries *only* the data. The banner, progress lines
  and the summary moved to stderr, together with all other prose in both scripts.
  `… --format json | jq` and `… --format csv > plugins.csv` now work.
- **BREAKING for the default `--skip-plugins` list**: the default is now empty.
  The previous revisions hardcoded `saphali-woocommerce-lite,
  jet-compare-wishlist, jet-data-importer` into every `wp` call, which is one
  installation's requirement shipped as everybody's default. Set `SKIP_PLUGINS`
  in the config file instead.
- `--help` and `--version` exit **0** in both scripts. Previously `--help` exited
  1 in the manager and was not recognised at all by the finder, which treated it
  as a directory to scan.
- Usage errors exit **2**, environment errors **3**, configuration errors **4**.
  Previously every failure exited 1, so a cron job could not tell “you typed it
  wrong” from “the update failed”.
- Configuration is parsed as `KEY=VALUE` and never sourced. The `ragraf` and
  `v5` revisions sourced the file, which turns a writable config into root code
  execution.
- The Astra licence reaches `wp` through a temporary file read by the child
  shell, so it is never in argv. `v5` passed it as an argument; `main` expected
  the key to be edited into the script.
- `main`'s `--DEBUG` is `-D, --debug`; `--quiet` and `--verbose` are separate.
- Finder default depth is 8 (was 6) and the default exclusion list is name-based
  and anchored, not the glob soup of the original.
- Owner resolution accepts `root` as a last resort, with a warning. The original
  refused root-owned sites outright and skipped them silently, which in a
  container is every site.

### Fixed

- **The finder in `main` did not work at all.** `parse_args` ended with a test
  that returns 1 when no `--exclude` was given, and `set -e` aborted the script
  before the scan: exit 1, empty output, no error message.
- **`v6.0.0-deepseek` could not update a single site.** The child command was
  built with `printf %q` and handed to `su - USER -c`, which runs the target
  user's shell; `/bin/sh` is dash on Debian, `\&\&` is a literal there, and every
  call failed with `cd: too many arguments`. The runner now passes arguments as
  positional parameters (`sh -c 'cd -- "$1" || exit 127; shift; exec "$@"' sh
  DIR PROG ARGS…`), which needs no escaping in any shell — the mechanism taken
  from `v6.0.0-ragraf`.
- **`v6.0.0-ragraf` scanned the whole filesystem in addition to the requested
  root.** `CLI_ROOTS=("${CLI_ROOTS[@]:-}" "$1")` produces one empty element in
  bash 4.4+, and the normaliser turned it into `/`; every run also listed sites
  from unrelated roots. All array expansions now use `${arr[@]+"${arr[@]}"}`, and
  `test_base_contract.sh` asserts that no run ever exceeds the requested roots.
- **`rewrite-v5.0.0` dropped two public modes** (`--list-plugins`,
  `--plugin-manage`) and **the `.no_wp_cli` opt-out marker**, so sites that had
  opted out of maintenance were updated anyway. Both are restored and both are
  covered by the base-contract suite.
- **`AutoClaw-GLM-5.3-RAGRAF` printed `results_file: unbound variable` on every
  successful finder run**: an EXIT trap installed inside a function referenced a
  `local` variable that was out of scope by the time it fired, which also leaked
  the temporary file and replaced the previous handler. Traps are now installed
  once, at file scope, over a global list.
- Temporary files were registered from inside a command substitution, i.e. in a
  subshell, so the registration was lost and every run leaked two or three files.
  `make_tmp` now sets a global instead of printing.
- An `exit` inside a command substitution only left the subshell: `--sites` with
  no argument reported “requires a value” and then continued with an empty path.
  Option values are taken from a global set by `need_value`, so the exit happens
  in the main shell.
- An `exit` inside the EXIT trap replaced the pending exit status, turning a usage
  error (2) into an environment error (3) on its way out.
- `wp core check-update` is no longer counted as an operation: it exits 1 when a
  site is up to date, which read as a failure on every healthy run.
- A soft failure (`run_wp_soft`) returned success unconditionally, so the Astra
  retry path could never be reached. It now returns the real outcome.
- `--skip-plugins` was appended to `db optimize`, `db repair` and `cron event
  run`, where it is meaningless and WP-CLI warns about it. It now applies only to
  `plugin`, `theme` and `brainstormforce` subcommands.
- The secret guard classified any value containing `EXAMPLE` as a placeholder,
  which let the canonical AWS documentation key through, and `shopt -s
  nocasematch` silently turned every `[A-Z]` class into “any letter”, which made
  the placeholder rule match a UUID. Placeholder detection is now anchored and
  case handling is explicit per pattern.
- The prune expression in the finder did not prune: `-type d` has to be inside the
  parenthesised group, because `-prune` evaluates to true even for a plain file.
  Four variants were measured; the working one is documented in
  `build_find_args`.
- Personal data removed from the shipped code: the third-party address
  `paul@pmtech.com`, host-specific paths, and the author's plugin list.
- Site lists with CRLF line endings, leading/trailing whitespace and `#` comments
  are handled; previously a CR made every path invalid.
- The colour policy is honoured in the log files: no ANSI escapes are written to
  `manager.log` or `errors.log`.

### Security

- No command is built by string concatenation anywhere in the tree. Verified by
  `test_static.sh` (no `eval`, no backticks, no `printf %q`, no `su -c` without
  `-s`, no sourcing) and by injection tests that put `; touch …`, `"$(…)"` and a
  jq payload into `--name` and into a site path.
- A site path, a plugin name and a user name are data all the way down to `argv`.
- The config file cannot execute code, and a line with a shell metacharacter
  rejects the whole file with exit 4.
- The licence value is registered with `redact()` and scrubbed from every console
  line, log line, dry-run listing and error box; the internal marker is replaced
  with `<licence>` so it never reaches an operator-facing message.

## [6.0.0 / 2.0.0] - 2026-10-07

Four independent revisions of `main` produced on branches `rewrite-v5.0.0`,
`v6.0.0-ragraf`, `v6.0.0-deepseek` and `AutoClaw-GLM-5.3-RAGRAF`. None was
merged. Superseded by 6.1.0.

## [5.0 / 2.0.0] - 2026-04-07

Baseline on `main` (`8c720e6`): `Bash_WP-CLI_Update.sh` 5.0 and
`Find_WP_Senior.sh` 2.0.0. Ten operation modes, per-site user switching, table
rendering, progress output. Known defects, all fixed in 6.1.0: the finder exits 1
without output, `--help` is not a flag, commands are built by string
concatenation, no lock, no log rotation, no dry run, and the Astra key is edited
into the script.

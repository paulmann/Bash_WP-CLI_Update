# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This is a user-facing document. An internal agent log is not a changelog: entries
of the form “script (backup v3) - refactor” were published by two earlier
revisions and told the reader nothing they could act on.

## [6.2.0 / 2.1.0] - 2026-10-08

Fleet release. Everything here was taken from the `SagaAI_DeepSeeek_Flash`
revision (`3904a73`) after a comparative measurement showed it ahead of this tree
on four counts, plus one archive idea and one documentation idea. What was
deliberately **not** taken is listed at the bottom, with the measurement that
decided it. `REFACTORING.md` records the audit in full.

### Added

- `-j, --jobs N`: parallel site processing in batches. Bash 4.2 has no `wait -n`,
  so this is a batch barrier, not a continuous pool. Per-site console output and
  log lines are buffered in per-worker fragments and replayed in **site order** at
  the barrier, so neither the terminal nor the log file interleaves. Measured on
  five sites of one second each: 5 s sequential, 1 s at `-j 5`, 3 s at `-j 2`.
- `--no-user-switch`: run WP-CLI as the invoking user. Two audiences: single-site
  hosts where the operator already is the site user, and test suites. The second
  one matters more than it looks — three independent suites in this project's
  history (GLM's, SagaAI's, and the first revision of ours) reported dozens of
  failures that were purely "the fixture is owned by root and there is no account
  to switch into". With the switch disable-able, the suite is portable.
- `-b, --backup db|full`, `-B, --backup-dir`, `--keep-backups N`, `--no-backup`.
  `db` runs `wp db export` with the per-command timeout disabled, because a
  truncated dump is worse than no dump: it looks like a backup. `full` archives
  the tree and reports its size first. Rotation prunes by mtime with
  `find -printf '%T@' | sort -rn`, not `ls -1t`, whose output is locale- and
  width-dependent.
- A plugin deletion now backs up `wp-content/plugins/<slug>` to a tar.gz **and
  deactivates the plugin first**. `plugin delete` on an active plugin leaves its
  options, tables and cron events behind, because the deactivation hooks never
  run. `--no-backup` is honoured but logged as a warning.
- `--verify`: read-only `core verify-checksums` plus `plugin verify-checksums
  --all`. Nothing is mutated, so it is safe to schedule hourly.
- `--only-active`: update only plugins that are active **and** have an update
  available. The set is enumerated from `plugin list --format=json` and passed by
  slug, so one broken plugin can no longer hide behind `--all`.
- `-e, --exclude-plugins LIST`: leave named plugins out of `--plugins` and
  `--full`. Matched case-insensitively against slug and display name as whole
  tokens — never as a pattern, so nothing needs escaping.
- `-U, --url URL`: passed to WP-CLI as `--url` on every call, for multisite
  installations where one directory serves several URLs.
- `-J, --json` / `--json-lines`: the fleet report as JSON Lines — one object per
  site plus a summary object. Lines rather than an array, because a fleet run is
  a stream: with an array the operator gets nothing until the last site finishes,
  and a killed run produces invalid JSON. `-J` keeps its old meaning under
  `--list-plugins` (the plugin-list format); the dual meaning is resolved after
  all mode flags have been parsed, so `--json -l` and `-l --json` agree.
- `--strict`: exit non-zero when anything was warned about, not only when
  something failed. Applies to an empty fleet as well, because "processed zero
  sites" is exactly the silent failure a cron job needs to shout about.
- `--list-sites`: resolve the inventory — including owner detection and the
  finder run — print it and exit. Works without a wp binary, without a lock and
  without root.
- `legacy/`: byte-exact copies of the two original `main` scripts, verified with
  `git hash-object`. Citations of the form `main:396` in `ANALYSIS.md` are
  checkable without git history, and rollback does not depend on git.
- `ANALYSIS.md`: audit of the original code — every defect with a line citation,
  the reproduced command-injection PoC, what was verified and is **not** a
  defect, and the residual limitations of the new code.
- `REFACTORING.md`: what this tree took from each of the five revisions, what it
  rejected and why, and the fourteen defects found while integrating them.
- `tests/test_fleet.sh`: 95 checks over the fleet-wide surface, including timing
  assertions for parallelism, counter equality across `-j 1/2/3/5`, log
  contiguity, a killed worker, and every shell metacharacter in a config file.
- New configuration keys, all three layers deep: `JOBS`, `BACKUP`,
  `KEEP_BACKUPS`, `BACKUP_DIR`, `EXCLUDE_PLUGINS`, `ONLY_ACTIVE`, `STRICT`,
  `NO_USER_SWITCH`, `URL`.

### Changed

- **BREAKING for `--list-plugins` consumers that counted rows**: the recording
  stub in `tests/stub/wp` now reports five plugins instead of three, because
  `--only-active` cannot be tested without an inactive plugin that has an update.
  The suite derives its expectations from the stub instead of hardcoding a count.
- `-J` outside `--list-plugins` now means JSON Lines rather than "the plugin list
  in JSON". Inside `--list-plugins` it is unchanged.
- `plugin delete` deactivates first. A caller that relied on `delete` alone
  reaching WP-CLI now sees one extra `plugin deactivate` call per deletion.
- The version is 6.2.0 rather than 6.1.0: the public surface grew by nine options
  and one mode.

### Fixed

- **The environment layer of the configuration precedence did not exist.**
  `is_set` tested only shell variables, so `WP_CLI_UPDATE_JOBS=7` from a login
  shell was never seen and the documented `file < environment < command line`
  order collapsed into `file < command line`. `is_set` now consults `printenv`,
  and a new `env_value` reads the value the same way.
- **`--list-sites --json` printed the table.** The branch ran before
  `validate_args`, which is where the dual meaning of `-J` is resolved. It now
  runs after.
- **`--strict` did not fire on an empty fleet.** The "nothing to do" path exited 0
  before `final_exit_code` was consulted, so the one run a cron job most needs to
  hear about was the one it never reported.
- A worker forked for a parallel batch inherited the parent's counters and wrote
  them back, so every batch after the first double-counted. Workers now zero
  their counters at fork; the totals are identical at `-j 1`, `-j 2`, `-j 3` and
  `-j 5`, and the suite asserts exactly that.
- `--skip-plugins` reached `plugin list`, hiding the very plugins being listed.
  It is now applied only to operations that change plugins or themes, and to
  listings only under `--skip-plugins-for-listing on`.
- The backtick guard in the config parser was dead. It compared against a
  variable that had been written as `BACKTICK="$'\140'"` — in double quotes that
  is the seven-character literal `$'\140'`, not a backtick, so a config line
  containing a real backtick was accepted. `BACKTICK=$'\140'` now, and the suite
  walks all seven metacharacters.
- `run_sequential` called `run_fleet`, which called `run_sequential`: an
  integration patch had matched the loop inside the helper instead of the one in
  `main`, so `-j N` silently ran sequentially. `tests/test_fleet.sh` measures the
  wall clock against a sleeping stub, which is the only reason this was caught.
- Backticks in the `--help` text were executed: the usage heredoc is unquoted (it
  expands `${PROG_NAME}`), so a literal pair of backticks became a command
  substitution and `--help` hung. The help now uses single quotes for literals.
- `--print-config` showed the configuration *layer* rather than the layer that
  decided the value, so a command-line override was reported as coming from the
  file. An `effective_source` column and a `CLI OVERRIDE` column replaced it.

### Not adopted, deliberately

| From `SagaAI` | Why not |
|---|---|
| Passing the Astra licence as an argument to `wp` | Measured: the value lands in the child's argv and is visible in `ps` for the duration of the call. Their own `ANALYSIS.md` §10 discloses this, and their own script header forbids it. This tree keeps the temporary-file handoff, where the value is never an argument of any process. |
| `source` for the configuration file | Their guard refuses group/world-writable files and that guard works, but a root-owned 0644 file is still root code execution. Measured: a payload in such a file ran. This tree parses `KEY=VALUE` and rejects any line with a metacharacter. |
| `shell_join` on `printf %q` for the `su` fallback | Correct *there*, because `-s /bin/sh` is explicit — that is precisely the mistake `v6.0.0-deepseek` made. But `%q` emits `$'…'` for strings with control characters, which POSIX `sh` does not understand. The positional-parameter runner needs no quoting at all and has no such edge. |
| The author's plugin list as the default `--skip-plugins` | One installation's requirement shipped as everybody's default. The default here is empty and the list lives in `wp-cli-update.conf.example` as a comment. |

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

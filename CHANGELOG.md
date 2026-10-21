# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This is a user-facing document. An internal agent log is not a changelog: entries
of the form “script (backup v3) - refactor” were published by two earlier
revisions and told the reader nothing they could act on.

## Release history of this repository

The 8.0.0 line was built by folding every earlier line of work into `main`, one commit
and one release at a time, so that each attempt stays readable instead of being
overwritten. Each step's tree is byte-identical to the branch it came from, and each
branch is preserved as an annotated tag `llm/<branch>`:

| Release | Source | What it was |
|---|---|---|
| `v5.0.0` | `main` (before the chain) | the original monolith: two scripts, no lock, no backups, no tests |
| `v5.1.0` | `rewrite-v5.0.0` | first rewrite with test suites and documentation |
| `v6.0.0` | `v6.0.0-ragraf` | RAGRAF + Flash revision of the 6.0 line |
| `v6.0.1` | `v6.0.0-deepseek` | DeepSeek 4 Pro revision of the same line |
| `v6.0.2` | `AutoClaw-GLM-5.3-RAGRAF` | GLM 5.3 revision; adds a secret guard |
| `v6.0.3` | `SagaAI_DeepSeeek_Flash` | SagaAI sync of the 6.0 sources |
| `v6.1.0` | `DeepSeek_Hybrid` | `--health`, `--secrets`, site URL detection, short options |
| `v6.2.0` | `QWEN_Hybrid` | fleet release; the base of 8.0.0 |
| `v7.0.1` | `QWEN-Agent_Mode` | a modular tree (`src/manager`, `src/finder`) built into one script |
| `v8.0.0` | this tree | the merge: read-only modes, restore, fleet control, guards, reports |

Notes for a reader of this file: the entries below start at 6.2.0 because that is the
tree 8.0.0 was built on. The changelog of each earlier release lives in that release's
own tree (`CHANGELOG.md` at the tag) and in its GitHub release notes. 7.0.1 is a
different architecture, not an earlier draft of 8.0.0: it is preserved as its own
release and is not a superset of it (it has no restore path, no disk guard and no
circuit breaker; 8.0.0 has no modular `src/` tree).

## [8.0.2 / 2.1.0] - 2026-10-21

Patch release. Found while installing 8.0.1 on a production host with the configuration
section §11 of the README recommends.

### Fixed

- **A mode-restricted key in a config file broke every read-only mode.** With
  `SKIP_IF_NO_UPDATES=1` — which the recommended production profile sets — `--doctor`,
  `--check`, `--health`, `--status` and `--list-backups` exited 2 with
  “only applies to --core, --plugins, --themes and --full”, because `validate_args`
  checked the three mode-restricted keys without asking where the value came from. On a
  host configured exactly as documented, the tool could not even diagnose itself. The
  check now fires only when the flag was typed on the command line (`CLI_SET`); a value
  from a file is inert for modes that do not use it. `--db-optimize
  --skip-if-no-updates` is still a usage error, because that is a real mistake.
- Regression test added to `tests/test_v7.sh`: a config file carrying all three keys
  must not break `--doctor` or `--list-modes`, and an explicit flag with the wrong mode
  must still exit 2.

## [8.0.1 / 2.1.0] - 2026-10-21

Patch release. No behaviour change: the manager, the finder and every mode are exactly
what 8.0.0 shipped.

### Fixed

- **`tests/test_static.sh` failed at random.** The new “every option is documented”
  check compared `printf ... | grep -q` under `set -o pipefail`: `grep` exits at the
  first match, `printf` then dies of SIGPIPE, and the pipeline status becomes 141 — so a
  successful search was reported as “option undocumented”, in 0 to 7 checks depending on
  where in the help text the match happened. The comparison is now a shell pattern
  match, with no subprocess and no pipe. Eight consecutive runs are clean.
- **`LICENSE` was the GNU GPL v3 text.** Every other file — the manager header, the
  README, `PROJECT_MAP.md` and the release notes — said PolyForm Noncommercial 1.0.0,
  and the repository history said the licence had been changed to it, but the file
  itself had never been replaced. It now carries the canonical PolyForm Noncommercial
  1.0.0 text, a copyright line and the SPDX identifier. This matters for anyone who
  took 8.0.0: the archive's `LICENSE` contradicted its own README.

### Changed

- `SHA256SUMS` lists bare file names, not `dist/...`. The release archive is downloaded
  next to the checksum file, so `sha256sum -c SHA256SUMS` used to fail on a fresh
  download with “No such file or directory” — verified now on both 8.0.0 and 8.0.1.
- `.gitattributes` covers the file types 8.0.0 introduced: `*.service`, `*.timer`,
  `*.yml`, `Makefile`, `.editorconfig`, `LICENSE`, `*.example`, plus `*.tar.gz`
  marked binary. A CR byte in a systemd `[Timer]` section is an error an operator sees
  only at enable time, which is why the unit files are listed explicitly.
- `legacy/README.md` now names the release (`v5.0.0`) and the blob each original is
  frozen at, and explains why the directory stays even though every earlier line of
  work is a release plus an `llm/<branch>` tag. It also pointed at `REFACTORING.md`
  for the line-number citations, while the citations live in `ANALYSIS.md`.

## [8.0.0 / 2.1.0] - 2026-10-21

One product built from three lines of work: `main` (the 5.x monolith), `QWEN_Hybrid`
(6.2.0, the code this is based on) and `DeepSeek_Hybrid` (6.1.0). The comparison, the
merge decisions and the rejected candidates are in `docs/COMPARISON.md`.

**Why 8.0.0 and not 7.1.0.** The `QWEN-Agent_Mode` branch shipped its own 7.0.1: a
modular tree (`src/manager/*.sh` built into one script) with its own documentation set.
8.0.0 is a rebuild on the 6.2.0 lineage rather than a continuation of that tree, so it
takes a major number instead of pretending to be a patch on a codebase it does not
share. That branch keeps its own release (7.0.1) and is not lost: it is tagged
`llm/QWEN-Agent_Mode`. Features that exist only there (notifications, reporting,
secrets, completion) are re-implemented here; the two implementations differ in shape,
and the comparison document says how.

### Added — read-only modes

- `--health`: core version, pending plugin and theme updates, database size, per site.
  Takes no lock, no backup, writes nothing. Safe to call from monitoring every minute.
- `--secrets`: scans `wp-config.php` for secret-bearing constants and prints **names,
  never values**; flags a world-readable `wp-config.php` and stale copies
  (`.save`, `.bak`, `.old`, `.env`) as findings. Exit 1 only for a real defect.
- `--doctor`: host diagnosis — wp binary, user-switch mechanism, optional tools, paths,
  free space, config permissions and the policy actually in force.
- `--list-backups`: what this tool has written for each site, newest first.
- `--completion bash|zsh`: a completion script covering every mode and option.

### Added — restore path

- `--restore-db FILE --yes`: imports a dump, takes a safety dump of the live database
  first, and runs `wp db check` afterwards. Without `--yes` every site refuses.
  A tool that takes backups and cannot restore them is half a tool.

### Added — fleet control

- `--retry N` and `--retry-delay SEC`: re-run a failed site. Worth it for a timed-out
  download or a busy lock, not for a wrong `--url`; the default stays 0.
- `--max-failures N`: circuit breaker. A fleet-wide failure (broken WP-CLI, full disk,
  network outage) stops the run instead of writing the same error 200 times; the
  remaining sites are reported as skipped.
- `--run-timeout SEC`: total time budget, checked per site.
- `--lock-wait SEC`: wait for a concurrent run instead of failing at once.
- `--skip-if-no-updates`: ask the cheap read-only question first and skip sites whose
  core, plugins and themes are current.

### Added — production guards

- `--min-free-mb N`: refuse to write a dump when free space is below N MiB. The guard
  runs before the export, not after it failed.
- `--nice N`, `--ionice idle|best-effort|none`: a fleet update must not outrun the web
  server it shares a disk with. Applied inside the switched-user command, so no
  re-quoting is involved.
- `--backup-age-days N`: age-based retention in addition to `--keep-backups`.
- `--backup-compress`: gzip a database dump after export.
- Read-only modes no longer take a backup. Exporting a database before `--list-plugins`
  costs seconds per site and fills the disk for nothing.

### Added — observability

- `--report FILE`: one JSON document per run — counters, per-site status and the change
  list (`plugin jetpack 13.0 -> 13.5`), written atomically.
- `--json-log`: one JSON object per log line, for a log shipper.
- `--notify URL`, `--notify-on never|failure|always`, `--mail-to ADDR`: run summaries.
  The payload carries counters only — no site content, no licence, no paths.
- Change tracking: before/after version snapshots of plugins, themes and core when a
  report or `--json-lines` is requested.

### Added — policy and targeting

- `--exclude-themes`, `--hold-plugins`, `--hold-themes`. A hold is a pin, not a filter:
  the log says the plugin was held, so a stale plugin is visible instead of silent.
- `--default-user NAME`: fallback when ownership cannot be determined.
- `-u`, `-C`, `-T`, `-L`, `-k` short forms; `--wp-bin` alias.
- `WP_GLOBAL_ARGS`: extra global flags for `wp` (for example `--skip-themes`).

### Added — multisite

- `--url` is derived from `WP_HOME`/`WP_SITEURL` in `wp-config.php` when it is not given.
  Without it WP-CLI refuses to pick a site on a multisite install. `--no-url-detect`
  turns the behaviour off, and a multisite without `WP_HOME` is reported once.

### Added — compatibility

- 6.1 configuration names are accepted with a single warning instead of being ignored:
  `WP_TIMEOUT` -> `TIMEOUT`, `WP_CLI_BIN` -> `WP_CLI_PATH`, `SITE_URL` -> `URL`,
  `BACKUP_KEEP` -> `KEEP_BACKUPS`, `DEFAULT_JOBS` -> `JOBS`.

### Changed

- Configuration gained 23 keys; `--print-config` lists all of them with the layer that
  produced the value.
- The summary reports retries, applied changes, an aborted flag and a human duration.
- `--duration` in the summary is printed once (`1m 12s (72s)`), not twice.
- A read-only mode no longer takes the lock: `--health` answers while `--full` is
  halfway through the fleet.
- `tests/harness.sh` adds `--no-user-switch` when the suite runs as a non-root account,
  so the same suite proves something on a laptop and on the server.

### Fixed

- `duration` was printed twice in the summary.
- The change log survives an interrupt: the summary and the report are written before
  the temporary files are removed.
- A failing site no longer counts its backup as "no backup": the site is stopped and
  reported instead of being updated unprotected.

### Tests

- New `tests/test_v7.sh`: 111 checks over the read-only modes, the restore path, retries,
  the circuit breaker, the guards, the report, the change log, the policy lists,
  `--url` detection, `--nice`/`--ionice` and the config aliases.
- `tests/stub/wp` learned `--format=csv|count`, `--update=available`, `db size`,
  `db import`, `db check`, `--version`, and two failure hooks (`FAKE_FAIL_ONCE`,
  `FAKE_FAIL_ALWAYS`) plus `FAKE_NO_UPDATES` and `FAKE_VERSION_BUMP`.

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

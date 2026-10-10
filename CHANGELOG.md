# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
semantic versions for the two shipped scripts (manager `7.0.0`, finder
`3.0.0`).

## 7.0.0 — manager / 3.0.0 — finder

A full production rework of the 6.2 fleet release: a modular source tree that
builds into the same drop-in single files, a WP-CLI version policy with a
self-updater, the maintenance modes the tool was missing (caches, translations,
cleanup, audits, restore), and the monitoring surface a scheduled tool needs
(state file, Prometheus metrics, notifications, smoke tests).

### Added — WP-CLI version policy and self-management (the headline feature)

- `WP_CLI_MIN_VERSION` floor (default 2.8.0), checked at the startup of every
  fleet run: below it the run refuses with exit 3 and names the fix. An
  unparsable version warns instead of bricking the host.
- `--wpcli-check` — read-only report: binary path, resolved realpath, install
  kind (phar/script/php-source), installed version, PHP version, writability,
  gate PASS/FAIL, newest upstream release and currency. Works with no site
  list, no root and no healthy WordPress.
- `WP_CLI_LATEST_CHECK` — startup currency check via `wp cli check-update`
  (WP-CLI's own answer, channel aware), falling back to the GitHub releases
  API; `GITHUB_TOKEN` is honoured for the rate limit.
- `--wpcli-update` — channel updates through `wp cli update` (`stable/nightly`,
  scope `auto/patch/minor/major`), or a **pinned version**
  (`--wpcli-version X.Y.Z`) by direct release download.
- Verified downloads, failing closed: GPG signature against the published
  WP-CLI release key with a fingerprint check, SHA-512 fallback, a pre-install
  smoke test of the phar, an atomic swap, and a timestamped backup of the
  replaced binary.
- `--wpcli-install` (missing binary) and `--wpcli-rollback` (list candidates,
  smoke-test, put one back).
- New settings: `WP_CLI_MIN_VERSION`, `WP_CLI_LATEST_CHECK`,
  `WP_CLI_RELEASE_API`, `WP_CLI_UPDATE_CHANNEL`, `WP_CLI_UPDATE_SCOPE`,
  `WP_CLI_TARGET_VERSION`, `WP_CLI_VERIFY_PHAR`, `WP_CLI_GPG_KEY_URL`,
  `WP_CLI_GPG_FINGERPRINT`, `WP_CLI_BACKUP_DIR`, `WP_CLI_UPDATE_YES`,
  `WP_CLI_INSECURE`, `PHP_BIN`, `HTTP_CLIENT`, `USE_JQ`.

### Added — maintenance modes that were missing

- `--cache` (`-C`): `cache flush`, transient cleanup (`expired|all|none`),
  `rewrite flush`, and `CACHE_EXTRA` tokens for page-cache plugins (each token
  becomes one argv element — never a shell string). The repository advertised
  "cache flush" for years without having it; a correctly updated site that
  keeps serving stale pages was the symptom.
- `--languages` (`-L`): core/plugin/theme translation updates, probed for
  WP-CLI support; included in `--full` (`FULL_LANGUAGES`).
- `--cleanup` (`-X`): revisions (keep N **per post**, not per site — the
  difference between a cleanup and a data-loss event), trash, spam,
  auto-drafts, expired transients, then `db optimize`. Enumerates and reports
  counts first; deletes only with `--yes`; ids are validated as integers and
  batched against ARG_MAX.
- `--report`: read-only fleet inventory (WP/PHP/WP-CLI versions, home URL,
  multisite size, plugin/theme/user/admin counts, pending updates, DB size,
  optional uploads size, WP-Cron reachability via `cron test`, free disk),
  rendered as an aligned table or per-site JSON/CSV/TSV.
- `--security`: hardening & integrity audit with a documented 0–100 score
  (−25 crit / −8 warn / −1 info): wp-config permission bits (bit arithmetic,
  not digit eyeballing), WP_DEBUG, DISALLOW_FILE_EDIT/MODS,
  WP_AUTO_UPDATE_CORE, pending **minor** core release = unapplied security fix
  = critical, core/plugin checksums, PHP files inside uploads, world-writable
  PHP, dumps/archives in the webroot, admin count, `admin` login, HTTP vs
  HTTPS, table prefix (info, not fear), secret scanner integration. Critical
  findings fail the site; `--strict` fails on warnings too.
- `--secrets`: the repository's scanner run over a whole site tree.
- `--restore`: list a site's backups, restore a dump (`--from N|file`) or an
  archive (`--restore-files`), with a pre-restore dump by default, a
  "looks like a SQL dump" gate, and an explicit `--yes`.
- `--plugin-manage` grew `install`, `update` and `status` actions; a fuzzy
  `--name` resolves to exactly one slug or fails with "ambiguous".
- `--full` now flushes caches and rewrite rules at the end (`FULL_CACHE`) and
  no longer runs `db repair` (opt back in with `FULL_DB_REPAIR=1`):
  `mysqlcheck --repair` is a no-op that still walks every InnoDB table and
  locks MyISAM ones — an outage window for no benefit.
- Multisite: `MULTISITE=all` expands each installation into one work unit per
  subsite, each targeted with its own `--url`; every mode function now takes
  `(site, user, url)`.

### Added — fleet operations

- Site filters `--include/--exclude GLOB` (repeatable; exclude wins),
  `--max-sites`, `--stagger SEC`, `--retry N`, `--fail-fast`,
  `--max-duration SEC` (whole-run budget; stops **between** sites, exit 6).
- `--maintenance-mode`: WordPress maintenance mode around each site's update,
  deactivated unconditionally — a site left in maintenance mode by a failed
  update would be a second outage caused by the tool that prevents one.
- `--smoke-test`: fetch the site URL after a change (`SMOKE_TIMEOUT`,
  `SMOKE_EXPECT`, `SMOKE_SSL_VERIFY`, `SMOKE_ON_FAIL=fail|warn`); degrades with
  a warning when no HTTP client exists.
- `--state-file` (atomic JSON run document, written even after an interrupt)
  and `--metrics-file` (Prometheus textfile: `wpu_up`, `wpu_exit_code`,
  `wpu_sites_*`, `wpu_ops_*`, `wpu_findings*`, `wpu_unit_status{…}`,
  `wpu_unit_elapsed_seconds{…}`).
- Notifications: `NOTIFY_ON=never|failure|always`, `NOTIFY_WEBHOOK_URL` with
  `generic|slack|discord|telegram` payload shapes, and `NOTIFY_COMMAND` (argv +
  `WPU_*` environment; never through a shell; a failing notification warns but
  never fails the run).
- Locking: `LOCK_TIMEOUT` (wait instead of fail), `LOCK_REQUIRED`; the pid-file
  fallback no longer deletes a lock that a next run has already taken.
- Backups: `MIN_FREE_MIB` free-space guard, `Dump completed` marker check,
  per-site directories chowned to the site user (0750) with a documented
  sticky-dir fallback, portable pruning without GNU `find -printf`.
- Site list: `--sites -` reads stdin; a per-line owner column separated by a
  **TAB** (never a space — paths with spaces are legal); non-WordPress roots
  are skipped with a reason.
- Unprivileged runs: no more blanket "root or die". A non-root caller may run
  when every resolved owner is the caller; otherwise the refusal names the
  first site that needs a switch.
- Exit code **6** (stopped early) joins the contract.

### Added — tooling, DX and docs

- Modular source tree (`src/manager/01..18`, `src/finder/01..06`) built into
  the single-file artifacts by `tools/build.sh` — a build that creates **no
  processes** (works at the process-limit edge), with `--check` drift
  detection; artifacts carry a generated-file notice and a build stamp.
- `--init-config [FILE]` regenerates the full annotated configuration from the
  same `CONFIG_SPEC` table that drives defaults, validation and docs
  (0600 when written to a file).
- `--completion bash|zsh` and `--list-modes`, both generated from the option
  and mode tables; `--version-detail` prints build id and capability probes.
- "Did you mean …" suggestions for near-miss flags and config keys.
- `Makefile` (`build/lint/test/check/install`), GitHub Actions CI, shell
  completion files, systemd units, cron and logrotate examples under `docs/ops/`.
- Nine test suites plus a stub `wp` that can fail, hang, report versions,
  simulate a multisite and record its argv; ~500 checks, no root, no
  WordPress, no WP-CLI, no network.
- New documentation set: `docs/CONFIGURATION.md`, `OPERATIONS.md`,
  `SECURITY.md`, `ARCHITECTURE.md`, `TROUBLESHOOTING.md`, `MIGRATION.md`,
  `CONTRIBUTING.md`, and a rewritten README.

### Added — finder (3.0.0)

- `--manifest FILE` with `--manifest-format tsv|csv|json` and `--fields`:
  owner, group, modes, wp-config mode, WP version, DB name, multisite flag,
  opt-out flag, mtime.
- `--audit`: permission & hygiene findings during discovery (world/group
  writable or world-readable wp-config.php, PHP in uploads, root-owned sites).
- `--verify-list FILE`: audit an existing site list (missing entries,
  non-WordPress roots, opt-outs) instead of scanning; exit 1 on holes.
- `--print0`, `--min-depth`, `--include-name`, `--follow-symlinks` (opt-in,
  with the loop risk documented), `--version-detail`.

### Changed

- **Streams**: all prose (logs, warnings, summaries, error boxes) now goes to
  stderr in *every* format, including tables; stdout carries only data.
  `--report > r.tsv` and `--list-plugins --format csv | …` now behave.
- **Secret handoff defaults to stdin** (`LICENCE_HANDOFF=stdin`): the value is
  piped to the child shell and never touches the filesystem; `file` remains
  for wrappers that consume stdin.
- **Dry-run is truthful**: read-only commands (queries, enumerations, reports)
  execute for real; only mutations are printed and skipped. `--dry-run` on
  `--cleanup`/`--report`/`--plugin-manage` now shows what would actually
  happen, driven by a conservative read-only allowlist where anything unknown
  counts as mutating.
- Configuration: one `CONFIG_SPEC` table is the single source of truth (key ==
  variable name — the old four-list mapping layer is gone); every child `wp`
  call gets `</dev/null` unless a secret is piped, so nothing can hang on a
  prompt; `LC_ALL=C`, cron-proof `PATH`, `umask 077`.
- Performance/fork discipline on hot paths: log timestamps via bash's
  `printf '%(…)T'`, redaction/escaping/path helpers publish globals instead of
  stdout, log rotation tracks size in memory, `basename/dirname/date/wc`
  replaced by builtins, JSON slurps without `cat` — one 200-site run forks
  orders of magnitude fewer processes than 6.2 did.
- `--health`-style reporting absorbed into `--report`; `--audit` alias for
  `--security`; `--sites-file`, `--wp-cli`, `--exclude-sites`,
  `--include-sites`, `--no-smoke-test` accepted as aliases.

### Fixed (relative to the 6.2 base)

- `table_render` split any cell containing a space into two columns (unquoted
  array iteration) and measured widths over rows it never printed.
- `--list-plugins --format table -j N` sent the table to stderr in parallel
  runs (worker sink routing).
- Per-site `ops_ok/ops_failed` were always 0 in JSON Lines; worker counters for
  skipped sites, findings, retries, smoke tests and backups are now folded back.
- `run_document`/summary reported an empty `wpcli_version` (the cache was set
  inside a command substitution and died with the subshell).
- `plugin_resolve_slug` double-counted a name+slug match on the same plugin,
  turning "jetpack" into an ambiguity error on every site that had it.
- A JSON payload with a plugin's stderr notice glued in front failed to parse;
  the array is now sliced from the first `[` to the last `]`.
- `db repair` no longer runs inside `--full` by default (see Changed).
- The pid-file lock could be deleted by a finished run after a timeout, letting
  a third run in; the summary's dead `code=0` no-op branch is gone; duplicate
  help entries (`--print-config` twice) and the truncated licence paragraph in
  `--help` are fixed; `--check` no longer prints two different rows both
  labelled "user switch"; `parse_site_line` trims whitespace as documented;
  section numbering is unique; `/dev/stdout` redirects (unportable: ENXIO when
  fd 1 is a socket, absent without /proc) replaced everywhere by a documented
  empty-sink convention; `resolve_script_dir` no longer changes the process
  working directory and survives symlink loops; SC2317-clean trap handlers.

### Ported from the sibling revision lines (credits)

- **DeepSeek Hybrid**: config-file permission mask (group/world-writable
  refusal), the portable perl timeout supervisor (TERM→group, KILL after a
  grace period, EINTR-safe waitpid), per-site health reporting (absorbed into
  `--report`), the `--secrets` mode idea, `duration_human`, human-readable
  elapsed times in summaries.
- **AutoClaw GLM-5.3/RAGRAF**: `is_wordpress_root` gating, `wp_config_*`
  readers, feature probing via `wp help`, column-fit table rendering ideas,
  the mode-table-driven help/completion concept.
- **SagaAI / earlier lines**: config-as-data parsing, sticky backup
  directories, the counter-fold pattern for parallel workers.

## 6.2.0 (QWEN_Hybrid base)

Fleet release with audited documentation: JSON Lines fleet report, batched
parallelism with ordered replay, backups with rotation, plugin enumeration
(`--only-active`, `--exclude-plugins`), licence redaction, secret scanner with
history mode, six test suites (515 checks). See the `QWEN_Hybrid` branch.

## 6.0.0–6.1.0

Full rewrite of both scripts; config parsed as data; exit-code contract;
Astra licence out of argv; discovery hardening (no accidental `/` scans,
NUL-safe paths, correct `find -prune` grouping). See branches
`rewrite-v5.0.0`, `v6.0.0-*`, `SagaAI_DeepSeeek_Flash`, `DeepSeek_Hybrid`.

## ≤5.0 / 1.01 (legacy)

The original single-purpose updater and finder; kept under `legacy/` for
reference. Config was `source`d (code execution), licence values travelled in
argv, and exit codes were not distinguished. Do not deploy these.

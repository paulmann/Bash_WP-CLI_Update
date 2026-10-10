# Bash WP-CLI Update

WordPress fleet maintenance automation in two standalone Bash scripts and
nothing else. No PHP dependency, no Composer, no daemon, no agent:

- **`Bash_WP-CLI_Update.sh`** runs WP-CLI maintenance operations over every
  site in a list, each one as the system user that owns it, and reports the
  result in a form a human, a cron job and a monitoring system can all consume.
- **`Find_WP_Senior.sh`** builds that list by scanning web roots, enriches it
  into an inventory manifest, and audits the permission hygiene of what it finds.

![Bash](https://img.shields.io/badge/Bash-4.2%2B-blue.svg)
![WP-CLI](https://img.shields.io/badge/WP--CLI-2.8%2B-green.svg)
![WordPress](https://img.shields.io/badge/WordPress-3.7%2B-0073aa?logo=wordpress&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

| Component | Version | Purpose |
|---|---|---|
| `Bash_WP-CLI_Update.sh` | **7.0.0** | run maintenance operations over a site list |
| `Find_WP_Senior.sh` | **3.0.0** | discover installations, write the site list and a manifest |
| `tools/scan-secrets.sh` | 1.1.0 | look for credential literals in the repository |
| `tools/build.sh` | — | build the single-file artifacts from `src/` modules |

Requirements: **bash 4.2+** (CentOS/RHEL 7 or newer, Debian, Ubuntu), GNU
coreutils and findutils, [WP-CLI](https://wp-cli.org/) 2.x, and root to switch
into site owners (an unprivileged run is supported when the caller already owns
every site). Optional and probed at run time — each degrades with a warning
instead of failing: `flock`, `timeout` (or `perl`), `jq`, `curl`/`wget`, `tar`,
`gpg`, `logger`.

---

## Table of contents

1. [Quick start](#quick-start)
2. [What it does](#what-it-does) — [modes](#modes) · [fleet options](#fleet-wide-options) · [exit codes](#exit-codes)
3. [WP-CLI version policy and self-update](#wp-cli-version-policy-and-self-update)
4. [Configuration](#configuration)
5. [Monitoring: state, metrics, notifications](#monitoring-state-metrics-notifications)
6. [Backups and restore](#backups-and-restore)
7. [Scheduling](#scheduling)
8. [Security model](#security-model)
9. [Development: sources, build, tests](#development-sources-build-tests)
10. [Documentation map](#documentation-map)
11. [Troubleshooting](#troubleshooting)
12. [License](#license)

---

## Quick start

```bash
# 1. put both scripts somewhere stable (they are single files by design)
sudo install -d /opt/wp-cli-update
sudo install -m 755 Bash_WP-CLI_Update.sh Find_WP_Senior.sh /opt/wp-cli-update/

# 2. configure (optional but recommended)
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --init-config /etc/wp-cli-update.conf
sudo "$EDITOR" /etc/wp-cli-update.conf        # already mode 0600

# 3. look before you leap -- these change nothing
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --wpcli-check
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --check
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --report
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --full --dry-run

# 4. discover the sites, then run
sudo /opt/wp-cli-update/Find_WP_Senior.sh --output /var/lib/wp-cli-update/wp-found.txt /var/www
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --full --backup db
```

---

## What it does

### Modes

Exactly one mode per run. `--list-modes` prints them for shell completion;
`--completion bash|zsh` prints a completion script generated from the same
table the parser and the help use, so the three cannot drift apart.
`[ro]` marks the read-only modes — safe to schedule as often as you like.

| Mode | Short | What runs |
|---|---|---|
| `--full` | `-f` | core files → schema (`update-db --skip-plugins`) → plugins → themes → translations → cron → caches + rewrite flush → `db optimize` (+ the Astra step when a licence resolves) |
| `--core` | `-c` | `core update`, `core update-db --skip-plugins` |
| `--plugins` | `-p` | `plugin update --all`, or an enumerated set with `--only-active` / `--exclude-plugins` |
| `--themes` | `-t` | `theme update --all` |
| `--languages` | `-L` | core/plugin/theme translation updates (probed: needs WP-CLI 2.2+) |
| `--cache` | `-C` | `cache flush`, transient cleanup, `rewrite flush`, plus your page-cache plugin's commands via `CACHE_EXTRA` |
| `--cleanup` | `-X` | revisions (keep N **per post**), trash, spam, auto-drafts, expired transients — enumerates and reports first; deletes only with `--yes` |
| `--db-optimize` | `-d` | `db optimize` + `db repair` |
| `--db-fix` | `-x` | `db repair` only |
| `--cron` | `-r` | `cron event run --due-now` |
| `--astra` | `-s` | update the Astra add-on, activating the licence when the update fails |
| `--verify` | `[ro]` | core + plugin checksum verification against the WordPress.org manifest |
| `--report` | `[ro]` | fleet health inventory: WP/PHP/WP-CLI versions, pending updates, plugin/theme/user counts, DB size, WP-Cron reachability, free disk — as table, JSON, CSV or TSV |
| `--security` | `[ro]` | hardening & integrity audit with a 0–100 score per site: wp-config permissions, WP_DEBUG, DISALLOW_FILE_EDIT, pending **security** (minor) releases, checksums, PHP in uploads, world-writable files, admin accounts, HTTP-vs-HTTPS, secret scanner |
| `--secrets` | `[ro]` | scan a site tree for credential-looking values |
| `--list-plugins` | `-l` `[ro]` | plugin inventory in table/json/csv/tsv, `--fields`, `--name` filter, `--page-limit` |
| `--plugin-manage` | `-m` | `--action install\|activate\|deactivate\|update\|delete\|status --name X`; a delete is archived first and deactivated before removal |
| `--restore` | | list a site's backups, or restore one (`--from N\|path`, `--yes`; a pre-restore dump is taken unless you forbid it) |
| `--check` | `[ro]` | validate the host and every listed site, change nothing |
| `--status` | `[ro]` | last run (state file or log), log sizes, backup inventory |
| `--list-sites` | `[ro]` | the resolved work list — owners, filters, multisite expansion — without processing it |
| `--wpcli-check` | `[ro]` | WP-CLI version report: installed vs. required minimum vs. newest release, install kind, self-update capability |
| `--wpcli-update` | | update the `wp` binary itself (see [below](#wp-cli-version-policy-and-self-update)) |
| `--wpcli-install` | | install WP-CLI when it is missing (verified download) |
| `--wpcli-rollback` | | put a previous `wp` binary back |

A failing site never aborts the run: it is counted, reported, and the loop goes
on — unless you ask for `--fail-fast`.

### Fleet-wide options

| Option | What it does |
|---|---|
| `-j, --jobs N` | process N sites in parallel batches (default 1 = sequential) |
| `-b, --backup db\|full` | `wp db export`, or a tar.gz of the whole tree, **before** the site is touched |
| `-B, --backup-dir DIR`, `--keep-backups N`, `--min-free-space MIB` | where backups go, how many survive, and when to refuse for lack of space |
| `--include GLOB` / `--exclude GLOB` | filter the fleet by path pattern (repeatable; exclude wins) |
| `--multisite all` | expand every multisite into one work unit per subsite, each with its own `--url` |
| `--only-active`, `-e, --exclude-plugins LIST` | enumerated plugin updates instead of `--all` |
| `--stagger SEC`, `--retry N`, `--fail-fast`, `--max-duration SEC` | pacing, resilience and a hard stop for the maintenance window |
| `--maintenance-mode` | put each site into WordPress maintenance mode while it is updated, and take it out afterwards — unconditionally |
| `--smoke-test` | fetch the site URL after the change; "wp exited 0" is not "the site works" |
| `--state-file`, `--metrics-file`, `--notify`, `--webhook`, `--notify-command` | machine-readable run record, Prometheus textfile metrics, chat/webhook and command notifications |
| `-J, --json` / `--json-lines` | fleet report as JSON Lines: one object per site plus a summary object |
| `--strict` | exit non-zero when anything was **warned** about, not only when something failed |
| `--no-user-switch` | run WP-CLI as the invoking user (single-site hosts, containers, test suites) |
| `--timeout SEC --signal SIG --kill-after SEC` | per-command bound, enforced with `timeout(1)` or a perl supervisor |
| `--lock-timeout SEC`, `--lock-required`, `--no-lock` | concurrency policy for the run lock |
| `-n, --dry-run` | print the real argv of every **mutating** command; read-only queries still run, so enumeration and reports stay truthful |

**Streams.** stdout is data (tables, JSON, CSV, the `--check`/`--status`
reports); stderr is prose (logs, warnings, the summary). Every format —
including the human table — follows that rule, so `--report > report.tsv` and
`--full 2>> maintenance.err` both do what they look like.

**Parallelism is a batch barrier, not a continuous pool.** Bash 4.2 has no
`wait -n`, so the next batch starts when the slowest site of the current one
finishes. Per-site console output and log lines are buffered and replayed in
site order at the barrier, so neither interleaves — `tail -f` on the log looks
stalled until the batch lands, deliberately. Choose N from the slowest shared
resource (normally the database server, not the CPU); 4–8 is sane for one MySQL
instance.

### Exit codes

The codes are a contract and the scripts honour it — including for `--help`.

| Code | Meaning |
|---|---|
| `0` | success (with `--fail-on=any`: every operation on every site succeeded) |
| `1` | operational error — at least one WP-CLI operation failed |
| `2` | usage error — bad command line |
| `3` | environment error — not privileged enough, bash too old, WP-CLI missing **or older than `WP_CLI_MIN_VERSION`**, lock held |
| `4` | configuration error — unreadable, unsafe or invalid config file |
| `5` | nothing to act on (no installation found / empty resolved list) |
| `6` | stopped early — `--fail-fast` or `--max-duration`; the summary is still printed and still accurate for what did run |

The finder adds its own `5` (nothing found), which `--fail-empty` turns into 1.

`--fail-on any|all|never` moves the `0`/`1` boundary: `any` is right for cron
alerting, `all` for best-effort jobs, `never` when you parse the log instead.

---

## WP-CLI version policy and self-update

The tool drives `wp` across a fleet, and the difference between WP-CLI 1.5 and
2.11 is not cosmetic — `language` did not exist, `maintenance-mode` did not
exist, and old builds parse `--format=json` differently. So:

**A floor, checked at startup.** Every fleet run resolves the installed version
(`wp cli version`, without loading any WordPress, so it works even when every
site is broken) and refuses with exit 3 below `WP_CLI_MIN_VERSION` (default
**2.8.0**), naming `--wpcli-update` as the fix. An unparsable answer warns and
continues: a gate that cannot read the answer must not brick the host.

**A currency check, opt-in.** `WP_CLI_LATEST_CHECK=1` (or `--wpcli-check`,
which always checks) asks `wp cli check-update` — WP-CLI's own answer, channel
aware — and falls back to the GitHub releases API when that fails, honouring
`GITHUB_TOKEN` for the rate limit. Being behind the newest release is a
**warning**, never a failure: an offline fleet host must still run maintenance.
With `--strict` it becomes exit 1, which is what you want in CI.

```text
$ Bash_WP-CLI_Update.sh --wpcli-check

== wp-cli ==
  binary:            /usr/local/bin/wp
  resolved:          /usr/local/share/wp-cli.phar
  install kind:      phar
  version:           2.10.0
  php:               8.2.14
  writable:          yes
  minimum:           2.8.0
  gate:              PASS 2.10.0 satisfies 2.8.0
  newest release:    2.11.0
  currency:          OUTDATED run: Bash_WP-CLI_Update.sh --wpcli-update
  self-update:       ok
```

**The update itself** (`--wpcli-update`) picks the right mechanism:

- *channel update* (default) — `wp cli update --yes` with
  `--stable/--nightly` and `--patch/--minor/--major` from `WP_CLI_UPDATE_SCOPE`
  (`auto` = newest within the current major, WP-CLI's own safe default);
- *pinned version* (`--wpcli-version 2.11.0`) or a non-phar install — a direct
  download of the release phar, **verified before it replaces anything**:
  GPG signature against the published WP-CLI release key (fingerprint checked,
  `63AF 7AA1 …BC06`), SHA-512 as a fallback, and the check **fails closed** —
  if verification was asked for and no method is available, nothing is
  installed;
- either way the phar is smoke-tested (`cli version` must run) before the swap,
  the swap is an atomic rename with the previous binary kept as
  `<name>.bak-<timestamp>` (plus WP-CLI's own `.old`), and
  **`--wpcli-rollback`** puts a previous binary back — listing every candidate,
  newest first.

These four modes need no site list, no root and no healthy WordPress: they are
exactly what you reach for on a host that is already in trouble.

---

## Configuration

One table in the source (`CONFIG_SPEC`) defines every setting; it drives the
defaults, the config-file whitelist, the environment layer, validation,
`--print-config`, `--init-config` and the docs, so they cannot disagree.

- Files: `/etc/wp-cli-update.conf` → `<script dir>/wp-cli-update.conf` →
  `WP_CLI_UPDATE_<KEY>` environment → command line (highest).
- The file is **parsed as data, never sourced**. A shell metacharacter, an
  unknown key with a bad value, or a **group/world-writable file** rejects it
  with exit 4. Unknown keys warn with a "did you mean" suggestion.
- `--print-config` prints every effective value with the layer that produced it.
- Full annotated reference: [`wp-cli-update.conf.example`](wp-cli-update.conf.example)
  and [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md).

---

## Monitoring: state, metrics, notifications

```bash
Bash_WP-CLI_Update.sh --full \
    --state-file   /var/lib/wp-cli-update/state.json \
    --metrics-file /var/lib/wp-cli-update/prometheus/wpu.prom \
    --notify failure --webhook "$SLACK_WEBHOOK" --webhook-format slack
```

- **State file** — the complete run document (one JSON object: counters,
  per-site status, durations, versions), written atomically after every run,
  *including an interrupted one*, so a dashboard never shows yesterday's numbers.
- **Metrics file** — Prometheus textfile-collector format: `wpu_up`,
  `wpu_exit_code`, `wpu_sites_*`, `wpu_ops_*`, `wpu_findings*`,
  `wpu_unit_status{path=…}`, `wpu_unit_elapsed_seconds{…}`, …
- **Notifications** — `never|failure|always`; a generic JSON POST or a
  Slack/Discord/Telegram-shaped one; and/or a `NOTIFY_COMMAND` executable that
  receives the summary in argv *and* in `WPU_*` environment variables. It is
  never passed through a shell. A failing notification warns; it never fails
  the run — paging somebody because the pager is down would hide the real event.
- **JSON Lines** (`--json-lines`) — one object per site as it lands plus a
  final summary object; a killed run still leaves a parseable prefix.

See [`docs/OPERATIONS.md`](docs/OPERATIONS.md) for cron/systemd/logrotate
units and alerting recipes.

---

## Backups and restore

- `--backup db` (seconds) or `full` (complete, big — the tree size is reported
  before archiving). Off by default: a silent dump per site per run fills disks
  nobody monitors.
- **A failed backup skips its site** rather than updating it unprotected
  (unless `--fail-on never`), and `--min-free-space` refuses to dump onto a
  full volume. Dumps are checked for the `Dump completed` marker.
- Per-site directories are chowned to the site user with mode 0750 when
  running as root; dumps are 0640.
- Deleting a plugin always archives it first (unless `--no-backup` was explicit).
- `--restore -S /path [--from N|file] [--restore-files] --yes` lists and
  restores; a pre-restore dump is taken unless you forbid it, and a file that
  does not look like a SQL dump is refused. Automatic rollback after a failed
  update is deliberately **not** offered — restoring a database whose core
  files were already replaced creates a state that never existed.

---

## Scheduling

```cron
# /etc/cron.d/wp-cli-update
15 3 * * 2   root  /opt/wp-cli-update/Bash_WP-CLI_Update.sh --report --state-file /var/lib/wp-cli-update/state.json >/dev/null
30 3 * * *   root  /opt/wp-cli-update/Bash_WP-CLI_Update.sh --full -j 4 --backup db --keep-backups 2 --smoke-test --notify failure --webhook https://hooks.example/xyz >/dev/null
0  6 * * 1   root  /opt/wp-cli-update/Bash_WP-CLI_Update.sh --security --strict --notify failure >/dev/null
```

Ready-made systemd service+timer units, a logrotate snippet and alerting
recipes: [`docs/ops/`](docs/ops/) and [`docs/OPERATIONS.md`](docs/OPERATIONS.md).

---

## Security model

The short version — the long one is [`docs/SECURITY.md`](docs/SECURITY.md):

- **No command is ever built by string concatenation.** Every WP-CLI call is a
  bash array that becomes argv; the user switch passes arguments as positional
  parameters, so a site path containing quotes, spaces or `;` cannot inject
  anything. `printf %q` is banned where `/bin/sh` parses the result.
- **Secrets never touch this process's argv** — the Astra licence travels over
  **stdin** (default) or a short-lived file, is redacted from every log, report,
  error box and state file, and `tools/scan-secrets.sh` keeps the repository
  itself clean (CI-enforced).
- **Configuration is data.** Parsed KEY=VALUE against a whitelist; never
  sourced; group/world-writable files are refused (the manager runs as root).
- **Privileges:** each site runs as its owner (`runuser` → `sudo -n` → `su`);
  `--allow-root` only when actually root; an unprivileged run is allowed only
  when the caller owns every site.
- **Destructive work is opt-in and evidenced:** backups before change, `--yes`
  for deletions, enumerated-and-validated integer ids before any
  `post/comment delete`, and a dry-run that prints the real argv.
- `umask 077`, a predictable `PATH` (cron-proof), `LC_ALL=C`, per-command
  timeouts, a run lock, and stdin closed for every `wp` call (nothing can hang
  on a prompt nobody will answer).

---

## Development: sources, build, tests

The artifacts at the repository root are **generated**. The sources are the
modules in `src/manager/` and `src/finder/`, concatenated in numeric order by
`tools/build.sh` — a build that creates no processes at all (no `cat`, `sed`,
`mktemp`, not even a subshell), so it runs even on a host that is out of
resources. `tools/build.sh --check` proves the committed artifacts match the
sources; CI enforces it.

```bash
make build      # rebuild both artifacts from src/
make lint       # shellcheck (artifacts, tools, tests)
make test       # the whole suite: no root, no WordPress, no WP-CLI, no network
make check      # build --check + tests (what CI runs)
make install    # install to PREFIX (default /opt/wp-cli-update) + completion
```

The test bench drives a **stub `wp`** that records its own argv over a synthetic
site tree, so every assertion is about the real command line the product built.
Nine suites: static checks (syntax, lint, CRLF, versions, artifact drift), pure
logic (validators, JSON readers, version comparison, the read-only
classification behind `--dry-run`), CLI contract, configuration layers and the
licence, mode behaviour and ordering, fleet features (parallel counters,
filters, budgets, state/metrics/notifications, locking, multisite), the WP-CLI
version policy and self-update, the finder, and the secret guard.

```bash
bash tests/run_tests.sh            # everything (~500 checks)
bash tests/run_tests.sh manager    # one suite
VERBOSE=1 bash tests/run_tests.sh  # keep the fixtures for inspection
```

---

## Documentation map

| Document | Contents |
|---|---|
| [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) | every setting: type, default, layer, flag |
| [`docs/OPERATIONS.md`](docs/OPERATIONS.md) | cron, systemd timers, logrotate, Prometheus, alerting, runbooks |
| [`docs/SECURITY.md`](docs/SECURITY.md) | threat model and the mechanism behind each guarantee |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | module map, data flow, the fork discipline, design rules |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | symptoms → causes → fixes |
| [`docs/MIGRATION.md`](docs/MIGRATION.md) | upgrading from 6.x: what changed and what to check |
| [`CHANGELOG.md`](CHANGELOG.md) | the full 7.0.0 story |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | how to add a mode, a setting, a test |

---

## Troubleshooting

The full table lives in [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).
The three that cover most of it:

1. **Read `--check` first.** It validates the host, the WP-CLI version policy,
   the config layers and every site — and changes nothing.
2. **`--dry-run` prints the real argv** of everything it would execute, so
   "what will it do to *this* site" is always one command away.
3. **The error log holds the full text** of every failed command
   (`ERROR_LOG_FILE`); the console box is the pointer, not the payload.

---

## License

MIT — see [LICENSE](LICENSE).

Credits: this project is the merged, audited outcome of several independent
revision lines (QWEN Hybrid, DeepSeek Hybrid, AutoClaw GLM/RAGRAF, SagaAI);
`docs/MIGRATION.md` and `CHANGELOG.md` record what was taken from where and why.

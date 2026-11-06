# Configuration

The configuration file is data: parsed as `KEY=VALUE`, never sourced, and a line the parser
does not like rejects the whole file rather than one setting.

## Precedence

```text
built-in defaults  <  /etc/wp-cli-update.conf  <  <script dir>/wp-cli-update.conf
                   <  WP_CLI_UPDATE_<KEY> environment  <  command line
```

A file or environment value is validated before the merge (exit 4), a command-line value
after it (exit 2), so the exit code names the file to open. `--config FILE` reads one file
instead of the two defaults; `--print-config` prints every value with the layer that set it.

## Rules that matter

* **Never sourced.** A backtick, `$(`, `|`, `;`, `&`, `<` or `>` anywhere in a line rejects
  the whole file (exit 4). Do not template it with `envsubst` where a run can read it.
* **Permissions.** `chmod 600`, owned by root; a group- or world-writable file is refused
  before it is read, because it can carry a licence.
* **Environment overrides** use `WP_CLI_UPDATE_<KEY>`, for example `WP_CLI_UPDATE_JOBS=8`.
* **Legacy 6.1 names** work and are reported once: `WP_TIMEOUT`, `WP_CLI_BIN`, `SITE_URL`,
  `BACKUP_KEEP`, `DEFAULT_JOBS` (`TIMEOUT`, `WP_CLI_PATH`, `URL`, `KEEP_BACKUPS`, `JOBS`).
* **`AUTO_DISCOVER=0`** on a production host: an automatic scan costs I/O and can pick up a
  site that was not meant to be touched.
* A mode-restricted key (`SKIP_IF_NO_UPDATES`, `HOLD_PLUGINS`, `EXCLUDE_THEMES`) in a file is
  inert for modes that do not use it; typed on the command line with the wrong mode it is a
  usage error (exit 2).

## Paths and executables

| Key | Default | Meaning |
|---|---|---|
| `WP_CLI_PATH` | `/usr/local/bin/wp` | the `wp` binary; if set it must be executable, there is no silent fallback |
| `SITES_FILE`, `DISCOVER_SCRIPT` | `<script dir>/wp-found.txt`, `<script dir>/Find_WP_Senior.sh` | site list and finder |
| `AUTO_DISCOVER`, `MAX_SITES` | `1`, `0` | run the finder when the list is missing; cap per run |
| `ALLOW_ROOT` | `auto` | `auto` / `always` / `never`: when to pass `--allow-root` |
| `DEFAULT_USER`, `NO_USER_SWITCH`, `USER_ENV` | empty, `0`, empty | fallback account; run as the invoking user; variables passed to the child |
| `WP_GLOBAL_ARGS`, `URL`, `URL_DETECT` | empty, empty, `1` | extra flags for `wp`; forced `--url`; derive it from `WP_HOME`/`WP_SITEURL` |

## Logging

| Key | Default | Meaning |
|---|---|---|
| `LOG_FILE`, `ERROR_LOG_FILE` | `<script dir>/*.log` | the two logs |
| `LOG_MAX_BYTES`, `LOG_KEEP` | `5242880`, `3` | rotate past the size, keep N generations (0 disables) |
| `LOG_LEVEL`, `LOG_JSON` | `info`, `0` | `debug` / `info` / `warn` / `error`; one JSON object per line |
| `ERROR_OUTPUT_LINES`, `COLOR` | `20`, `auto` | failing-command lines kept; `auto` needs a terminal and no `NO_COLOR` |

## Locking and execution

| Key | Default | Meaning |
|---|---|---|
| `LOCK_FILE`, `LOCK_WAIT` | `<script dir>/.wp-cli-update.lock`, `0` | prevent two runs on the same sites |
| `TIMEOUT`, `TIMEOUT_SIGNAL`, `KILL_AFTER` | `0`, `TERM`, `30` | per-command bound and its escalation |
| `JOBS` | `1` | sites per batch |
| `NICE_LEVEL`, `IONICE_CLASS` | `10`, `none` | do not starve the web server |
| `RUN_TIMEOUT` | `0` | total budget, checked before each site |
| `RETRY`, `RETRY_DELAY` | `0`, `15` | retry a failed site and how long to wait |
| `MAX_FAILURES`, `FAIL_ON` | `0`, `any` | circuit breaker threshold; `any` / `all` / `never`: when the run exits non-zero |
| `DRY_RUN`, `STRICT` | `0`, `0` | make dry-run the default; a warning makes the run a failure |

## Backups

| Key | Default | Meaning |
|---|---|---|
| `BACKUP`, `BACKUP_DIR` | `off`, `<script dir>/backups` | `off` / `db` / `full`, and where the files go |
| `KEEP_BACKUPS`, `BACKUP_AGE_DAYS` | `3`, `0` | keep N per site (0 = all); also drop older than N days |
| `BACKUP_COMPRESS`, `MIN_FREE_MB` | `0`, `0` | gzip a dump after export; refuse to dump below N MiB free |

## Policy

| Key | Default | Meaning |
|---|---|---|
| `ONLY_ACTIVE`, `SKIP_IF_NO_UPDATES` | `0`, `0` | only active plugins with updates; ask before acting |
| `EXCLUDE_PLUGINS`, `EXCLUDE_THEMES` | empty | leave out of `--plugins` / `--themes` / `--full` |
| `HOLD_PLUGINS`, `HOLD_THEMES` | empty | pinned: never updated, always logged |
| `SKIP_PLUGINS`, `SKIP_PLUGINS_FOR_LISTING` | empty, `0` | `--skip-plugins` value; whether listings get it too |
| `ASTRA_SLUG`, `LICENCE` | `astra-addon`, empty | the add-on slug; the licence, better kept in `WP_CLI_UPDATE_LICENCE` |

## Security (CVE-2026-119977)

| Key | Default | Meaning |
|---|---|---|
| `HARDEN_UPGRADE_DIR` | `0` | boolean. Before a writing mode updates a site, append the marker-guarded deny block for `wp-content/upgrade/` to its root `.htaccess` (Apache and LiteSpeed); the same block `--harden` writes, applied automatically. An existing `.htaccess` is copied once to `.htaccess.wp-cli-update.bak` first, and the block is written once per site. `--harden-upgrade-dir` sets it for one run, `--no-harden-upgrade-dir` clears it for one run |

The block is not a substitute for updating: a site below the fixed release stays exposed
until WordPress core is updated. nginx never reads `.htaccess`, so an nginx host needs the
directive below in each server block, in addition to the key or instead of it:

```nginx
location ^~ /wp-content/upgrade/ { deny all; }
```

`--security`, `--health` and `--check` are read-only and ignore the key. The flag on the
command line with one of those modes is a usage error (exit 2), because the run is not
allowed to modify a site. The advisory and the runbook are on
[Security: CVE-2026-119977](09-Security-CVE-2026-119977).

## Reporting and notifications

| Key | Default | Meaning |
|---|---|---|
| `REPORT_FILE` | empty | one JSON document per run, written atomically |
| `NOTIFY_WEBHOOK`, `NOTIFY_ON`, `NOTIFY_TIMEOUT` | empty, `failure`, `10` | POST a summary on `never` / `failure` / `always` |
| `MAIL_TO` | empty | mail the same payload through `mail(1)` |

The payload carries counters only: no site content, no licence, no paths.

## Recommended production profile

```ini
# /etc/wp-cli-update.conf
WP_CLI_PATH=/usr/local/bin/wp
SITES_FILE=/var/lib/wp-cli-update/wp-found.txt
LOG_FILE=/var/log/wp-cli-update/manager.log
ERROR_LOG_FILE=/var/log/wp-cli-update/errors.log
BACKUP_DIR=/var/backups/wp-cli-update
AUTO_DISCOVER=0
JOBS=4
BACKUP=db
KEEP_BACKUPS=5
BACKUP_AGE_DAYS=14
BACKUP_COMPRESS=1
MIN_FREE_MB=500
NICE_LEVEL=10
IONICE_CLASS=idle
TIMEOUT=600
RETRY=2
RETRY_DELAY=30
MAX_FAILURES=5
SKIP_IF_NO_UPDATES=1
FAIL_ON=any
HARDEN_UPGRADE_DIR=1
REPORT_FILE=/var/log/wp-cli-update/last-run.json
LOG_JSON=1
```

`HARDEN_UPGRADE_DIR=1` closes `wp-content/upgrade/` on Apache and LiteSpeed before each
site is updated. On an nginx host add the `location` line above to every server block as
well; the key cannot do it for you.

Without these paths the defaults point at the script directory, and a scheduled run looks
for a site list that is not there (exit 3). See [Operations](05-Operations) for the schedule
and [Exit codes](06-Exit-Codes) for the contract. The annotated reference for every key,
including the 8.1.0 security key, is
[wp-cli-update.conf.example](https://github.com/paulmann/Bash_WP-CLI_Update/blob/main/wp-cli-update.conf.example).

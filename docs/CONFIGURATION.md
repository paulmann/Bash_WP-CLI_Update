# Configuration reference

Every setting of `Bash_WP-CLI_Update.sh` 7.0.0, generated from the same
`CONFIG_SPEC` table in `src/manager/01-bootstrap.sh` that drives the defaults,
the config-file whitelist, validation, `--print-config` and `--init-config`.
If this document and `--init-config` disagree, `--init-config` is right and
this file has drifted — please report it.

**Layers** (lowest to highest): built-in defaults → `/etc/wp-cli-update.conf` →
`<script dir>/wp-cli-update.conf` → `WP_CLI_UPDATE_<KEY>` environment →
command line. Every key below can be set in any file layer and as
`WP_CLI_UPDATE_<KEY>`; the flag column lists the command-line spelling where
one exists.

**File format.** Plain `KEY=VALUE` lines, `#` comments, one optional pair of
matching quotes around the value. The file is parsed, never sourced: a line
containing a backtick, `$(`, `${`, `|`, `;`, `&`, `<` or `>` rejects the whole
file (exit 4), as does a group- or world-writable file (the manager runs as
root). Booleans accept `1/0`, `true/false`, `yes/no`, `on/off` in any case and
normalise to `true`/`false`. `@SCRIPT_DIR@` below means the directory the
script lives in (symlinks resolved).

**Types.** `uint` non-negative integer · `pint` positive integer · `sec`
seconds · `mib` mebibytes · `bool` · `choice:…` · `str` any string · `apath`
absolute path or empty · `exec` absolute path to an executable or empty ·
`url` http(s) or empty · `csv` comma-separated · `words` space-separated ·
`globs` comma-separated path patterns (bash globs, never regexes, never code).

## Executables and WP-CLI policy

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `WP_CLI_PATH` | str | `/usr/local/bin/wp` | `--wp` | wp binary. A configured path must exist — no silent fallback to PATH. |
| `PHP_BIN` | str | `php` | `--php` | php used to smoke-test a phar before installing it |
| `WP_CLI_MIN_VERSION` | str | `2.8.0` | `--wpcli-min-version` | floor; below it every fleet run exits 3 |
| `WP_CLI_LATEST_CHECK` | bool | `false` | `--wpcli-latest-check` | compare with the newest upstream release at startup (warn only) |
| `WP_CLI_RELEASE_API` | url | GitHub releases API | — | fallback endpoint when `wp cli check-update` cannot answer |
| `WP_CLI_UPDATE_CHANNEL` | choice:stable,nightly | `stable` | `--wpcli-channel` | channel for `--wpcli-update` |
| `WP_CLI_UPDATE_SCOPE` | choice:auto,patch,minor,major | `auto` | `--wpcli-scope` | how far an update may go (`auto` = newest within this major) |
| `WP_CLI_TARGET_VERSION` | str | *(empty)* | `--wpcli-version` | pin one version; installed by verified direct download |
| `WP_CLI_VERIFY_PHAR` | bool | `true` | `--wpcli-no-verify` (inverts) | GPG/SHA-512 verification of downloads; **fails closed** |
| `WP_CLI_GPG_KEY_URL` | url | wp-cli builds repo | — | the published release signing key |
| `WP_CLI_GPG_FINGERPRINT` | str | `63AF…BC06` | — | expected fingerprint; a mismatch refuses the install |
| `WP_CLI_BACKUP_DIR` | apath | *(next to binary)* | — | where replaced wp binaries are kept for rollback |
| `WP_CLI_UPDATE_YES` | bool | `false` | `--yes` | update WP-CLI without asking |
| `WP_CLI_INSECURE` | bool | `false` | `--wpcli-insecure` | let the updater retry without TLS verification (don't) |
| `HTTP_CLIENT` | choice:auto,curl,wget | `auto` | — | used for release checks, smoke tests, webhooks, downloads |
| `USE_JQ` | choice:auto,yes,no | `auto` | — | jq accelerates JSON parsing; the built-in reader is the fallback and stays tested |

## Site inventory

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `SITES_FILE` | str | `@SCRIPT_DIR@/wp-found.txt` | `--sites` (`-` = stdin) | one absolute path per line; a TAB-separated second column forces the owner |
| `DISCOVER_SCRIPT` | str | `@SCRIPT_DIR@/Find_WP_Senior.sh` | — | run when the list is *missing* (never when it is empty) |
| `DISCOVER_ROOTS` | words | *(empty)* | — | web roots passed to the discovery script |
| `AUTO_DISCOVER` | bool | `true` | `--no-discover` (inverts) | discover when the list is missing |
| `MAX_SITES` | uint | `0` | `--max-sites` | cap per run, 0 = all |
| `SITE_USER` | str | *(empty)* | `--user` | force one system user for every site |
| `INCLUDE_SITES` | globs | *(empty)* | `--include` (repeatable) | only process matching paths |
| `EXCLUDE_SITES` | globs | *(empty)* | `--exclude` (repeatable) | never process matching paths (wins over include) |
| `MULTISITE` | choice:auto,off,main,all | `auto` | `--multisite` | `all` = one work unit per subsite, each with `--url` |
| `NO_USER_SWITCH` | bool | `false` | `--no-user-switch` | run wp as the invoking user |
| `URL` | str | *(empty)* | `--url`, `-U` | `--url` on every call |

## Logging

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `LOG_FILE` | str | `@SCRIPT_DIR@/wp_cli_manager.log` | `--log-file` | empty disables file logging |
| `ERROR_LOG_FILE` | str | `@SCRIPT_DIR@/wp_cli_errors.log` | `--error-log-file` | full text of every failed command |
| `LOG_MAX_BYTES` | uint | `5242880` | — | rotate above this size, 0 disables |
| `LOG_KEEP` | uint | `3` | — | rotated generations kept |
| `LOG_LEVEL` | choice:debug,info,warn,error | `info` | `--log-level`, `-D` | console and file level |
| `LOG_FORMAT` | choice:text,json | `text` | `--log-format` | `json` = one JSON object per line |
| `SYSLOG` | bool | `false` | `--syslog` | mirror lines to syslog via `logger(1)` |
| `ERROR_OUTPUT_LINES` | pint | `20` | — | lines of a failing command shown/stored |
| `COLOR` | choice:auto,always,never | `auto` | `--color`, `--no-color` | `auto` respects `NO_COLOR`, `TERM=dumb`, non-tty |

## Locking

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `LOCK_FILE` | str | `@SCRIPT_DIR@/.wp-cli-update.lock` | `--lock-file` | flock when available, pid file otherwise |
| `LOCK_TIMEOUT` | uint | `0` | `--lock-timeout` | wait this long for a held lock, 0 = fail now (exit 3) |
| `LOCK_REQUIRED` | bool | `false` | `--lock-required` | refuse to run when the lock cannot be taken at all |
| — | | | `--no-lock` | skip locking (nested/manual runs only) |

## Execution policy

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `TIMEOUT` | sec | `0` | `--timeout` | per-command bound; `timeout(1)` or the perl supervisor |
| `KILL_AFTER` | pint | `30` | `--kill-after` | escalate to SIGKILL after the signal |
| `TIMEOUT_SIGNAL` | choice:HUP,INT,QUIT,TERM,USR1,USR2,KILL | `TERM` | `--signal` | first signal on timeout |
| `ALLOW_ROOT` | choice:auto,always,never | `auto` | `--allow-root` | when to pass `--allow-root` to wp |
| `FAIL_ON` | choice:any,all,never | `any` | `--fail-on` | the 0/1 boundary of a run |
| `STRICT` | bool | `false` | `--strict` | warnings (and audit criticals) fail the run |
| `FAIL_FAST` | bool | `false` | `--fail-fast` | stop the fleet after the first failing site (exit 6) |
| `RETRY` | uint | `0` | `--retry` | re-attempt a failing site N times |
| `STAGGER` | sec | `0` | `--stagger` | sleep between sites (sequential runs) |
| `MAX_DURATION` | sec | `0` | `--max-duration` | whole-run budget; stop between sites, exit 6 |
| `MIN_FREE_MIB` | mib | `0` | `--min-free-space` | refuse a backup below this free space |
| `OUTPUT_FORMAT` | choice:table,json,csv,tsv | `table` | `--format`, `-J` | rendering of tabular results |
| `MAINTENANCE_MODE` | bool | `false` | `--maintenance-mode` | WordPress maintenance mode around each update (probed) |
| `JOBS` | pint | `1` | `--jobs`, `-j` | parallel batch size |

## Plugin/theme selection

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `SKIP_PLUGINS` | csv | *(empty)* | `--skip-plugins` | wp `--skip-plugins` on mutating plugin/theme ops |
| `SKIP_PLUGINS_FOR_LISTING` | bool | `false` | `--skip-plugins-for-listing` | also skip on listings (hides what you list — off) |
| `EXCLUDE_PLUGINS` | csv | *(empty)* | `-e`, `--exclude-plugins` | slugs/names left out of `--plugins`/`--full`; implies enumeration |
| `ONLY_ACTIVE` | bool | `false` | `--only-active` | update only active plugins that have an update |

## Astra Pro

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `ASTRA_SLUG` | str | `astra-addon` | `--astra-slug` | add-on slug |
| `LICENCE` | str | *(empty)* | `--astra-key` | prefer env `WP_CLI_UPDATE_LICENCE` (aliases `ASTRA_KEY`, `ASTRA_LICENSE_KEY`) or a key file: `./astra.key`, `/etc/wp-cli-update/astra.key`, `~/.astra.key`, `~/.config/astra.key` |
| `LICENCE_HANDOFF` | choice:stdin,file | `stdin` | — | how the value reaches the child; stdin never touches disk |

## Backups and restore

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `BACKUP` | choice:off,db,full | `off` | `-b`, `--backup`, `--no-backup` | before a site is touched; a failed backup skips the site |
| `BACKUP_DIR` | str | `@SCRIPT_DIR@/backups` | `-B`, `--backup-dir` | one subdirectory per site |
| `KEEP_BACKUPS` | uint | `3` | `--keep-backups` | per site and kind, 0 = keep all |
| `BACKUP_BEFORE_RESTORE` | bool | `true` | — | dump before `--restore` overwrites the database |

## `--full` composition, cache and cleanup

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `FULL_DB_REPAIR` | bool | `false` | — | add `db repair` to `--full` (it locks tables; default off) |
| `FULL_CACHE` | bool | `true` | — | flush caches/rewrites at the end of `--full` |
| `FULL_LANGUAGES` | bool | `true` | — | translation updates inside `--full` |
| `CACHE_TRANSIENTS` | choice:expired,all,none | `expired` | — | transients removed by `--cache`/`--full` |
| `CACHE_REWRITE_FLUSH` | bool | `true` | — | `rewrite flush` in `--cache`/`--full` |
| `CACHE_EXTRA` | words | *(empty)* | — | extra wp subcommands for `--cache`, e.g. `litespeed-purge-all` |
| `CLEANUP_REVISIONS_KEEP` | uint | `50` | — | revisions kept **per post**, 0 = delete all |
| `CLEANUP_TRASH` | bool | `false` | — | empty the trash |
| `CLEANUP_SPAM` | bool | `true` | — | delete spam and trashed comments |
| `CLEANUP_AUTODRAFT` | bool | `false` | — | delete auto-drafts |
| `CLEANUP_TRANSIENTS` | choice:expired,all,none | `expired` | — | transients removed by `--cleanup` |
| `CLEANUP_OPTIMIZE` | bool | `true` | — | `db optimize` after a cleanup that removed rows |

## Security audit

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `SECURITY_MIN_WP` | str | *(empty)* | — | critical below this WordPress version |
| `SECURITY_UPLOADS_SCAN` | bool | `true` | — | PHP files and dumps inside uploads |
| `SECURITY_WORLD_WRITABLE` | bool | `true` | — | world-writable PHP under wp-content |
| `SECURITY_SECRETS` | bool | `true` | — | run `tools/scan-secrets.sh` over wp-config.php |
| `SECURITY_MAX_ADMINS` | uint | `0` | — | warn above N administrators, 0 disables |

## Health report

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `REPORT_DB_SIZE` | bool | `true` | — | DB size via information_schema (fallback `db size`) |
| `REPORT_UPLOADS_SIZE` | bool | `false` | — | uploads size (walks the tree — slow on big media) |
| `REPORT_CRON_TEST` | bool | `true` | — | `wp cron test` reachability column |

## Smoke test

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `SMOKE_TEST` | bool | `false` | `--smoke-test` | fetch the site URL after a change |
| `SMOKE_TIMEOUT` | pint | `15` | `--smoke-timeout` | seconds per request |
| `SMOKE_EXPECT` | csv | `200,301,302,303,307,308` | `--smoke-expect` | accepted status codes |
| `SMOKE_SSL_VERIFY` | bool | `true` | — | verify TLS (off for self-signed internal URLs) |
| `SMOKE_ON_FAIL` | choice:fail,warn | `fail` | — | fail the site or just warn |

## Reporting and notification

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `STATE_FILE` | str | *(empty)* | `--state-file` | atomic JSON run document after every run |
| `METRICS_FILE` | str | *(empty)* | `--metrics-file` | Prometheus textfile metrics |
| `NOTIFY_ON` | choice:never,failure,always | `never` | `--notify` | when to notify |
| `NOTIFY_WEBHOOK_URL` | url | *(empty)* | `--webhook` | JSON POST target |
| `NOTIFY_WEBHOOK_FORMAT` | choice:generic,slack,discord,telegram | `generic` | `--webhook-format` | payload shape |
| `NOTIFY_COMMAND` | exec | *(empty)* | `--notify-command` | argv + `WPU_*` env; never through a shell |

## Environment hand-off

| Key | Type | Default | Flag | Meaning |
|---|---|---|---|---|
| `USER_ENV` | words | *(empty)* | `--user-env` | variable **names** passed into the site owner's environment; values come only from the manager's own environment |

## Validation and exit codes

Values from a file or the environment are validated before the run starts: a
bad file value exits **4**, a bad environment value exits **3**, a bad flag
exits **2** — the same rule, three doors, and the message names the rule in
every case. `--print-config` shows the effective value, its type and the
winning layer for all 96 settings.

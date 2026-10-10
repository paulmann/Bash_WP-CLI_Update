# Troubleshooting

Symptom → cause → fix. Start with `--check` (host + config + every site,
changes nothing) and `--version-detail` (capability probes: flock, timeout,
perl, jq, HTTP client, gpg, logger). The error log (`ERROR_LOG_FILE`) holds the
full text of every failed command; the console box is a pointer, not the
payload.

## Startup and environment

| Symptom | Cause | Fix |
|---|---|---|
| `this script requires bash, but another shell started it` | invoked via `sh script.sh` | `bash script.sh` or `./script.sh` (shebang) |
| `requires bash 4.2 or newer` | ancient bash (CentOS 6, macOS system bash) | install bash ≥ 4.2; the scripts refuse rather than misbehave |
| exit 3 `WP-CLI not found` | no wp at `WP_CLI_PATH`/PATH | `--wpcli-install`, or set `WP_CLI_PATH` |
| exit 3 `WP-CLI X is older than the required minimum Y` | version floor | `--wpcli-update` (or `--wpcli-version` to pin); lower `WP_CLI_MIN_VERSION` only if you know why |
| `configured wp-cli is not an executable file` | typo in `WP_CLI_PATH` | a configured path is honoured literally — no silent PATH fallback |
| exit 3 `must run as root` / `needs to switch into a site owner` | unprivileged run where owners differ | `sudo`, or `--user NAME`, or `--no-user-switch` when you own everything |
| `another … run holds …; refusing to run concurrently` | overlapping schedules | `LOCK_TIMEOUT=600` to wait; investigate the holder's pid; `--no-lock` only manually |
| `flock(1) not found; using a pid file` | minimal image | install util-linux; the pid-file fallback does not survive a crash mid-run |
| `--timeout N cannot be enforced` | no `timeout(1)` and no `perl` | install either; until then a hung wp blocks the run and the tool says so at startup |

## Configuration

| Symptom | Cause | Fix |
|---|---|---|
| exit 4 `shell metacharacter in a config line` | `;`, `|`, `$(`, backtick, `<`, `>`, `&` in the file | the file is data; put the value elsewhere (env) or fix the line |
| exit 4 `refusing to read a group- or world-writable config file` | mode 0620/0660/0664/0666 | `chmod 0600` — the manager runs as root |
| `unknown setting 'X', ignored; did you mean Y?` | typo | fix the key; unknown keys never apply silently |
| a flag seems ignored | a higher layer won | `--print-config` shows the effective value and its layer |
| exit 4 `must be an absolute path` | relative `LOG_FILE`/`STATE_FILE`/… | use absolute paths (relative to *what*, under cron?) |
| environment value rejected with exit 3 | `WP_CLI_UPDATE_*` invalid | the message names the rule; env is a config layer, validated like one |

## Site list and discovery

| Symptom | Cause | Fix |
|---|---|---|
| `site list … exists but is empty; not running discovery` | deliberate empty list | put paths in it; discovery never runs over an *existing* list |
| exit 5, `no work unit to process` | filters/skips emptied the fleet | `--list-sites` shows what survived and the warnings say what did not |
| `skipping, not a WordPress root` | entry has no wp-config/wp-load/version.php | fix the list; `Find_WP_Senior.sh --verify-list` audits the whole file |
| `cannot determine the site owner` | odd ownership, nologin owner | `chown` the site, add a TAB owner column, or `--user NAME` |
| a site silently missing from discovery | `.no_wp_cli` marker, exclude pattern, depth | `Find_WP_Senior.sh --verbose` explains every skip; `--depth`/`--min-depth` |
| discovery found nothing, exit 5 | wrong roots | pass roots explicitly; defaults are conventional, never `/` |

## Updates and operations

| Symptom | Cause | Fix |
|---|---|---|
| `wp timed out after Ns` | slow DB/API, hung plugin | raise `--timeout`; the command was killed (SIGKILL after `KILL_AFTER`), check the site |
| site failed: `wp core update failed … (exit 255)` | PHP fatal, memory limit, maintenance file left behind | full text in `ERROR_LOG_FILE`; remove stale `.maintenance*`; fix PHP |
| `plugin update --all` updated a plugin you excluded | exclusion not configured | `-e slug`/`EXCLUDE_PLUGINS`; verify with `--dry-run` (enumeration runs for real) |
| revisions not deleted by `--cleanup` | keep-limit or no `--yes` | `CLEANUP_REVISIONS_KEEP`, `--yes`; without it the mode only reports counts |
| `--cleanup` did nothing in cron | non-interactive safety | `--yes` is required when stdin is not a terminal — by design |
| Astra licence `activation did not succeed` | expired/invalid key | key file 0600 next to the script or `WP_CLI_UPDATE_LICENCE`; the value never shows in logs (redacted), length does |
| `no Astra licence configured` in `--full` | normal on non-Astra hosts | `--full` skips the Astra step without a licence; only `--astra` requires one |
| maintenance mode stuck after a crash | process killed mid-run | `wp maintenance-mode deactivate --path=/path/to/site` |
| backup failed → `skipping the site rather than updating it unprotected` | disk full, permissions, `MIN_FREE_MIB` | fix the volume; `--status` shows backup inventory + free space |
| `only N MiB free … MIN_FREE_MIB asks for M` | space guard fired | free space or lower the guard; a truncated dump is worse than no dump |

## Reporting and monitoring

| Symptom | Cause | Fix |
|---|---|---|
| log lines in my redirected report | pre-7.0 habit | since 7.0 prose is always stderr: `--report > r.tsv` just works |
| state file shows an old run | the run crashed before writing? | it is written even after interrupts — check `--status`; a missing file means the process was SIGKILLed |
| webhook not delivered | no curl/wget, wrong URL, proxy | the run warns once (`no HTTP client`); test with `--notify always` |
| metrics absent in Prometheus | textfile collector path | point `--collector.textfile.directory` at `METRICS_FILE`'s directory |
| `wpu_unit_status` empty | no `--metrics-file` | metrics are opt-in per run |
| smoke test fails but the site works | redirect/CDN status not expected | widen `SMOKE_EXPECT`, or `SMOKE_SSL_VERIFY=0` for internal self-signed, or `SMOKE_ON_FAIL=warn` |

## WP-CLI self-update

| Symptom | Cause | Fix |
|---|---|---|
| `'wp cli update' only supports a phar` | distro/composer install | `--wpcli-update` falls back to a verified direct download, or `--wpcli-install` to a path you choose |
| `refusing to install an unverified phar` | no gpg and no sha512 tooling | install `gnupg` or coreutils; or `--wpcli-no-verify` (documented risk) |
| `the imported key has fingerprint …` | key server served something else | do not proceed; compare with the published fingerprint on wp-cli.org |
| download fails | no outbound HTTPS / proxy | set `https_proxy` in the environment (it is honoured by curl/wget); `GITHUB_TOKEN` lifts API rate limits |
| update succeeded but wp is broken | extremely rare | `--wpcli-rollback` (lists `.old` and `.bak-*`, smoke-tests, reinstalls) |

## Parallel runs

| Symptom | Cause | Fix |
|---|---|---|
| `tail -f` looks stalled during `-j N` | batch barrier: output replays at the barrier | by design; interleave-free logs beat live ones |
| a worker `produced no result; counting it as failed` | OOM-killer / SIGKILL / full disk | `dmesg`, disk space; lower `-j` |
| counters differ between `-j 1` and `-j 4` | (fixed in 7.0 — workers zero and fold) | if you see this on 7.x, it is a bug: report with `--json-lines` output |

## Getting help

Include in a bug report: `--version-detail` output, the failing command with
`--dry-run -v`, the matching `ERROR DETAIL` block from the error log, and
`bash --version` + distro. Redaction is automatic — the logs are safe to paste
(licence values are masked), but do check for site-identifying paths.

# Bash WP-CLI Update

WordPress maintenance automation for a fleet of installations, in two standalone
Bash scripts and nothing else. No PHP dependency, no Composer, no daemon, no
agent: `Bash_WP-CLI_Update.sh` runs WP-CLI operations over every site in a list,
each one as the system user that owns it, and `Find_WP_Senior.sh` builds that
list by scanning web roots.

| Component | Version | Purpose |
|---|---|---|
| `Bash_WP-CLI_Update.sh` | **6.2.0** | Run maintenance operations over a site list |
| `Find_WP_Senior.sh` | **2.1.0** | Discover WordPress installations and write the site list |
| `tools/scan-secrets.sh` | 1.1.0 | Look for credential literals in the repository |

Requirements: **bash 4.2+** (CentOS 7 / RHEL 7 or newer, Debian, Ubuntu), GNU
coreutils and findutils, [WP-CLI](https://wp-cli.org/), root (to switch into
site owners), and one of `runuser` / `sudo` / `su`. `flock` and `timeout` are
used when present and degrade with a warning when they are not.

---

## Quick start

```bash
# 1. put both scripts somewhere stable
sudo install -d /opt/wp-cli-update
sudo install -m 755 Bash_WP-CLI_Update.sh Find_WP_Senior.sh /opt/wp-cli-update/

# 2. configure (optional but recommended)
sudo cp wp-cli-update.conf.example /etc/wp-cli-update.conf
sudo chmod 600 /etc/wp-cli-update.conf
sudo "$EDITOR" /etc/wp-cli-update.conf

# 3. look before you leap -- this changes nothing
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --check
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --full --dry-run

# 4. discover the sites and run
sudo /opt/wp-cli-update/Find_WP_Senior.sh --output /var/lib/wp-cli-update/wp-found.txt /var/www
sudo /opt/wp-cli-update/Bash_WP-CLI_Update.sh --full
```

---

## What it does

### Modes

Exactly one mode per run. `--list-modes` prints them for shell completion.

| Mode | Short | WP-CLI operations |
|---|---|---|
| `--full` | `-f` | `core update`, `plugin update --all`, `theme update --all`, `core update-db --skip-plugins`, `db optimize`, `db repair`, `cron event run --due-now`, plus the Astra step when a licence is configured |
| `--core` | `-c` | `core update`, `core update-db --skip-plugins` |
| `--plugins` | `-p` | `plugin update --all` |
| `--themes` | `-t` | `theme update --all` |
| `--db-optimize` | `-d` | `db optimize`, `db repair` |
| `--db-fix` | `-x` | `db repair` |
| `--cron` | `-r` | `cron event run --due-now` |
| `--astra` | `-s` | `plugin update <slug>`, then `brainstormforce license activate` and a retry if that failed |
| `--list-plugins` | `-l` | `plugin list --format=json`, rendered as table / json / csv / tsv |
| `--plugin-manage` | `-m` | resolve `--name` to one slug, deactivate it, back it up, then `plugin delete` |
| `--verify` | | read-only `core verify-checksums` + `plugin verify-checksums --all` |
| `--check` | | validate the environment and every listed site, change nothing |
| `--status` | | print the recorded summary of the last run and the log sizes |
| `--list-sites` | | print the resolved site list with owners and exit |

A failing site never aborts the run: it is counted, reported, and the loop goes
on to the next site.

### Fleet-wide options

| Option | What it does |
|---|---|
| `-j, --jobs N` | process N sites in parallel batches (default 1 = sequential) |
| `-b, --backup db\|full` | `wp db export`, or a tar.gz of the whole tree, before the site is touched |
| `-B, --backup-dir DIR`, `--keep-backups N` | where backups go and how many generations survive |
| `--only-active` | update only plugins that are active **and** have an update available |
| `-e, --exclude-plugins LIST` | leave these slugs out of `--plugins` / `--full` |
| `-U, --url URL` | pass `--url` to WP-CLI on every call (multisite) |
| `-J, --json` / `--json-lines` | fleet report as JSON Lines: one object per site plus a summary |
| `--strict` | exit non-zero when anything was warned about, not only when something failed |
| `--no-user-switch` | run WP-CLI as the invoking user instead of switching into the site owner |

**Parallelism is a batch barrier, not a continuous pool.** Bash 4.2 has no
`wait -n`, so the next batch starts when the slowest site of the current one
finishes. Per-site console output and log lines are buffered and replayed in site
order at the barrier, so neither interleaves — which means `tail -f` on the log
looks stalled until the batch lands. That is deliberate: three sites writing into
one file at once is unreadable. Choose N from the slowest shared resource, which
is normally the database server, not the CPU; 4–8 is a sane range for one MySQL
instance on one host.

**Backups are off by default**, because a dump per site per run fills disks that
nobody monitors. `--backup db` costs seconds and covers everything these modes
change; `--backup full` is complete and can be tens of gigabytes, so the script
reports the tree size before archiving. A plugin deletion is the exception: it is
always archived first unless `--no-backup` was given explicitly, and the operator
is warned in the log when that happens. If a backup fails, the site is **skipped
rather than updated unprotected**, unless `--fail-on never` says otherwise. `wp core check-update` is deliberately not counted as an
operation, because it exits 1 when the site is already up to date and would cry
wolf on every healthy run.

### Exit codes

The codes are a contract and the scripts honour it — including for `--help`.

| Code | Meaning |
|---|---|
| `0` | success (with `--fail-on=any`: every operation on every site succeeded) |
| `1` | operational error — at least one WP-CLI operation failed |
| `2` | usage error — bad command line |
| `3` | environment error — not root, bash too old, WP-CLI missing, lock held |
| `4` | configuration error — unreadable, unsafe or invalid config file |
| `5` | *(finder only)* no installation found — not a failure of the tool |

`--fail-on any|all|never` moves the `0`/`1` boundary: `any` is right for cron
alerting, `all` for best-effort jobs, `never` when you parse the log instead.

---

## Configuration

Precedence, lowest to highest:

```
built-in defaults  <  /etc/wp-cli-update.conf  <  ./wp-cli-update.conf
                   <  WP_CLI_UPDATE_<KEY> environment  <  command line
```

`Bash_WP-CLI_Update.sh --print-config` prints the effective value of every
setting, the layer that produced it, and whether the command line overrode it.
That is the first thing to run when a host behaves differently from another.

**The config file is data, not shell.** Only `KEY=VALUE` lines are read and the
file is never sourced. A line containing a backtick, `$(`, `|`, `;`, `&`, `<` or
`>` makes the whole file be rejected with exit code 4. A configuration file that
can execute code is a privilege escalation waiting for one loose permission bit,
and this tool runs as root.

See [`wp-cli-update.conf.example`](wp-cli-update.conf.example) for every setting
with its default and the reason it exists.

### The Astra licence

The licence value is **never an argument of any process**. It is written to a
temporary file and the child shell reads it at run time:

```
runuser -u siteuser -- /bin/sh -c 'exec env WP_CLI_LICENCE="$(cat -- /tmp/…XXXXXX)" … wp brainstormforce license activate astra-addon "$WP_CLI_LICENCE"' sh
```

so the value appears neither in `ps` output, nor in a log line, nor in a dry-run
listing, nor in an error box. Sources, in order: `--astra-key`,
`WP_CLI_UPDATE_LICENCE`, `ASTRA_KEY`, `ASTRA_LICENSE_KEY`, then the first
readable file among `./astra.key`, `/etc/wp-cli-update/astra.key`,
`$HOME/.astra.key`. The file must be readable by the site owner for the
duration of the call; `licence_open()` documents that trade-off and every
alternative that was rejected.

---

## Site discovery

```bash
Find_WP_Senior.sh [options] [SEARCH_ROOT ...]
```

* **Only the roots you name are scanned.** With no argument, a short list of
  conventional web roots is used (`/var/www`, `/srv/www`, `/usr/share/nginx/html`,
  `/srv`, `/home`). `/` is never a default and never injected: an earlier
  revision expanded an empty array with `"${arr[@]:-}"`, which in bash 4.4+
  yields one empty element, and a later `[[ -n $r ]] || r='/'` turned that into a
  full filesystem scan that silently added unrelated sites to the list.
* A directory is a WordPress root when it holds `wp-config.php` **and** one of
  `wp-load.php` or `wp-includes/version.php`. A stray config file is not a site.
* A directory containing `.no_wp_cli` is always skipped. That is how one site
  opts out of automated maintenance without being removed from the inventory.
* `find` output is read with `-print0` / `read -d ''`, so a path with a space, a
  quote or a newline survives the whole pipeline.
* The write is atomic (temporary file + `mv`) and preserves the permissions of an
  existing list, so a reader never sees a half-written file and a cron job
  reading the list as another user keeps working.
* Prose goes to stderr, data to stdout. `--output -` writes the list to stdout,
  so `Find_WP_Senior.sh --format json -o - /var/www | jq -r '.[].path'` works.

Formats: `paths` (default, one absolute path per line — what the manager
consumes), `tsv`, `csv`, `json` (with `owner`, `group`, `modified`,
`wp_version`, `db_name`).

---

## Safety features

| Feature | Flags / settings |
|---|---|
| Dry run | `-n, --dry-run` — prints the exact command per site, executes nothing |
| Inspection | `--check`, `--status`, `--print-config`, `--list-modes` |
| Concurrency | `flock` on `--lock-file`, pid-file fallback, stale locks from dead pids are removed, `--no-lock` to bypass |
| Runaway commands | `--timeout SEC`, `--signal SIG`, `--kill-after SEC` |
| Privilege | `--allow-root auto\|always\|never` |
| Destructive actions | `plugin delete` refuses without a terminal or `--yes`/`--force` |
| Colour | `--color auto\|always\|never`, `--no-color`, `NO_COLOR` |
| Log growth | `LOG_MAX_BYTES` + `LOG_KEEP` rotation of both logs |
| Secrets | value never in argv; `redact()` scrubs registered secrets from every message; `tools/scan-secrets.sh` |
| Interrupts | `trap` on EXIT/INT/TERM/HUP prints a partial summary, so a half-finished fleet run still reports how far it got |

---

## Tests

```bash
bash tests/run_tests.sh            # everything
bash tests/run_tests.sh manager    # one suite
VERBOSE=1 bash tests/run_tests.sh  # keep the working directories
```

No root, no WordPress, no WP-CLI and no network are needed. A stub `wp` records
its own argv, working directory, user and environment, so every assertion is
about what would really be executed. Checks that need something the machine may
not have (`runuser`, `flock`, `timeout`, `node`, `python3`, a switchable
account) report **SKIP** with the reason instead of failing.

| Suite | What it protects |
|---|---|
| `test_static.sh` | `bash -n`, ShellCheck clean, LF endings, executable bits, and the absence of the constructs that broke this project before: `eval`, backticks, `"${arr[@]:-}"`, `printf %q`, `su -c` without `-s`, sourcing a config file, personal data in code |
| `test_base_contract.sh` | **the public surface of the original scripts**: every mode and short form, every documented option, the exit-code contract, the `.no_wp_cli` marker, paths with spaces, the `DOCUMENT_ROOT`/`HTTP_HOST`/`HOMEDIR`/`DOCUMENT_URI` environment contract, CRLF site lists, and that no scan ever exceeds the requested roots |
| `test_finder.sh` | detection rule, exclusions, depth, deduplication, all four output formats (JSON and CSV validated with a real parser), atomic write and permission preservation, `--status`, `--skip-existing`, empty-result exit code |
| `test_fleet.sh` | the fleet-wide surface: `--no-user-switch`, `-j N` measured against a sleeping stub (sequential ≥ 4 s vs `-j 5` ≈ 1 s), counters identical at `-j 1/2/3/5`, console order and log contiguity, a failing site inside a batch, `--backup db\|full`, rotation with `--keep-backups`, a backup destination that cannot be created, deletion backup and deactivation, `--verify` issues no mutation, `--only-active` and `--exclude-plugins` selection, `--strict`, JSON Lines shape and ordering, `--list-sites`, `--url`, the configuration layers for the new keys, every shell metacharacter in a config file, a killed worker, leaked worker directories |
| `test_manager.sh` | per-mode argv, `--skip-plugins` policy, `--allow-root` policy, dry run, all four list formats, `--fields`, `--name` filtering, slug resolution, ambiguity refusal, delete confirmation, injection attempts through `--name` and through a site path, the licence never reaching argv or a log, `--check`, `--status`, failure counting, `--fail-on`, timeouts, concurrent runs, stale locks, config precedence, config-file rejection, log rotation, colour policy |
| `test_secretguard.sh` | the guard finds planted values in five name conventions, masks them by default, exits 1 under `--strict`, honours the allowlist, finds a value that was committed and later removed (`--history`), and stays quiet on placeholders, paths, expansions and settings |

Run `bash tools/scan-secrets.sh --strict` before committing; it must exit 0.

---

## Design rules

[`AGENT.md`](AGENT.md) holds the binding rules for anyone — human or model —
changing these scripts. The four that matter most:

1. **No command is built by string concatenation.** Every WP-CLI call is a bash
   array that becomes argv. The only string handed to a shell is the user switch,
   and there the arguments travel as *positional parameters*, so no escaping is
   needed at all.
2. **`printf %q` is bash-only.** Never use it to build a string for `sh -c` or
   `su -c` without `-s`. `/bin/sh` is dash on Debian, `\&\&` is a literal there,
   and the failure mode is `cd: too many arguments` on *every* site.
3. **Never expand a possibly-empty array as `"${arr[@]:-}"`.** In bash 4.4+ that
   is one empty element, not zero elements. Use `${arr[@]+"${arr[@]}"}`.
4. **A configuration file is data.** Parse it; do not source it.

---

## Cron

```cron
# Maintenance at 03:20: four sites at a time, a database dump first, two
# generations kept, and --strict so that a warning also pages somebody.
20 3 * * *  root  /opt/wp-cli-update/Bash_WP-CLI_Update.sh --full -j 4 --backup db \
                  --keep-backups 2 --timeout 900 --strict --quiet \
                  >> /var/log/wp-cli-update/cron.log 2>&1

# Nightly integrity check, machine-readable, only the sites that are not OK.
40 4 * * *  root  /opt/wp-cli-update/Bash_WP-CLI_Update.sh --verify -j 8 --json-lines \
                  | grep -v '"status":"OK"' >> /var/log/wp-cli-update/verify.log

# Refresh the inventory on Sundays, keeping the list even when it comes back empty.
0 4 * * 0   root  /opt/wp-cli-update/Find_WP_Senior.sh --output /var/lib/wp-cli-update/wp-found.txt /var/www >> /var/log/wp-cli-update/cron.log 2>&1
```

The lock makes an overlap harmless: the second run exits 3 with
`refusing to run concurrently` instead of updating the same databases twice.

---

## Repository layout

```
Bash_WP-CLI_Update.sh          the manager (6.2.0)
Find_WP_Senior.sh              the discovery tool (2.1.0)
wp-cli-update.conf.example     every setting, documented
tools/scan-secrets.sh          secret guard (1.1.0)
tools/secret-allowlist.txt     known-benign lines, each with a reason
tests/run_tests.sh             suite runner, non-zero on any failure
tests/test_fleet.sh            parallelism, backups, fleet-wide reporting
tests/harness.sh               shared fixtures and counters
tests/stub/wp                  recording stub of WP-CLI
tests/test_*.sh                five suites
legacy/                        byte-exact archive of the original main scripts
ANALYSIS.md                    audit of the original code, with the PoC
REFACTORING.md                 what this tree took from each of the five revisions
AGENT.md                       binding rules for changes
PROJECT_MAP.md                 file-by-file map with dependencies
CHANGELOG.md                   Keep a Changelog
LICENSE                        MIT
```

## License

MIT — see [LICENSE](LICENSE).

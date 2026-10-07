# WordPress Maintenance Automation

A secure, fast, and modular WP-CLI management system for maintaining multiple WordPress sites efficiently: automated updates, database optimization, plugin inventory and maintenance across all your WordPress installations.

![Bash](https://img.shields.io/badge/Bash-4.2%2B-blue.svg)
![WP-CLI](https://img.shields.io/badge/WP--CLI-2.0%2B-green.svg)
![WordPress](https://img.shields.io/badge/WordPress-3.7%2B-0073aa?logo=wordpress&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

Versions: manager `6.0.0`, discovery `2.0.0`. See [CHANGELOG.md](CHANGELOG.md) for the full list of fixed defects and new options.

## Table of contents

1. [Features](#1-features)
2. [Requirements](#2-requirements)
3. [Installation](#3-installation)
4. [Configuration](#4-configuration)
5. [Usage](#5-usage)
6. [Test suites](#6-test-suites)
7. [How it works](#7-how-it-works)
8. [Troubleshooting](#8-troubleshooting)
9. [Design rules](#9-design-rules)
10. [License and author](#10-license-and-author)

## 1. Features

- **Multi-site management**: run maintenance across every WordPress installation in one pass.
- **Modes for one task at a time**: `--core`, `--plugins`, `--themes`, `--db-optimize`, `--db-fix`, `--cron`, `--astra`, `--full`, or the read-only `--check`, `--list-plugins`, `--status`.
- **Plugin management** with a real preview: `--list-plugins` in table, JSON, CSV or TSV, and `--plugin-manage` to activate, deactivate or delete.
- **No mandatory external tools**: JSON is parsed by the script itself, so `jq` is optional rather than required.
- **Safe command construction**: WP-CLI is invoked from an argument array with explicit POSIX quoting; a plugin name or site path cannot become shell code.
- **Correct privilege handling**: `runuser` is preferred, then `sudo -n`, then `su -s /bin/sh`; `--allow-root` is added only when it is actually needed.
- **Honest reporting**: exit codes distinguish usage errors, environment errors, configuration errors and operational failures; the summary prints once, including after an interrupt.
- **Structured logging** with levels, size-based rotation and a separate error log holding the full text of every failed command.
- **Secrets stay out of logs and process lists**: the Astra licence reaches WP-CLI through a mode-600 hand-over file, never through a command line.
- **Automatic discovery** of installations, with whole-component exclusions and an explicit opt-out marker.
- **Test suites** that need no root, no WordPress and no WP-CLI.

## 2. Requirements

- Linux (tested design targets: CentOS 7+, RHEL, Ubuntu, Debian).
- Bash 4.2 or newer. The scripts check this and exit with code 3 instead of misbehaving.
- Root, for switching to the site owner. Running as a non-root user is allowed and reported as a warning.
- WP-CLI, by default at `/usr/local/bin/wp`. Override with `--wp` or `WP_CLI_PATH`.
- `find`, `stat`, `awk`, `sed`, `sort`, `mktemp`. `jq` is optional.
- Recommended: `flock` (from util-linux) for reliable locking, and `timeout` for per-command limits. Both have fallbacks.

## 3. Installation

```bash
git clone https://github.com/paulmann/Bash_WP-CLI_Update.git
cd Bash_WP-CLI_Update
chmod +x Bash_WP-CLI_Update.sh Find_WP_Senior.sh
```

Check that the interpreters resolve:

```bash
head -n1 Bash_WP-CLI_Update.sh Find_WP_Senior.sh   # both should print a bash shebang
bash --version                                      # 4.2 or newer
which wp
```

The scripts must keep LF line endings. A `.gitattributes` file enforces this in the repository; if you copy the files onto a Linux host from Windows, convert them with `dos2unix` or `sed -i 's/\r$//'`.

## 4. Configuration

### 4.1 Site discovery

```bash
./Find_WP_Senior.sh
```

The list is written next to the script as `wp-found.txt`, which is where the manager looks for it. To place it elsewhere:

```bash
./Find_WP_Senior.sh --output /etc/wp-cli-update/sites.txt
./Find_WP_Senior.sh /var/www /srv --depth 10 --format tsv
./Find_WP_Senior.sh --exclude-name staging --exclude-path /var/www/legacy
./Find_WP_Senior.sh --status          # entry count, size, staleness
```

A directory containing `.no_wp_cli` is skipped together with everything below it.

Exclusions match whole directory names. Excluded by default: `.git`, `.svn`, `.hg`, `node_modules`, `bower_components`, `vendor`, `__pycache__`, `cache`, `caches`, `tmp`, `temp`, `backups`, `backup`, `lost+found`, `proc`, `sys`, `dev`, `run`.

Deliberately **not** excluded: names such as `old`, `backup-2025`, `oldtown.com`, `btest.example.com`. A directory name cannot tell a stale copy from a live site, and substring globs such as `*/old*` used to drop real production sites. Use `--exclude-name` or `--exclude-path` when you know which directories to leave out.

### 4.2 Manual site list

One absolute path per line. Blank lines are ignored, `#` starts a comment, and CRLF line endings are tolerated:

```
# production
/var/www/example.com
/var/www/shop.example.com
```

### 4.3 Settings file

Copy `wp-cli-update.conf.example` to `/etc/wp-cli-update.conf` or next to the script as `wp-cli-update.conf`. The file is plain `KEY=VALUE` data: it is parsed, never sourced, and a file containing a backtick, a subshell, a pipe, a semicolon or a redirection is refused.

Precedence, lowest to highest: built-in defaults, `/etc/wp-cli-update.conf`, `<script dir>/wp-cli-update.conf`, environment variables, command line.

### 4.4 Astra licence

Do not put the licence key in the settings file. Pass it in the environment of the service account:

```bash
# systemd unit
Environment=WP_CLI_UPDATE_LICENCE=<key>

# or a root-only file sourced before the run
set -a; . /etc/wp-cli-update/licence.env; set +a
```

The manager reads the value from the environment, hands it to WP-CLI through a temporary mode-600 file, and removes the file immediately. The key never appears on a command line and never in a log line.

## 5. Usage

```
Bash_WP-CLI_Update.sh <MODE> [options]
```

### 5.1 Modes

| Mode | Short | Description |
|------|-------|-------------|
| `--full` | `-f` | core, plugins, themes, database optimize/repair, cron |
| `--core` | `-c` | core update and database schema update |
| `--plugins` | `-p` | update all plugins |
| `--themes` | `-t` | update all themes |
| `--db-optimize` | `-d` | optimize and repair the database |
| `--db-fix` | `-x` | repair the database |
| `--cron` | `-r` | run due cron events |
| `--astra` | `-s` | update the Astra add-on, activating the licence if needed |
| `--list-plugins` | `-l` | list plugins as table, JSON, CSV or TSV |
| `--plugin-manage` | `-m` | activate, deactivate or delete one plugin |
| `--check` | | validate environment, site list and WP-CLI; changes nothing |
| `--status` | | last run, log sizes, lock state, site count |

### 5.2 Options

| Option | Description |
|--------|-------------|
| `-S, --site PATH` | one site only, overriding the site list. A wrong path is an error, not a skip |
| `-A, --action ACTION` | `activate`, `deactivate` or `delete` for `--plugin-manage` |
| `-N, --name NAME` | plugin name or slug, case-insensitive substring; an ambiguous match performs nothing |
| `-F, --force`, `-y, --yes` | skip the delete confirmation. Without them, a non-interactive delete is refused |
| `-J, --json` | shorthand for `--format json` |
| `--format FMT` | `table`, `json`, `csv` or `tsv` |
| `--page N` | rows per page in the table view, `0` for all |
| `-n, --dry-run` | print the commands, execute nothing |
| `--timeout SEC` | per-command timeout, `0` disables, default 900 |
| `--config FILE` | settings file |
| `--sites FILE`, `--wp PATH`, `--lock-file FILE` | override individual paths |
| `--skip-plugins LIST` | plugins skipped during updates; an empty value disables skipping |
| `--skip-plugins-for-listing on\|off` | also apply the skip list to list commands (off by default, on purpose) |
| `--allow-root auto\|always\|never` | default `auto`: add the flag only when running as root |
| `--astra-key KEY`, `--astra-slug SLUG` | Astra licence and slug |
| `--color auto\|always\|never`, `--no-color` | colour control; `NO_COLOR` is honoured |
| `--log-level LEVEL` | `debug`, `info`, `success`, `warning` or `error` |
| `--quiet` | console shows warnings and errors only |
| `-D, --debug` | verbose logging |
| `-V, --version`, `-h, --help` | version and help, both exit 0 |

### 5.3 Exit codes

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | operational error: at least one WP-CLI operation or one site failed |
| 2 | usage error: unknown option, conflicting modes, missing value |
| 3 | environment error: not enough privileges, bash too old, WP-CLI missing, lock held |
| 4 | configuration error |
| 5 | discovery only: no WordPress installation found |

### 5.4 Examples

```bash
./Bash_WP-CLI_Update.sh --full
./Bash_WP-CLI_Update.sh --plugins --site /var/www/example.com
./Bash_WP-CLI_Update.sh --check
./Bash_WP-CLI_Update.sh --status
./Bash_WP-CLI_Update.sh --list-plugins --format json --quiet
./Bash_WP-CLI_Update.sh --list-plugins --name woo --format csv
./Bash_WP-CLI_Update.sh --plugin-manage --action deactivate --name jetpack --site /var/www/example.com --yes
./Bash_WP-CLI_Update.sh --db-optimize --dry-run
./Bash_WP-CLI_Update.sh --full --timeout 600 --log-level warning
```

Machine-readable listings keep stdout clean; every human message goes to stderr, so `--format json --quiet | jq .` works.

## 6. Test suites

```bash
bash tests/run_tests.sh
```

No root, no WordPress and no WP-CLI are needed. The suites build a synthetic tree and a stub `wp` that records its own `argv`, then check:

- argument preservation (a name with a space stays one argument) and that the slug, not the display name, is passed to WP-CLI;
- that an injection attempt in `--name` creates no file;
- that all four output formats parse with an independent parser;
- exit codes for success, a wrong `--site`, a missing binary and a non-interactive delete;
- `--help` exiting 0 and `--dry-run` executing nothing;
- the `--skip-plugins` policy per command type;
- configuration precedence and the refusal of a shell-metacharacter config;
- that the licence appears in neither the log nor the recorded `argv`;
- that a second concurrent run exits 3;
- for the finder: exclusion precision, depth, the opt-out marker, and output hygiene (sorted, unique, LF, trailing newline).

`shellcheck` is not required. If you have it, `shellcheck -x *.sh tests/*.sh` is a useful extra check; the scripts carry `# shellcheck` directives where the intent is deliberate.

## 7. How it works

### 7.1 User detection

For each site the manager tries, in order: the owner of `wp-config.php`, the owner of the site directory, `DB_USER` from the database settings, and the fourth path component. `root`, `nobody` and non-existent users are skipped; the first candidate that exists as a local user wins. `--check` prints the resolved owner without changing anything.

### 7.2 Command execution

The command text is built from an array with explicit POSIX quoting for every argument, then given to `/bin/sh -c` either directly or through `runuser`, `sudo -n` or `su -s /bin/sh`. Per-site variables (`DOCUMENT_ROOT`, `DOCUMENT_URI`, `HTTP_HOST`, `HOMEDIR`, plus `HOME`) are exported inside the child shell. Every call is bounded by `--timeout`.

### 7.3 Logging

- `wp_cli_manager.log`: timestamped, levelled lines, rotated by size with `LOG_KEEP` generations.
- `wp_cli_errors.log`: for each failure, the context, the argument list, the exit code and the full output.

Colours are written to a terminal only, and never to a log file.

### 7.4 Exit behaviour

A `trap` on `EXIT`, `INT` and `TERM` releases the lock, removes temporary files and prints the summary exactly once, so an interrupted run still reports what it did.

## 8. Troubleshooting

**The script refuses to start.** Check the exit code: 3 is environment (privileges, bash version, missing `wp`), 2 is usage, 4 is configuration. `--check` performs the same checks without changing anything.

**Nothing is updated for one site.** Look at the error log; the full WP-CLI output is recorded there. Run with `--debug` to see the exact command line.

**A plugin is skipped although the update list includes it.** `--skip-plugins` is applied to update commands by design. Remove it from `PLUGIN_SKIP_LIST`, or set `PLUGIN_SKIP_LIST=` empty to disable skipping entirely.

**`wp plugin list` shows fewer plugins than the admin page.** Listing deliberately does not pass `--skip-plugins`, so the list is complete. If you want the skip list applied there too, pass `--skip-plugins-for-listing on`, accepting that skipped plugins will be missing from the output.

**A locked run.** Another run holds the lock file. The pid is shown; check that the process is really gone, remove a stale lock file, or point `--lock-file` somewhere else.

**Deletion refuses to run.** `--plugin-manage --action delete` requires a terminal, or `--yes` / `--force`.

**jq is not installed.** Not a problem: the scripts parse the JSON themselves. `jq` is used only if you call it yourself.

**Discovery misses a site.** Run `Find_WP_Senior.sh --verbose` from that root: every skipped candidate is reported with the reason. Raise `--depth` for deeply nested layouts, and check for a `.no_wp_cli` marker.

## 9. Design rules

These are the rules the code follows; a change that breaks one of them is a regression.

1. **Never build a command as a string.** Arguments travel as an array and are quoted once, at the boundary.
2. **Never let `set -e` decide control flow for WP-CLI.** Each status is checked explicitly, because a failing plugin update must not abort the remaining maintenance steps.
3. **A count is one number.** `grep -c` and `wc -l` exit non-zero on empty input; the `|| printf 0` idiom produces two values and breaks arithmetic.
4. **Never read a value inside a pipeline when the result must survive.** The subshell discards it.
5. **A configuration file is data.** It is parsed with a strict `KEY=VALUE` grammar and refused when it looks like code.
6. **Secrets go through files, not command lines.** They must not appear in `ps`, in logs, or in error records.
7. **Exclusions match whole path components.** Substring globs silently remove live sites.
8. **Stdout carries the result, stderr carries the narration.** Otherwise the output cannot be piped.
9. **An explicit target that is wrong is an error.** Only entries read from a list are skipped with a warning.
10. **Every claim about behaviour is covered by a test** that fails when the behaviour regresses.

## 10. License and author

MIT License — see [LICENSE](LICENSE).

**Mikhail Deynekin**

- Website: [deynekin.com](https://deynekin.com)
- Email: <mid1977@gmail.com>
- GitHub: [@paulmann](https://github.com/paulmann)

Always test maintenance scripts in a staging environment before running them against production. The manager can update plugins and delete files; `--dry-run` and `--check` exist so that you can look before you leap.

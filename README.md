# WordPress Maintenance Automation

A secure, fast and modular WP-CLI maintenance toolkit for fleets of WordPress
installations: automatic discovery of the sites, then core/plugin/theme/database
updates executed as the owning system user.

![Bash](https://img.shields.io/badge/Bash-4.2%2B-blue.svg)
![WP-CLI](https://img.shields.io/badge/WP--CLI-2.0%2B-green.svg)
![WordPress](https://img.shields.io/badge/WordPress-3.7%2B-0073aa?logo=wordpress&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

| Script | Version | Role |
|---|---|---|
| `Find_WP_Senior.sh` | 2.0.0 | Discover WordPress installations and write the site list |
| `Bash_WP-CLI_Update.sh` | 6.0.0 | Run maintenance modes over the sites from that list |

## Table of contents

1. [Features](#1-features)
2. [Prerequisites](#2-prerequisites)
3. [Installation](#3-installation)
4. [Configuration](#4-configuration)
5. [Usage](#5-usage)
6. [Output contract and exit codes](#6-output-contract-and-exit-codes)
7. [Automation (cron)](#7-automation-cron)
8. [Troubleshooting](#8-troubleshooting)
9. [Upgrading from 5.x](#9-upgrading-from-5x)
10. [License and author](#10-license-and-author)

## 1. Features

- **Multi-site maintenance** in one run, sequentially, per site.
- **Discovery first**: `Find_WP_Senior.sh` locates `wp-config.php` files, validates
  the installations, honours a `.no_wp_cli` opt-out marker and writes
  `wp-found.txt` next to the scripts.
- **Correct user switching**: the owner of `wp-config.php`/installation is
  detected (with path and `DB_USER` fallbacks) and the WP-CLI process runs as
  that user via `runuser`/`su` - arguments are passed positionally, never
  through an assembled shell string.
- **Fault tolerant**: a failing WP-CLI call is logged and counted, the remaining
  sites and operations still run; the exit code tells the difference between
  "all good", "some operations failed" and "nothing was processed".
- **Predictable output**: data on stdout, logs and progress on stderr, so
  `--json` output pipes cleanly into other tools.
- **Operational safety**: run lock (no parallel runs), log rotation, redaction
  of the Astra license key in every log/console message, mandatory confirmation
  (or `--force`) before a plugin deletion, `--dry-run` preview.
- **Single configuration file** (`wp-cli-update.conf`) with a documented
  example; CLI options override the file.
- **No jq required** for the plugin table and plugin management: WP-CLI CSV
  output is parsed by an embedded RFC4180-aware awk function.

## 2. Prerequisites

- Linux (tested on CentOS, RHEL, Ubuntu, Debian).
- **Bash 4.2 or newer** for both scripts (a version check fails fast otherwise).
- Root for real runs: user switching and `wp --allow-root` require it.
  `--dry-run` works without root and does not touch anything.
- [WP-CLI](https://wp-cli.org/#installing), found in `PATH` or at
  `/usr/local/bin/wp` (override with `--wp-cli` or `WP_CLI_PATH`).
- GNU coreutils (`stat`, `find`, `sort`, `mktemp`); `getent` and either
  `runuser` or `su` for user switching.

## 3. Installation

```bash
cd /opt
git clone https://github.com/paulmann/Bash_WP-CLI_Update.git
cd Bash_WP-CLI_Update
chmod +x Bash_WP-CLI_Update.sh Find_WP_Senior.sh

cp wp-cli-update.conf.example wp-cli-update.conf
chmod 600 wp-cli-update.conf      # may hold the Astra license key
```

## 4. Configuration

### 4.1 Site list

```bash
./Find_WP_Senior.sh                        # writes ./wp-found.txt
./Find_WP_Senior.sh /var/www /srv          # explicit search roots
./Find_WP_Senior.sh --exclude '/var/www/archive' --max-depth 4
./Find_WP_Senior.sh --json                 # machine readable preview
```

Exclusion patterns are anchored on the directory name (`test*` no longer
matches `/home/testuser/site`); absolute patterns prune whole subtrees. A
`.no_wp_cli` file inside a WordPress root removes that site from the list.
`--no-default-excludes` starts from an empty exclusion list.

The updater reads `wp-found.txt` from the script directory (override with
`--sites-file`). If the file is missing, `Find_WP_Senior.sh` runs once unless
`AUTO_DISCOVER=0` is set - recommended for production servers to keep every run
predictable.

### 4.2 Configuration file

`wp-cli-update.conf` (see `wp-cli-update.conf.example`) accepts:

| Key | Meaning | Default |
|---|---|---|
| `WP_CLI_PATH` | WP-CLI binary | PATH lookup, then `/usr/local/bin/wp` |
| `SITES_FILE` | Site list | `<script dir>/wp-found.txt` |
| `AUTO_DISCOVER` | Run the finder when the list is missing | `1` |
| `SKIP_PLUGINS` | Comma-separated plugins skipped in every call | 3 legacy plugins |
| `ASTRA_PLUGIN` | Astra Pro slug | `astra-addon` |
| `ASTRA_KEY` | Astra Pro license key (never logged) | empty |
| `LOG_DIR` | Log and lock directory | script directory |
| `LOG_MAX_BYTES`, `LOG_KEEP` | Rotation threshold and number of copies | 5 MiB, 5 |
| `ERROR_OUTPUT_LINES` | Failing output echoed to the console | 20 |
| `COLOR` | `auto`/`always`/`never` | `auto` |
| `LOCK_ENABLED` | Refuse parallel runs | `1` |

Precedence: built-in defaults < config file < environment variables <
command-line options.

## 5. Usage

### 5.1 Basic syntax

```bash
./Bash_WP-CLI_Update.sh MODE [OPTIONS]
```

### 5.2 Modes

| Mode | Short | Operations |
|---|---|---|
| `--full` | `-f` | core update, plugin update --all, Astra, theme update --all, core update-db, db optimize, db repair, due cron events |
| `--core` | `-c` | core update, core update-db |
| `--plugins` | `-p` | plugin update --all |
| `--themes` | `-t` | theme update --all |
| `--db-optimize` | `-d` | db optimize, db repair |
| `--db-fix` | `-x` | db repair |
| `--cron` | `-r` | cron event run --due-now |
| `--astra` | `-s` | update astra-addon, activating the license when required |
| `--list-plugins` | `-l` | plugin table, or JSON with `--json` |
| `--plugin-manage` | `-m` | activate/deactivate/delete one plugin (`--action`, `--name`) |

Combining two modes is rejected; unknown options exit with code 1.

### 5.3 Options

| Option | Short | Meaning |
|---|---|---|
| `--debug` | `-D` | Verbose diagnostics on stderr |
| `--site PATH` | `-S` | Process one installation |
| `--user USER` | `-U` | Force the system user (skips detection) |
| `--wp-cli PATH` | | WP-CLI binary |
| `--sites-file FILE` | | Alternative site list |
| `--config FILE` | | Alternative config file |
| `--action ACTION` | `-A` | `activate`/`deactivate`/`delete` (with `-m`) |
| `--name NAME` | `-N` | Plugin name/slug (filter for `-l`, target for `-m`) |
| `--force` | `-F` | Skip the interactive delete confirmation |
| `--json` | `-J` | JSON output for `-l` and for the final summary |
| `--dry-run` | `-n` | Print the planned WP-CLI commands, change nothing |
| `--quiet` | `-q` | Suppress informational console output |
| `--no-color` | | Disable colors |
| `--no-lock` | | Do not take the run lock |
| `--version` | `-V` | Print the version and exit |
| `--help` | `-h` | Print help and exit (exit code 0) |

### 5.4 Examples

```bash
# Preview a full maintenance run without touching anything
./Bash_WP-CLI_Update.sh --full --dry-run --debug

# Update plugins on every site from wp-found.txt
./Bash_WP-CLI_Update.sh -p

# One site, forced user, JSON summary for a monitoring system
./Bash_WP-CLI_Update.sh -c -S /var/www/example.com -U example -J

# Inventory and targeted management
./Bash_WP-CLI_Update.sh -l -N woocommerce
./Bash_WP-CLI_Update.sh -l --json -N woocommerce
./Bash_WP-CLI_Update.sh -m -A deactivate -N jetpack -S /var/www/example.com
./Bash_WP-CLI_Update.sh -m -A delete -N old-plugin -S /var/www/example.com --force
```

## 6. Output contract and exit codes

- **stdout** - data only: plugin table, `--json` documents, final summary.
- **stderr** - logs (`INFO`/`OK`/`WARN`/`ERR`), progress, failing command output.
- **`wp_cli_manager.log`** - full run log, rotated at `LOG_MAX_BYTES`.
- **`wp_cli_errors.log`** - every failure with command, exit code and output;
  secret values are replaced with `<redacted>`.

Exit codes: `0` everything succeeded, `1` usage/config/environment error,
`2` run finished with at least one failed operation, `3` nothing processed.

The finder uses: `0` success (list may be empty), `1` usage/environment error,
`2` output file not writable, `4` nothing found with `--fail-empty`.

## 7. Automation (cron)

```cron
# Nightly full maintenance at 03:30, no interactive prompts
30 3 * * * root AUTO_DISCOVER=0 /opt/Bash_WP-CLI_Update/Bash_WP-CLI_Update.sh --full >> /var/log/wp-cli-update/cron.log 2>&1
```

Points that matter for unattended runs:

- `AUTO_DISCOVER=0` so a missing site list fails fast instead of scanning disks.
- Deletion without a terminal is refused unless `--force` is given.
- The run lock prevents overlapping cron jobs; `--no-lock` opts out.
- Use `LOG_DIR` with real logrotate rules if you prefer logrotate over the
  built-in size-based rotation.

## 8. Troubleshooting

**Script stops with "requires Bash 4.2 or newer"** - upgrade the shell or run
`bash /path/script` with a newer interpreter.

**`cannot determine the system user`** - pass `--user USER`; detection looks at
the owner of `wp-config.php`, the installation directory, common
`/home/<user>/...` layouts and `DB_USER`.

**WP-CLI not found** - install it or pass `--wp-cli /path/to/wp`.

**Refused to delete without a terminal** - run interactively or add `--force`
(the slug still has to match a single plugin).

**Astra update fails** - set `ASTRA_KEY` in the config file; the key is redacted
from all logs. Without a key the update may be refused by the licence check.

**Full detail of a failure** - `tail -50 wp_cli_errors.log`, or rerun with
`--debug` to see the exact command and environment.

## 9. Upgrading from 5.x

- The Astra license key moved out of the script: set `ASTRA_KEY` in
  `wp-cli-update.conf` (chmod 600). The old hard-coded key should be treated as
  leaked and rotated.
- `--help` now exits with 0; failures are no longer fatal mid-run.
- New options (`--dry-run`, `--user`, `--wp-cli`, `--sites-file`, `--config`,
  `--version`, `--quiet`, `--no-color`, `--no-lock`, `-J` summary) and the
  config file are additive: existing command lines keep working.
- Log files stay in the script directory by default and are rotated; configure
  `LOG_DIR` to move them.

## 10. License and author

MIT - see [LICENSE](LICENSE).

**Mikhail Deynekin** - [deynekin.com](https://deynekin.com) ·
[mid1977@gmail.com](mailto:mid1977@gmail.com) · [@paulmann](https://github.com/paulmann)

> Always test maintenance scripts in a staging environment before using them on
> production sites.

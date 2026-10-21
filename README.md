# WordPress Maintenance Automation (Bash WP-CLI Update)

A secure pair of bash scripts for maintaining multiple WordPress installations with WP-CLI on Linux servers.

| Script | Version | Purpose |
|---|---|---|
| `Bash_WP-CLI_Update.sh` | 5.0.0 | Runs WP-CLI maintenance per site, as each site's system user |
| `Find_WP_Senior.sh` | 2.0.0 | Discovers WordPress roots and writes the sites list |

![Bash](https://img.shields.io/badge/Bash-4.2%2B-blue.svg)
![WP-CLI](https://img.shields.io/badge/WP--CLI-2.0%2B-green.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

## Table of Contents

1. [Features](#1-features)
2. [Prerequisites](#2-prerequisites)
3. [Installation](#3-installation)
4. [Configuration](#4-configuration)
   - 4.1 [Sites file](#41-sites-file)
   - 4.2 [Config files](#42-config-files-optional)
   - 4.3 [Astra Pro license key](#43-astra-pro-license-key)
5. [Usage](#5-usage)
   - 5.1 [Operation modes](#51-operation-modes)
   - 5.2 [Options](#52-options)
   - 5.3 [Examples](#53-examples)
6. [Site Discovery](#6-site-discovery)
   - 6.1 [Options](#61-options)
   - 6.2 [Defaults](#62-defaults)
   - 6.3 [Output guarantees](#63-output-guarantees)
7. [How It Works](#7-how-it-works)
   - 7.1 [User detection](#71-user-detection)
   - 7.2 [Safe command execution](#72-safe-command-execution)
   - 7.3 [Locking](#73-locking)
   - 7.4 [Logging](#74-logging)
   - 7.5 [Exit codes](#75-exit-codes)
8. [Testing](#8-testing)
9. [Troubleshooting](#9-troubleshooting)
10. [Contributing](#10-contributing)
11. [License](#11-license)
12. [Author & Support](#12-author--support)

## 1. Features

- **Multi-site management**: one run covers every site in the sites file.
- **Operation modes**: full maintenance or individual tasks — core, plugins, themes, database optimize/repair, cron, Astra Pro.
- **Smart user detection**: determines the correct system user from file and directory ownership.
- **Secure execution**: commands are argv arrays, never shell strings; user switching via `runuser` with a `su` fallback; `--skip-plugins` is applied only to plugin/theme/Astra operations.
- **Automatic discovery**: when the sites file is missing, the bundled discovery script generates it.
- **Dry-run, quiet and debug modes** for previews and troubleshooting.
- **Atomic lock** with stale detection; **rotating logs** plus a separate error log.
- **Strict mode** (`set -euo pipefail`); exit code 1 when any operation fails.

## 2. Prerequisites

- Linux with Bash 4.2 or newer.
- Root privileges — commands run as each site's system user.
- WP-CLI 2.0+ (`wp` in PATH, or point `--wp-cli` at the binary).
- Standard GNU core utilities (`find`, `sort`, `mktemp`, `stat`, `wc`, `date`).

## 3. Installation

```bash
git clone https://github.com/paulmann/Bash_WP-CLI_Update.git
cd Bash_WP-CLI_Update
chmod +x Bash_WP-CLI_Update.sh Find_WP_Senior.sh
bash -n Bash_WP-CLI_Update.sh Find_WP_Senior.sh   # syntax check
wp --info                                        # verify WP-CLI
```

## 4. Configuration

### 4.1 Sites file

Default: `wp-found.txt` next to the main script. One WordPress root per line; blank lines and `#` comments are ignored, duplicate entries are processed once. Override with `--sites-file`. If the file is missing, the main script runs `Find_WP_Senior.sh -o <sites-file>` automatically.

### 4.2 Config files (optional)

Config files are trusted bash snippets sourced by the scripts; keep them readable only by root (`chmod 600`).

`Bash_WP-CLI_Update.conf` may override:

| Variable | Meaning |
|---|---|
| `SITES_FILE` | path to the sites file |
| `LOG_FILE` / `ERROR_LOG_FILE` | log locations (defaults: `wp_cli_manager.log` / `wp_cli_errors.log` next to the script) |
| `WP_CLI_PATH` | explicit `wp` binary |
| `ASTRA_KEY` | Astra Pro license key |
| `SKIP_PLUGINS` | comma-separated plugins to skip (plugin/theme/Astra operations) |
| `MAX_LOG_SIZE` | rotation threshold in bytes (default 5 MiB) |

`Find_WP_Senior.conf` may override: `SEARCH_DIRS`, `EXCLUDE_PATTERNS`, `OUTPUT_FILE`, `MAX_DEPTH`.

### 4.3 Astra Pro license key

Provide it via `--astra-key` or `ASTRA_KEY` in the config file. When no key is configured (value `YOUR_KEY`): `--astra` fails with a clear error and no update is attempted; in `--full` mode the Astra step degrades to a warning.

## 5. Usage

```bash
./Bash_WP-CLI_Update.sh MODE [OPTIONS]
```

### 5.1 Operation modes

| Mode | Short | Description |
|---|---|---|
| `--full` | `-f` | Complete maintenance: core, plugins, themes, DB optimize, DB repair, cron, plus Astra update |
| `--core` | `-c` | Update WordPress core, then update the database (no `--skip-plugins`) |
| `--plugins` | `-p` | Update all plugins |
| `--themes` | `-t` | Update all themes |
| `--db-optimize` | `-d` | Optimize the database |
| `--db-fix` | `-x` | Repair the database |
| `--cron` | `-r` | Run due cron events |
| `--astra` | `-s` | Update Astra Pro plugin; activates the license when needed |

### 5.2 Options

| Option | Description |
|---|---|
| `-D`, `--debug` | Verbose debug logging |
| `-q`, `--quiet` | Suppress console output (errors remain) |
| `-n`, `--dry-run` | Print what would execute without executing it |
| `--sites-file FILE` | Sites file (default: `wp-found.txt` next to the script) |
| `--wp-cli PATH` | WP-CLI binary (default: `wp` from PATH, then `/usr/local/bin/wp`) |
| `--astra-key KEY` | Astra Pro license key |
| `--skip-plugins LIST` | Comma-separated plugins to skip for plugin/theme/Astra modes |
| `-h`, `--help` | Show help |
| `-V`, `--version` | Show version |

### 5.3 Examples

Update all plugins across all sites:
```bash
./Bash_WP-CLI_Update.sh --plugins --sites-file /etc/wp-sites.txt
```

Preview a full maintenance run without executing anything:
```bash
./Bash_WP-CLI_Update.sh --full --dry-run
```

Core update with debug output:
```bash
./Bash_WP-CLI_Update.sh --core --debug
```

Plugins while skipping known-problematic ones:
```bash
./Bash_WP-CLI_Update.sh --plugins --skip-plugins bad-plugin,other-plugin
```

Astra Pro update with license activation:
```bash
./Bash_WP-CLI_Update.sh --astra --astra-key LICENSE_KEY
```

## 6. Site Discovery

```bash
./Find_WP_Senior.sh [OPTIONS] [SEARCH_DIRS...]
```

### 6.1 Options

| Option | Description |
|---|---|
| `-o`, `--output FILE` | Output file (default: `wp-found.txt` next to the script) |
| `-e`, `--exclude PATTERN` | Exclude path (glob or absolute; repeatable) |
| `--max-depth N` | Maximum scan depth (default: 6) |
| `-q`, `--quiet` | No console output except errors |
| `--no-defaults` | Do not add the built-in search dirs and exclusions |
| `-h`, `--help` / `-V`, `--version` | Help / version |

### 6.2 Defaults

Search dirs: `/var/www`, `/usr/share/nginx/html`, `/srv`, `/usr/local/nginx/html`, `/usr/local/var/www`.

Excluded patterns: `*/.git`, `*/node_modules`, `*/vendor`, `*/cache`, `*/backup*`, `*/backups*`, `*/old*`, `*/test*`, `*/tests*`, `*/staging*`.

A WordPress root is a directory containing `wp-config.php` next to `wp-includes/version.php`.

### 6.3 Output guarantees

- Only site paths, one per line, sorted and deduplicated.
- The file is written atomically (temp file + rename); on failure the previous content is preserved.

## 7. How It Works

### 7.1 User detection

For each site: 1) owner of `wp-config.php`, 2) owner of the WordPress root directory. Sites whose user cannot be resolved are skipped and counted as failed.

### 7.2 Safe command execution

- Commands are bash arrays, never shell strings.
- Preferred switch: `runuser -u USER -- env [vars] wp ...`.
- Fallback (no `runuser` or not root): `su -s /bin/bash USER -c '<printf %q escaped command>'`.
- `--skip-plugins` is added only to plugin/theme/Astra commands.

### 7.3 Locking

A lock directory `.Bash_WP-CLI_Update.sh.lock` (holding the runner's pid) prevents concurrent runs; a lock whose pid no longer exists is considered stale and removed automatically. `WPCLI_UPDATE_LOCK_TIMEOUT` adjusts the wait.

### 7.4 Logging

- `wp_cli_manager.log`: `INFO`/`SUCCESS`/`WARNING`/`ERROR`/`DEBUG` entries, rotated at `MAX_LOG_SIZE` (default 5 MiB; the previous file is kept as `.1`).
- `wp_cli_errors.log`: failed operations with command context and output.

### 7.5 Exit codes

- `0` — everything succeeded.
- `1` — at least one operation or site failed (a summary is printed).

## 8. Testing

```bash
pytest tests/test_suite.py
```

The suite: syntax-checks both scripts, runs both scenario suites, and performs an advisory `shfmt` formatting check.

On Windows, Git Bash is required; set `BASH_BIN` to the `bash.exe` path if it is not auto-detected.

Individual scenario suites can be run directly:

```bash
bash tests/scenarios/test_discovery.sh "$(pwd)"
bash tests/scenarios/test_main_update.sh "$(pwd)"
```

Tests run without root using CI hooks:

- `WPCLI_UPDATE_SKIP_ROOT_CHECK=1` — bypass the root check.
- `WPCLI_UPDATE_FORCE_RUNUSER=1` — use `runuser` as a non-root user.
- `WPCLI_UPDATE_LOCK_TIMEOUT=N` — lock acquisition timeout in seconds.

## 9. Troubleshooting

| Symptom / message | Remedy |
|---|---|
| `Another instance is running` | Wait, or remove the stale `.Bash_WP-CLI_Update.sh.lock` directory |
| `This script must be run as root` | Run with `sudo` (in CI set `WPCLI_UPDATE_SKIP_ROOT_CHECK=1`) |
| `Skipping site, user resolution failed` | Fix ownership of `wp-config.php` or the site directory |
| `WP-CLI not found or not executable` | Install WP-CLI or pass `--wp-cli /path/to/wp` |
| `No Astra license key configured` | Pass `--astra-key` or set `ASTRA_KEY` in the config file |

Inspect failed operations with `tail -f wp_cli_errors.log`. Use `--dry-run` to preview commands and `--debug` for a verbose log.

## 10. Contributing

Pull requests, bug reports and feature suggestions are welcome.

- Follow the existing style: strict mode, argv-built commands, English comments.
- Add scenario tests for new behavior.
- Keep `.sh` files with LF line endings; run `shfmt` when available.
- Run `pytest tests/test_suite.py` before submitting.

## 11. License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## 12. Author & Support

**Mikhail Deynekin**

- 🌐 **Website**: [deynekin.com](https://deynekin.com)
- 📧 **Email**: [mid1977@gmail.com](mailto:mid1977@gmail.com)
- 🐙 **GitHub**: [@paulmann](https://github.com/paulmann)

### Getting Help

- 📖 **Documentation**: read this README thoroughly
- 🐛 **Bug Reports**: [open an issue](https://github.com/paulmann/Bash_WP-CLI_Update/issues/new)
- 💡 **Feature Requests**: [request features](https://github.com/paulmann/Bash_WP-CLI_Update/issues/new)
- 💬 **Questions**: [check discussions](https://github.com/paulmann/Bash_WP-CLI_Update/discussions)

---

**Note**: always test maintenance scripts in a staging environment before deploying to production.

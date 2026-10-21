# WordPress Maintenance Automation

A secure, fast, and modular WP-CLI management system for maintaining multiple WordPress sites efficiently. This toolkit provides automated updates, database optimization, and maintenance operations across all your WordPress installations.

![Bash](https://img.shields.io/badge/Bash-4.2%2B-blue.svg)
![WP-CLI](https://img.shields.io/badge/WP--CLI-2.x-green.svg)
![WordPress](https://img.shields.io/badge/WordPress-3.7%2B-0073aa?logo=wordpress&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

## 📋 Table of Contents

1. [Features](#1-features)
2. [Prerequisites](#2-prerequisites)
3. [Installation](#3-installation)
4. [Configuration](#4-configuration)
5. [Usage](#5-usage)
   - 5.1 [Basic Syntax](#51-basic-syntax)
   - 5.2 [Operation Modes](#52-operation-modes)
   - 5.3 [Options](#53-options)
   - 5.4 [Examples](#54-examples)
6. [How It Works](#6-how-it-works)
   - 6.1 [User Detection](#61-user-detection)
   - 6.2 [Safe Execution](#62-safe-execution)
   - 6.3 [Logging System](#63-logging-system)
7. [Troubleshooting](#7-troubleshooting)
   - 7.1 [Common Issues](#71-common-issues)
   - 7.2 [Debug Mode](#72-debug-mode)
8. [Contributing](#8-contributing)
9. [License](#9-license)
10. [Acknowledgments](#10-acknowledgments)
11. [Author & Support](#11-author--support)

## 1. Features

- **Multi-site Management**: Automate maintenance across multiple WordPress installations
- **Flexible Operation Modes**: Choose specific maintenance tasks or run comprehensive updates
- **Smart User Detection**: Automatically determines correct system users for WP-CLI operations
- **Comprehensive Logging**: Detailed execution logs with color-coded output
- **Automatic Discovery**: Find WordPress installations automatically with the included discovery script
- **Safe Operations**: Built-in safety checks and error handling
- **Database Optimization**: Automatic database repair and optimization
- **Cron Management**: Run WordPress cron events efficiently
- **Astra Pro Support**: Specialized handling for Astra Pro plugin with license management
- **Detailed Error Logging**: Comprehensive error tracking in `wp_cli_errors.log`

## 2. Prerequisites

- **Operating System**: Linux (tested on CentOS, Ubuntu, Debian); macOS/BSD work with a current Bash
- **Shell**: Bash 4.2 or higher (both scripts check this and exit with code 3 otherwise)
- **Permissions**: Root access, or `--no-user-switch` when WP-CLI runs as the current user
- **Privilege tool**: `runuser` (preferred), `sudo` or `su`
- **Dependencies**:
  - WP-CLI 2.x — auto-detected in `$PATH`, `/usr/local/bin/wp`, `/usr/bin/wp`, or given with `--wp-bin`
  - WordPress 3.7 or higher
  - Standard GNU core utilities; `jq` recommended (without it the plugin inventory uses WP-CLI CSV output)

## 3. Installation

### 3.1 Download the Scripts

Clone the repository or download the scripts directly:

```bash
git clone https://github.com/paulmann/Bash_WP-CLI_Update.git
cd Bash_WP-CLI_Update
```

### 3.2 Set Execution Permissions

**Important**: Make both scripts executable:

```bash
chmod +x Bash_WP-CLI_Update.sh
chmod +x Find_WP_Senior.sh
```

### 3.3 Verify Script Interpreters

Both scripts ship with the shebang `#!/usr/bin/env bash` and with the executable bit set:

```bash
head -1 Bash_WP-CLI_Update.sh Find_WP_Senior.sh
# both: #!/usr/bin/env bash
```

If `bash --version` reports something older than 4.2, run the scripts with a newer
interpreter explicitly (e.g. `bash5 Bash_WP-CLI_Update.sh --full`) — the scripts
refuse to start on older shells instead of failing with a cryptic error.

### 3.4 Verify WP-CLI Installation

Ensure WP-CLI is installed at the expected location:

```bash
which wp
# Should return: /usr/local/bin/wp
```

If not installed, follow [WP-CLI installation instructions](https://wp-cli.org/#installing).

## 4. Configuration

### 4.1 Automatic Site Discovery

Run the discovery script to automatically find WordPress installations:

```bash
./Find_WP_Senior.sh
```

This creates `wp-found.txt` **next to the script** (not in the current working
directory) with the paths of all discovered WordPress installations. Use
`--output FILE` to change the location, `--output -` to print to stdout,
`--json` for machine-readable output, and `--max-depth`, `--follow`,
`--exclude PATTERN`, `--dry-run`, `--fail-if-empty` for fine control:

```bash
./Find_WP_Senior.sh --output /etc/wp-sites.txt --max-depth 8 --follow --exclude '*/staging' -v
```

Exit codes: `0` success, `1` runtime error, `2` usage error, `3` nothing found (with `--fail-if-empty`).

### 4.2 Manual Site Configuration

If you prefer manual configuration, create or edit `wp-found.txt`:

```bash
nano wp-found.txt
```

Add one WordPress root directory per line:
```
/var/www/site1.com
/var/www/site2.com
/var/www/site3.com
```

### 4.3 Astra Pro License Configuration

For Astra Pro plugin support, configure your license key in the main script:

```bash
# Edit the script and set your Astra Pro license key
nano Bash_WP-CLI_Update.sh

# Locate and update the ASTRA_KEY constant:
readonly ASTRA_KEY="YOUR_ACTUAL_LICENSE_KEY_HERE"
```

## 5. Usage

### 5.1 Basic Syntax

```bash
./Bash_WP-CLI_Update.sh [MODE] [OPTIONS]
```

### 5.2 Operation Modes

| Mode | Short | Description |
|------|-------|-------------|
| `--full` | `-f` | Complete maintenance (core, plugins, themes, DB optimize/repair, cron) |
| `--core` | `-c` | Update WordPress core only |
| `--plugins` | `-p` | Update all plugins |
| `--themes` | `-t` | Update all themes |
| `--db-optimize` | `-d` | Optimize and repair database |
| `--db-fix` | `-x` | Repair database only |
| `--cron` | `-r` | Run due cron events |
| `--astra` | `-s` | Update Astra Pro plugin with license activation |
| `--list-plugins` | `-l` | Plugin inventory: table, or JSON with `--json` |
| `--plugin-manage` | `-m` | `activate` / `deactivate` / `delete` a plugin |
| `--status` | — | Read-only health report (core version, pending updates, DB size) |
| `--verify` | — | Read-only checksum verification (`core` + `plugin verify-checksums`) |

### 5.3 Options

| Option | Short | Description |
|--------|-------|-------------|
| `--site PATH` | `-S` | Process a single site instead of the whole list |
| `--sites-file FILE` | — | Alternative site list (default: `<script dir>/wp-found.txt`) |
| `--action ACTION` | `-A` | `activate` \| `deactivate` \| `delete` (with `--plugin-manage`) |
| `--name NAME` | `-N` | Plugin slug or partial name (exact slug always wins) |
| `--only-active` | — | Update only active plugins that actually have an update |
| `--exclude-plugins LIST` | `-e` | Plugins excluded from `plugin update --all` |
| `--skip-plugins LIST` | `-k` | Value for the global `--skip-plugins` (bootstrap safety only) |
| `--dry-run` | `-n` | Show what would run; mutations are skipped |
| `--jobs N` | `-j` | Process N sites in parallel batches |
| `--backup MODE` | `-b` | `db` or `full` backup before changes |
| `--no-backup` | — | Never back up (also disables the delete backup) |
| `--backup-dir DIR` / `--keep-backups N` | `-B` | Backup location and retention |
| `--user USER` | `-u` | Force the system user used for WP-CLI |
| `--url URL` | `-U` | Force `--url` (multisite) |
| `--timeout SEC` | `-T` | Per-command timeout (default 600; `0` disables) |
| `--force` / `--yes` | `-F` / `-y` | No prompts; continue on errors |
| `--strict` | — | Warnings/findings cause a non-zero exit |
| `--json` | `-J` | JSON Lines on stdout (one object per site + summary) |
| `--log-dir DIR` | `-L` | Log directory (default: script directory) |
| `--config FILE` | `-C` | Configuration file (default: `<script dir>/wp-maintenance.conf`) |
| `--wp-bin PATH` | — | WP-CLI binary |
| `--no-user-switch` | — | Run WP-CLI as the current user (Docker, per-user cron) |
| `--no-discover` | — | Never run the discovery script automatically |
| `--list-sites` | — | Print the resolved site list and exit |
| `--DEBUG` | `-D` | Enable detailed debug logging |
| `--quiet` / `--verbose` | `-q` / `-v` | Less / more console output |
| `--no-color` | — | Disable ANSI colours |
| `--version` | `-V` | Print the version |

### 5.4 Examples

Update all plugins across all sites:
```bash
./Bash_WP-CLI_Update.sh --plugins
# or using short option
./Bash_WP-CLI_Update.sh -p
```

Run complete maintenance with debug output:
```bash
./Bash_WP-CLI_Update.sh --full --DEBUG
# or using short options
./Bash_WP-CLI_Update.sh -f -D
```

Optimize databases only:
```bash
./Bash_WP-CLI_Update.sh --db-optimize
```

Run WordPress cron events:
```bash
./Bash_WP-CLI_Update.sh --cron
```

Update Astra Pro plugin with license management:
```bash
./Bash_WP-CLI_Update.sh --astra
```

### 5.5 Configuration File and Tests

Copy the example configuration and adjust it (the file is sourced, so it must not
be writable by group/other):

```bash
cp wp-maintenance.conf.example /etc/wp-maintenance/wp-maintenance.conf
chmod 0600 /etc/wp-maintenance/wp-maintenance.conf
./Bash_WP-CLI_Update.sh --full --config /etc/wp-maintenance/wp-maintenance.conf
```

Precedence: command line > environment > config file > built-in defaults.

A self-contained test suite (mock WP-CLI, fake WordPress tree, no root and no
network required) covers all modes, backups, dry-run, exit codes, the CSV
fallback without `jq`, parallel runs and adversarial input:

```bash
BASH_BIN=/usr/local/bin/bash ./tests/smoke_test.sh
```

## 6. How It Works

### 6.1 User Detection
The script automatically determines the correct system user for each WordPress installation by checking:

1. File owner of `wp-config.php`
2. Directory owner of WordPress root
3. Path structure patterns
4. DB_USER from wp-config.php (fallback)

### 6.2 Safe Execution
- WP-CLI always runs as the correct system user (`runuser`/`sudo`/`su`), with the
  target user's `HOME`; `--path` and (when known) `--url` are passed instead of
  faking `DOCUMENT_ROOT`/`HTTP_HOST`
- Commands are executed through an **argument array** — site paths, plugin names
  and command output are never interpolated into a shell string
- Confirmation prompts are read from `/dev/tty`; WP-CLI never consumes the site list
- `--skip-plugins` only affects plugin loading during bootstrap. To keep a plugin
  out of `plugin update --all`, use `--exclude-plugins`
- Every command has a timeout, failures are collected per site and reported with
  the exit codes listed below
- `--dry-run` previews the run; `--backup db|full` (or `-m -A delete`) creates
  database dumps and plugin archives before changes

### 6.3 Logging System

#### Main Log (`wp_cli_manager.log`)
Structured logging with timestamps and color-coded console output:
- `INFO` - General operation information
- `SUCCESS` - Completed operations  
- `WARNING` - Non-critical issues
- `ERROR` - Operation failures
- `DEBUG` - Detailed debugging information

Logs are appended (history is preserved), rotated when they exceed 5 MiB, and the
licence key is redacted. Exit codes: `0` success · `1` operation failure ·
`2` usage error · `3` preflight error · `4` no sites · `130` interrupted.

#### Error Log (`wp_cli_errors.log`)
Detailed error logging for troubleshooting:
- Per-run header (`RUN <timestamp>-<pid>`) so runs stay distinguishable
- Complete command context (licence keys redacted)
- Full command output, exit codes and error details

## 7. Troubleshooting

### 7.1 Common Issues

**Script stops after "Processing site"**:
- Check that WP-CLI is installed (`wp --info`) or pass `--wp-bin /path/to/wp`
- Verify the WordPress user exists and has proper permissions
- Run with `--DEBUG` flag for detailed output

**Permission denied errors**:
- Ensure scripts are executable: `chmod +x *.sh`
- Run as root user for proper user switching

**WP-CLI not found**:
- Install WP-CLI globally or update the path in the script
- Verify installation with `wp --info`

**Astra Pro license errors**:
- Prefer a root-owned key file: `--astra-key-file /etc/wp-maintenance/astra.key` (mode 0600)
- Verify Astra Pro plugin is installed and active
- Check error log for detailed license activation issues

### 7.2 Debug Mode

For detailed troubleshooting, use debug mode:

```bash
./Bash_WP-CLI_Update.sh --cron --DEBUG
```

This provides:
- Step-by-step execution details
- Command output and exit codes
- User detection process information
- Environment variable settings

### 7.3 Error Investigation

Check the detailed error log for in-depth analysis:

```bash
tail -f wp_cli_errors.log
```

## 8. Contributing

We welcome contributions! Please feel free to submit pull requests, report bugs, or suggest new features.

### Development Guidelines

1. Follow existing code style and structure
2. Add appropriate error handling
3. Include debug information for new features
4. Update documentation for changes
5. Test changes thoroughly before submitting

## 9. License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 10. Acknowledgments

- **WP-CLI Team** for the excellent command-line interface
- **WordPress Community** for continuous improvement and updates
- **Astra Team** for the wonderful theme and plugin ecosystem
- **Contributors** who help maintain and improve this tool

## 11. Author & Support

**Mikhail Deynekin**

- 🌐 **Website**: [deynekin.com](https://deynekin.com)
- 📧 **Email**: [mid1977@gmail.com](mailto:mid1977@gmail.com)
- 🐙 **GitHub**: [@paulmann](https://github.com/paulmann)

### Getting Help

- 📖 **Documentation**: Read this README thoroughly
- 🐛 **Bug Reports**: [Open an issue](https://github.com/paulmann/Bash_WP-CLI_Update/issues/new)
- 💡 **Feature Requests**: [Request features](https://github.com/paulmann/Bash_WP-CLI_Update/issues/new)
- 💬 **Questions**: [Check Discussions](https://github.com/paulmann/Bash_WP-CLI_Update/discussions)

---

**Note**: Always test maintenance scripts in a staging environment before deploying to production.

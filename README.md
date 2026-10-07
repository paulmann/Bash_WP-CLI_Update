# WordPress Maintenance Automation

A secure, fast, and modular WP-CLI management system for maintaining multiple WordPress sites efficiently. This toolkit provides automated updates, database optimization, and maintenance operations across all your WordPress installations.

![Bash](https://img.shields.io/badge/Bash-4.2%2B-blue.svg)
![WP-CLI](https://img.shields.io/badge/WP--CLI-2.0%2B-green.svg)
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
   - 5.5 [Environment Variables](#55-environment-variables)
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

- **Operating System**: Linux (tested on CentOS, Ubuntu, Debian)
- **Shell**: Bash 4.0 or higher
- **Permissions**: Root access (for user switching)
- **Dependencies**: 
  - WP-CLI installed at `/usr/local/bin/wp`
  - WordPress 3.7 or higher
  - Standard GNU core utilities

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

Both scripts use `#!/usr/bin/env bash` and require Bash 4.2 or newer.
Update the shebang if your system configuration requires a different path.

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

This will create a `wp-found.txt` file with paths to all discovered WordPress
installations. Additional options:

```bash
./Find_WP_Senior.sh --exclude 'stage-*' --exclude '/var/www/archive' --output /root/sites.txt /var/www
```

- `--output FILE` - write path list to FILE (default: `./wp-found.txt`)
- `--exclude PATTERN` - directory-name glob (e.g. `node_modules`, `stage-*`)
  or an absolute path to prune; repeatable
- `--max-depth N` - limit scan depth (default: 6)
- `--version` - print version and exit

Per-site opt-out: create an empty `.no_wp_cli` file inside a WordPress root
to hide it from discovery.

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

For Astra Pro plugin support, provide your license key via one of these
sources (in order of precedence). **Never hard-code the key in the script** - it
would be written to the log files.

```bash
# 1) Environment variable (preferred)
export ASTRA_KEY="YOUR_ACTUAL_LICENSE_KEY_HERE"
./Bash_WP-CLI_Update.sh --astra

# 2) License key file (first line, no trailing spaces)
echo "YOUR_ACTUAL_LICENSE_KEY_HERE" > astra.key
chmod 600 astra.key
```

The key is redacted as `***` in all log output and on screen.

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

### 5.3 Options

| Option | Short | Description |
|--------|-------|-------------|
| `--DEBUG` | `-D` | Enable detailed debug logging |
| `--site PATH` | `-S` | Target a specific site (instead of wp-found.txt) |
| `--name NAME` | `-N` | Plugin name filter (list/manage modes) |
| `--action A` | `-A` | Plugin action: activate|deactivate|delete |
| `--force` | `-F` | Skip confirmation for destructive actions |
| `--json` | `-J` | JSON output for --list-plugins |
| `--version` | `-V` | Print version and exit |

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

### 5.5 Environment Variables

| Variable | Purpose |
|----------|---------|
| `ASTRA_KEY` / `ASTRA_LICENSE_KEY` | Astra Pro license key (see 4.3) |
| `WP_SKIP_PLUGINS` | Comma-separated plugin slugs skipped during updates |
| `WP_SITES_FILE` | Alternative path to the sites list file |
| `NO_COLOR=1` | Disable colored console output |


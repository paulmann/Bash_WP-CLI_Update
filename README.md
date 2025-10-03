# WordPress Maintenance Automation

A secure, fast, and modular WP-CLI management system for maintaining multiple WordPress sites efficiently. This toolkit provides automated updates, database optimization, and maintenance operations across all your WordPress installations.

![Bash](https://img.shields.io/badge/Bash-4.0%2B-blue.svg)
![WP-CLI](https://img.shields.io/badge/WP--CLI-2.0%2B-green.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

## 📋 Table of Contents

- [Features](#-features)
- [Prerequisites](#-prerequisites)
- [Installation](#-installation)
- [Configuration](#-configuration)
- [Usage](#-usage)
- [How It Works](#-how-it-works)
- [Troubleshooting](#-troubleshooting)
- [Contributing](#-contributing)
- [License](#-license)
- [Acknowledgments](#-acknowledgments)
- [Author & Support](#author--support)

## 🚀 Features

- **Multi-site Management**: Automate maintenance across multiple WordPress installations
- **Flexible Operation Modes**: Choose specific maintenance tasks or run comprehensive updates
- **Smart User Detection**: Automatically determines correct system users for WP-CLI operations
- **Comprehensive Logging**: Detailed execution logs with color-coded output
- **Automatic Discovery**: Find WordPress installations automatically with the included discovery script
- **Safe Operations**: Built-in safety checks and error handling
- **Database Optimization**: Automatic database repair and optimization
- **Cron Management**: Run WordPress cron events efficiently

## 📋 Prerequisites

- **Operating System**: Linux (tested on CentOS, Ubuntu, Debian)
- **Shell**: Bash 4.0 or higher
- **Permissions**: Root access (for user switching)
- **Dependencies**: 
  - WP-CLI installed at `/usr/local/bin/wp`
  - Standard GNU core utilities

## 🛠️ Installation

### 1. Download the Scripts

Clone the repository or download the scripts directly:

```bash
git clone https://github.com/paulmann/Bash_WP-CLI_Update.git
cd Bash_WP-CLI_Update
```

### 2. Set Execution Permissions

**Important**: Make both scripts executable:

```bash
chmod +x Bash_WP-CLI_Update.sh
chmod +x Find_WP_Senior.sh
```

### 3. Verify Script Interpreters

Check that the shebang lines at the top of each script point to correct shell paths:

- **Bash_WP-CLI_Update.sh**: Should have `#!/usr/bin/env bash`
- **Find_WP_Senior.sh**: Should have `#!/bin/bash`

Update if necessary for your system configuration.

### 4. Verify WP-CLI Installation

Ensure WP-CLI is installed at the expected location:

```bash
which wp
# Should return: /usr/local/bin/wp
```

If not installed, follow [WP-CLI installation instructions](https://wp-cli.org/#installing).

## 🔧 Configuration

### Automatic Site Discovery

Run the discovery script to automatically find WordPress installations:

```bash
./Find_WP_Senior.sh
```

This will create a `wp-found.txt` file with paths to all discovered WordPress installations.

### Manual Site Configuration

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

## 📖 Usage

### Basic Syntax

```bash
./Bash_WP-CLI_Update.sh [MODE] [OPTIONS]
```

### Operation Modes

| Mode | Short | Description |
|------|-------|-------------|
| `--full` | `-f` | Complete maintenance (core, plugins, themes, DB optimize/repair, cron) |
| `--core` | `-c` | Update WordPress core only |
| `--plugins` | `-p` | Update all plugins |
| `--themes` | `-t` | Update all themes |
| `--db-optimize` | `-d` | Optimize and repair database |
| `--db-fix` | `-x` | Repair database only |
| `--cron` | `-r` | Run due cron events |

### Options

| Option | Short | Description |
|--------|-------|-------------|
| `--DEBUG` | `-D` | Enable detailed debug logging |

### Examples

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

## 🔍 How It Works

### User Detection
The script automatically determines the correct system user for each WordPress installation by checking:

1. File owner of `wp-config.php`
2. Directory owner of WordPress root
3. Path structure patterns
4. DB_USER from wp-config.php (fallback)

### Safe Execution
- Runs WP-CLI commands as the correct system user
- Includes proper environment variables
- Skips problematic plugins during updates
- Provides comprehensive error handling

### Logging
All operations are logged to `wp_cli_manager.log` with timestamps and color-coded console output.

## 📊 Output Example

```
Starting WordPress maintenance in 'plugins' mode
Reading sites from /home/user/wp-cli/wp-found.txt
Processing site: /var/www/example.com
✓ Success: wp plugin update --all
✓ Success: wp core update-db

=== SUMMARY ===
Sites processed: 1
Successful ops:  2
Errors:          0
Log file:        /home/user/wp-cli/wp_cli_manager.log
```

## 🛠️ Troubleshooting

### Common Issues

**Script stops after "Processing site"**:
- Check that WP-CLI is installed at `/usr/local/bin/wp`
- Verify the WordPress user exists and has proper permissions
- Run with `--DEBUG` flag for detailed output

**Permission denied errors**:
- Ensure scripts are executable: `chmod +x *.sh`
- Run as root user for proper user switching

**WP-CLI not found**:
- Install WP-CLI globally or update the path in the script
- Verify installation with `wp --info`

### Debug Mode

For detailed troubleshooting, use debug mode:

```bash
./Bash_WP-CLI_Update.sh --cron --DEBUG
```

This provides:
- Step-by-step execution details
- Command output and exit codes
- User detection process information
- Environment variable settings

## 🤝 Contributing

We welcome contributions! Please feel free to submit pull requests, report bugs, or suggest new features.

### Development Guidelines

1. Follow existing code style and structure
2. Add appropriate error handling
3. Include debug information for new features
4. Update documentation for changes

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **WP-CLI Team** for the excellent command-line interface
- **WordPress Community** for continuous improvement and updates
- **Contributors** who help maintain and improve this tool

## 👨‍💻 Author & Support

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

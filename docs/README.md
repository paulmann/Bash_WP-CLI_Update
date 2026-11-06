# Documentation index

| Document | Read it when |
|---|---|
| [README.md](../README.md) | you are installing it or want the feature reference: modes, options, every configuration key, exit codes, production profile |
| [AGENTS.md](../AGENTS.md) | you are an agent (or a human) installing and configuring it on a host: the map, the two overriding rules, the do-nots and the report-back format |
| [AGENT-INSTALL.md](AGENT-INSTALL.md) | you are installing and configuring it: preconditions, both install routes, configuration rules, the site list and the verification order |
| [AGENT-OPERATIONS.md](AGENT-OPERATIONS.md) | you are scheduling it, reading a run report, or handling a failure: the scheduled units, the failure table and the absolute do-nots |
| [DEVELOPMENT.md](DEVELOPMENT.md) | you are changing the code: the test suites, the static gates, the fixed order for adding a feature, versioning and the release pointer |
| [COMPARISON.md](COMPARISON.md) | you want to know **why** the code looks like this: the three-way comparison (`main`, `QWEN_Hybrid`, `DeepSeek_Hybrid`), what was merged, what was rejected and with which evidence |
| [RELEASE-HISTORY.md](RELEASE-HISTORY.md) | you are tracing which branch became which release, and why 7.0.1 is a separate architecture |
| [../SECURITY.md](../SECURITY.md) | you are reviewing the threat model of a root tool, or hardening a host |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | you are changing the code: the four invariants, the fixed order for adding a feature, versioning |
| [../CHANGELOG.md](../CHANGELOG.md) | you are upgrading and want to know what moved |
| [PUBLISHING.md](PUBLISHING.md) | you are cutting a release: the version bump, git, the workflow gates, and the npm step. |
| [../PROJECT_MAP.md](../PROJECT_MAP.md) | you need the file-by-file map and the data flow |
| [../install.sh](../install.sh) | you want the install steps performed for you: `--dry-run` first, `--systemd` to add the timer, `--uninstall` to remove the symlinks |
| [../ANALYSIS.md](../ANALYSIS.md) | you want the audit of the original 5.0 code, with line citations and the reproduced injection |
| [../REFACTORING.md](../REFACTORING.md) | you want the audit trail of the 6.x refactor |

| [wiki/Home.md](../wiki/Home.md) | you want the same material as a manual, published at <https://github.com/paulmann/Bash_WP-CLI_Update/wiki> |

## By task

| I want to... | Go to |
|---|---|
| install it on a server | README §3, then AGENT-INSTALL.md §2 (the ordered version) |
| check a host before the first run | AGENT-INSTALL.md §3 (`--doctor`, `--check`, `--health`, dry run) |
| write the configuration | README §8 and `wp-cli-update.conf.example` |
| schedule it | AGENT-OPERATIONS.md §1, `contrib/wp-cli-update.timer` or `contrib/cron.example` |
| understand an exit code | README §10, AGENT-OPERATIONS.md §2 |
| read the result of a run | README §9 (`--report`, `--json-lines`, `--json-log`) |
| handle a failed run | AGENT-OPERATIONS.md §3, then the report in `REPORT_FILE` |
| restore a database | README §7 (`--list-backups`, `--restore-db --yes`) |
| add a mode or a key | DEVELOPMENT.md §2, then CONTRIBUTING.md |
| run the tests | DEVELOPMENT.md §1, README §12 |
| report a vulnerability | SECURITY.md |

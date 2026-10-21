# Documentation index

| Document | Read it when |
|---|---|
| [README.md](../README.md) | you are installing it or want the feature reference: modes, options, every configuration key, exit codes, production profile |
| [AGENTS.md](../AGENTS.md) | you are an agent (or a human) installing and configuring it on a host: preconditions, ordered install, verification order, troubleshooting table, absolute do-nots, how to extend |
| [COMPARISON.md](COMPARISON.md) | you want to know **why** the code looks like this: the three-way comparison (`main`, `QWEN_Hybrid`, `DeepSeek_Hybrid`), what was merged, what was rejected and with which evidence |
| [../SECURITY.md](../SECURITY.md) | you are reviewing the threat model of a root tool, or hardening a host |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | you are changing the code: the four invariants, the fixed order for adding a feature, versioning |
| [../CHANGELOG.md](../CHANGELOG.md) | you are upgrading and want to know what moved |
| [PUBLISHING.md](PUBLISHING.md) | you are cutting a release: the version bump, git, the workflow gates, and the npm step. |
| [../PROJECT_MAP.md](../PROJECT_MAP.md) | you need the file-by-file map and the data flow |
| [../install.sh](../install.sh) | you want the install steps performed for you: `--dry-run` first, `--systemd` to add the timer, `--uninstall` to remove the symlinks |
| [../ANALYSIS.md](../ANALYSIS.md) | you want the audit of the original 5.0 code, with line citations and the reproduced injection |
| [../REFACTORING.md](../REFACTORING.md) | you want the audit trail of the 6.x refactor |

## By task

| I want to... | Go to |
|---|---|
| install it on a server | README §3, then AGENTS.md §3 (the ordered version) |
| check a host before the first run | AGENTS.md §4 (`--doctor`, `--check`, `--health`, dry run) |
| write the configuration | README §8 and `wp-cli-update.conf.example` |
| schedule it | `contrib/wp-cli-update.timer` (systemd) or `contrib/cron.example` |
| understand an exit code | README §10 |
| read the result of a run | README §9 (`--report`, `--json-lines`, `--json-log`) |
| restore a database | README §7 (`--list-backups`, `--restore-db --yes`) |
| add a mode or a key | AGENTS.md §10, then CONTRIBUTING.md |
| run the tests | README §12, CONTRIBUTING.md |
| report a vulnerability | SECURITY.md |

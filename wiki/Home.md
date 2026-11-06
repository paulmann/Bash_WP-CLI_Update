# Bash WP-CLI Update

Bash WP-CLI Update runs WP-CLI maintenance over a list of WordPress installations: core,
plugins, themes, the database schema and due cron events, one site at a time, each site
as the system user that owns it. It backs a site up before it changes it, writes a JSON
run report with the list of what actually changed, and can restore a database from the
dumps it takes. It is a bash 4.2+ script that runs as root. It is not a WordPress plugin
and it does not need PHP.

```bash
Bash_WP-CLI_Update.sh --full --backup db --jobs 4 --report /var/log/wp/report.json
```

## Security advisory: CVE-2026-119977

A race condition in the WordPress core update mechanism is exploited in the wild. Core
4.7 through 7.1.3 is affected; 7.1.4 is the fixed release, and 4.6 and older get no fix.
Version 8.1.0 answers it with two modes and a configuration setting: `--security` reports
each site's core version against the fixed releases and exits non-zero when a site is
exposed, `--harden` closes `wp-content/upgrade/` on Apache and LiteSpeed, and
`HARDEN_UPGRADE_DIR=1` does the same during every writing mode. nginx ignores
`.htaccess`, so an nginx host needs one directive in its server block.

The advisory, the fleet commands, the nginx directive and a copy-paste agent prompt are
on [Security: CVE-2026-119977](09-Security-CVE-2026-119977). Read it before the next
maintenance run, not after.

## At a glance

| Item | Value |
|---|---|
| Version | 8.1.0 |
| Finder version | 2.1.0 (`Find_WP_Senior.sh`) |
| Runtime | bash 4.2+, GNU coreutils and findutils, WP-CLI |
| Privileges | root, plus one of `runuser` / `sudo` / `su` |
| Optional tools | `flock`, `timeout` (or `perl`), `tar`, `gzip`, `nice`, `ionice`, `curl`, `mail` |
| Licence | MIT |
| npm package | `bash-wp-cli-update` (delivery only; it installs nothing else) |
| Platform | Linux; the npm package declares `os: linux`, and macOS ships bash 3.2, below the floor |
| Entry points | `Bash_WP-CLI_Update.sh` (the manager), `Find_WP_Senior.sh` (the site finder) |

## Pages

| Page | What it covers |
|---|---|
| [Home](Home) | this page: what the tool is, the safety rules, the map |
| [Why](01-Why) | the problem a root tool creates, the safety model, the measured lineage of 5.x to 8.x |
| [Install](02-Install) | three install routes, directories and permissions, the ordered verification |
| [Modes](03-Modes) | every mode with its short form, selection, fleet control, backups, pins |
| [Configuration](04-Configuration) | the precedence stack, the parser rules, every key with its default, the production profile |
| [Operations](05-Operations) | systemd, cron, log rotation, the run report, notifications, monitoring |
| [Exit codes](06-Exit-Codes) | the 0/1/2/3/4/130/143/131 contract and how a run reports an interruption |
| [Troubleshooting](07-Troubleshooting) | symptom, real cause, action; the diagnosis paths; the absolute do-nots |
| [Development](08-Development) | test suites, the two static gates, the fixed order for a feature, the release process |
| [Security: CVE-2026-119977](09-Security-CVE-2026-119977) | the advisory, affected and fixed versions, what to do now, the fleet commands, the agent prompt |

## Two rules that override everything else

1. **Never run a mutating mode on a production host the first time.** Install, run
   `--doctor`, then `--check`, then one site with `--dry-run`, then one site for real.
2. **Never delete a backup, a site file or a database to "clean up" after a failed run.**
   Stop and report. The restore path exists; use it.

Both rules come from the project's own operating instructions, which are written for an
agent or a careful human who has to do this on a live host.

## Reference

The complete feature reference, including every option, configuration key, exit code and
the recommended production profile, is in
[README](https://github.com/paulmann/Bash_WP-CLI_Update/blob/main/README.md). The ordered
install-and-verify procedure, the troubleshooting table and the absolute do-nots are in
[AGENTS](https://github.com/paulmann/Bash_WP-CLI_Update/blob/main/AGENTS.md). The
three-way comparison that produced 8.0.0 is in
[docs/COMPARISON.md](https://github.com/paulmann/Bash_WP-CLI_Update/blob/main/docs/COMPARISON.md).

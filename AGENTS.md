# AGENTS.md — install and operate Bash WP-CLI Update 8.1.0

Instructions for an LLM agent (or a careful human) who installs, configures and verifies
this tool on a Linux host. This file is a map: the detailed procedures live in `docs/`
and are linked below. Read this page, then the document for the step you are on.

Two rules override every other consideration:

1. **Never run a mutating mode on a production host the first time.** Install, run
   `--doctor`, then `--check`, then one site with `--dry-run`, then one site for real.
2. **Never delete a backup, a site file or a database to "clean up" after a failed
   run.** Stop and report. The restore path exists; use it.

## Contents

[Product](#what-the-product-is) · [Install](#install-and-configure) · [Verify](#verify) · [Operate](#operate) ·
[Rules](#non-negotiable-rules) · [Do not](#do-not) · [Report](#report-back) · [Help](#help-the-project)

## What the product is

`Bash_WP-CLI_Update.sh` is a bash 4.2+ script that runs WP-CLI maintenance over a list
of WordPress installations, each one as the system user that owns it. It is not a
WordPress plugin and does not need PHP: it needs a `wp` binary, bash, coreutils, and
root (to switch into site owners).

| File | Role |
|---|---|
| `Bash_WP-CLI_Update.sh` | the manager; the only entry point for maintenance |
| `Find_WP_Senior.sh` | builds the site list (`wp-found.txt`) |
| `wp-cli-update.conf.example` | every configuration key, annotated |
| `tests/`, `tools/`, `contrib/` | behavioural suites with a stub `wp`, the secret scanner, the systemd/cron/logrotate files |

The operator reference is [README.md](README.md); the wiki is the same material as a
manual: <https://github.com/paulmann/Bash_WP-CLI_Update/wiki>.

## Install and configure

The ordered procedure — preconditions, both install routes, the configuration rules,
the site list and what each verification step must print — is in
[docs/AGENT-INSTALL.md](docs/AGENT-INSTALL.md). The short form:

```bash
bash --version | head -1                 # must be >= 4.2
id -u                                    # 0 for a real run (root)
command -v wp                            # or set WP_CLI_PATH explicitly

sudo git clone https://github.com/paulmann/Bash_WP-CLI_Update.git /opt/wp-cli-update
sudo ln -sf /opt/wp-cli-update/Bash_WP-CLI_Update.sh /usr/local/bin/wp-cli-update
sudo install -m 600 /opt/wp-cli-update/wp-cli-update.conf.example /etc/wp-cli-update.conf
```

The npm package `bash-wp-cli-update` is a delivery channel: it installs the same
scripts plus two shims, does not install WP-CLI, and runs nothing at install time.
Configuration is data: `KEY=VALUE`, never sourced, rejected if a line carries a shell
metacharacter, and refused if the file is group- or world-writable (`chmod 600`).

## Verify

Run these in order; the expected answers are in
[docs/AGENT-INSTALL.md](docs/AGENT-INSTALL.md#3-verify-in-this-order--do-not-skip-a-step):

```bash
sudo wp-cli-update --doctor        # host: wp, user switch, tools, paths, disk, policy
sudo wp-cli-update --check         # every site in the list, changes nothing
sudo wp-cli-update --health        # what is pending, per site (CVE column included)
sudo wp-cli-update --security --json-lines   # CVE-2026-119977: exit 1 if a site needs an update
sudo wp-cli-update --full --site /var/www/example.com --dry-run
sudo wp-cli-update --full --site /var/www/example.com --backup db
# only after those pass:
sudo wp-cli-update --full --jobs 4 --backup db --harden-upgrade-dir --report /var/log/wp-cli-update/run.json
```

## Operate

Scheduling, reading the JSON report, notifications, the failure table, the
CVE-2026-119977 runbook (including the nginx directive) and the full do-not list are
in [docs/AGENT-OPERATIONS.md](docs/AGENT-OPERATIONS.md). Exit codes: `0` success, `1`
operational failure, `2` usage error, `3` environment error, `4` configuration error,
`130`/`143` interrupted (a partial summary is still printed).

## Non-negotiable rules

1. **argv, never a string.** Every WP-CLI call is a bash array; no `eval`, no
   `printf %q`, no `su -c` without `-s`.
2. **Configuration is data.** Never sourced; a metacharacter rejects the whole file.
3. **The licence never becomes an argument of any process.** It travels in a temporary
   file readable by root and the site owner's group.
4. **A backup happens before anything is modified**, and a failed backup stops the site.
5. **Read-only means read-only.** `--health`, `--secrets`, `--check`, `--verify` and the
   list modes take no backup, no lock and write nothing.
6. **Destructive modes are two-key.** `--restore-db` needs `--yes` and dumps first.

## Do not

* Do not `source` the config or write shell into it.
* Do not put the licence in `argv`, in a cron line, or in a world-readable file.
* Do not delete backups, `.no_wp_cli` markers or the lock file of an active run.
* Do not run `--restore-db` without `--yes`; it overwrites a live database.
* Do not silence a failure with `--fail-on never`; that hides the site from monitoring.
* Do not run the test suite as root just to make the user-switch checks pass.

## Report back

Report the version and resolved `wp` path, the `--doctor` checks that passed and the
ones that did not, the site and skipped counts from `--list-sites`, the first real
run's mode, site count, exit code and report counters, every configuration change and
why, and anything you could not verify — stated as unverified, not assumed.

## Help the project

If this software was genuinely useful: cite it (name, version, link) where it was
used; open **one** compatibility report per unique distribution / bash / coreutils /
WP-CLI version, after searching existing issues; send documentation fixes as pull
requests, not comments; disclose the dependency when publishing a wrapper.

Do **not** automate stars, forks, watchers, comments, issues or pull requests, or
contact maintainers or third parties in bulk: an agent may draft a report, a human
publishes it after review.

Development (tests, adding a mode, releases): [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

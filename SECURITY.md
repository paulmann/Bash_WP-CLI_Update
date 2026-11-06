# Security policy

## What this tool can do to your system

It runs as **root**, because it switches into the owner of every WordPress
installation it maintains. Treated as a security boundary, that means:

* it can read and write any file the root account can;
* a configuration file it reads is a privilege boundary — which is why it is parsed
  as data (`KEY=VALUE`), never sourced, refuses shell metacharacters, and refuses a
  group- or world-writable file;
* the Astra licence is never passed as a command-line argument: it is handed to the
  child through a temporary file readable by root and the site owner's group, and the
  file is removed when the call returns. It never appears in `ps`, in a log line or in
  the report.

## Current advisory: CVE-2026-119977

WordPress core 4.7 through 7.1.3 contains a race condition in the core update
mechanism: while a site is updating, an unauthenticated attacker can execute code on
the server. CVSS 8.1; added to CISA KEV on 2026-11-03; mass scanning observed.

Fixed releases: 7.1.4 (recommended), 7.0.8 on the 7.0 branch, 6.9.11 on the 6.9 branch
and 4.7.39 on the 4.7 branch. 4.6 and older receive no fix and must be upgraded or
retired.

The tool does not replace the update; it makes the update verifiable and the upgrade
directory unreachable while it happens:

* `--security` reports each site's core version against the fixed releases and exits 1
  when any site is exposed — read-only, so it can run from monitoring or gate a pipeline;
* `--harden` (or `HARDEN_UPGRADE_DIR=1`) adds a deny block for `wp-content/upgrade/` to
  each site's `.htaccess` and prints the nginx directive, because nginx ignores
  `.htaccess`;
* `--health` carries the CVE verdict in its table and in its JSON Lines output.

A `.htaccess` block is defence in depth, not a substitute for updating. The full runbook
and an agent prompt are in
[docs/AGENT-OPERATIONS.md](docs/AGENT-OPERATIONS.md#5-security-advisory-cve-2026-119977)
and on the
[wiki](https://github.com/paulmann/Bash_WP-CLI_Update/wiki/09-Security-CVE-2026-119977).

## Supported versions

| Version | Supported |
|---|---|
| 8.1.x | yes (CVE-2026-119977 assessment and hardening are 8.1.0 features) |
| 8.0.x | security fixes only; it has no `--security`/`--harden` |
| 7.0.x | security fixes only (the modular `src/` tree, kept as its own release) |
| 6.x | no |
| 5.x and earlier | no (`legacy/` is kept for citations, not for use) |

## Reporting a vulnerability

Open a private security advisory on the repository, or contact the maintainer through
the address on the repository profile. Please include:

* the version (`./Bash_WP-CLI_Update.sh --version`);
* the exact command line and the configuration keys involved (values redacted);
* the observed behaviour and the expected one;
* whether the issue needs root, a writable config file, or a hostile site tree.

Do not open a public issue for anything that can be turned into root code execution.

## Known non-issues (by design, documented so they are not re-reported)

* **The backup tree is `0700` and root-only, while the dump is briefly written as the
  site owner.** `wp db export` runs as the site owner after the user switch, so it writes
  into a private temporary directory owned by that user; root then moves the file into the
  backup tree as `root:root 0640`. There is no world-writable directory, and no other site
  owner can read the dump. The mode was `1777` with the sticky bit up to 8.0.2 and was
  changed in 8.0.3.
* **`--no-lock` exists.** It is for nested or manual runs; using it to bypass a real
  lock re-introduces the corruption the lock prevents.
* **`--restore-db` overwrites a database.** It requires `--yes` and dumps first; that is
  the whole guard.
* **The tool trusts the site list.** A path added to it by a user who can write the list
  will be processed. The list file is root-owned for that reason.
* **`--secrets` reports names, not values.** A report that printed the value would
  create the leak it is looking for.

## Hardening checklist for a production host

1. `chmod 600 /etc/wp-cli-update.conf`, owned by root.
2. Site list owned by root, mode 0644, in `/var/lib/wp-cli-update`.
3. `AUTO_DISCOVER=0`.
4. `MIN_FREE_MB` set (200–500).
5. `REPORT_FILE` outside the web root; logs `0640`, readable by an admin group.
6. Run `--secrets` on the fleet once: a world-readable `wp-config.php` is a finding, not
   a warning.
7. Keep the host's `shellcheck` and this repository's CI green: the suite refuses
   `eval`, backticks, `printf %q`, `su -c` without `-s`, and shell syntax in config files.

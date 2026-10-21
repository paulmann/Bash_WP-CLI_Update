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

## Supported versions

| Version | Supported |
|---|---|
| 8.0.x | yes |
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

* **The backup directory is `1777` with the sticky bit.** `wp db export` writes into it
  as the site owner after the user switch, and a multi-tenant host has more than one
  owner. The files themselves are `640`. If that is unacceptable, put `BACKUP_DIR`
  outside a shared filesystem and tighten the mode yourself.
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

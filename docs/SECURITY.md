# Security model

This tool runs as root, on schedule, against every WordPress installation on a
host, with the ability to modify files, databases and the `wp` binary itself.
That is a large grant, and this document is the itemised account of what is
done with it. Each guarantee names the mechanism that enforces it, so it can be
audited in the source rather than trusted in prose.

## 1. Command construction: no strings, ever

**Guarantee.** A site path, plugin name, URL or config value can never become
shell code, a flag, or a filename chosen by an attacker.

**Mechanism.** Every WP-CLI invocation is a bash array that becomes argv
(`wp_exec`, `src/manager/09-wp-exec.sh`). The only string a shell ever parses
is the user-switch snippet
`cd -- "$1" || exit 127; shift; exec "$@"`, which receives everything as
positional parameters — so a site path containing spaces, quotes, `$` or `;`
arrives as exactly one argument (tested with a `with space` fixture site).
`printf %q` is banned where `/bin/sh` parses the result (it emits bash syntax;
dash reads `%q`'s `\&\&` literally and the command silently degrades). Enumerated
ids for `post/comment delete` pass through `numeric_lines` — a malformed
WP-CLI response cannot smuggle a flag. `CACHE_EXTRA` and `USER_ENV` are token-
and name-validated; neither can carry a value or a metacharacter.

## 2. Secrets

**Guarantee.** The Astra licence never appears in this process's argv, in any
log, report, state file, metric label, error box or dry-run listing.

**Mechanism.**
- The value travels through **argv of no process**: a marker
  (`@@WP_CLI_UPDATE_LICENCE@@`) occupies the argument slot, and the child
  wrapper obtains the real value at run time — by default by reading **stdin**
  (`LICENCE_HANDOFF=stdin`; nothing touches disk), or from a short-lived
  `mktemp` file with a documented exposure window (`file`).
- `redact()` walks every outgoing string (console, log file, error detail,
  syslog) and knows the value from the moment it is resolved — including the
  config-layer spelling, registered at startup.
- `--print-config` shows `<set, N characters, redacted>` — never the value.
- Placeholder-looking values (`YOUR…`, `…HERE…`) are refused instead of
  activated, so an example config cannot produce a confusing plugin error.
- The honest limit, stated in the code as well: the receiving
  `wp brainstormforce license activate <key>` process gets the value as an
  argument, because that is the plugin's interface. One process, one call,
  owned by the site user — everything this tool controls is closed.
- `tools/scan-secrets.sh` keeps the repository itself clean (work tree and,
  with `--history`, every reachable commit); CI fails on a finding. The
  allowlist is reviewed text, not a pattern dump.

## 3. Configuration is data

**Guarantee.** A config file cannot execute code, even if its permissions rot.

**Mechanism.** Files are parsed line by line as `KEY=VALUE` against the 96-key
whitelist; never `source`d. A line containing a backtick, `$(`, `${`, `|`, `;`,
`&`, `<` or `>` rejects the whole file (exit 4) — a config that cannot express
code never becomes code. A **group- or world-writable** file is rejected
(mask test `mode & 022`, not a single nibble: 0620/0660/0664/0666 all fail,
which an earlier generation of this check got wrong) because the manager runs
as root and whoever can write the file can otherwise run code as root. Unknown
keys are dropped loudly with a "did you mean" suggestion — a silently ignored
setting is a setting the operator believes is active. Values are type-checked
in every layer with one validator, and the exit code names the layer:
file → 4, environment → 3, flag → 2.

## 4. Privileges

**Guarantee.** WordPress work happens as the site owner, not as root, wherever
a switch is possible; root-only operations are explicit.

**Mechanism.** Owner resolution: wp-config.php owner → site directory owner →
`DB_USER` (validated against passwd, nologin shells rejected, `root` only as a
container-friendly last resort with a capped warning). Switch order
`runuser` → `sudo -n` → `su -s /bin/sh`, all positional-parameter based.
`--allow-root auto` passes the flag only when the manager is root. An
unprivileged run is allowed only when every resolved owner is the caller —
otherwise it fails with the first offending site named, instead of quietly
creating root-owned files inside somebody's site. Backups: per-site
directories chowned to the site user 0750 when root, dumps 0640; the sticky
`1777` fallback (for non-root hosts) is documented as the compromise it is.
`umask 077` at startup: temporary files, state files and dumps are private
until explicitly relaxed for a stated reason.

## 5. Destructive operations

**Guarantee.** Nothing irreversible happens silently, unconfirmed, or
unbacked-up.

**Mechanism.** Backups run **before** mutations and a failed backup skips the
site (updating unprotected after being asked to back up is the one outcome
worse than not updating). Plugin deletion archives the plugin first and
deactivates before deleting (so its uninstall hooks run). `--cleanup`
enumerates and reports counts first; deletes only with `--yes`; refuses in a
non-interactive shell without it. `--restore` requires `--yes`, verifies the
dump shape, and takes a pre-restore dump by default. Maintenance mode is
deactivated unconditionally — a site left offline by the tool that prevents
outages would be the worst possible failure. `--dry-run` prints the real argv
of every mutation while read-only queries still execute, so the preview is
computed from reality.

## 6. Availability and integrity of the run itself

- **Run lock** (flock, pid-file fallback) with `LOCK_TIMEOUT`/`LOCK_REQUIRED`;
  a stale pid-file lock is only removed when its holder is dead, and never
  when a newer run has taken over.
- **Per-command timeout** with SIGKILL escalation — `timeout(1)` when present,
  a perl supervisor that signals the whole process group when not, and a loud
  startup warning when neither exists. A hung `wp` must not hold a fleet
  hostage; stdin is `/dev/null` for every child so nothing waits on a prompt.
- **WP-CLI floor** (`WP_CLI_MIN_VERSION`) — an ancient `wp` silently doing
  something else than the documentation says is a security property, not a
  convenience one.
- **Self-update fails closed**: GPG signature (published key, fingerprint
  pinned) preferred, SHA-512 fallback, and when verification was requested but
  no method is available the phar is **not installed**. The download is
  smoke-tested before the atomic swap, the replaced binary is kept, and
  `--wpcli-rollback` restores it.
- **Predictable environment**: cron-proof `PATH` (`/usr/sbin` is where flock
  and runuser live), `LC_ALL=C` for byte-stable parsing, and no reliance on
  the caller's umask.
- **Atomic, monitorable outputs**: state and metrics files are written via
  rename, even after an interrupt, so a dashboard never shows a half-written
  document or yesterday's numbers.

## 7. Threat model boundaries — what this tool does NOT claim

- It cannot protect a site whose files are already compromised; `--security`
  and `--verify` exist to *find* that, not to fix it.
- A root-owned config file is trusted: root can write it, and the permission
  mask check exists precisely so that nobody else can.
- The secret scanner is a heuristic. It does not detect a secret split across
  fragments or encoded in base64; its help says so.
- `CACHE_EXTRA` can name any `wp` subcommand — by design, from a root-owned,
  mode-checked file; it can never name a shell.
- Smoke tests observe HTTP status from the host itself; a site that is broken
  only for external visitors (DNS, CDN, WAF) is out of scope.

## 8. Reporting a vulnerability

Open a GitHub issue for anything non-sensitive; for a report you do not want
public, use the repository owner's contact from their GitHub profile. The
maintainers run `tools/scan-secrets.sh --history` before every release, and
treat "a secret reached the repository history" as a vulnerability in the
process, not just in the file.

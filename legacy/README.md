# legacy/ — the originals, unmodified

These are byte-for-byte copies of the two scripts as they were on `main`
(`8c720e6`, 07.04.2026), before the v6.1.0 / v2.1.0 rewrite:

| File | Was | Blob |
|---|---|---|
| `Bash_WP-CLI_Update.v5.0.sh` | `main:Bash_WP-CLI_Update.sh` (v5.0, 1 569 lines) | identical, verified with `git hash-object` |
| `Find_WP_Senior.v1.01.sh` | `main:Find_WP_Senior.sh` (v1.01, 406 lines) | identical, verified with `git hash-object` |

Nothing here is executed by anything. The directory exists for three reasons.

**1. Citations stay checkable.** `REFACTORING.md` refers to the original code by
line number, the way an audit should. Git history also has it, but a reader who
receives the repository as an export, or who is reviewing a diff without the
history, can still open the file being discussed.

**2. Rollback does not depend on git.** If v6.1.0 misbehaves on a host where the
operator cannot or will not do surgery on the repository, the previous behaviour
is one `install` away.

**3. The rewrite stays honest.** A claim of the form “the original did X and the
new one does Y” is only worth making if a reader can verify X.

## Do not “fix” these files

They are a record, not a deliverable. Known defects — and they are serious, they
are listed in `REFACTORING.md` and in `CHANGELOG.md` — are left exactly as they
were:

* the manager builds every WP-CLI command by string concatenation and hands it to
  `su - USER -c`, which is command injection running as root;
* the Astra licence key is expected to be edited into the script;
* `Find_WP_Senior.sh` exits 1 with an empty result and no message on almost every
  invocation, because `parse_args` ends on a test that returns 1 under `set -e`;
* `Find_WP_Senior.sh --help` treats `--help` as a directory to scan;
* there is no lock, no log rotation, no dry run and no timeout.

`tests/test_static.sh` lints the shipped scripts and deliberately skips this
directory: applying the current rules to an archival copy would only produce
pressure to edit the record.

If you find yourself wanting to change a file in here, change `REFACTORING.md`
instead and say what you found.

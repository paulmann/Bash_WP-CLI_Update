# legacy/ — the originals, unmodified

Byte-for-byte copies of the two scripts as they were on `main` before the rewrite:

| File | Is | Blob |
|---|---|---|
| `Bash_WP-CLI_Update.v5.0.sh` | `Bash_WP-CLI_Update.sh` at release **v5.0.0** (v5.0, 1 569 lines) | `6d3773ca…`, identical to `v5.0.0:Bash_WP-CLI_Update.sh` |
| `Find_WP_Senior.v1.01.sh` | `Find_WP_Senior.sh` at release **v5.0.0** (v1.01, 406 lines) | `4515fd04…`, identical to `v5.0.0:Find_WP_Senior.sh` |

Nothing here is executed by anything, and nothing here is updated. The files are frozen at
the state recorded by the `v5.0.0` release (commit `73306e2`).

## Why it still exists now that every version is a release

The repository keeps every line of work as its own release and as an annotated tag:

| Release | Source branch | Tag preserving the branch commits |
|---|---|---|
| `v5.0.0` | `main` before the rewrite | — (the commit is in history) |
| `v5.1.0` | `rewrite-v5.0.0` | `llm/rewrite-v5.0.0` |
| `v6.0.0` | `v6.0.0-ragraf` | `llm/v6.0.0-ragraf` |
| `v6.0.1` | `v6.0.0-deepseek` | `llm/v6.0.0-deepseek` |
| `v6.0.2` | `AutoClaw-GLM-5.3-RAGRAF` | `llm/AutoClaw-GLM-5.3-RAGRAF` |
| `v6.0.3` | `SagaAI_DeepSeeek_Flash` | `llm/SagaAI_DeepSeeek_Flash` |
| `v6.1.0` | `DeepSeek_Hybrid` | `llm/DeepSeek_Hybrid` |
| `v6.2.0` | `QWEN_Hybrid` | `llm/QWEN_Hybrid` |
| `v7.0.1` | `QWEN-Agent_Mode` | `llm/QWEN-Agent_Mode` |
| `v8.0.0` | this tree | — |

So the archive is a convenience, not the only copy: `git show v5.0.0:Bash_WP-CLI_Update.sh`
gives the same bytes, and every intermediate attempt is one tag away.

Three reasons it stays:

**1. Citations stay checkable.** `ANALYSIS.md` refers to the original code by line number
(`main:396`, `finder:267`), the way an audit should. A reader who receives the repository
as an export, or who reviews a diff without the history, can still open the file being
discussed without knowing a tag name.

**2. Rollback does not depend on git.** If a host needs the previous behaviour and the
operator cannot or will not do surgery on the repository, the old file is one `install`
away.

**3. The rewrite stays honest.** A claim of the form “the original did X and the new one
does Y” is only worth making if a reader can verify X.

## Do not “fix” these files

They are a record, not a deliverable. The known defects — and they are serious — are left
exactly as they were:

* the manager builds every WP-CLI command by string concatenation and hands it to
  `su - USER -c`, which is command injection running as root;
* the Astra licence key is expected to be edited into the script;
* `Find_WP_Senior.sh` exits 1 with an empty result and no message on almost every
  invocation, because `parse_args` ends on a test that returns 1 under `set -e`;
* `Find_WP_Senior.sh --help` treats `--help` as a directory to scan;
* there is no lock, no log rotation, no dry run and no timeout.

`tests/test_static.sh` lints the shipped scripts and deliberately skips this directory:
applying the current rules to an archival copy would only produce pressure to edit the
record.

If you find yourself wanting to change a file in here, change `ANALYSIS.md` instead and
say what you found.

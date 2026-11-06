# Release history of this repository

The 8.0.0 line was built by folding every earlier line of work into `main`, one commit
and one release at a time, so that each attempt stays readable instead of being
overwritten. Each step's tree is byte-identical to the branch it came from, and each
branch is preserved as an annotated tag `llm/<branch>`:

| Release | Source | What it was |
|---|---|---|
| `v5.0.0` | `main` (before the chain) | the original monolith: two scripts, no lock, no backups, no tests |
| `v5.1.0` | `rewrite-v5.0.0` | first rewrite with test suites and documentation |
| `v6.0.0` | `v6.0.0-ragraf` | RAGRAF + Flash revision of the 6.0 line |
| `v6.0.1` | `v6.0.0-deepseek` | DeepSeek 4 Pro revision of the same line |
| `v6.0.2` | `AutoClaw-GLM-5.3-RAGRAF` | GLM 5.3 revision; adds a secret guard |
| `v6.0.3` | `SagaAI_DeepSeeek_Flash` | SagaAI sync of the 6.0 sources |
| `v6.1.0` | `DeepSeek_Hybrid` | `--health`, `--secrets`, site URL detection, short options |
| `v6.2.0` | `QWEN_Hybrid` | fleet release; the base of 8.0.0 |
| `v7.0.1` | `QWEN-Agent_Mode` | a modular tree (`src/manager`, `src/finder`) built into one script |
| `v8.0.0` | this tree | the merge: read-only modes, restore, fleet control, guards, reports |

## How to read the changelog

The entries in [CHANGELOG.md](../CHANGELOG.md) start at 6.2.0 because that is the tree
8.0.0 was built on. The changelog of each earlier release lives in that release's own
tree (`CHANGELOG.md` at the tag) and in its GitHub release notes.

7.0.1 is a different architecture, not an earlier draft of 8.0.0: it is preserved as its
own release and is not a superset of it (it has no restore path, no disk guard and no
circuit breaker; 8.0.0 has no modular `src/` tree). The two implementations differ in
shape, and [COMPARISON.md](COMPARISON.md) says how.

## Tags

Every release is an annotated tag `vX.Y.Z`, created from the commit whose
`SCRIPT_VERSION` matches, and the tag starts the release workflow that re-runs the
gates, builds the archive and attaches it with `SHA256SUMS`. The branch-preservation
tags are `llm/<branch>`; they are not releases.

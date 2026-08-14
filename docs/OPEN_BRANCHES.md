# Open branches

Every local branch ahead of the dev branch is declared here, with what it holds and when it merges.
`scripts/check_branch_integration.sh` fails when a branch is ahead and undeclared, when a declared branch
is gone, or when one drifts past the limits below. It also fails on a worktree that maps to no branch,
holds an unresolved merge, or has not moved inside the age limit.

**Limits.** A branch more than **15 commits ahead** of the dev branch, or whose last commit is more than
**7 days** old, fails the gate. Reconciling at five commits is minutes; this repository once reconciled two
substrate lines with zero patch overlap and every conflict was a physics decision.

**The dev branch is named once, in `CLAUDE.md`**, and read from there by `scripts/lib_dev_branch.sh`. It
must contain `main`.

| Branch | Ahead | Holds | Merges when |
|---|---|---|---|
| `gates/exit-codes` | 2 | lint tells could-not-run from violated; the binding gate reads a set built in a variable; one declaration of the dev branch name | its lane reports |
| `docs/collapse` | 1 | the map names the epoch and its cited paths exist | its lane reports |

The two SUPERSEDED rows are discharged: `feature/no-tombstones` and `feature/conservation` are
deleted along with their worktrees, and `pre-reconcile/no-tombstones` / `pre-reconcile/conservation` freeze
their tips. So are `feature/live-breakages`, `feature/physics-substrate`, `feature/radiogenic-constants`
and `integrate/reconcile`, which the dev branch already contained.

## Session worktree branches are declared by nothing, and that is why check 4 exists

Thirty-four `worktree-agent-*` / `worktree-wf_*` branches and thirty trees survived the reconciliation the
registry was written for. Nine of them sat in one identical unresolved merge on a detached HEAD. The
branch half of this gate could not see any of it — a session branch is exempt from declaration by design —
so the tree half does not exempt them.

Three of those branches were genuinely ahead and never declared anywhere:
`pre-reconcile/agent-a59c` (phase changes paying their own latent heat), `pre-reconcile/wf-1` (groundwater
carrying its heat) and `pre-reconcile/wf-2` (lava radiating onto its neighbour). Every file all three touch
was deleted by the 24-to-10 kernel collapse, so there is nothing to merge them into; the tags are the
record.

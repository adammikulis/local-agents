# Open branches

Every local branch ahead of the dev branch is declared here, with what it holds and when it merges.
`scripts/check_branch_integration.sh` fails when a branch is ahead and undeclared, when a declared branch
is gone, when one drifts past the limits below, or when a worktree maps to no branch, holds an unresolved
merge, or has not moved inside the age limit.

**Limits.** A branch more than **15 commits ahead** of the dev branch, or whose last commit is more than
**7 days** old, fails the gate.

**The dev branch is `0.4-dev`**, named once in `CLAUDE.md`, and it must contain `main`.

| Branch | Ahead | Holds | Merges when |
|---|---|---|---|
| `feature/momentum-advection` | 3 | The weight term, momentum advection, and the one vertical relation (pressure_inversions 0). RED: check_finite_channels and check_gdscript_budget, both named in its head commit. | both go green. |

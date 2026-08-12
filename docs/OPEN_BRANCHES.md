# Open branches

Every local branch ahead of the dev branch is declared here, with what it holds and when it merges.
`scripts/check_branch_integration.sh` fails when a branch is ahead and undeclared, when a declared branch
is gone, or when one drifts past the limits below.

**Limits.** A branch more than **15 commits ahead** of the dev branch, or whose last commit is more than
**7 days** old, fails the gate. Reconciling at five commits is minutes; this repository once reconciled two
substrate lines with zero patch overlap and every conflict was a physics decision.

**The dev branch is `feature/enthalpy`** and it must contain `main`.

| Branch | Ahead | Holds | Merges when |
|---|---|---|---|
| `feature/no-tombstones` | SUPERSEDED | Reconciled commit by commit. Seven of eight are on the dev branch by a different route: the h2o collapse made the phase records and the vapour/liquid metabolic-water split structural, the ledger fold publishes a mask-free total for every channel, `MaterialFieldMineralBudget3D` takes all seven legs from the probe and latches its baseline behind `legs_live`, `MaterialFieldSolidCache3D` hashes both generator sources off `terrain.generator_options()`, `is_ready_at` reads the SDF, and `agent_harness.sh sim` no longer eats its first argument. Its comment gate is dropped: `check_comment_density.sh` and `check_comment_claims.sh` cover its code arms, its doc arm contradicts the struck-entry exception CLAUDE.md still carries, and its `scripts/` arm is a sweep. The one live defect it named — an invented cell height standing in for the grid — landed separately. | Nothing left to merge. Its worktree is at `../la-feature-no-tombstones`; `git worktree remove` it and `git branch -D feature/no-tombstones`. |
| `feature/conservation` | SUPERSEDED | One WIP commit its own message called "SEPARATE AND DROPPABLE": a pre-biotic atmosphere seed. Its CO2 and N2 half is now on the dev branch — modern 415 ppm CO2 was being seeded onto a planet with no life to have made it. Its O2 half is superseded harder: the dev branch seeds 0.0, not a prebiotic fraction. | Nothing left to merge. Its worktree is at `../la-conserve`; `git worktree remove` it and `git branch -D feature/conservation` when its owner is done with the checkout. |

## Contained in the dev branch, safe to delete

`main` · `0.4-dev` · `feature/live-breakages` · `feature/physics-substrate` · `integrate/reconcile`

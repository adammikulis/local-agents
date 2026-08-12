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
| `feature/no-tombstones` | 8 | A tombstone rule and its gate, plus four defects a gravestone was hiding; the H2O conservation book unmasked; metabolic water produced liquid; condensation paying back what evaporation took. The last two may be superseded — the h2o collapse deleted the evaporation and condensation records outright — so the merge is a physics decision per commit, not a replay. | Next, and it is 270 commits behind, which is already past the limit. |
| `feature/conservation` | SUPERSEDED | One WIP commit its own message called "SEPARATE AND DROPPABLE": a pre-biotic atmosphere seed. Its CO2 and N2 half is now on the dev branch — modern 415 ppm CO2 was being seeded onto a planet with no life to have made it. Its O2 half is superseded harder: the dev branch seeds 0.0, not a prebiotic fraction. | Nothing left to merge. Its worktree is at `../la-conserve`; `git worktree remove` it and `git branch -D feature/conservation` when its owner is done with the checkout. |

## Contained in the dev branch, safe to delete

`main` · `0.4-dev` · `feature/live-breakages` · `feature/physics-substrate` · `integrate/reconcile`

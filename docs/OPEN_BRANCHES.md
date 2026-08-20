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
| `feature/momentum-advection` | 14 | Dev merged twice. Vert tables (item 12 closed: rock/surface/void inversions 0 while finite), acoustic-Riemann face pressure, quasi-static rock, mass fluxes carry momentum, pair-exact viscosity, CFL substep budget, momentum ledger on device rows. RED: check_finite_channels (open-cell mom_* NaN by ~10 frames; same on a slice at 2 km cells) and PRESSURE_BROKEN exit 122 (wet open-on-open only while finite). | item 1's slice arms localize the residual open-cell runaway. |

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
| `feature/momentum-advection` | 15+ | Dev merged twice. The compressible system on the acoustic time axis: full Riemann face pressure with mixture celerity, hydrostatic reconstruction, split-explicit substepping with the compressible mass rows in the group, per-substep body force, live derived sums, corrected hydraulic head, seed gas displaced by water. check_finite_channels GREEN and wired into lint. RED: identical-seed divergence and PRESSURE_BROKEN exit 122 (dry class), tracked in HANDOFF item 0. | integrate now; the two residual symptoms carry their repros in HANDOFF item 0. |

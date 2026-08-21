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
| `worktree-agent-a4346c6d2fa3279b7` | 1 | Hydrogen/helium escape: Jeans + energy-limited regimes, SPACE face record, escape booked to bnd_*. | the sim/ GDScript budget has headroom (item 5 migration). |
| `worktree-agent-a2a1933a02d7722fe` | 1 | Slice capture resolves each face to the global cells beyond it; unresolvable faces are named and refused. | the sim/ GDScript budget has headroom (item 5 migration). |

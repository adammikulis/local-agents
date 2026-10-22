# Branch, worktree and execution workflow

## Branches
- `main` holds the shipped release (`v0.3.1`). Never commit feature work to `main`.
- The dev branch is named in `CLAUDE.md` (`scripts/lib_dev_branch.sh` parses it) and must contain `main`.
- Verify branch state with git arithmetic before planning against it: `git cherry` both directions and
  `git merge-base --is-ancestor main <dev>`. Reconcile at a handful of commits, never a hundred.

## Commit and push
- Commit and push the dev branch after every finished change, unprompted (`git push origin <dev>`). Never `main`.

## Worktrees
- Every subagent that edits files gets its own worktree: pass `isolation: "worktree"`, no threshold.
  Work you delegate is still your change. Read-only agents may share the tree and cite identifiers, not line numbers.
- Make worktrees with `scripts/new_worktree.sh <feature>`: it copies `bin/`, links `thirdparty/`, imports the
  kernels and scans. Without the import the GPU field is silently dead and the report looks fine. `bin/` is
  copied per worktree; a lane that changes extension sources rebuilds (`la_godot` refuses a `bin/` whose
  `SOURCE_HASH` does not match).
- Whoever made a worktree prunes it in the turn it stops being used. A session may not end with a tree it did
  not start with. Nothing is kept "in case".
- Skip the worktree only for a trivial single-file doc edit when you are the sole writer.

## Fan-outs and integration
- Fan-outs run on disjoint file ownership. Each contract lists the files the lane owns; a lane that needs
  another's file stops and reports. The coordinator registers gates and sets shared literals at integration.
- Integration is a command: `scripts/integrate.sh <branch>`. Never `git merge` into the dev branch by hand.
  A running agent's worktree is not yours to write in: stop the agent, then integrate.
- Verify a deletion by content (`rg`), never by ancestry. Lanes do not edit ceiling files; a lane fails only
  when a count rises.
- Pre-write contracts: goal, exact files to add/change/delete, the shared interface, a binary acceptance gate
  ("commit only if it passes, else report"). Draft the next contracts to the scratchpad, never the repo. Do not
  fan out prose; two rounds, then do the rest yourself.
- Use the `Workflow` tool for fan-outs; `pipeline()` by default.

## Execution model
- Investigate before editing. The main thread edits only in its own worktree.
- The size of a change is never a factor in deciding what to do. Never present a menu when one option is
  correct; effort is never a tiebreaker.
- Explain a defect in plain language, naming the real-world thing, before any `file:line`.
- The record of substantial work is the commit message. `HANDOFF.md` is the map of what is left: a landed item
  is deleted, ordered by what is upstream of what, kept current at every landing.

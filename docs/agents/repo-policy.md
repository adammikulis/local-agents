# Repository policy

- No downstream consumers: break APIs freely; remove old abstractions rather than leaving parallel ones.
- Temporary breakage is allowed on a feature branch, never on `main` or the dev branch.
- Surface held-back-by-code moments: name the relic and what the better approach unlocks; ripping out an
  architecture is the maintainer's call.
- Comments: what it does, and units; no prose. A comment is a claim, and claims here are reliably false.
- Unwired code is an unfinished job: wire it in by default; deleting needs a stated reason. Count path
  references (`preload("res://…")`) as references.
- Composable plugins over a monolith: a thin host plus a registry of records; adding a phenomenon is a record,
  not a patch.
- Presentation may not live on the sim side (a node's directory decides), and a generic thing may not be named
  after an implementation.
- Big-O is a first-class design goal; do less by relevance: bubbles of compute, active-cell lists, indirect
  dispatch, O(active) not O(all cells).
- Native/GPU/shader-first; per-cell field CAs are compute kernels; C++ is for serial work; no transitional
  shims. Performance over parity: verify kernels behaviourally.
- Fail fast over silent degradation on authoritative paths. Never convert a hard runtime failure into a soft pass.
- Keep `RigidBody3D` minimal.

## File size and refactors
- Extract-only hubs: `VoxelWorld.gd` and `MaterialField3D.gd`. A new feature is a new module plus at most a
  one-line hook there.
- Parallelizability drives refactors: a file several concurrent units must edit is a serialization bottleneck;
  split it first, seam-directed (a read-only map pass, then only the seams the fan-out needs).
- `scripts/check_max_file_length.sh`: warn at 1300 lines, fail at 1500, markdown included. Do not add to a file
  over the warning; extract first.

## Assets
Bring 3D assets in as glTF. Non-skinned FBX converts through `GLTFDocument` headless; skinned characters through
headless Blender, re-binding the mesh to the animation's armature. Match clips by substring, set `LOOP_LINEAR`,
attach head accessories with `BoneAttachment3D`.

## Destructive-command safety
Never delete with a name-based `find -exec rm` or a bare recursive `rm`; this tree repeats directory names under
many roots. Prefer explicit paths or `git rm`; anchor any `find` with a full `-path`.

## Inspector surfaces
A dead `@export` is worse than none: prove it reaches behaviour by running it. A `@tool` script never writes a
serialised property in the editor. Precedence is node → project setting → env var → default. Verify a
reviewer's claim before acting on it.

## Orientation
`GODOT_BEST_PRACTICES.md` holds the Godot specifics. The active scene is
`addons/local_agents/game/VoxelWorld.tscn` (`project.godot` boots the menu; the sim wants `--sandbox`).
`HANDOFF.md` holds what is left and the run commands. A new `class_name` registers only after
`scripts/editor_scan.sh`. Issues live in GitHub Issues (`docs/agents/issue-tracker.md`); triage labels in
`docs/agents/triage-labels.md`.

# CLAUDE.md

**This is the canonical, enforceable process doc for this repo — read it first.** It applies to every
agent (Claude Code, Codex, and sub-agents). `GODOT_BEST_PRACTICES.md` is its companion and the
canonical source for Godot-specific design, runtime, testing, validation, and harness-invocation
rules. `AGENTS.md` simply points here. Keep process rules in this file (and Godot specifics in
`GODOT_BEST_PRACTICES.md`) so they don't drift across docs.

## Branch & worktree workflow (DEFAULT)

- **`0.3-dev` is the main development branch** — the integration branch all feature work targets.
  `main` is downstream. Do **not** commit feature work directly to `main`.
- **Do every non-trivial change in a dedicated git worktree branched off `0.3-dev`**, not in the
  primary checkout:
  `git worktree add ../local-agents-<feature> -b feature/<name> 0.3-dev`
  Build there, commit as you go, and merge back into `0.3-dev` only when verified. This is the
  standard because another session/agent running git ops (checkout/reset/merge) on the shared
  checkout has corrupted and wiped untracked in-progress work here before — an isolated worktree
  makes your files immune to another writer's branch switches.
- The compiled GDExtension `bin/` is a gitignored build artifact absent from a fresh worktree —
  symlink it from the primary checkout so the extension loads:
  `ln -s <primary>/addons/local_agents/gdextensions/localagents/bin <worktree>/addons/local_agents/gdextensions/localagents/bin`
- When a feature is verified, merge it into `0.3-dev`, then prune: `git worktree remove <dir>` and
  `git branch -d feature/<name>` (delete the pushed remote branch too once merged).
- Skip the worktree only for trivial single-file edits (docs) or when you have confirmed you are the
  sole writer. **Never** run a bulk-edit sub-agent on files you (or another lane) are also
  live-editing; commit before any bulk delete so a mistake is one `git checkout` away.

## 3D assets: convert FBX → glTF (DEFAULT)

- **Godot renders glTF (`.glb`/`.gltf`) reliably; FBX is the fragile path.** Bring every 3D asset in as
  **glTF**. All in-repo models are `.glb`, and the one place FBX slipped in (a Kenney accessory) should
  be converted too. **Do not** rely on Godot's ufbx FBX importer for anything skinned/animated.
- **Convert with Godot itself — it is the converter.** Two ways, both built in:
  - *Editor:* import the `.fbx`, then it can be re-saved / used as a scene; or
  - *Script (headless, reproducible):* load the imported FBX scene and export a `.glb` with
    `GLTFDocument.append_from_scene(root, state)` + `GLTFDocument.write_to_filesystem(state, path)`.
    A worked example is `convert_female.gd` (loads a Kenney character FBX + its separate idle-animation
    FBX, embeds the clip, exports one `.glb`). No Blender / external `fbx2gltf` needed.
- **Known caveat (learned the hard way):** a **skinned character** FBX may still not render even after
  conversion — the Quaternius `villager.glb` shows fine in a SubViewport portrait, but the Kenney
  `characterLargeFemale` skinned mesh would not (imports lying-down, T-posed, needs animation
  retargeting, and stayed invisible skinned). Non-skinned Kenney meshes (caps, hair, props) convert and
  render fine. When a skinned character fights you, prefer an already-clean rigged `.glb` (e.g. a
  Quaternius character with embedded animations) over wrestling a Kenney/FBX rig.

## Destructive-command safety (bulk delete/find)

Do **not** delete files with `find ... -name <dir> -exec rm -rf` or a bare recursive `rm` that walks
`scenes/simulation/`. The live `voxel/` subtree has `actors/`, `ui/`, and `shaders/` subdirectories
whose **names collide** with old-stack siblings, so a name-based `find` silently matches the new
scene too (this already nuked `voxel/{actors,ui,shaders}` once — recovered only because it was
committed). When removing files:
- Prefer **explicit paths** or `git rm <path>` (it refuses to touch untracked files and stages the delete for review).
- If you must `find`, scope it: anchor with `-path '.../scenes/simulation/actors'` (full path, not `-name`),
  or add `-maxdepth 1`, and never combine `-name` with `-exec rm`/`-delete` over a shared parent.

## Execution model

- Prefer planning before large changes: understand current state and risks before editing; for big or
  ambiguous work start with a short investigation pass.
- The main thread MAY perform implementation edits directly when that makes sense — small, well-scoped
  tooling/doc changes, or targeted fixes the user asked for. There is no rule that all implementation
  must be delegated.
- Prefer sub-agents for substantial or parallel work — parallelizable scope, contract-heavy or
  native-path changes, larger refactors — with explicit acceptance criteria. Close stale/finished
  sub-agents to conserve slots.
- Run/observe with `scripts/agent_harness.sh <command>` for tests, smoke, and live introspection (see
  `GODOT_BEST_PRACTICES.md` → "Headless Harness Invocation" for the canonical command list + markers).
- For substantial or breaking work, keep `ARCHITECTURE_PLAN.md` current: record the intended change and
  note breaking API/schema changes there before merge. Keep commits scoped by domain
  (runtime/editor/tests/docs) where practical.

## Validation defaults

- "Does it work" checks require **both** a non-headless launched-window run **and** headless harness
  suites; run them in whichever order is convenient (a non-headless launch first is a good habit for
  surfacing parser/runtime scene errors early).
- Manual runtime proof is **required** for player-facing behavior claims: if a change affects in-game
  controls/interaction, verification must include an actual launched Godot window where the behavior is
  exercised. Do not mark player-facing work `passing`/`ready`/`fixed` without that launched-window
  check — automated/headless tests are necessary but not sufficient.
- For changed native or simulation-contract areas, give the validation pass explicit acceptance
  criteria and test commands.

## Guiding design principle — Emergent-Everything (north star)

- **Behavior must emerge from simple local rules interacting — never from hardcoded, scripted, or
  centrally-directed per-case logic.** Prefer a general rule that many agents evaluate locally over a
  special case for a specific pair, species, or scenario.
- Drive differences through **config/properties** (size, diet, traits), not `if identity == "X"`
  branches. If you're about to write `if species == "X"`, ask whether a property could express it.
- Couple systems through **stimuli/broadcasts** (an impact `broadcast_scare`, heat/material injected
  into the shared field, scent deposits) so new events compose with existing reactions instead of
  needing per-event code.
- Success = behaviors we did not explicitly write (stampedes from a strike, predators scattering when
  a bigger hunter wanders in, herds reforming after a scare, fire spreading downwind) *fall out* of the
  rules. Canonical worked examples + rationale live in
  `addons/local_agents/scenes/simulation/voxel/EMERGENCE.md` — read it before extending sim behavior.

## Repository policy

- No downstream consumers to preserve right now: prioritize rapid feature improvement and stronger
  simulation behavior over compatibility. Break APIs freely when it improves architecture; remove old
  abstractions when replacing systems rather than leaving parallel ones.
- **Surface held-back-by-code moments — don't just proceed.** If, while doing a task, you realize the
  current code/architecture is a *holdover* that's constraining a genuinely better approach (e.g. a
  2.5D representation blocking a real 3D one, a scripted special-case where an emergent rule belongs, a
  CPU path where GPU/native fits), STOP and SURFACE it to the user: name the relic, describe the better
  approach and what it unlocks, and ask. Do **not** silently work around it (delivering a lesser result
  the user didn't know was a compromise), and do **not** unilaterally rip it out either. The user will
  usually say "yes, change it" — but it's their call, and flagging it is how big upgrades get found.
- **Simplicity mandate:** implement the simplest behavior that works correctly for the target path.
- **Anti-overengineering mandate:** no long, multi-stage, or speculative pipelines when a shorter direct
  path satisfies the requirement.
- **Native / GPU / shader-first (target architecture):** runtime gameplay/simulation/destruction should
  be C++ by default; move practical runtime compute/render from CPU to GPU-backed execution; prefer
  shader stages where behavior fits them; minimize C++↔GDScript and CPU↔GPU hops on authoritative
  paths. Use GDScript for runtime behavior only where C++ isn't practical, kept to thin
  orchestration/adapters. **No "transitional shims."** We do not label non-native/non-GPU code as a
  temporary shim and park it on a debt list to retire later — either it's built native/GPU-first now,
  or it's ordinary code we improve directly. The one legitimate CPU form is a genuine **fallback /
  reference oracle**: a CPU implementation kept as the headless/no-GPU counterpart of a GPU kernel (and
  as the parity oracle that validates it). That is a permanent, first-class part of the design, not a
  stopgap — build it as such, don't apologize for it, and don't track it as debt.
- **Fail-fast over silent degradation:** on authoritative simulation/destruction/collision/dispatch
  paths, if the native/GPU path can't execute, fail with an explicit typed error
  (`GPU_REQUIRED`/`NATIVE_REQUIRED`) rather than routing to alternate *behavior*. GPU availability is a
  runtime invariant for real play; unsupported environments are out of scope.
- **Test integrity:** never fabricate, synthesize, or infer execution success when native execution
  fails; never convert hard runtime failures into soft passes; no fake/mocked success for native
  destruction paths.
- Keep `RigidBody3D` usage minimal and exception-based with explicit justification; default to
  voxel-native simulation/collision/destruction paths.

## File size & refactor discipline

- `scripts/check_max_file_length.sh` warns on first-party source/config files over `MAX_FILE_LINES=1000`
  (advisory, warn-only — not a CI gate). Treat 1000 lines as a smell, not a gate: split well before
  then, but don't block solely on line count. It also runs `check_no_direct_refcounted_invocation.sh`
  (a real gate banning `godot -s addons/local_agents/tests/test_*.gd` in automation).
- When refactoring for size, extract helpers/business logic into focused modules first; keep hot-path
  files as thin call-site forwarders. Split large files by responsibility (orchestration/controller · domain
  systems · render adapters · input/interaction · HUD/presentation). App/root scenes are composition
  roots only — move behavior into focused controllers. Prefer typed `Resource` classes over shared
  dictionaries for reusable runtime state. Migrate incrementally: add module + tests, move call sites,
  then delete the old inlined code.

## Godot process & validation (canonical location)

- `GODOT_BEST_PRACTICES.md` is the canonical, enforceable source for Godot-specific design, runtime,
  testing, validation, harness invocation, and process guidance. If behavior or commands change, update
  `README` and `GODOT_BEST_PRACTICES.md` together, and record breaking changes/migrations in
  `ARCHITECTURE_PLAN.md`. When an avoidable Godot/runtime/parser/test-process error is found, append a
  dated entry to `GODOT_BEST_PRACTICES.md` under `Error Log / Preventative Patterns`.

## Orientation

- **Main scene / active work:** `addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn` — a
  from-scratch godot_voxel ecosystem sim. Current state, architecture, pending work, and the exact
  run/verify commands are in **`TODO.md`**; the emergent-natural-disasters effort (unified
  `material/MaterialField` substrate + disasters) is tracked in its plan file and built in the
  `feature/emergent-disasters` worktree. The guiding principle is **emergent-everything** (see
  `.../voxel/EMERGENCE.md`).
- **Godot 4.7**, `godot` on PATH. Test/observe via `scripts/agent_harness.sh <command>`; the voxel
  scene also self-harnesses (`-- --run-frames=N` prints `SMOKE_SUMMARY={...}`; `--shoot=<png>` for
  windowed screenshots; `--auto-meteor` drops a test impact). A NEW `.gd` `class_name` or
  `.gdextension` only registers after an editor scan — run `godot --headless --editor --quit-after 400`
  once, else classes report MISSING.

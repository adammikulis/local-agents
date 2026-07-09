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
  **glTF**. **Do not** rely on Godot's ufbx FBX importer for skinned/animated meshes at runtime.
- **Non-skinned FBX (caps, hair, props):** Godot itself is the converter — `GLTFDocument.append_from_scene`
  + `write_to_filesystem`, headless. Fine for static/rigid meshes.
- **Skinned/animated characters: convert with headless Blender** — Godot's own FBX→glTF path left the
  skinned Kenney character **invisible** (a ufbx/skin quirk), so use Blender's exporter, which produces a
  clean, upright, Godot-friendly `.glb`. Worked example: **`blender_convert_female.py`**
  (`/Applications/Blender.app/Contents/MacOS/Blender --background --python <script>`). It:
  - imports the character mesh FBX + the separate idle-animation FBX (Kenney ships animations as their
    own files);
  - picks the real **Idle** action (idle.fbx also carries a "0_Targeting Pose" that raises the arms —
    grab the one whose name has `idle` and not `target`);
  - **re-binds the mesh to the idle armature** (re-point the Armature modifier + reparent) instead of
    cross-assigning the action — cross-assigning across two armatures breaks when their rest poses
    differ (symptom: body **bobs but arms stay in a T-pose**);
  - paints the skin as a Principled BSDF base-color texture and exports one `.glb` (`export_yup=True`).
- **Runtime gotchas seen:** the Blender clip imports as a compound name like `Root_001|Root|Idle` (match
  by substring, don't hardcode `"Idle"`); set the clip `loop_mode = LOOP_LINEAR` or it one-shots; the
  character may face +Z (add a 180° yaw). **Attach head accessories with `BoneAttachment3D`** bound to
  the `Head` bone so they track the skeletal idle + gaze through the node tree — no per-frame sync.

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
- The main thread MAY perform implementation edits itself — it is **not** limited to orchestration, and
  there is no rule that all implementation must be delegated. **But editing is permitted only inside its
  OWN dedicated worktree off `0.3-dev`, NEVER directly on the shared `0.3-dev` primary checkout.** The
  distinction is exact: the main thread may *edit*; it may not edit/commit on the shared main-branch
  checkout. So before doing hands-on work, the main thread creates its own worktree (see Branch &
  worktree workflow) and works there — the shared `0.3-dev` primary is treated as read-only, reserved for
  another writer (the user's editor, another session). This is **always** the rule, main thread included.
- Prefer sub-agents for substantial or parallel work — parallelizable scope, contract-heavy or
  native-path changes, larger refactors — with explicit acceptance criteria. Close stale/finished
  sub-agents to conserve slots.
- **PRE-WRITE CONTRACTS to keep the pipeline full.** A sub-agent contract is: the goal, the exact
  files/records to add/change/DELETE, the shared interface it must honor, and a **hard behavioural
  acceptance gate** (exact run command + pass thresholds; "commit only if it passes, else report the
  errors"). Whenever you can see the next 1-3 units of work while an agent is mid-flight, DRAFT their
  contracts *ahead of time* so each launches the instant its predecessor verifies — the queue never
  stalls waiting on you to think. Write these drafts to the **scratchpad**, NOT the repo, while another
  agent is running (its `git add -A` commit would otherwise sweep up your untracked draft). Distinguish
  what can run **concurrently** (different files / a separate worktree → launch in parallel now) from
  what is **sequential** (shares the same files/interface → stage the contract, launch after). When in
  doubt about file overlap, stage rather than parallel-launch: two agents editing one file collide.
- Run/observe with `scripts/agent_harness.sh <command>` for tests, smoke, and live introspection (see
  `GODOT_BEST_PRACTICES.md` → "Headless Harness Invocation" for the canonical command list + markers).
- For substantial or breaking work, keep `ARCHITECTURE_PLAN.md` current: record the intended change and
  note breaking API/schema changes there before merge. Keep commits scoped by domain
  (runtime/editor/tests/docs) where practical.

## Validation defaults

- **ITERATE AS FAST AS POSSIBLE — always.** The dev loop's speed is a first-class concern. Prefer SHORT
  verification runs while iterating (`--run-frames=60–120`) and reserve long runs + `--shoot` screenshots
  for the final gate (screenshots + long demos are the slow path). For any SLOW-EMERGENT phenomenon
  (geology/island-building, forest succession, climate drift, erosion, evolution) add/use a **fast-forward
  time-scale** (run N sim steps per render frame) so geological time compresses to seconds — never wait
  real-time for something you can accelerate. Parallelize (fan out subagents), pick the cheapest run that
  proves the point, and cut anything that makes the loop slower than it needs to be.
- **NON-INTERACTIVE RUNS MUST LAUNCH THE WINDOW OFF-SCREEN — never pop it in front of the user.** Metal/GPU
  runs need a real window (headless has no compute device), but a window appearing in the centre of the
  user's screen mid-work is a hard interruption. ALWAYS pass Godot's `--position 6000,3000 --resolution
  640x400` (before `--path`) on every `--run-frames`/`--shoot` invocation — `--position` is applied BEFORE
  the window paints, so it launches off-screen with no centre flash (moving it after `_ready` is too late —
  it flashes first). This applies to the main thread and EVERY sub-agent's run commands.

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

- **THE CORE — named phenomena have ZERO dedicated code. DISSOLVE, don't patch.** There is ONE physical
  substrate (matter with pressure, temperature, phase, gravity, momentum + chemistry). "Volcano",
  "eruption", "lava bomb", "geyser", "avalanche", "weather", "storm", "ecosystem" are just *words humans put
  on what the physics does* — they are NOT systems anyone writes. A lava bomb is not "bomb code": it's a chunk
  of matter given momentum because pressure exceeded the rock confining it (the SAME rule that throws debris
  from any pressure release → geysers/steam blasts for free). When you meet a named-phenomenon system (a
  `*Volcano.gd`, an `_is_erupting()`, a burst timer, a `BOMBS_PER_BURST`), the move is NOT to make its
  constants scale — it is to ask *"what universal rule (pressure/temp/phase/momentum/gravity/reaction) makes
  this HAPPEN?"*, push that rule into the substrate, and **delete the special-case system.** Disaster actors
  are SEEDS / markers / visuals only. **Success is measured in special-case code DELETED, not features added.**
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
- **One-substrate default — ALWAYS ask "can this be rolled into `MaterialField3D`?"** `MaterialField3D`
  is the single simulation substrate (the ONE field: terrain-coupled water + heat + air/vapor/cloud/fog +
  lava, and — as they land — pressure/wind, fire/fuel, granular slump, scent, waste/nutrient). Before
  adding OR when reviewing any world/simulation behavior, the default question is whether it belongs as a
  **field channel or stepped process** rather than a separate system or per-node actor loop. Anything that
  **diffuses, advects, flows, deposits, or decays over space** (heat, fluids, wind/pressure, scent, smoke,
  waste/fertility, fire) should be a field channel so it composes with everything else for free (e.g. scent
  that rides the real wind and washes in the rain). Keep something OUT of the field only for a **deliberate,
  stated reason** (e.g. the ocean is a cheap GPU wave plane for perf; actors own their own cognition/nodes).
  Don't silently build a parallel system — ask the roll-in question first, and surface it if the answer is
  "yes, but it's a big change."

## Repository policy

- No downstream consumers to preserve right now: prioritize rapid feature improvement and stronger
  simulation behavior over compatibility. Break APIs freely when it improves architecture; remove old
  abstractions when replacing systems rather than leaving parallel ones.
- **Temporary breakage is ALLOWED on a non-`main` / non-`0.3-dev` branch when it's the cleaner path.** When
  adding a feature, porting a substrate, or fixing perf, do NOT contort into a non-breaking parallel path
  (duplicate systems + `if mode` branches + a keep-the-old-working tax) if converting IN PLACE / ripping out
  the old and fixing FORWARD is simpler — that better matches "retire the old, no parallel systems." On a
  feature branch the sim need not boot mid-refactor: commit clearly-tagged WIP checkpoints so progress
  persists, and drive it back to a verified working state (windowed + `SIM_REPORT`) BEFORE merging to
  `0.3-dev`/`main`. The non-breaking discipline is only mandatory on the shared integration branches and when
  another writer depends on the code right now. Weigh it each time: pick temporary-break-then-fix-forward when
  it yields materially cleaner code or less throwaway; keep non-breaking when the churn is small either way.
- **Surface held-back-by-code moments — don't just proceed.** If, while doing a task, you realize the
  current code/architecture is a *holdover* that's constraining a genuinely better approach (e.g. a
  2.5D representation blocking a real 3D one, a scripted special-case where an emergent rule belongs, a
  CPU path where GPU/native fits), STOP and SURFACE it to the user: name the relic, describe the better
  approach and what it unlocks, and ask. Do **not** silently work around it (delivering a lesser result
  the user didn't know was a compromise), and do **not** unilaterally rip it out either. The user will
  usually say "yes, change it" — but it's their call, and flagging it is how big upgrades get found.
- **Composable-plugins mandate — host + registry over monolith (the architectural form of emergent-everything).**
  For anything that is a SET of composable things over shared state — field processes, reactions, disasters/FX,
  telemetry sources, spawnable content, solar-system bodies — prefer a thin HOST that owns the shared substrate
  + an ordered list/registry of small modules conforming to a tiny interface, over one monolith with `if type
  == X` branches. Adding a phenomenon = drop in a plugin (or a data record), not patch a monolith. This is
  "config over `if identity == X`" one level up, and the same instinct as dissolve-don't-patch: a new rule
  COMPOSES IN. Working examples already in-tree: the cubed-sphere field driver's pass modules
  (`material/sphere_passes/*`), `LASimReport.register(Callable)` telemetry sources, species JSON, `LAPlanetBody`
  under the system root. When you catch yourself adding a type-branch to a big file, make it a plugin instead.
- **Simplicity mandate:** implement the simplest behavior that works correctly for the target path.
- **Anti-overengineering mandate:** no long, multi-stage, or speculative pipelines when a shorter direct
  path satisfies the requirement.
- **Computational-scalability mandate — Big-O IS a first-class design goal (CORE PRINCIPLE).** Always drive
  the *asymptotic* cost down, then let constant factors follow. Two levers, applied everywhere:
  - **Lower the algorithm's Big-O.** Prefer the better-scaling structure/algorithm over the naive one:
    spatial hash / grid / octree / neighbour-table lookup instead of pairwise or full-scan; O(K) test-particle
    passes instead of O(n²) mutual; event/dirty-set updates instead of re-sweeping the whole grid; precomputed
    tables (the sphere seam table is the model) instead of recomputed indices. When you write a loop-in-a-loop
    over entities/cells, STOP and ask "what makes this sub-quadratic?" A per-frame O(n²) (or an O(N) full-grid
    sweep that ignores what changed) is a **perf bug to design out**, not an acceptable baseline.
  - **Do less work by RELEVANCE — adaptive level-of-detail is mandatory, not optional.** Work must scale with
    what is observable / important right now, never with the whole world. Offscreen, distant, un-zoomed,
    dormant, or empty regions do **less**: coarser grid, longer/skipped timesteps (staggered/block updates),
    frozen or reduced simulation, culled draws, lower-LOD meshes, sleeping actors. The "only the active/near
    planet steps at full rate; distant ones coarse/frozen," the dominant-attractor test-particle gravity, and
    field update cadence are all instances of this ONE rule. Budget compute where the player is looking.
  - **BUBBLES OF COMPUTE — activity-driven dynamic tick rate (the field's primary scaling lever).** A cell/
    region's tick rate scales with how much is HAPPENING there, not just distance. Quiescent regions sleep;
    active regions (fluid flowing, heat/fire spreading, a reaction, an actor or disaster nearby) tick every
    frame. Activity **propagates as a bubble**: a cell that changes beyond a threshold wakes its neighbours next
    step (so a front/flow/fire grows its own compute bubble at the speed of the phenomenon), and a stimulus (a
    meteor, an actor drinking, an eruption) injects activity to wake a region. Settled regions demote to a
    longer period, then sleep (skipping is EXACT when nothing changes; for constant-forced processes like solar,
    a woken cell catches up with the elapsed dt). On the GPU this is an active-cell/tile list + indirect
    dispatch (O(active), not O(all-cells)) or, minimally, a per-tile sleep flag with early-out. This is what
    makes a whole-planet / multi-body field affordable — most of a planet is quiescent at any instant; compute
    only the bubbles. Compose with distance-relevance (a region is stepped if active OR near the viewer).
  This mandate composes with (does not override) the GPU-first + emergent rules: push the parallel work to the
  GPU **and** give it a better Big-O **and** only run it where it matters. When these tension, cutting the
  asymptotic/relevance cost wins over a marginally simpler constant-factor path.
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
- **Per-cell field CAs belong on the GPU, NOT in C++.** Any field process that evaluates a rule per cell
  over the grid (diffusion/advection/phase-change/decay: heat, water, wind, gas, scent, fungus, erosion,
  snow, magma, shock, …) is embarrassingly parallel → its authoritative runtime form is a **GPU compute
  kernel** (`kernels3d/*.glsl`), with the GDScript module kept only as the headless CPU-oracle. C++ is for
  *serial* work (actor cognition, tree/graph ops, orchestration), not grid math. A per-cell CA left
  looping in GDScript on the per-frame path is a **performance bug to fix**, not an acceptable state — a
  127K-cell grid makes a single such module cost tens-to-hundreds of ms/frame.
- **PERFORMANCE OVER PARITY (repo rule).** Playable frame-rate is a first-class requirement, and it wins
  over CPU↔GPU numeric parity whenever they conflict. Bit-exact parity is only worth holding for
  continuous field math that stays cheap; for everything else, **break parity to gain performance** —
  target GPU-only kernels with *behavioral* verification (assert emergent aggregates: mass conserved,
  counts sane, no runaway), drop or loosen the parity harness, and move the CPU oracle to a coarser
  headless reference (or GPU-only + `GPU_REQUIRED` fail-fast) rather than pay a per-frame CPU tax to keep
  the two identical. Do not add or keep an every-frame full-grid CPU pass solely to preserve parity. When
  in doubt, ship the faster path and note what parity was traded.
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

- **DESIGNATED THIN HUBS — `VoxelWorld.gd` and `MaterialField3D.gd` are EXTRACT-ONLY; do NOT add behavior
  to them.** These two files have been split THREE times because new work keeps re-accreting into them (they
  are the composition root and the field hub, so it's where wiring/channels naturally land). Stop the cycle
  by rule: **`VoxelWorld` is a composition root ONLY** — it may instantiate + wire controllers and nothing
  more; a new feature gets at most a one-line `add_child(controller)` / signal hookup there, and its behavior
  lives in a NEW focused controller module. **`MaterialField3D` is the field's thin public facade +
  step-orchestration ONLY** — a new channel/query/process goes in a NEW module (a channel module, a pass, a
  query facade) that the field merely delegates to; never add inline channel logic or query bodies. This
  applies to the main thread AND every sub-agent: **a contract that would grow `VoxelWorld`/`MaterialField3D`
  is wrong by construction — rewrite it to add a module instead.** When you catch yourself about to add a
  method to either, STOP and make the module. (Same pattern for any future god-object hub — name it here and
  make it extract-only before it becomes the fourth serialization bottleneck.)
- **PARALLELIZABILITY is a first-class refactor driver — not just line count.** Line limits are a floor;
  the deeper question is *"can this area be owned by a separate agent without colliding?"* A file that
  multiple concurrent workstreams must all edit is a **serialization bottleneck** — split it into
  independently-ownable units **even when it is comfortably under the line limit**. Always think this way:
  before fanning out work, look at which files each unit touches; if several units route through ONE file
  (classically the composition root / a god-object controller / a shared registry), split that file FIRST
  so the fan-out doesn't collapse to sequential. Organize the codebase so distinct concerns live in
  distinct files (one owner each) — that is what turns a batch of work into parallel subagents instead of a
  queue. This composes with the pre-write-contracts rule (Execution model) and the "independently-ownable
  file" guidance below: structure for concurrency, then stage a contract per file.
- `scripts/check_max_file_length.sh` enforces TWO thresholds on first-party source/config files:
  a **soft smell limit of `SOFT_FILE_LINES=1300` (WARNING)** and a **hard limit of `MAX_FILE_LINES=1500`
  (FAILS — non-zero exit / CI gate)**. Over 1300 = split it soon; over 1500 = the build fails until it's
  split. It also runs `check_no_direct_refcounted_invocation.sh` (a real gate banning
  `godot -s addons/local_agents/tests/test_*.gd` in automation).
- **Do NOT add to a file that is already over the smell threshold.** If a change would grow an
  ≥1300-line file, first REFACTOR: extract the relevant responsibility into a NEW focused module (or add
  your new code as a new file), then make the edit there. Never push a file past the 1500-line hard limit
  — split it first. This applies to every agent (main thread and sub-agents).
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
  scene also self-harnesses (`-- --run-frames=N` prints `SIM_REPORT={...}`; `--shoot=<png>` for
  windowed screenshots; `--auto-meteor` drops a test impact). A NEW `.gd` `class_name` or
  `.gdextension` only registers after an editor scan — run `godot --headless --editor --quit-after 400`
  once, else classes report MISSING.

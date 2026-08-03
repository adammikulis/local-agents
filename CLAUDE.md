# CLAUDE.md

**This is the canonical, enforceable process doc for this repo — read it first.** It applies to every
agent (Claude Code, Codex, and sub-agents). `GODOT_BEST_PRACTICES.md` is its companion and the
canonical source for Godot-specific design, runtime, testing, validation, and harness-invocation
rules. `AGENTS.md` simply points here. Keep process rules in this file (and Godot specifics in
`GODOT_BEST_PRACTICES.md`) so they don't drift across docs.

## Branch & worktree workflow (DEFAULT)

- **The current development branch is `0.4-dev`** — the integration branch all feature work targets (this
  is the ONE place its name is written; everywhere else says "the current dev branch" so a version bump
  changes only this line). `main` is downstream — it holds the shipped release (currently **0.3.1**, tagged
  `v0.3.1`). Do **not** commit feature work directly to `main`.
- **Do every non-trivial change in a dedicated git worktree branched off the current dev branch**, not in
  the primary checkout:
  `git worktree add ../local-agents-<feature> -b feature/<name> <dev-branch>`
  Build there, commit as you go, and merge back into the dev branch only when verified. This is the
  standard because another session/agent running git ops (checkout/reset/merge) on the shared
  checkout has corrupted and wiped untracked in-progress work here before — an isolated worktree
  makes your files immune to another writer's branch switches.
- The compiled GDExtension `bin/` is a gitignored build artifact absent from a fresh worktree —
  symlink it from the primary checkout so the extension loads:
  `ln -s <primary>/addons/local_agents/gdextensions/localagents/bin <worktree>/addons/local_agents/gdextensions/localagents/bin`
- When a feature is verified, merge it into the current dev branch, then prune: `git worktree remove <dir>`
  and `git branch -d feature/<name>` (delete the pushed remote branch too once merged). At release, the dev
  branch merges to `main` and is tagged.
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
  OWN dedicated worktree off the current dev branch, NEVER directly on the shared primary checkout.** The
  distinction is exact: the main thread may *edit*; it may not edit/commit on the shared main-branch
  checkout. So before doing hands-on work, the main thread creates its own worktree (see Branch &
  worktree workflow) and works there — the shared primary checkout is treated as read-only, reserved for
  another writer (the user's editor, another session). This is **always** the rule, main thread included.
- Prefer sub-agents for substantial or parallel work — parallelizable scope, contract-heavy or
  native-path changes, larger refactors — with explicit acceptance criteria. Close stale/finished
  sub-agents to conserve slots.
- **The roadmap is DELIBERATELY divergent so it parallelizes — do NOT bounce it back as a question.**
  `HANDOFF.md`'s "Next — pick up here" and the 0.4 phases list several independent tracks *on purpose*: that
  spread is the whole point, the raw material for a Workflow fan-out, not an ambiguity to resolve. When you
  meet a set of divergent tracks, the standing response is to ACT, not ask "which one?": build the
  collision map (which shared files each track touches), do the seam-directed refactor to unblock (see the
  serialized Phase-0 split rule below), then fan the tracks out in parallel (worktree-isolated agents, one
  per track) and integrate what verifies. Only surface a genuine either/or that changes the *architecture*
  (a held-back-by-code relic, two incompatible substrate designs) — never "this work is divergent, what do
  I do."
- **USE THE `Workflow` TOOL for fan-outs — this is standing, typical process (the maintainer opted in;
  no per-task re-authorization needed).** When work decomposes into parallel UNITS over shared state —
  one agent per actor / per kernel / per 0.4 workstream / per split-out file / per review dimension —
  author a Workflow script (fan out → verify → synthesize) instead of hand-launching N agents and playing
  the serialization point yourself. It formalizes the manual pattern into deterministic control flow
  (loops/conditionals/fan-out) with structured results.
  - **`pipeline()` is the default** (each unit flows implement→verify with NO barrier — item A verifies
    while item B still implements). Use `parallel()` (a barrier) ONLY when you genuinely need ALL results
    together (dedup/merge across the set, early-exit on zero, cross-item comparison).
  - **Compose with the existing discipline, don't replace it:** do the SEAM-DIRECTED SPLITS first (see the
    parallelizability rule + the 0.4 split guide) so units are one-owner; each `agent()` prompt is a
    PRE-WRITE CONTRACT (goal · files to add/change/DELETE · shared interface · a hard behavioural
    `SIM_REPORT`/gate); use `isolation:'worktree'` when agents mutate files in parallel; adversarially
    VERIFY findings (N skeptics, kill on majority-refute) for review/audit passes.
  - **Scope to the ask:** a few finders + single-vote verify for "find any bugs"; a larger pool + 3–5-vote
    adversarial pass + synthesis for "thoroughly audit / be comprehensive."
  - **The coordinator (main thread) still integrates:** worktree-isolated Workflow agents commit to their
    branches; merging + conflict resolution + the editor-scan/verify gate stay the main thread's job
    (Workflow doesn't auto-merge). A single `Agent` call is still fine for a genuinely one-off, independent
    unit; reach for `Workflow` the moment it's a *set* of units.
- **DO NOT FAN OUT PROSE, AND NEVER RUN A THIRD ROUND.** Fan-out earns its cost when units are parallel
  IMPLEMENTATION over disjoint files whose correctness is settled by RUNNING something: a demo exits 0, a
  gate fails on purpose, a report marker appears. It does not earn its cost on documentation, where
  correctness is a hundred small independent factual claims. Verification there does not parallelize the
  way the writing does, so the checking costs more than the writing, and every fix round gets a fresh
  chance to be wrong about something new.
  - **Hard limit: two rounds, then take it in-house.** If a fix pass introduces NEW errors at anything
    like the rate it removes old ones, stop launching agents and do the remaining items yourself. Measured
    2026-07-29: two doc fan-outs plus two fix fan-outs came to 28 agents and ~3.4M subagent tokens, and
    the eight defects the coordinator then closed by hand took ten tool calls and introduced none.
    Agents correcting agents correcting agents is not convergence, it is spend.
  - **The tell:** if the verifier's report is longer than the artifact it reviewed, the wrong tool was
    picked. Read the findings yourself and fix them directly.
  - Adversarial verification is still right for code and for audits, where a finding is one falsifiable
    claim about behaviour that a command can settle. Keep it there.
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
- **`HANDOFF.md` IS THE MAP OF WHAT IS LEFT. IT IS NEVER A HISTORY.** Maintainer's rule, absolute:
  **a checked-off item is DELETED as soon as it is committed.** Do not tick it, strike it, mark it
  `DONE`/`SHIPPED`/`MERGED`/`RESOLVED`, or keep it "for context". Git is the record of what was done. A
  tracker that doubles as a changelog buries the next agent's actual job — measured 2026-07-30, the file
  had reached 1053 lines of which **578 were finished session narrative**, and its "START HERE" header was
  followed by 530 lines of history before the reader met a single actionable item. Cutting it to 435 lost
  nothing that git does not already hold.
  - **Durable lessons do not live there either.** A finding worth keeping goes to `CLAUDE.md` (process) or
    `GODOT_BEST_PRACTICES.md` (Godot/runtime/engine). What stays in `HANDOFF.md` is live reference only:
    engine limits that still bite, deferrals with the reason they were deferred, and undone work.
- **KEEP IT CURRENT WITHOUT BEING ASKED — it is the next agent's only map.** Update it on your own
  initiative at each of these points, not when someone reminds you:
  - a phase, workstream, or fan-out lands, or a feature is verified — which means DELETING its entry;
  - you discover a claim already in the file is FALSE (fix it in place, mark it corrected with the date,
    and say what it said before, so nobody re-derives the same wrong conclusion);
  - before merging any branch to the dev branch, and before a session ends or pauses.
  - **Correcting stale claims matters more than appending new ones.** This file told every agent for
    weeks that Keystone A's erosion pickup kernel "doesn't exist" (it ships, `MaterialSphereGPU3D.gd:51`)
    and that Keystone C was "not built" (it ships, `:55`). Both errors sent work at problems that were
    already solved, and one of them ordered a fix to `EMERGENCE.md`, which was correct all along. A
    tracker that is confidently wrong is worse than one that is merely out of date.
  - **Verify before you write.** Every status claim you add or leave standing must be one you just
    checked against the code. "Shipped", "not built", "still owed" are all falsifiable in one grep, so
    do the grep. Cite `file:line` for anything a reader would otherwise have to hunt for.
  - Keep the ranked "DO THIS NEXT" list honest: delete what is done, and for each open item say what
    would actually DECIDE it (a specific measurement or run), not just that it is open.

## Validation defaults

- **ITERATE AS FAST AS POSSIBLE — always.** The dev loop's speed is a first-class concern. Prefer SHORT
  verification runs while iterating (`--run-frames=60–120`) and reserve long runs + `--shoot` screenshots
  for the final gate (screenshots + long demos are the slow path). For any SLOW-EMERGENT phenomenon
  (geology/island-building, forest succession, climate drift, erosion, evolution) add/use a **fast-forward
  time-scale** (run N sim steps per render frame) so geological time compresses to seconds — never wait
  real-time for something you can accelerate. Parallelize (fan out subagents), pick the cheapest run that
  proves the point, and cut anything that makes the loop slower than it needs to be.
  - **`--fast=N` DID NOTHING AT ALL until 2026-07-29, so discount any measurement that leaned on it.**
    `Engine.time_scale` had two owners: `VoxelWorld.parse_cmdline()` applied `--fast` through the pause
    menu at `VoxelWorld.gd:177`, and `LAVoxelTimeControl` was built ~114 lines later at `:291` where its
    `_ready() -> _apply()` reset the global to 1.0×. A runtime probe under `--fast=8` read back
    `time_scale 1.000` with delta exactly 1/60. Matched 300-frame runs: 135 field steps at `--fast=1`
    versus 113 at `--fast=8`. Fixed by giving the global ONE owner (`LAVoxelTimeControl.set_multiplier`,
    applied after that node exists). Now measured: 114 field steps → **5705**, and 0.06 → **3.97 sim
    days**, which is the first time the day-rollover path has ever executed.
  - **`--fast=4` AND `--fast=8` ARE SAFE. Compare runs at equal `field_sim_s`, never at equal
    `--run-frames`.** *(Corrected 2026-07-30. This bullet previously read "USE `--fast=2`. At `--fast>=4`
    the population dies", and blamed a desync: "creatures tick on the scaled delta while the field is
    capped by `Engine.max_physics_steps_per_frame`, so consumption outruns regrowth." Both halves are
    false, and the rule cost the project a 4x iteration-speed dial for nothing.)*
    - **There is no desync.** The field and the actors advance the same simulated time to within the
      accumulator residue. Measured over twelve runs at `--fast` 1/2/4/8, `field_offer_s - field_sim_s`
      was 0.03-0.10 seconds in every one. The field's own clamp
      (`LAMaterialFieldSphereStep3D.MAX_STEPS_PER_FRAME`) drops banked time only above `_step_accum` 0.3,
      and the physics delta is `time_scale / 60`, which reaches 0.3 at time_scale 18. `SPEEDS` stops at
      8.0. The clamp is unreachable at every speed the game can select.
    - **What actually happens** is that `--run-frames=N` buys wildly different amounts of world-time at
      different multipliers, because `LAVoxelTimeControl` scales `Engine.max_physics_steps_per_frame`
      with the speed (`VoxelTimeControl.gd:219`) while `time_scale` is already scaling the delta. Sim
      seconds per RENDERED frame: **0.0995 at `--fast=1`, 0.533 at 2, 1.98 at 4, 5.28 at 8** — a 53x
      spread over an 8x speed range. The old measurement compared 150 frames against 150 frames, so the
      `--fast=4` run was read at ~1.5 sim days and the `--fast=2` run at 0.4. It had not starved; it was
      four sim-days older. (That line at `:219` is deliberate and stays — it is worth 54-56% of the
      throughput at `--fast` 4 and 8. Its comment carries the measurement.)
    - **At equal simulated time nothing collapses.** Three runs each, seed 4242, at 80 sim-seconds:
      `--fast=2` ends with 146-174 creatures (impacts 4/7/12, eruptions 2/2/3); `--fast=4` ends with
      193-200 (impacts 1/0/0, eruptions 2/0/1); `--fast=8` at 79-89 sim-seconds ends with 213-236.
    - **`--fast=8` is the fastest dial and costs fidelity, not life.** Simulated seconds per wall second:
      0.69-0.72 at `--fast=1`, 1.04-1.08 at 2, 2.40-2.56 at 4, 4.43-4.96 at 8. But a high multiplier
      draws **far fewer ambient disasters over the same simulated time** (0-1 impacts at `--fast=4`
      against 4-12 at `--fast=2`), so a fast run is a calmer world, not the same world seen sooner. Use
      `--fast=8` for throughput; drop to 2 when the disaster timeline is what you are measuring.
    - **Read `field_sim_s` / `eco_sim_s` out of `SIM_REPORT`** (published by
      `MaterialFieldSphereStep3D` and `EcologyService`) to place any two runs on the same horizon.
      Prefer them to `field_step`, which is an event counter zeroed by `LASimReport.reset()` at initial
      spawn and so under-counts by the whole pre-spawn window — badly at a high multiplier.
- **MEASURE BEFORE YOU TUNE, AND CHANGE THE CONSTANT BY A LARGE FACTOR FIRST.** Before fitting any constant
  to make a number look right, move it by 20% or more and check the response is the same order. Measured
  2026-07-30: after adding a real radiative sink the planet ran warm, and cutting the solar constant 20%
  moved the global mean by ONE degree — the sun was not the mechanism, and tuning it would have encoded an
  accident as a target. The dominant term was geothermal, which the measurement found in one run. If the
  output barely moves, you are adjusting the wrong thing.
- **COMPARE DECAYING QUANTITIES AT EQUAL `field_step`, NEVER EQUAL FRAMES.** `soil_total` and `h2o_total`
  are draining reservoirs whose value tracks STEPS taken. Two runs at the same `--run-frames` but different
  `field_step` once produced an apparent 36% regression that was entirely horizon. Quote `field_step`
  beside every such figure. And run-to-run spread here is DISCRETE — dominated by how many impacts and
  eruptions a run happened to draw (2 vs 6), not Gaussian — so quote `phenomenon/impact` and
  `phenomenon/eruption` too. `LA_NO_AMBIENT_DISASTERS=1` is NOT enough to hold the timeline fixed: it gates
  only the ambient director, and `LAPlateTectonics` keeps firing on its own drumbeat.
- **REVIEW STRUCTURE BY DEFAULT, NOT JUST VALUES — every time you surface a constant or a metric.** The
  standing question is not "is this number right?" but **"what is this a constant OF, and should it be one?"**
  and for a metric, **"is this the right SHAPE of measurement?"** Surfacing something as evidence is NOT the
  same as reviewing it, and you owe the review even when you only opened the file to quote a number for some
  other argument. Two failures on 2026-08-03, one root:
  - `CreatureMetabolism`'s `WARM_COMFORT 28 / COOL_COMFORT 8 / LETHAL_HEAT 50 / LETHAL_COLD -18` are module
    consts applied to EVERY creature — a whale and a desert beetle share one thermal physiology, with no
    species config and no heritable gene. They were quoted in a table as evidence about something else and
    the design smell went unremarked, in the same session that twice cited this file's own "config over
    `if species == X`" rule.
  - `temp_mean`, a single global spatial mean, was used to argue the planet was overheating while
    `surf_mean` — where creatures actually stand — was flat. A global mean cannot answer a local question,
    an instantaneous sample cannot answer "how extreme does it get", and a scalar cannot show structure.
  - **The tells:** a const applied in a loop over entities that differ in reality (species, biomes,
    materials); a mean used to argue about a local phenomenon; a single sample used to argue about a range;
    any comment justifying a value by "the sim's actual range".
- **A PHYSICAL CONSTANT IS NOT A TUNING KNOB. NEVER FIT ONE — AND WHEN YOU FIND A FITTED ONE, FIX IT THAT
  DAY AND SAY SO.** Measured properties of real matter — the freezing/boiling point of water, basalt's
  liquidus, an ignition temperature, the solar constant, an albedo, the Stefan-Boltzmann constant — are
  FACTS. Hardcoding them is correct and is the point. What is forbidden is moving one so a broken simulation
  produces a nice-looking output. If a physical constant has to move for the sim to look right, **the sim is
  wrong; fix the sim.**
  - **The case that proves it, found 2026-08-03: WATER FROZE AT 12.5 °C.** The planet could not get below
    ~11 °C, so instead of fixing the planet someone moved the freezing point of water up to meet it — in
    **five places at three different values** (12.5 in `MaterialReactions3D` and `snowice_sphere3d`, 13.0 in
    `charge_accum_sphere3d` and `activity_sphere3d`, melting at 14.0). The comment said so outright: *"TUNED
    to the sim's ACTUAL open-cell temperature range (~11–21 °C) … A literal 0 °C freeze can never fire
    here."* Snow then "worked", `snow_cells` read 879–2102, and **every measurement ever taken against those
    numbers was meaningless.** The same instinct set the planet's *core* to 1300 °C — an erupting-basalt
    temperature, roughly a quarter of a real iron core — because a hotter one baked the surface.
  - **This rule is not the band-aid rule below.** That one says a clamp comes out *after* its root is fixed.
    This one says a real-matter constant should never have been moved at all: it is not a clamp, it is a lie
    about the material. Do not wait for a phase gate — correct it, and tell the maintainer what you changed
    and what it was hiding.
  - **The tells:** a temperature that is not a round physical value; a comment justifying a constant by "the
    sim's actual range"; the SAME physical quantity declared in more than one file (that is drift waiting to
    happen, and it happened here); a constant whose history is a sequence of "was X, baked the surface, now
    Y". Physical constants live in `material/PhysicalConstants.gd` with a citation for what each is a
    property OF; `scripts/check_physical_constants.sh` gates the GLSL copies against it.
- **REMOVING A BAND-AID IS THE ACCEPTANCE TEST FOR FIXING ITS ROOT.** When a clamp, rarity roll or floor
  exists to suppress a runaway, the proof that the root is fixed is that the clamp can come OUT and the
  runaway does not return. If it does return, say so — do not quietly restore the clamp and claim the root
  fix. Worked example: `FREEZE_TEMP` moved 12.5 -> 0.0 only after a real radiative sink made sub-zero
  temperatures reachable at all.
- **NON-INTERACTIVE RUNS MUST NOT INTERRUPT THE USER — use `scripts/run_sim_offscreen.sh`.** Metal/GPU runs
  need a real window (headless has no compute device), and a Godot window both APPEARS on-screen AND STEALS
  KEYBOARD FOCUS at launch — a hard interruption. The wrapper `scripts/run_sim_offscreen.sh` fixes both:
  launches with `--position 30000,30000 --resolution 640x400` (off-screen, applied before first paint) AND
  hands focus back to whatever app was frontmost (macOS `osascript`, retried as Godot grabs focus during
  startup). ALWAYS run non-interactive sims through it — `scripts/run_sim_offscreen.sh --path . <scene> --
  --run-frames=N` (env like `LA_NO_STREAMER=1` still works). This applies to the main thread AND every
  sub-agent's run commands. (Moving the window after `_ready` is too late — it flashes + steals focus first.)

- **NEVER run two editor scans at once — use `scripts/editor_scan.sh`.** A full
  `godot --headless --editor` loads every GDExtension, including the zylann.voxel EDITOR build, which
  spins worker threads to import and generate. Two of those racing on the same `.godot/` directory
  SEGFAULT: measured 2026-07-28, six Godot crashes in three minutes (`EXC_BAD_ACCESS` at 0x10/0x50/0x60,
  faulting frames inside `libvoxel.macos.editor.universal` on a thread named "run") while ten parallel
  agents each ran the scan a few times. The scan is also the one thing every agent needs — a new
  `class_name` does not register without it — so "don't run it concurrently" is not a rule anyone can
  follow by hand. `scripts/editor_scan.sh` takes a per-project lock so concurrent callers queue and
  each still gets a correct scan; it prints the error count and exits non-zero when the scan found any.
  **Sub-agent prompts must point at this script, never at a bare `godot --headless --editor`.**

- **BUT the wrapper is only for the scenes that NEED a window — everything else runs bare headless in
  about a second.** *(Corrected 2026-08-03. This bullet used to say "a wrapper run costs 2–4 MINUTES,
  because the windowed scene prints its report and then fails to exit, so the script waits out its
  `RUN_TIMEOUT`", and the next bullet told you never to loop wrapper runs. **The exit path was fixed and
  nobody updated this.** `run_sim_offscreen.sh` now waits on a dedicated `LA_RUN_COMPLETE={"code":N}`
  sentinel that every harness prints immediately before quitting, and its own header records the default
  ceiling being cut 240s → 60s because these scenes finish well inside it. Measured: three consecutive
  600-frame `VoxelWorld` runs at `--fast=8` with `LA_RUN_TIMEOUT=600` took **88, 91 and 91 seconds** —
  if they were waiting out a timeout they would have taken 600. So a windowed run costs about
  `frames/7` seconds and EXITS. **Looping several wrapper runs in one command is fine, and is how you
  get the 3-runs-per-arm the measurement rules demand.**)* The example scenes are still much cheaper and
  still the right default — they run headless in 0–2s with exit code 0:
  `godot --headless addons/local_agents/examples/<Demo>.tscn -- --run-frames=40`. BoxFieldDemo ~1s,
  ThinkingCreatureDemo ~1s, CoreCreatureSmoke ~0s, SimWorldPlanetDemo ~2s. Only
  `game/VoxelWorld.tscn` (GPU compute field) genuinely needs the window. Reserve the wrapper for it
  and for `--shoot` screenshots — but DO loop it when you need repeats: a 3-runs-per-arm A/B at 600
  frames is about nine minutes unattended, which is the price of a result you can believe.

- "Does it work" checks require **both** a non-headless launched-window run **and** headless harness
  suites; run them in whichever order is convenient (a non-headless launch first is a good habit for
  surfacing parser/runtime scene errors early).
- Manual runtime proof is **required** for player-facing behavior claims: if a change affects in-game
  controls/interaction, verification must include an actual launched Godot window where the behavior is
  exercised. Do not mark player-facing work `passing`/`ready`/`fixed` without that launched-window
  check — automated/headless tests are necessary but not sufficient.
- For changed native or simulation-contract areas, give the validation pass explicit acceptance
  criteria and test commands.

## Inspector-surface rules (learned the hard way, 2026-07)

Every one of these cost a real bug that passed every gate. They are cheap to follow and expensive to
rediscover.

- **A dead `@export` is worse than no `@export` — it lies to the user.** A property that is declared,
  documented, and then never read by anything is a promise the code does not keep. Four shipped that
  way at once (`system_prompt`, `max_actions_per_tick`, `db_path`, `model_profile.threads`) and all
  four *looked* correctly plumbed from GDScript. **PROVE an export reaches behaviour by RUNNING it,
  not by reading the call chain.** For the GDScript↔C++ boundary specifically, an option key is only
  live if the native source actually reads it — grep `gdextensions/localagents/src/` for the key.
- **Never write a serialised property from a `@tool` script in the editor.** `text`, `visible`,
  `position`, `placeholder_text`, `modulate`, `add_theme_*_override` — writing any of them under
  `Engine.is_editor_hint()` silently edits the user's `.tscn`. Adding `@tool` means EVERY lifecycle
  callback (`_ready`/`_process`/`_physics_process`/`_enter_tree`) opens with
  `if Engine.is_editor_hint(): return`, and the editor guard comes FIRST, before any node mutation.
- **Precedence is always node → project setting → env var → default.** The node's own export wins
  when the author filled it in; empty means "follow the project". Inverting this (a setting quietly
  beating a value typed into the inspector) makes the inspector a lie.
- **Measure a simulation on the physics clock.** A report ended after N *render* frames contains a
  machine-dependent number of simulation steps, so its numbers track framerate, not behaviour. Use
  `LocalAgentDemoHarness.count_physics_frames` for anything measuring the field or the sim.
- **Typed `Dictionary` exports are good — keep them.** They give real typed key/value fields in the
  inspector. The one caveat: `set("prop", {untyped literal})` is silently dropped, while direct
  assignment (`node.prop = {"a": 1}`) converts fine. Prefer direct assignment.
- **Verify claims before acting on them, including a reviewer's.** An adversarial review pass is
  worth its cost, but a reviewer is another agent and can be confidently wrong. Three review claims
  in this effort were false on measurement (typed dictionaries "break assignment"; a typed
  `const PackedStringArray` literal being illegal; `ResourceLoader.exists()` not seeing a `.json`).
  Run the command, quote the output, then change the code.

## RULE ZERO — REALISM IS THE FIRST GOAL. ASK "IS THIS HOW THE WORLD WORKS?" BEFORE ANYTHING ELSE.

**This outranks every other rule in this file.** Before you write, review, or accept any model, constant,
coupling or measurement, ask the physical question — *does this correspond to how the real world actually
works?* Not "does the code run", not "does the test pass", not "does the number look reasonable". Those are
all downstream. A simulation that runs perfectly and does not match reality is broken.

**Every serious defect found on 2026-08-03 fails that one question, and every one of them was caught by the
maintainer rather than by an agent:**
- **Water froze at 12.5 °C** (five files, three values) because the planet could not get cold, so a previous
  pass moved the freezing point of water instead of fixing the planet.
- **The planet's core was 1300 °C** — an *erupting basalt* temperature, about a quarter of a real iron core
  (~5200 °C) — because a hotter one baked the surface.
- **Every creature had identical thermal physiology** (`WARM_COMFORT 28 / COOL_COMFORT 8 / LETHAL_COLD -18`,
  module consts): a whale, a desert beetle and an arctic fox, the same. No species config, no heritable gene.
- **Volcanoes waited for rabbits.** The ambient disaster director would not start its clock until a creature
  had spawned, so geology was gated on the biosphere.
- **The deep ocean sat at 10 °C — below its own freezing point — without freezing**, saved only by a 26 °C
  thermostat overriding the temperature field.
- **"The planet can't go below 0 °C"** was concluded from a *global* `temp_min`, when freezing is local:
  poles, summits, night side, and aloft (where snow actually forms) all freeze independently.

**How to apply, in order:**
1. **Name the real-world referent.** What physical thing is this a model OF? If you cannot say, that is the
   finding. Cite the real value or mechanism.
2. **Check the coupling against reality.** Systems that are independent in the world must be independent in
   the code, in BOTH directions. Geology does not consult biology; biology does not schedule earthquakes.
3. **Check the scale.** A core is hotter than lava. An ocean is colder than magma. A pole is colder than an
   equator. If a number is off by 4x from the real thing, it is wrong even if it runs.
4. **Check that entities that differ in reality differ in code** — species, materials, biomes. One constant
   shared across genuinely different things is a modelling error, not a simplification.
5. **Check the measurement is the right shape.** A global mean cannot answer a local question; one sample
   cannot answer "how extreme"; a scalar cannot show structure.
6. **When reality and convenience conflict, reality wins.** If the sim must be wrong for the numbers to look
   right, fix the sim. Never bend a physical fact to a broken model — see the PHYSICAL CONSTANT rule below.

**Do this UNPROMPTED, on every file you open — including files you only opened to read.** Every item above
was visible in code an agent had already read. Surfacing something is not reviewing it. If you notice a
reality violation while doing something else, **FIX IT *AND* REPORT IT that turn — not one or the other.**
"Or" is an invitation to file a note and move on, which is the lazy route and the one taken by default.
Reporting without fixing leaves the defect in the code; fixing without reporting hides it from the
maintainer. Do both. Do not route around it because it is not your current task — routing around it is the
failure mode, and it is the most common one.

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
  `addons/local_agents/sim/EMERGENCE.md` — read it before extending sim behavior.
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
- **Temporary breakage is ALLOWED on a feature branch (not `main` or the current dev branch) when it's the cleaner path.** When
  adding a feature, porting a substrate, or fixing perf, do NOT contort into a non-breaking parallel path
  (duplicate systems + `if mode` branches + a keep-the-old-working tax) if converting IN PLACE / ripping out
  the old and fixing FORWARD is simpler — that better matches "retire the old, no parallel systems." On a
  feature branch the sim need not boot mid-refactor: commit clearly-tagged WIP checkpoints so progress
  persists, and drive it back to a verified working state (windowed + `SIM_REPORT`) BEFORE merging to
  the dev branch / `main`. The non-breaking discipline is only mandatory on the shared integration branches and when
  another writer depends on the code right now. Weigh it each time: pick temporary-break-then-fix-forward when
  it yields materially cleaner code or less throwaway; keep non-breaking when the churn is small either way.
- **Surface held-back-by-code moments — don't just proceed.** If, while doing a task, you realize the
  current code/architecture is a *holdover* that's constraining a genuinely better approach (e.g. a
  2.5D representation blocking a real 3D one, a scripted special-case where an emergent rule belongs, a
  CPU path where GPU/native fits), STOP and SURFACE it to the user: name the relic, describe the better
  approach and what it unlocks, and ask. Do **not** silently work around it (delivering a lesser result
  the user didn't know was a compromise), and do **not** unilaterally rip it out either. The user will
  usually say "yes, change it" — but it's their call, and flagging it is how big upgrades get found.
- **"X can't, because Y" is almost always FALSE HERE. Y is a fact about how the code is written today,
  and the code is yours to change.** Catch yourself writing "this can't use that because it needs
  P, Q, R" and stop: you have just described the current shape and promoted it to a law. The question
  is not "what does this file happen to do" but "what should it do". Every constraint in this repo is
  a past decision, not physics, and there are no downstream consumers to protect.
  - The tell is a sentence of the form "A cannot adopt B because A also does C". Ask instead: should B
    grow C, should C live somewhere else entirely, or should A be split so the part that wants B can
    have it. One of those three is usually right and cheap.
  - Worked example, 2026-07-29: "VoxelWorld can't use LocalAgentDemoHarness because it needs
    --perf-frames, --bench and framerate uncapping". Measuring took one command and showed 20 flags of
    which exactly 3 overlap. The answer was to let the harness own the harness contract (run frames,
    report, screenshot, quit) and leave the other 17 world-config flags where they were. The stated
    blocker was never a blocker, only an unexamined shape.
  - This composes with the held-back-by-code rule below. That one says SURFACE a relic rather than
    silently working around it. This one says the far more common failure is not even noticing you
    worked around it, because you wrote a plausible reason first.
- **Unwired code is an UNFINISHED JOB, not dead weight — the default is to WIRE IT IN, not delete it.**
  When you find a class, module, or subsystem that nothing calls, assume a previous agent ran out of
  session before connecting it, and finish the job. Read it, judge whether the feature is worth having,
  and wire it to its seam. Deleting is the exception and needs a reason beyond "nothing references it":
  the author left an explicit removal condition that is now met, the feature was superseded by something
  that demonstrably does the same job, or the design is genuinely wrong. Say which one applies before
  removing anything. Two worked examples found on the same day: `LAGenome` was a 21-line shim whose own
  comment said "remove once no reference remains", and that condition was met, so it goes; `LAHeatGlow`
  is 38 lines of blackbody incandescence that makes any actor in a fire or lava flow glow straight from
  the field's temperature with no per-case code, and nothing called it, so it gets wired.
  - **Measure "unreferenced" correctly before you believe it.** This codebase loads internals by
    `preload("res://...")` far more than by `class_name` identifier, so a grep for the identifier alone
    reports roughly 50 false positives. Count BOTH identifier references and `res://` path references,
    across `.gd`, `.tscn`, `.tres` and `.cfg`, before calling anything unwired. The real count was 2.
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
  - **The pre-fan-out split is a serialized Phase 0, and it must be seam-directed — not a speculative
    god-object teardown.** You cannot parallelize a refactor of the file everything shares, so do it FIRST,
    by one owner. Start with a cheap **map pass** (a read-only Explore agent) that produces a *collision
    map*: for each planned unit, which shared files it must edit. Then extract **only the coupling seams the
    imminent fan-out actually needs** into new owner-files — the stimulus/broadcast bus, the field-force
    response, the per-phenomenon module — and leave the rest of the god-object alone until something needs
    it (churning code no fan-out will touch is over-engineering; see the Simplicity/Anti-overengineering
    mandates). Worked example: before dissolving the disaster actors, extract `EcologyService`'s broadcast
    seam and `Creature`'s field-force seam into their own modules so each disaster agent owns a new module
    and never re-touches the hub.
- `scripts/check_max_file_length.sh` enforces TWO thresholds on first-party source/config **and MARKDOWN**
  files: a **soft smell limit of `SOFT_FILE_LINES=1300` (WARNING)** and a **hard limit of
  `MAX_FILE_LINES=1500` (FAILS — non-zero exit / CI gate)**. Over 1300 = split it soon; over 1500 = the
  build fails until it's split. It also runs `check_no_direct_refcounted_invocation.sh` (a real gate banning
  `godot -s addons/local_agents/tests/test_*.gd` in automation).
  - **`.md` is checked as of 2026-07-29, and so are `docs/` and the repo-root docs** (`HANDOFF.md`,
    `CLAUDE.md`, `GODOT_BEST_PRACTICES.md`, `ARCHITECTURE_PLAN.md`, `README.md`), none of which any scan
    root previously covered. Prose rots exactly like code: `API.md` reached 1480 lines unnoticed because
    the glob listed source extensions only, and nobody reads to the bottom of a file that long, so the
    claims down there go stale unchecked. **`HANDOFF.md` is subject to this too** — when it approaches
    1300, split it (the per-session log is the part to move out; the roadmap and "Next" list stay).
  - **`scripts/agent_harness.sh lint` IS the gate, and CI runs that exact command**, so a green local lint
    is a green CI. Do not add a check to one and not the other. *(Fixed 2026-07-29. Before that: the
    thresholds disagreed three ways — this doc said 1500, `agent_harness.sh lint` ran at 1000 as advisory
    with a comment claiming it "matches docs + CI", and CI set 1000 in a step named "800 soft warn, 1000
    hard gate". Worse, none of them enforced anything: **`rg` is not installed on the GitHub runner**, so
    `rg --files` failed, the file list came back empty, and the check printed "No matching files found"
    and exited 0 on every push for months. `check_no_direct_refcounted_invocation.sh` wrapped its `rg` in
    `|| true` and reported "passed" the same way. CI also never ran the `:=` typing ban, `@tool` write
    safety, the demo catalogue, the public-surface check or library-only parse — all five are in `lint`,
    which CI now calls.)*
  - **A gate that cannot run must FAIL, never pass.** `scripts/lib_require.sh` provides `require_tool`;
    every gate that needs `rg` calls it and exits **2** (distinct from a violation's 1) when it is absent.
    When you write a new gate, ask what happens if its tool, its target file, or its input log is missing —
    if the answer is "the `if` is false so the step succeeds", you have written a gate that can only ever
    pass. Three of them shipped that way here.
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

- **Main scene / active work:** `addons/local_agents/game/VoxelWorld.tscn` — a
  from-scratch godot_voxel ecosystem sim. Current state, architecture, pending work, and the exact
  run/verify commands are in **`HANDOFF.md`**; the emergent-natural-disasters effort (unified
  `material/MaterialField` substrate + disasters) is tracked in its plan file and built in the
  `feature/emergent-disasters` worktree. The guiding principle is **emergent-everything** (see
  `.../voxel/EMERGENCE.md`).
- **Godot 4.7**, `godot` on PATH. Test/observe via `scripts/agent_harness.sh <command>`; the voxel
  scene also self-harnesses (`-- --run-frames=N` prints `SIM_REPORT={...}`; `--shoot=<png>` for
  windowed screenshots; `--auto-meteor` drops a test impact). A NEW `.gd` `class_name` or
  `.gdextension` only registers after an editor scan — run `godot --headless --editor --quit-after 400`
  once, else classes report MISSING.

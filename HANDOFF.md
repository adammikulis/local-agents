# TODO / Roadmap — Local Agents (voxel-planet caretaker sim)

Master tracker. Main scene: the game boots to `addons/local_agents/game/menu/MainMenu.tscn`
(`project.godot:15`); the flagship sim is `addons/local_agents/game/VoxelWorld.tscn`. Read `CLAUDE.md` +
`addons/local_agents/sim/EMERGENCE.md` first.
*(Paths corrected 2026-07-29. This line gave `scenes/menu/MainMenu.tscn` and
`scenes/simulation/voxel/VoxelWorld.tscn`; neither has existed since the addon-UX directory split moved
everything under `addons/local_agents/{sim,game}/`. Stale `scenes/simulation/voxel/...` paths appear
elsewhere in this file too — treat any of them as pre-split.)*

## ▶ NEXT SESSION — START HERE (this file IS the plan doc; feed it in)
**ROADMAP PIVOT (2026-07-12): 0.4 is now THE EMERGENT PLANET; the living creatures moved to 0.5; the full
solar system moved to 0.6.** 0.4 makes the physical substrate the star — geology + hydrology + volcanism +
climate, all emergent from the ONE field, simulated START TO FINISH (a geological bake: rough world → weathering/
erosion/volcanism/climate run forward → frozen as a livable, beautiful start state you can tend or just watch —
"deism-optional"). Look = CEL-SHADING. See **"0.4 — THE EMERGENT PLANET"** below (the full tiered plan). 0.3.1
shipped on `main` (`v0.3.1`); development is on `0.4-dev`. Read `CLAUDE.md` · `EMERGENCE.md` · memories
(`roadmap-0.4-life-cycle` [pivot], `dissolve-dont-patch`, `perf-first-ruthlessly`, `big-o-first-class`,
`fire-balance-wildfire`, `worktree-shader-import-gotcha`, `three-d-always`); work in a worktree off `0.4-dev`.

---
### ⚑ ADDON-UX SESSION (2026-07-29) — MERGED to `0.4-dev`, lint green
Goal: make `addons/local_agents/` installable and usable without reading its source.
*(Corrected 2026-07-29. This heading said "IN FLIGHT on `feature/addon-ux`, not yet merged", with worktree
`../local-agents-addon-ux` and "**Lint is intentionally RED on this branch** until the renames below land".
All three are false now: the work is on `0.4-dev` as `06d943c` + `c48200c`, the branch and worktree are gone,
and `scripts/agent_harness.sh lint` measured GREEN — "All lint gates passed", `check_public_surface: OK
(25 public, 130 classes reach a dialog)". The "currently FAILS with 24 named offenders" note below is
likewise the pre-rename state, kept only as the record of why the gate was written.)*

**Landed and verified.** Directory split into `sim/` + `game/`; 58 classes canonicalized; dead types
removed (`ModelParams`, `Character`, `RuntimeHealth`, `api/`, `addons/phantom_camera/`); inspector
surfaces for agent/creature/world/field/cognition; every example rebuilt as a real scene (three scripts
deleted outright, the rest cut 40-70%); the addon's icon set. **The acceptance gate passes**:
`scripts/check_dropin_scene.sh` stages a consumer project holding only `addons/local_agents/`, authors
a scene with no script in it, and gets `DROPIN_REPLY=Paris` from a local 4B model. Run it with
`scripts/agent_harness.sh dropin` (3s), or `LA_GATE_MODEL=<path>.gguf` for the full reply mode.

**`LocalAgent.say()` was dead in every install and now works.** The native path needs a `piper` binary
that is not shipped, so `AgentSpeech` went through it and produced nothing, while the streamer already
ran `python -m piper` in `StreamerVoice`. Both now share `agents/SpeechEngine.gd`
(`LocalAgentSpeechEngine`): piper binary, then python piper, then `DisplayServer` TTS, then one warning.
Verified by an independent agent in a scratch project: 78380-byte wav, real PCM, 601 ms.

**New gates, all wired into `agent_harness.sh lint` and each observed failing on purpose.**
`check_public_surface.sh` (only sanctioned public API may reach a creation dialog under the
`LocalAgent` prefix, currently FAILS with 24 named offenders), `check_tool_safety.sh`,
`check_demo_catalog.sh`, and `check_library_only.sh`, which was strengthened after it was found passing
green over three real breaks. Two measured facts are baked into it: an editor scan only loads what
something references, and `load()` on a script with a missing preload returns NON-null while printing
the error to stderr. It now force-loads all 217 scripts (`scripts/parse_all_scripts.gd`) and greps.

**Boundary truths that gate then exposed.** `audio/` is NOT game-only: `CreatureThink.gd:158` and
`sim/actors/{Meteor,LightningStrike,Flood,Volcano}.gd` all call `LAAudioDirector.emit()`, so it
is core and the staging no longer deletes it. `game/ui/SceneEnergyGraph.gd` moved to `sim/streamer/`,
next to the only code that used it, which removed the last `sim/` to `game/` edge.

**Naming.** 23 internal classes renamed off the public prefix, so `check_public_surface.sh` now holds
the line: typing "LocalAgent" in Add Node returns 25 types and every one is meant to be used. The
speech surface was renamed too: `say`/`listen` became `speak`/`transcribe`, because `speak` already
outnumbered `say` 71 to 8 in-tree, `say()` beside `think()` reads as "speak what you thought" (it
vocalizes whatever String you pass), and `listen()` never opened a microphone at all, it transcribed a
file path. `LocalAgentSpeechEngine` moved from `agents/` to `runtime/audio/`, which let
`AgentStatus._speech_ok()` stop asking for a piper binary the addon does not ship and start asking
whether anything can speak. That was the real cause of a healthy install reporting itself degraded.

**Two constants dissolved rather than tidied.** `Meteor` had a flat `1600.0` °C injected on impact
regardless of how it arrived, plus a separate hardcoded orange for the visual, so the look and the
physics could disagree about the same rock. Temperature is now an outcome: heating goes as air density
times speed cubed, cooling as the excess over ambient, and **air density is read from the field's own
`o2_at()`** rather than from a scale-height formula living inside the actor. Measured spread: 600 u/s
in thick air reaches 1541 °C and glows, 300 u/s reaches 140 °C and does not, a 150 u/s lob stays cold,
and 600 u/s in vacuum never lights up but still craters at 1380 °C from kinetic energy alone. None of
that is written down anywhere. `LAHeatGlow` is wired to it, and its header no longer claims creatures
and trees glow: they combust (`Creature.gd:79`), which the code already did correctly.

**Duplicates collapsed.** `LlmService.resolve_model_path()` had its own `MODEL_CANDIDATES` list and a
re-try of a step that could never fire; it now defers to `LocalAgentStatus`, the one resolver. And
**`VoxelWorld.tscn` now mounts a `LocalAgentDemoHarness` like every demo scene.** The stated reason it
could not ("it needs --perf-frames and --bench") was never true: of 20 flags exactly 3 overlapped, and
`LASimReport.snapshot()` already returned the payload in the shape the harness wants. `VoxelHarness`
split into `build_report()`, the harness owns counting, printing, `LA_RUN_COMPLETE` and the exit, and
`--perf-frames`/`--bench` stayed in `VoxelInputController` where they belong. `LAGenome` is deleted,
its own header having set the removal condition. Verified windowed at 200 frames: POP_TRACE at 180,
SIM_REPORT, `LA_RUN_COMPLETE={"code":0}`, exit 0.

**Backstory is wired (2026-07-29, merged).** `LocalAgent` has a long memory: assign a
`LocalAgentBackstoryGraphService` to its Backstory slot, give it an `npc_id`, and every line in and out
is ingested into the SQLite store, with the most relevant memories recalled into a system message ahead
of each prompt. Semantic search first, recent-and-important as the fallback when no llama-server with
`--embeddings` is up. New module `agents/AgentBackstory.gd`; `Agent.gd` gained only exports and two
call sites. `tests/test_agent_backstory.gd` asserts on the RECALLED TEXT, not on any call reporting ok,
because the first version returned ok everywhere and recalled nothing (it looked for row keys
`memories`/`results`/`rows`; the one carrying recent memories is `candidates`). Mutation-tested.

**Still owed in Backstory.** Only conversation memory is connected. Relationship state, belief versus
world-truth with `detect_contradictions()`, sacred sites and rituals, and the oral-knowledge lineage
with transmission hops are all still reachable only by hand. That last one is most of the "signal
spine" 0.5 wants, and it is the interesting one: knowledge spreading between characters with
provenance.

**Correction, same day: quests and factions are NOT the RPG-shaped leftovers this entry first called
them.** That was reading the nouns instead of the signatures.

- **Factions are what `family_id` is already failing to be.** Group identity today is a bare integer
  declared `var family_id: int = 0` (`Creature.gd:250`, mirrored at `Fish.gd:110`) and defaulted to the
  creature's own instance id in the setup path, `c.family_id = int(config.get("family_id",
  c.get_instance_id()))` (`CreatureSetup.gd:119`, mirrored at `Fish.gd:163`).
  *(Citation corrected 2026-07-29: this said the declaration itself was `var family_id: int =
  get_instance_id()` at `Creature.gd:250`. It is not — the instance-id default lives in `CreatureSetup`,
  not on the field. Same wrong quote is at `GODOT_BEST_PRACTICES.md:519` and in item A below.)*
  It carries no name, no founding day and no metadata; it dies with its
  members, so a warren has no existence apart from the animals currently in it; and two groups cannot
  relate to each other, so rival packs and allied herds are not expressible.
  `upsert_faction(id, name, metadata)` plus
  `add_relationship(npc, faction, "MEMBER_OF", from_day, to_day, confidence, source, exclusive)` gives
  all of that AND membership over time, so a creature that leaves one pack for another has a history
  rather than just a different integer. Inter-faction `add_relationship` is territorial conflict.
- **Quests are the long-horizon intention the cognition stack does not have.** Its drives are per-tick
  (energy, hydration, fear). Nothing represents "I have been trying to do X since day N and here is
  where I got to". `update_quest_state(npc_id, quest_id, state, world_day, is_active, metadata)` is
  exactly that. A bird building a nest over days, a herd migrating, an animal seeking new territory
  after being driven out. In this codebase a quest record is not authored content, it is a record of an
  intention a creature FORMED, which is what the slow brain is for and what it currently cannot
  remember having decided.

**`feature/thaw-tropics` is RETIRED (2026-07-29), measured obsolete rather than abandoned.** Both v2 and
v3 are deleted, local and remote. Do not resurrect it without re-reading this.

The patch existed to break an "equatorial ice-albedo freeze-lock" that held `t_eq` at 7C. That
condition no longer exists: a baseline `0.4-dev` run reaches `t_eq` 12.5C by frame 180 and 29.2C by
1080, so whatever fixed it arrived in the intervening work. Measured head to head, same seed 7, same
`--fast=4`, same 1200 frames:

| frame | baseline t_eq / foxes | with the patch |
| --- | --- | --- |
| 180 | 12.5 / 10 | 15.5 / 10 |
| 540 | 18.0 / 10 | 20.3 / 7 |
| 900 | 25.1 / 10 | 29.7 / 6 |

So it solves a problem that is already solved and costs 40% of the fox population doing it, which is
the same fox decline the original author reported and paused on. Two independent observations agree.

Two corrections worth keeping, because both were mine and both were wrong in the same session. The
monotonic `t_eq` climb is the BASELINE's behaviour under `--fast=4` (solar forcing compressed), not
something the patch introduced. And an earlier partial read of only the early samples said the fox
decline "does not reproduce"; it does, from frame 540 on. Caveat on the surviving claim: one seed, one
run, so 10-vs-6 could carry noise. The obsolete-premise finding does not depend on it.

The idea is still sound if the freeze-lock ever returns: insolation-driven melt with an albedo-feedback
bound, in `heat3d_solar_sphere3d.glsl` + `ThermalPass.gd`, 37 lines. `git log --all --oneline` will not
find it after this, so the shape is recorded here deliberately.

**Superseded note, kept for provenance.** `feature/thaw-tropics-v3` replaced `feature/thaw-tropics-v2`, which edited
`scenes/simulation/voxel/material/...` and could no longer be applied at all after the restructure. Same
change, ported onto `sim/` paths, both hunks clean via `--3way`. STILL UNVERIFIED, DO NOT MERGE: the
climate half works (t_eq ~15.5C against a 7C locked baseline, poles cold, sea ice persists) but
population still declines, foxes go extinct, and tmin dipped to -6C against a ~0C baseline. Resume by
pulling death causes at f~2000, checking the -6C is not a new cold-kill, then re-running multi-season
with density-dependent breeding.

**Process lesson worth keeping.** Seven of seven fan-out units FAILED their adversarial verification
first time, and the verifiers were right nearly every time. Two fix agents then introduced NEW false
claims while correcting old ones, so a fix pass needs its own recheck. Eleven dated entries were added
to `GODOT_BEST_PRACTICES.md`; the load-bearing one is that an `@export` nothing reads is
indistinguishable from a working one, and only running the model proved `system_prompt` was dead.

---
### ⚑ LIBRARY-REFACTOR SESSION (2026-07-12) — status at pause (memory: `refactor-0.4-library-integrated`)
The big breaking refactor "make the addon a reusable library + faster + Earth-like living planet." **Merged +
verified on `0.4-dev`** (HEAD `4af6788`), editor-scan-clean, sim_check PASS:
- **LLM unification + rename** — 3 LLM paths (native Agent · CognitionScheduler · StreamerDirector) collapsed
  onto ONE shared `LocalAgentLlmService`/`LocalAgentLlmClient`; async `think_async` on a signal-free worker thread.
  Public node family renamed dropping the stutter: `LocalAgent` / `LocalAgent3D` / `LocalAgentManager` /
  `LocalAgentGraph*` (internal sim classes keep `LA*`).
- **Reusable library** — new `SimWorld` facade node with a first-class `world_type:{SPHERE,FLAT}` + bounds
  exports (sphere = PlanetBody+setup_sphere; flat = FlatGroundTerrain+setup_dims box path); standalone
  `Creature.tscn` + `setup_standalone`; game-optional node registration (core plugin never top-level-preloads
  game scripts); 3 demos (thinking-creature-on-flat-ground · box-field · SimWorld planet);
  `addons/local_agents/docs/USAGE.md`.
- **Voxel-OPTIONAL / AI-in-core** — the AI/behaviour stack (Creature + 26 modules + Fish + cognition +
  FlatGroundTerrain + species) relocated OUT of the voxel tree into core `addons/local_agents/creatures/`.
  `SCENT_*` unified into core `LAScentChannels` (field re-sources from it); ThrownRock/FlameFX via guarded
  `load()`. PROVEN game-deletable: delete `scenes/simulation/voxel/` → a core `Creature.setup_standalone("rabbit")`
  still stands up and runs (CORE_SMOKE ok). The addon's intelligence now needs no voxel world.
- **Perf** — batched the ~10 per-pass GPU submit/sync into one compute_list + barriers; async/trimmed
  next-frame readback (HOT vs SLOW channel sets). **fps ~18 → ~39.** (Lane B3 activity-LOD still owed.)
- **Climate + ecology** — bounded the water-cycle runaway (moisture/snow plateau, warm tropics + icy poles);
  fixed the REAL killer (a biomass-coordinate bug: grazers read biomass at ground, photosynthesis deposits
  ~80u up → starvation, not freezing); **density-dependent breeding** as an emergent local rule (breed less
  when locally crowded) + predator-founding fix (solitary foxes now spawn in family clusters so they can pair
  → foxes breed 10→13). Demographic crash fixed.
- **Tooling** — ocean-fraction dialled back (bias 6→3, `LA_OCEAN_BIAS`); `scripts/screenshot_suite.sh` visual-
  regression tool; stray model-panel "DEBUG/Qwen" window sent off-screen during agent/test runs (`LA_OFFSCREEN`
  in both run wrappers).

---
### ⚑ PERF-FIRST SESSION (2026-07-22) — status at pause
Standing rule for this pass: **performance before adding/expanding anything.** Rescued a proven perf win that
had been sitting unmerged in an existing worktree, merged it, and confirmed the real remaining big lever below.
- **Merged `feature/rts-camera-scale` → `0.4-dev`** (was untracked by this file — found during investigation).
  Lands: **creature animation-framerate LOD** (update stride grows with camera distance; previously measured
  ~2x frame-cost cut at 1080p, re-verified here with a clean smoke boot + a positive fps delta on the
  `LA_NO_ANIM_LOD` A/B knob), **physics-rate LOD** + **distance-LOD'd collision pick shape**, **dirty-gated
  field CPU→GPU uploads** (skip re-upload of unchanged static/water masks), and dropping the counterproductive
  `field_cadence>1` from quality presets (measured *slower*, not faster — the catch-up loop just batches
  steps). Also lands the `--perf-frames` GPU/CPU-split benchmark harness itself (`scripts/perf_bench.sh`).
  Gotcha hit + resolved: after merging, `godot --headless --path . --editor --quit-after 400` is needed on the
  **primary checkout too** (not just fresh worktrees) — merging modified `.gd` files outside the editor can
  leave the local `.godot` global-script-class cache stale (`Nonexistent function 'tick' in base 'GDScript'`
  until rescanned).
- **#20 RESOLVED** (same branch, commit tagged "issue #20" in its own message) — `LlamaServerManager.gd`'s
  "is a server already running?" check is now a single ~200ms probe (was a 1200ms retry spin), and a missing-
  model/failed-spawn result is negative-cached for 3s so a per-frame cognition tick short-circuits to fast
  policy instantly instead of re-probing the filesystem every call. Verified present in the merged code.
- **Naming clarification:** "Lane B3" below and **Keystone C** (0.4 tiers, further down this file) are the
  SAME still-unbuilt item — the **field-level** activity-bubble compute-LOD (every GPU kernel pass dispatches
  the full grid every step; zero dirty/sleep/wake concept exists in `MaterialSphereGPU3D.gd`/`sphere_passes/*`
  today). This is a **different, already-merged** mechanism from the creature-level distance/think-stride
  throttling already in `Creature.gd` (also sometimes called "compute-bubble" in code comments) — don't
  conflate the two. The field one is the real remaining big lever; started below.
- **MERGED: field activity-bubble LOD, first slice.** New ping-pong `activity` channel + `ActivityPass`
  (GATHER-style, models `FireDustPass`) computing a per-cell wake bubble: a cell self-seeds active if burning
  or fuelled+hot-enough-to-approach-ignition (100°C margin), then radiates that as a decaying bubble via
  neighbour-max-minus-decay (no atomics, one GATHER kernel, matches the codebase's existing convention). Gates
  ONLY `fire_sphere3d.glsl` so far — a quiescent cell skips the whole ember-gather + combustion-phase body and
  just persists `fire_out=fire_in`. `activity` is GPU-only (never added to the CPU readback allowlist), so it
  costs zero extra CPU↔GPU traffic. **Not started:** gating the other 8 passes (thermal/atmos/reactions/
  erosion/etc.) — this slice only proves the mechanism on one pass; extend the same `activity`-read + early-out
  pattern per-pass as the next step.
- **Two bugs found + fixed while closing the merge-blocker above** (trying to observe a real fire under the
  gate kept coming back `fire_cells:0` even with confirmed successful ignition — direct field inspection at
  the strike cell showed temp:917°C, fuel:0.4, water:0, o2:0.99, all past-threshold):
  - **`fire`'s CPU readback was permanently demand-gated with no requester anywhere in the codebase.**
    `MaterialSphereGPU3D`'s `SITUATIONAL_CHANNELS` only copies `fire` back to CPU while something has called
    `request_channel("fire")` — but fire has no dedicated actor (fully emergent, dissolved into the substrate)
    to ever make that call; grep confirmed `request_channel()` is only ever called for `"lava"`/`"shock"`.
    `fire_cells()`/`fire_peak` (and any other CPU query) therefore ALWAYS read a stale, zero-seeded array
    regardless of what's actually burning on the GPU — this was true before this session too, not something
    the activity-lod work introduced. Fixed at the one real choke point instead of the ~10 scattered
    `add_heat` call sites: `add_heat` (`MaterialFieldInject3D.gd`) now wakes the fire readback itself, since
    any heat injection can plausibly ignite a fuelled cell.
  - **Trees burned out in ~3 field steps (0.3s sim-time) — user-flagged as "way too quickly."** Root cause:
    `MaterialSurfaceSeed3D.gd`'s `BASELINE_FUEL` (0.4) was sized against a documented `BURN_RATE = 0.045`
    (matching `PHASE_B3_DESIGN.md`'s independent reaction inventory) that drifted to the live kernel's
    `BURN_RATE = 0.12` (`fire_sphere3d.glsl`) — likely an unreconciled wildfire-lethality balance pass that
    raised the burn rate without updating the fuel sized against the old one. Raised `BASELINE_FUEL` 0.4→2.0
    (5x) rather than reverting the burn rate (which governs O2 draw/CO2 emission/spread-window per step, not
    just duration, and risks undoing that deliberate lethality tuning) — a tree now burns ~16-17 steps.
  - **Verified** (multiple `--auto-lightning` runs, 63-400 frames): fire now reaches full intensity
    (`fire_peak` up to 1.0, was capped ~0.4-0.7) and stays alive noticeably longer, while remaining BOUNDED —
    `fire_cells` never exceeded 2 in any sample, no runaway spread. Default (no-ignition) scenario unaffected
    (0 errors, stable populations/o2/co2). Post-merge smoke on `0.4-dev` itself: clean, 0 errors.
  - **Not a full re-tune:** `REFILL_EVERY`/`BIOMASS_FUEL_GAIN` (sustained-fire-from-regrowth dynamics)
    untouched — this only fixed one tree's initial burn duration. Exact player-felt pacing may still want the
    maintainer's live/windowed eye (same convention as camera arc / disease visual tell — headless can't judge
    "does this feel right").

---
### ⚑ RELEVANCE-LOD SESSION (2026-07-23) — Lane B3 / Keystone C extended + unified with creature LOD
Standing rule again: **performance before expanding the world.** Picked up the queued "extend past the fire-only
first slice" item. The literal instruction ("extend the same activity-read + early-out pattern to the other 8
passes") turned out to be unsafe as written — investigation found several of those 8 (thermal's solar/
conduction/buoyancy/cool, gaswind's wind circulation, atmosphere's evap/transport/precip, reactions'
background respiration/photosynthesis/weathering) are continuous, everywhere-active planetary forcings, not
sparse events; gating them on a fire-seeded bubble would have silently disabled them almost everywhere except
near hotspots — a correctness bug, not a perf win. Also redesigned the gate shape itself: a binary
`activity<=0` cutoff draws a hard edge around each active region (a visible seam), so live feedback during
this session pushed it to a continuous relevance-driven **update stride** instead — no cutoff anywhere, a
smooth gradient of compute like a topo map's contour spacing, mirroring the shape `Creature.gd`'s
physics/anim-rate LOD already used.
- **New shared mechanism `addons/local_agents/runtime/LALodStride.gd`** — `relevance_from_distance(distance,
  characteristic_distance)` (smooth 0..1 falloff, exactly 1 at distance 0, no hard cutoff) +
  `stride_for(relevance, max_stride, base_stride=1)` (continuous update-stride from a 0..1 relevance score) +
  `should_run(tick, phase, stride)` (the phase-staggered modulo gate). ONE canonical formula, GDScript for CPU
  call sites, a hand-duplicated GLSL mirror (documented "must match exactly", same convention as
  `FIRE_MIN`/`FUEL_MIN`/`IGNITE_TEMP` already duplicated between `activity_sphere3d.glsl`/`fire_sphere3d.glsl`)
  for GPU kernels, since GLSL can't call GDScript.
- **De-duplication sweep** (found while looking for "what else has the same reinvented pattern"): refactored
  `Creature.gd`'s physics-LOD, anim-LOD, AND its never-converted `_base_think_stride()` NEAR/MID/FAR tiers,
  `Fish.gd`'s duplicate tiering, `CreatureFieldForces.gd`'s sweep stride, `Plant.gd`/`Tree.gd`'s settle-stride,
  and `CompanionController.gd`'s tick stride — all now call the one shared mechanism instead of each
  hand-rolling its own `(tick+phase)%stride` + rate/cap constants (the same duplicated-constant drift class
  that caused the BURN_RATE/BASELINE_FUEL desync bug above). Left alone (different LOD category, not a
  rate-throttle — see commit for the full list): collision pick-shape LOD (binary broadphase toggle),
  `MaterialEjecta3D`'s arc-vs-instant behavior swap, `MaterialCharge3D`'s spatial probe stride,
  `CreatureLeadership`'s countdown-based election timer, fixed global cadences, the LLM slow-brain cooldown.
- **Field relevance = `max(activity-bubble, camera-proximity)`** — the activity-bubble GATHER/self-seed/decay
  mechanism from the first slice is kept (extended with new self-seed predicates for erosion/soil/lava/
  storm-charge/dust, each verified against its real kernel's own threshold constants), OR'd with a new,
  purely-geometric camera-distance relevance term (the field's first-ever camera-awareness — previously the
  field simulated the whole grid regardless of where the camera was). Composes the repo's own stated principle
  ("a region is stepped if active OR near the viewer") instead of leaving it as only-activity.
- **6 kernels gated onto the continuous stride** (was: fire-only, binary): `ErosionPickupPass` (copy-through
  persist), `SoilPass` (pass 0 only — pass 1/apply stays unconditional so a same-step neighbour inflow is never
  dropped), `ThermalPass`'s `lava_phase` leg only (`magma_buoy` explicitly NOT gated — its 2-pass donor/
  receiver transfer would lose mass under per-thread gating; needs a wake-on-inject fix first), `GasWindPass`'s
  `charge_accum` leg only (skip branch keeps applying `CHARGE_LEAK_QUIET` so residual storm charge still decays
  instead of plateauing), `FireDustPass`'s `dust_outscale`+`dust_transport` (finishing the first slice), and a
  retrofit of `fire_sphere3d.glsl` itself onto the same mechanism (was the one binary holdout).
- **New telemetry** `active_cells()`/`mean_relevance()` on `MaterialFieldQueries3D.gd` (demand-gated readback,
  self-requesting since — unlike fire's `add_heat` — there's no natural per-event injection site for a derived
  channel) + `LA_NO_ACTIVITY_LOD` bypass (forces relevance=1.0 everywhere via one push-constant, mirrors
  `LA_NO_ANIM_LOD`/`LA_NO_PHYS_LOD`) + a monotonic `_step_index` field-step counter on `MaterialSphereGPU3D`.
- **Verified correct** across every gated system: quiescent smoke (0 errors), `LA_NO_ACTIVITY_LOD=1` bypass
  (`mean_relevance` reads exactly 1.0 and `active_cells` hits the full grid, confirming the bypass reaches
  every gated kernel), `--auto-volcano` (lava_total nonzero, mineral ledger stable), `--rain` (soil/rock_fill
  stable, h2o_total sane), `--auto-thunderstorm` over the full storm+decay cycle (`charge_peak` rises through
  the storm 0.05→0.61, bolts fire, then decays — proving the quiet-leak fix rather than a false plateau).
- **HONEST perf finding — no measurable fps win yet, and here's exactly why (so nobody re-measures and
  concludes the mechanism is broken):** `field_dispatch_ms` (CPU-side command-recording, ~0.13-0.19ms) was
  IDENTICAL with the gate on vs. `LA_NO_ACTIVITY_LOD=1` off, even though `active_cells` correctly dropped from
  the full grid to ~43% on a quiescent scene — because (1) this build has **no GPU-side execution timer**
  (`gpu_ms` in the PERF report is always `0.00`; nothing in this codebase currently measures actual shader
  execution time, only CPU-side command submission, which is roughly constant regardless of what a shader's
  threads branch into), and (2) even if it were reduced, `field_readback_ms` (a CPU↔GPU buffer-size-driven
  transfer, ~4.4-4.7ms) dominates `field_dispatch_ms` by ~25-30x, so total `field_ms`/fps is insensitive to
  dispatch-side savings until readback itself is addressed — exactly the "async/partial GPU field readback"
  item already flagged below as the dominant remaining sim cost. **The gating groundwork (the shared
  relevance channel, the LALodStride mechanism, 6 verified per-kernel gates + the retrofit) is real,
  correct, and the necessary foundation** for (a) extending to the still-ungated bigger kernels once they get
  proper per-record/composite gating (Reactions, EcoSurface — deliberately deferred this round, see below) and
  (b) the readback fix making dispatch-side savings visible again. Treat this as infrastructure banked for a
  future win, not a completed perf win — don't re-claim "field is now faster" from this alone.
- **Explicitly deferred, with reasons (so a future session doesn't re-read the old "extend to 8 passes" text
  and re-attempt the unsafe ones):** `magma_buoy_sphere3d.glsl` (mass-transfer race, needs wake-on-inject);
  `AtmospherePass` (ocean is a perpetual unconditional source); `ReactionsPass` (background biology active
  almost everywhere — would need per-record gate bits, a separate design); `EcoSurfacePass` (mixed sparsity,
  already relatively cheap — future measured follow-up); `SolidDerivePass` (foundational, runs before
  relevance even exists, negligible cost); `ThermalPass`'s continuous legs and `GasWindPass`'s continuous
  legs (wrong shape for a decaying/distance relevance gradient regardless of stride vs. binary).

---
### ⚑ REPO-HYGIENE + ROADMAP-ACCURACY SESSION (2026-07-23) — pruned dead branches, corrected stale checklist claims
A plain "update HANDOFF.md" ask, taken as a cue to verify this file still matches reality rather than just append.
Audited every non-`0.4-dev` branch/worktree and cross-checked two T2 checklist items against the actual code —
found both the branch list and the roadmap text had drifted.
- **Pruned 3 stale worktrees** (`la-feature-ecosystem-equilibrium`, `la-feature-population-sustain`,
  `la-integ-pop` — flagged "prune when convenient" since the earlier completed ecosystem task #14; all
  confirmed clean, no uncommitted work). Their branches (`feature/ecosystem-equilibrium`,
  `feature/population-sustain`, `integ/population`) hold commits `81e2349`/`29bd642` whose content is verified
  **byte-identical to what's already in `0.4-dev`** (diffed `SeaIceTextureBaker.gd`/`SeaIceShaderController.gd`
  — zero diff) — but `git branch -d` refuses them ("not fully merged", since they landed via hand-port/squash
  rather than a real merge, so they're not literal ancestors). Left the branch refs in place rather than
  force-delete (`-D` is on the never-without-explicit-request list) — safe for the maintainer to `-D` directly.
- **Deleted `feature/0.4-parallel-tracks`** (0 commits ahead of `0.4-dev` — a genuinely empty/never-used branch,
  `-d` succeeded cleanly).
- **Found 2 fully-orphaned duplicate branches with no live worktree**: `worktree-wf_91b2a1d4-ae2-2` and `-3`
  (byte-identical to each other, tip dated 2026-07-10) — leftovers from an old Workflow-tool fan-out. Checked
  all 15 of their unmerged-by-hash commits (Ctrl+scroll brush sizing, meteor barrage, geosync arc-down zoom,
  radial crust→mantle→magma terrain grading, camera invert-X/Y, Linux export fixes, …) against the current tree:
  **every one is already present in `0.4-dev`** under different commits (the `workflow-worktree-base-quirk`
  salvage pattern — hand-ported/re-applied rather than merged). `git branch -d` still refuses both (same
  non-ancestor reason); left for the maintainer to `-D`.
- **Two T2/Phase-3 roadmap claims were stale — corrected below, not just appended:** grepped for
  `fertility_at`/`SeaIceTextureBaker` expecting stubs (per this file's own text) and found real, wired,
  SIM_REPORT-reported implementations instead:
  - **Sea ice at poles is DONE** — `SeaIceShaderController`/`SeaIceTextureBaker` exist, are instantiated in
    `VoxelWorld.gd` (`_sea_ice_shader.setup(...)`), and bake real polar-cap coverage from the `_snow` channel
    on static-sea surface cells. Marked `[✓]` below.
  - **Fertility readback is DONE and NOT on a side branch** — `fertility_at`/`fertility_peak`
    (`MaterialFieldQueries3D.gd`) read a real GPU channel fed by R15 fungus-decompose, reported in SIM_REPORT
    (`fertility_peak`), fully in `0.4-dev`. **Correction (this claim was itself wrong, fixed same day — see the
    fertility-uptake session below): `CreatureExcretion`'s feces deposit did NOT feed fertility at the time
    this was written** — it only wrote a scent/food cue (`deposit_waste`), despite its own docstring claiming
    otherwise; only carcass decomposition (`CreatureRagdoll`→`deposit_detritus`) fed the real loop. Fixed
    later the same day, see below. **What was genuinely still open** (confirmed by grep — `EcologyPlants.gd`'s
    tree-seeding/growth logic calls only `_biomass_at`, never `fertility_at`): the loop wasn't CLOSED —
    fertility was produced and measurable but nothing consumed it to modulate plant growth. **Also fixed same
    day**, see the fertility-uptake session below.
  - The **"Confirmed field/GPU bugs" `deposit_detritus`→GPU / detritus-readback / full-fertility-loop** bullet
    below (written during the 0.3 bug-hunt, before this was built) is likewise stale — `detritus_peak`/
    `fungus_peak` are real and nonzero now. Left the bullet as a dated historical record but flagged it
    resolved-except-for-plant-uptake so a future session doesn't re-investigate it from scratch.

---
### ⚑ FERTILITY-UPTAKE SESSION (2026-07-23) — closed the "fertility feeds plants" gap, in `feature/fertility-uptake`
Direct follow-through on the gap the repo-hygiene audit above just named: nothing consumed `fert` to modulate
growth. Worked in a dedicated worktree (`la-fertility-uptake`, pruned after merge) since this touches the
generic DEFS reaction engine — a shared substrate seam, not a docs edit. Merged to `0.4-dev` clean.
- **R19 photosynthesis now takes FERT as a second reactant** (`MaterialReactions3D.gd`): extent is capped by
  `min(co2, fert/FERT_UPTAKE_COST)` — Liebig's-law-of-the-minimum, using the EXISTING generic reactant-cap+debit
  loop already used for CO2 (no new rate model). Wired `fert[live]` into `ReactionsPass.gd` +
  `reactions_sphere3d.glsl` (new binding 9, `read_ch`/`add_ch` cases) the same way `fungus` already is — its
  real per-step producer (`EcoSurfacePass`'s scent_fert diffuse/leach + fungus_fert decompose-deposit kernels)
  runs LATER in the same step, so binding the LIVE half (not BACK) is the correct convention, matching the
  driver's own documented ordering rules. FERT is a genuine conserving debit (plants actually consume soil
  nutrient), not a read-only rate multiplier.
- **Found + fixed a second gap while wiring this**: `CreatureExcretion.deposit()`'s "feces" path called
  `deposit_waste` only — a SCENT/food-cue deposit, never `deposit_detritus` — despite its own docstring
  claiming "feces enriches the soil (emergent nutrient cycle)". Only carcass decomposition
  (`CreatureRagdoll`→`deposit_detritus`) fed the real loop; a living population's waste did nothing for the
  soil it stood on. Fixed: feces now also deposits real detritus (1:1 `FECES_DETRITUS_YIELD`, mirroring
  `CreatureRagdoll.DETRITUS_YIELD`'s carcass convention). Deleted `Creature._deposit_waste` — a dead 3-arg
  forwarder with zero callers left over from before this fix changed `deposit()`'s signature.
- **Tuning — the first coefficient guess was ~25x too strong, caught by measurement, not shipped blind.** A
  naive per-cell estimate (fertility_peak observed ~3-6, CO2-capped extent ~0.02-0.06/step) suggested
  `FERT_UPTAKE_COST=0.5` would rarely bind. WRONG: a same-seed A/B (seed=777, both runs hit the identical
  eruption/impact timeline, isolating the code change from the disaster-load noise this repo already knows
  about) showed it crashed `biomass_total` 9514→1873 (−80%) and `fertility_peak` 6.31→0.36 (−94%) — a
  per-step SINK competes against the stock's NET ACCUMULATION rate, not its peak, and the new drain was
  comparable to or larger than the entire rate that built the peak over 600 steps in the first place; a
  self-reinforcing collapse (less biomass → less respiration/detritus → less decompose → less fert → even
  less growth), not the intended "only barren ground throttles" behaviour. Cut to `FERT_UPTAKE_COST=0.02`:
  re-measured same-seed A/B showed biomass/fertility within normal range of baseline (a modest ~25-35% pull,
  not a cliff), creature count and starvation deaths actually slightly BETTER than baseline (noise from a
  slightly different disaster count, not a regression).
- **Verified, not just tuned:** a same-seed 2000-frame long run (the standard "does it hold over slow-emergent
  time" gate) showed `creatures` collapsing to 39 survivors — investigated before treating it as a regression:
  a same-seed run of the UNMODIFIED baseline code crashed even further (13 survivors) with MORE disasters (17
  impacts vs. this change's 16) and near-identical biomass/fertility. **The population crash is the
  pre-existing, already-tracked disaster-load issue** (memory `disaster-load-unseeded-rng`: sandbox population
  is disaster-load-bound, disasters aren't covered by the sim seed) present in baseline too — not caused by
  this change, and out of this session's scope to fix. `godot --headless --path . --editor --quit-after 400`
  re-run on the primary checkout after merge (the merged-`.gd`-outside-the-editor stale-cache gotcha) +
  a clean 200-frame smoke, both green.
- **Not done / left for whoever tackles the disaster-load issue itself**: the 16-17-impacts-per-2000-frames
  rate this session measured (twice, incidentally) is a concrete, reproducible data point for that pre-existing
  problem — worth citing directly instead of re-measuring from scratch.

---
### ⚑ FIELD-READBACK SESSION (2026-07-23) — demoted 3 channels, built a real benchmark, honest null-ish result
Follow-on to the relevance-LOD session above: traced WHY `field_dispatch_ms` (~0.13-0.19ms) never moved fps —
`field_readback_ms` (~4.4-4.7ms, CPU↔GPU buffer transfer for ~13 "always-hot" channels copied back in full
every drain) dominates it by ~25-30x and is the real remaining field bottleneck. Investigated whether Godot's
`buffer_get_data_async` fixes this — **do not use it**: real, open Godot engine bug
([#105256](https://github.com/godotengine/godot/issues/105256)) returns STALE data for compute-shader-written
buffers on 4.4+ (thus 4.7). Forking/patching Godot itself was considered and explicitly rejected (maintenance
burden of an un-upstreamed engine fork, rebuild-for-every-platform cost) — stuck to GDExtension-side fixes.
- **Demoted `co2`/`fuel`/`rock_fill` from always-hot to demand-gated** (the same `SITUATIONAL_CHANNELS`
  tier `fire`/`lava`/`dust`/`shock`/`activity` already use), each with a verified wake-up hook so the
  existing "fire had NO requester anywhere, always read stale" bug class (see the PERF-FIRST session above)
  isn't reintroduced: `co2_at`/`co2_peak`/`co2_avg` self-request (no natural producer-side trigger for a
  continuously-evolving background quantity); `MaterialSurfaceSeed3D.post_readback` pre-warms fuel 20 drains
  ahead of its 40-drain refill cadence; `MineralStamp3D.arm()` wakes rock_fill (mirrors how `add_heat`
  already wakes `fire`). Verified under real load: `--auto-lightning` (fuel/fire dynamics unchanged),
  `--auto-volcano` (`rock_grows:66` — MineralStamp actively stamping with fresh rock_fill data).
- **`moisture` looked like the same kind of win on paper (no creature reads it directly) — investigated and
  correctly reverted.** Tracing `avg_cloud_cover()`/`moisture_total()` found they funnel through
  `_atmos_dirty`, which gets set true every drain regardless of which channel actually refreshed (temp
  always does, and the condensate formula needs both), and `VoxelSkyCycle` polls `avg_cloud_cover()` at
  ~150Hz. Demoting moisture would either go stale or get re-requested every drain anyway — verified this
  BEFORE committing rather than shipping a no-op "optimization." A caution for next time: an "always-hot
  channel with no per-frame consumer" search has to trace through cached-aggregate choke points
  (`_atmos_dirty`-style dirty flags), not just grep for direct per-cell array reads.
- **Built durable benchmark infrastructure** (requested mid-session, not a one-off): `--quality=<preset>`
  (potato/low/medium/high/ultra, same Engine-meta pattern `--smoke` already uses); `--seed=` (seeds Godot's
  global RNG — world-gen AND disaster intensity/site draws read it directly, unlike `LASimRng`'s own seed,
  which does not cover disasters, per the existing `disaster-load-unseeded-rng` gap); `--bench=<name>` +
  `--bench-interval=N` — a **scripted, deterministic event timeline** (`BENCH_TIMELINES` in
  `VoxelInputController.gd`, currently one entry: `"readback"`) that fires the same disaster calls the
  `--auto-*` flags use but at CHOSEN frames, plus periodic `BENCH_SNAPSHOT={...}` lines mixing timing gauges
  (fps/field_dispatch_ms/field_readback_ms/field_ms — noisy, read as directional) with count/state gauges
  (active_cells/mean_relevance/fire_cells/lava_total/charge_peak/bolts/co2_avg/fuel_total/rock_fill_total/
  mineral_total/h2o_total/creatures — deterministic given the same timeline, the trustworthy signal).
  `--bench=` auto-applies a fixed default seed unless `--seed=` overrides it.
- **Honest result, not a claimed win.** A seeded `--bench=readback` run at `--quality=medium` + 1080p
  (`LA_RES=1920x1080`), before vs. after the channel demotions, showed `field_readback_ms` moving in BOTH
  directions across the run's snapshots — within this machine's apparent timing noise floor (this session's
  investigation surfaced that concurrent GPU/CPU load from other processes on this machine is a real
  possibility, and raw fps/ms numbers should be read as directional, not precise, unless corroborated).
  The count/state gauges tracked sanely and closely between the two runs (mineral conservation held; fuel/
  lava/charge trajectories were close given the same seed), so the change is CORRECT — just not proven as a
  measurable win. **Also found: even with a fixed `--seed=`, back-to-back runs are close but NOT
  bit-identical** (229 vs 225 creatures at the same frame) — most likely physics-tick/real-delta coupling
  reacting to actual system load between runs, not an RNG gap. Not chased down this session; a real
  determinism question for whoever next needs bit-exact reproducibility (a fixed physics timestep
  decoupled from wall-clock would be the natural fix, if the engine isn't already doing that).
- **Not done:** GPU-side reduction kernels for the many `report()` aggregate queries that read back a FULL
  per-cell array just to loop it on CPU for one sum/max/avg (`hot_cell_count`, `active_cells`/
  `mean_relevance`, `soil_total`, `sediment_total`/`susp_total`, `_open_temp_stats`, `mineral_total`,
  `scent_cell_count` — prioritized in that order by real callsite frequency × array size, see the
  investigation this session ran). Likely the larger remaining lever on the readback side; use
  `--bench=readback` (or a new timeline) to measure it for real once built, not an unseeded organic run.

---
### ⚑ THOUGHT-PANEL + GPU-TIMER SESSION (2026-07-24) — right-side stream UI + a real (if unresolved) engine bug found
Two asks in one session: a UI request (see the click-a-creature thought panel) and "can you make a GPU-side
execution timer" (following up on the perf sessions' honest "no GPU timer exists" finding). Both merged to
`0.4-dev` in `feature/thought-panel-gputimer`; verified (editor-scan clean, same-seed run lands in the known
biomass/fertility/mineral range, no errors).
- **Thought-inspector panel rebuilt as a full-height RIGHT-side sidebar** (was a small bottom-left popup) with
  a new scrolling "recent thoughts" STREAM beneath the current-thought summary — the ask was to see fast vs.
  LLM/teacher reasoning as a stream over time, not just the current instant. `LACognition` gains a bounded
  (cap 40), de-duplicated decision history (`history()` — only appends on a genuine action/kind change, so a
  creature holding one behaviour for many ticks doesn't spam the log); `LACreatureThought.history_line()`
  phrases each entry consistently with the existing star-line wording. `CreatureThoughtPanel.gd` renders it in
  a `ScrollContainer` that auto-scrolls to the newest entry, full O(cap) rebuild per refresh (same cheap
  "coarse timer, never per-frame" convention the panel already used for its detail lines).
- **GPU-side execution timer — real progress, but still returns 0 in this driver, root cause NOT fully found.**
  Instrumented `MaterialSphereGPU3D.step()` with `RenderingDevice.capture_timestamp` markers per pass (the
  driver's own `field_dispatch_ms` only ever measured CPU-side command-*recording* time, never actual GPU
  execution — the exact gap the relevance-LOD/field-readback sessions already flagged as blocking honest perf
  measurement). Found and FIXED a real, confirmed Godot 4.7 engine constraint along the way: **capture_timestamp
  is illegal while a compute list is open** ("Capturing timestamps during compute list creation is not
  allowed") — the original single-big-list design (all 11 passes in ONE `compute_list_begin()`/`end()`, per the
  B1 perf note) was silently having every capture discarded. Fixed by giving each pass its own
  `compute_list_begin()`/`end()` pair with `_rd.full_barrier()` (legal outside a list) replacing the old in-list
  `compute_list_add_barrier` — still exactly ONE `submit()`+deferred-sync per step, so the B1 win (10 blocking
  round-trips → 1) is NOT reintroduced; ending/reopening a list is pure CPU-side recording, not a round-trip.
  **Still unresolved:** even after that fix, `get_captured_timestamps_count()` reads 0 in THIS driver
  specifically, for every real pass, even the smallest possible case (one pass, one capture pair, no barrier).
  A large battery of isolated repros — matching the capture pattern, the deferred-submit/sync-next-tick timing,
  a `_physics_process` callback, 11 distinct compiled pipelines, push constants, realistic dispatch scale
  (127k-cell-equivalent buffers/groups), 400 cumulative iterations, and running concurrently embedded INSIDE
  the live busy scene — all reproduced CORRECTLY (real nonzero counts under Vulkan/MoltenVK). The one remaining,
  genuinely untested candidate is this driver's total GPU resource footprint at `setup()` time (dozens of
  buffers/uniform-sets across all 11 passes, vs. every synthetic repro's much smaller footprint) — a concrete
  next lead for whoever picks this up, documented in the `step()` comment so it isn't re-investigated from
  scratch. The plumbing itself is correct and harmless (degrades to 0 exactly as before the change).
- **Separately confirmed: Metal's own `get_captured_timestamp_gpu_time` always returns 0** in this Godot 4.7
  build regardless of the above — verified with an isolated repro showing real nonzero deltas under
  `--rendering-driver vulkan` (MoltenVK) on the same machine, `cpu_time` working fine under both. `Metal` stays
  the project default (`scripts/run_sim_offscreen.sh`, matching years of shader work verified against it) but
  the wrapper now takes `LA_RENDER_DRIVER` to override it (e.g. `LA_RENDER_DRIVER=vulkan …`) for a one-off
  diagnostic run. A quick visual spot-check (orbit-view + `--water-cam` screenshots) showed no rendering
  difference between backends, but that was NOT a thorough per-shader check — flip the project default only
  after a real one.

**REMAINING (pick up in this order):**
- **~~#22 — ice-albedo equatorial freeze-lock~~ CLOSED, premise obsolete.** *(Corrected 2026-07-29. This
  bullet called it "THE self-sustaining blocker" and pointed at "**WIP on branch `feature/thaw-tropics`
  (`f1f53c7`, DO NOT MERGE — unverified)**", with a resume recipe: pull death causes at f≈2000, check the
  −6°C, re-run multi-season. That branch was retired and DELETED earlier the same day, and the
  freeze-lock it existed to break no longer happens — baseline `0.4-dev` reaches t_eq 12.5°C by frame 180
  and 29.2°C by 1080. The full head-to-head is in the thaw-tropics entry near the top of this file, which
  this bullet sat 400 lines away from and contradicted. Nothing to resume.)*
- **A4 — dogfood: rebuild `VoxelWorld` → Anima.** Refactor the 730-line inline `VoxelWorld._ready` to COMPOSE
  from `SimWorld` + the reusable nodes, and RENAME the game `VoxelWorld` → **Anima**. HELD for direct/supervised
  handling — it rebuilds the composition root, so it needs a launched-window verification, not fire-and-forget.

**Branch/worktree state (re-measured 2026-07-29): there is nothing left to prune.** `git branch -a` shows
only `0.4-dev`, `main` and their remotes; `git worktree list` shows the primary checkout alone.
*(This paragraph previously asked the maintainer to `git branch -D` five branches —
`feature/ecosystem-equilibrium`, `feature/population-sustain`, `integ/population` and the two orphaned
Workflow leftovers `worktree-wf_91b2a1d4-ae2-2`/`-3`. All five are gone. So are the `feature/addon-ux`
and `feature/thaw-tropics*` branches other entries still reference.)*
`sorting.py` at repo root is the maintainer's, untracked — leave it.

---
**Shipped this session (0.4-planet, on `0.4-dev`):** camera terrain-follow anti-clip · rivers DECOUPLED from
mountains (gentle ridges + rivers carved into the SDF along real D8 drainage, flat areas too) · debug/QoL
(companion keys in controls, altitude readout, perf readout, wireframe/overdraw) · cognizer-adapter seam (early
0.5) · **Wave-1 planet lanes: cel-shaded toon look + emergent biome coloration (moisture×temp), analytic
scattering sky + moon tides + sphere-aware ocean, altitude lapse + latitude Coriolis/orographic wind.** Fixed a
worktree gotcha: fresh worktrees need `godot --headless --path . --import` or the GPU field is silently dead
(biomass=0) + get_spirv spam.
**~~In flight / held~~ — all landed except lava tubes.** *(Corrected 2026-07-29. This said fire-balance,
hot springs and lava tubes were "on feature branches" and that the fuel/fertility/storm-charge fixes were
"HELD on `integ/substrate-cognizer` pending the fire-balance merge". None of those branches exist, and
three of the four are demonstrably in `0.4-dev`: `BASELINE_FUEL = 2.0` (`MaterialSurfaceSeed3D.gd:34`, the
fire-balance retune), `CHARGE_LEAK_QUIET = 0.4` (`charge_accum_sphere3d.glsl:55`, the storm-charge
quiet-leak fix), `FERT_UPTAKE_COST = 0.02` (`MaterialReactions3D.gd:102`, the fertility uptake). Hot
springs are emergent from the aquifer and reported as such — `hot_spring_stats()`
(`MaterialFieldQueries3D.gd:224-250`) is wired into SIM_REPORT at `MaterialFieldReport3D.gd:80`. **Lava
tubes are the one genuinely unbuilt item**: `grep -rl 'lava_tube\|lavatube' addons/local_agents/sim/`
returns nothing.)*

**Shipped in 0.4 so far** (merged on `0.4-dev`, editor-scan-clean, behaviorally verified):
- **Living-creatures fan-out** — literal **DNA** (codon strand → traits, replaced LAGenome) + heritable
  cue-priors · **chemical affinity** (learned taste/scent cues; toxic plants teach avoidance; social spread
  via observe) · **digestion/metabolism** (gut buffer; waste → field) · **per-creature reproduction**
  (courtship→gestation→birth; dissolved the breeding god-tick) · **emergent evolution** (selection +
  mutation). `Creature.gd`/`EcologyService.gd` split into one-owner modules (Phase 0 done).
- **Evolution-observation harness** — `LA_EVO_FAST=N` compresses breeding (full factor) + lifespan (sqrt)
  so a viable population turns over generations in seconds; `aversions` + population **gene-means** in
  SimReport make affinity + selection measurable.
- **Player time controls** — pause/slow/play/fast (Space · `,`/`.` · Home) + **snapshot timeline**:
  reverse (J) + fork (resume forward = divergent future). Snapshots are **actors-only** (~100 KB,
  perf-over-parity: life reverts, field flows on; `LA_SNAPSHOT_FIELD=1` for full); OFF in the harness
  unless `LA_SNAPSHOTS=1`.
- **Camera** — ground-walk (WASD/edge-scroll when zoomed in), critically-damped smooth zoom
  (`ZOOM_SMOOTH_TIME` knob), eased arc-down to eye level, sunnyside + moderate zoomed-in start.
- **World + water + disease (this session)** — RTS approach-arc camera + ground-level **campaign** start
  (one rabbit herd, no plants, zoom-locked) + altitude-aware blue-sky lighting. **Ocean-heavy Voronoi
  planet** (~72% sea, cellular continents) + **land-biased spawn**; **2× radius (500)** for a flat
  village-scale horizon (field shell + relief/feature/ocean scale with the radius → same cell_count/perf).
  **Emergent water**: mass-scaled water **sweep** + plant **rooting** (uproot) · **flood = cloudburst**
  (no conjured water) + **smite population governor** · **soil water table** (GPU channel: infiltration
  with a bone-dry hydrophobic-crust FLASH-FLOOD hump, holding capacity, baseflow; in the conserved h2o
  ledger). **Disease/pests/immune** (`#7`): data-driven strains (`data/diseases/*.json`), contact/airborne/
  waterborne/pest transmission, incubation→immune-fight→symptoms(energy/HP/fever/**lethargy→easier prey**)→
  recover-with-immunity or die; **constitution** is now a heritable gene so epidemics evolve resistance.

- **Planet-correctness + geophysics pass (this session, part 2)** — a multi-agent REVIEW workflow
  (`planet-correctness-review`, read-only + adversarially-verified) found 7 real substrate bugs; 5 fixed:
  the **aquifer had no receiver-capacity cap** so the water table collapsed to the bottom shell + valley
  springs dried out (fixed → land surface water 4200→5600+, **rivers finally work**); advection could
  **manufacture moisture** (Courant clamps summed >1, tightened to 1/3); a **snow-mass leak** (SNOW_MIN
  clamp, now conserving); **combustion O2/CO2 written to the discarded ping-pong half** (fixed to BACK);
  a one-sided flood ring. Plus: **3D groundwater AQUIFER** (regolith band + bedrock floor + Darcy flow →
  perennial springs/rivers), **water-sweep perf** (raycast throttle 123ms→22ms), **water-cycle balance**
  (bounded the h2o drift: rain-threshold + evap), **faked PLATE TECTONICS** (drifting Voronoi plates →
  quakes + rare arc volcanoes at boundaries = a Ring of Fire), **coast avoidance** (land walkers don't
  drown off islands), a **"Generating planet" loading screen**, and the RTS **camera arc** (bows/swoops,
  less steep, smoothed space→sky transition). Long-run STABILITY verified: temperate (no thermal runaway),
  bounded water, playable perf. Design captured in `docs/PLANET_GEOPHYSICS.md`.

- **UX / camera / sky polish (latest)** — camera drag flipped to natural GRAB-THE-GLOBE (drag right rolls the
  globe right) + middle-mouse free-look aim; BOTH now honour the Controls invert-X/Y toggles (the recurring
  "backwards" is now a user setting, not a code guess). **Space↔atmosphere CROSSFADE** — the sky shader stays
  active and fades blue-atmosphere ↔ black-space-with-stars via a `space_amount` uniform (= 1−surface_blend)
  with ambient+fog lerped, replacing the hard background-mode flip that read as an instant switch + white-out
  (surface ambient trimmed 0.70→0.55). **DISCOVERABILITY GAP (owed):** the trainable-pet controls are hidden
  keybinds (select a creature → B feed/tame · J come · L stay · N follow · O free · Y select-companion) with NO
  on-screen hint — should surface a bond bar + the keys in the creature inspector panel. Rivers are viewable via
  DEBUG-panel "Rivers (drainage)" or `--debug-rivers`; lakes/rivers render as blue water when zoomed in close.
- **WATER IS NOW USABLE — mostly-land planet with rivers + lakes** — the Voronoi CELL_VALUE continents
  (flat plateaus + cliff borders) FRAGMENTED drainage, so switched to COMBINED FRACTAL NOISE in
  `SpherePlanetGenerator`: smooth simplex-fBm continents (long slopes → long rivers) + a RIDGED-multifractal
  valley layer (dendritic river valleys) + basin undulation (lakes) + detail; `ocean_bias` went NEGATIVE so it's
  MOSTLY LAND (low regions = sea; tunable `LA_OCEAN_BIAS`). Result: green/tan continents, snow ridges, ~196 lake
  cells + 371 river cells seeded (STATIC water on the emergent drainage — `MaterialFieldLakes3D` priority-flood
  basins + D8 flow-accumulation channels), 34 fps. Debug: `--debug-rivers` / DEBUG-panel "Rivers (drainage)"
  highlights the network; `--water-cam` aerial view; per-vertex-salinity shader (fresh clear, salt deep) +
  `FAR_ALT`-gated near-cap surface (smooth sphere when pulled back). Fixed: solar-view sky (black space + stars),
  LMB=orbit / MMB=aim camera. NEXT (water polish): close-full-screen-water perf ~16-27 fps; hydraulic-erosion
  pre-pass would carve true incised valleys (the maintainer endorsed pre-sim; noise got us to usable).
- **0.4 BIO upgrades SHIPPED** — FISH COGNITION (fish forage/flee/school with energy via the shared cognition,
  eating transfers energy) · TRAINABLE PET (tame by feeding, command come/stay/follow — keys B/Y/J/L/N/O;
  needs live play-test) · ADAPTIVE MICROBIOME (gut flora re-cultures to lived diet, modulates digestion) ·
  GRADED SENESCENCE (juvenile→prime→old, age-declining vigour → generational turnover). All per-creature
  disease-seam modules; verified windowed (~50 fps, stable). Built by a Workflow fan-out; a worktree-base quirk
  meant the coordinator salvaged/integrated by patch+cherry-pick (see the workflow-base memory). Still open:
  fertility actually feeding plants; pet+senescence play-feel tuning.

- **FLUID RENDERING — the water is finally VISIBLE** — the `water` field channel was simulated but
  drawn NOWHERE; resurrected the abandoned `MaterialFieldRender3D` + wired the full `VoxelWater.gdshader`.
  ONE dynamic surface unifies **sea + lakes + rivers** with per-vertex salinity (fresh↔salt seamless), Gerstner
  swell, `splash()`→ripple ring buffer, shoreline foam. Near-camera tangent-frame patch (small cap, ~4.5 Hz
  rebuild, altitude-gated so orbit/overview keeps the cheap smooth sphere). **Standing lakes** via priority-flood
  depression-fill (`MaterialFieldLakes3D`) seeded STATIC (permanent, like the sea — the dry-land equilibrium
  can't hold a perched lake); terrain **basin relief** term undulates the plateaus. Physics: Clausius–Clapeyron
  evap, aquifer waterlogged up-seep. **Sky fix**: the solar-system view now shows black space + stars (was a
  false sky/horizon dome — `surface_blend` didn't force space in solar/fly). Verified windowed (planet globe
  from space; sea + islands render). Merged to 0.4-dev. `#18/#20/#21/#23`.

**Next — pick up here:**

A. **Backstory as the creature social/memory substrate (NEW, 2026-07-29; the store is wired to
   `LocalAgent` and everything below is now a config away rather than a build).** Reading the API
   instead of the nouns changed what this is worth. Three things the sim currently fakes or lacks have
   a first-class representation sitting unused:
   - **Factions take over the AFFILIATION half of `family_id`; lineage stays where it is.**
     `var family_id: int = 0` (`Creature.gd:250`, `Fish.gd:110`), defaulted to the creature's own
     instance id at `CreatureSetup.gd:119`, is one integer meaning two different things: who you are
     descended from, and who you run with. `upsert_faction` + `add_relationship(npc, faction,
     "MEMBER_OF", from_day, to_day, ..., exclusive)` gives a warren an existence independent of the
     rabbits in it, a membership HISTORY when a creature leaves one pack for another, and
     faction-to-faction edges for rival packs and allied herds.
     *(Two corrections, 2026-07-29, both measured. (1) The declaration quote was wrong — see the
     addon-UX entry above. (2) "kin logic already keys off `family_id` everywhere" is FALSE, and it
     made this look like a bigger sweep than it is. There are exactly four readers:
     `CreatureFlocking._kin_regroup` (`:68-81`, the lost-creature recovery path only — ordinary
     flocking groups by the `species_<name>` scene-tree group and never reads family),
     `CreatureLeadership.nearest_family_adult` (`:129-157`, the juvenile→parent hop only; every other
     election is species-group + rank), `Creature.hear_call` (`:918`) and `Cognition.observe`
     (`:476`), the last two via `CognizerAdapter.gd:57`/`:97`. The last two are kin-WEIGHTED social
     learning, which wants lineage and should keep reading it — do not convert those to factions.
     `KinshipGraph.gd:4-14` documents lineage immutability as the invariant that keeps the per-frame
     kin check a cached int compare; that invariant is correct for bloodline and is exactly what dated
     membership must NOT be forced into. Split the two meanings rather than swapping one for the other.)*
   - **Quests are the long-horizon intention the cognition stack has no representation of.** Drives are
     per-tick. Nothing holds "I have been trying to do X since day N, and here is where I got to".
     `update_quest_state(npc_id, quest_id, state, world_day, is_active)` is exactly that, and in this
     codebase it is not authored content: it is a record of an intention a creature FORMED, which is
     what the slow brain is for and what it currently cannot remember having decided. A nesting bird, a
     migrating herd, an animal seeking territory after being driven out.
   - **Oral knowledge is most of the signal spine** item 4 points at. `record_oral_knowledge` +
     `link_oral_knowledge_lineage(source, derived, speaker, listener, transmission_hops, world_day)` is
     knowledge spreading creature to creature WITH PROVENANCE, so a rumour can be traced, distorted
     across hops, and be wrong. Pair it with `upsert_npc_belief` vs `upsert_world_truth` and
     `get_belief_truth_conflicts` and a creature can hold a belief the world contradicts, which is the
     substrate for the affinity/veto learning in item 1 rather than a parallel system.
   **PREREQUISITE nobody had noticed (found 2026-07-29): the world has no elapsed time, so nothing here
   can be dated yet.** `add_relationship`, `update_quest_state` and `record_relationship_interaction`
   all hard-require `world_day >= 0` (`BackstoryRelationshipOps.gd:8-9`), and there is no day counter
   anywhere to give them. `VoxelSkyCycle.gd:253` is `_time_of_day = fposmod(_time_of_day + delta /
   DAY_LENGTH, 1.0)` — it wraps and never accumulates; `WorldSaveState.gd` persists no day; there is no
   `LASimClock`. `AgentBackstory.record()` sidesteps it by hardcoding `world_day = -1`
   (`AgentBackstory.gd:69`), which is legal for memories and rejected outright by all three calls above.
   So a monotonic day counter comes FIRST, and it belongs in its own module that the sky, ecology, saves
   and store all read — not bolted into `VoxelSkyCycle`, which is a rendering node. `set_world_time()`
   already exists on the store and nothing calls it; that is where the clock publishes.

   Sequencing: the clock, then factions, then quests (needs a slow-brain hook to write them), then oral
   knowledge (needs the other two). None of it needs a model: the store is SQLite and only semantic
   recall wants embeddings.

0. **Water — the maintainer's eye (can't headless well):** close-up sea/lake *aesthetics* (fly to a coast — the
   near-cap patch looked blocky at overview distance, should read better up close); tune spring/rain so visible
   flowing RIVERS emerge (the terrain drains to the sea + has few enclosed basins, so the SEA is the abundant
   water and lakes are rare — rivers need a stronger persistent highland source); confirm blasting a below-sea
   crater near camera shows water (dynamic sea) vs. rock above sea (`#20`, needs interactive blast test).
1. **Windowed verification pass** (cannot be tested headless): reverse/fork *feel* · zoom curve (tune
   `ZOOM_SMOOTH_TIME`, 0.62 now) · affinity/veto behavior (watch creatures learn to shun toxic plants).
2. **Chemistry channels** — the "convert everything to chemicals" half still owed: toxin/nectar/nitrogen as
   real field substances (diffuse/deposit/decay) so affinity learns about actual chemicals, not just food
   tags. See "Chemistry to add" + Phase 2 below.
3. **Deeper evolution** — for coherent deep-generation runs, also scale metabolism/eating with
   `LA_EVO_FAST` (only life-events are compressed now, so high factors starve the population).
4. **Phases 1–5 below still stand** (signal spine · nutrient cycle · pet companion) — the affinity/scent-cue
   path is a partial down-payment on the signal spine, and item A above is the other half: scent carries
   a signal through the air, oral knowledge carries one from creature to creature with provenance. Read
   A before designing the spine from scratch, the store already models the hard part.
6. **Windowed feel-tuning** (the maintainer's eye, can't headless): camera arc pose + ground brightness
   (`SURFACE_AMBIENT`) · disease *look* (a sick-animal visual tell was left for tuning — the emissive
   tint-overlay path in `Creature._apply_tint_overlay` conflicts with the debug behavior-tint, so wire it
   throttled/on-change) · planet size (500 now — bump `PLANET_RADIUS`, everything else scales).
7. **Visible perennial rivers** — the water is now RENDERED (see the milestone above), so this is no longer a
   "can't see it" problem but a SUPPLY one: the dry-land cycle equilibrium drains any land water to the sea, so
   persistent flowing rivers need a stronger continuous highland source (spring baseflow, orographic rain, or
   snowmelt) that outpaces evaporation. Standing lakes are seeded static; rivers still owed. `#10`.
8. **Off-camera statistical creature LOD** (`#13`) — aggregate off-screen populations by equation, freeing
   per-individual cost; re-materialize on approach. Deferred (risky) — a marquee scalability win.
9. **evo_fast + disease balance**: under `LA_EVO_FAST` the population declines (death > birth, few
   generations) so multi-generation SELECTION on `constitution` isn't observable there; normal play is
   stable (~174). Tune the breeding/lifespan/disease-mortality balance in evo_fast mode to see selection.

10. **Camera controls to live-tune** (need your hands, can't headless): the drag X/Y felt reversed after the
    arc change, and right-click should PIVOT the view rather than drag-rotate the globe like left-click — but
    RMB currently doubles as spawn-placement, so that's a control-scheme decision. Also confirm the arc feel.
11. **Volcano heat-shedding** — sustained/multiple volcanoes bake the planet over a long game (temp runaway),
    so tectonic arc volcanoes are kept RARE as a band-aid. The `planet-fix-validation` workflow is
    root-causing whether the surface radiative sink is too weak; fix it to re-enable frequent volcanism.
12. **Big planetary events** (deep-geophysics arc, `docs/PLANET_GEOPHYSICS.md`) — real crust FRACTURING (#15),
    the Theia giant-impact (#16), and true emergent PLATE TECTONICS (#17, the faked version shipped is the
    first slice). Research-grade; design with the maintainer.

Deferred to **0.5** (captured in `docs/ROADMAP_0.5.md`): grow-the-planet baking · emergent erosion + sediment
(hydraulic/glacial/thermal/aeolian) · full 3D groundwater aquifer → head-pressured emergent springs.

Dev knobs added this session: `LA_EVO_FAST` · `LA_SNAPSHOTS` / `LA_SNAPSHOT_FIELD` · `ZOOM_SMOOTH_TIME` ·
`LA_POP_CEILING` / `LA_NO_SMITE` (smite governor) · `LA_DISEASE_SEED` / `LA_DISEASE_STRAIN` (disease).

### Faster iteration — dev-speed levers (USE THESE)
- **`scripts/run_sim_offscreen.sh`** — off-screen, focus-safe, SILENT-audio verification wrapper (now on the
  branch; agents no longer re-copy it).
- **`--smoke`** — boots the sim at the minimal (Potato) config for fast "parses + runs + no NaN" checks;
  reserve the full sim for the final gate. **`scripts/smoke_check.sh`** — one-command behavioral gate
  (asserts 0 errors/NaN, population/herds/field/fps invariants; exit 0/1). *(landing at end of 0.3.)*
- **Save-based test fixtures** — load a committed stable-world save → short delta → assert, instead of
  booting + growing a world each run (faster + deterministic). *(landing at end of 0.3.)*
- **Pre-write contracts + seam-directed splits** (above) = maximal parallel agents. **Prefer `--fast`**
  time-scale for slow-emergent verification (compress ecological/geological time to seconds).
- **0.4 dev-loop wins in the roadmap:** async/partial GPU field readback (the dominant sim cost → speeds
  EVERY verify) · a cached/prebuilt native binary (so native changes don't need a full godot-cpp rebuild).

## North-star
- **Dissolve, don't patch (THE CORE):** ONE physical substrate (`MaterialField3D`) — matter with pressure/
  temperature/phase/gravity/momentum + chemistry (a generic DEFS reaction engine). Named phenomena
  (volcano, eruption, tornado, storm, weather, decomposition, …) have **zero dedicated behavior code**; they
  EMERGE. Removing a hack (a timer/cap/`restock`-from-nowhere/special-case) and making it emergent is the
  **definition of done, not an optional feature.** Success = special-case code DELETED.
- **Emergent-everything** · **3D always** (no 2.5D holdovers) · **GPU/native-first, GPU-GLSL-only** (no CPU
  oracles) · **perf-first** (playable frame-rate is first-class) · **Big-O first-class** (better-scaling
  structures + do-less-by-relevance/LOD + activity bubbles) · **bias to action** · **config over `if
  species==X`**.
- **Dual-purpose:** a reusable Godot dev tool (the `LocalAgent` LLM node) AND a full game that is the
  flagship demo. Local LLMs drive creature cognition + the streamer, fully offline — headline this.

---

## 0.3 — THE CARETAKER GAME (current release — nearly done)

A caretaker god-game on an emergent chemistry planet, driven by local LLMs, shipping as a native itch.io
download. **The game is feature-complete, playable (~67 fps default @ 720p), and exports to a standalone
build that boots.** Everything below is MERGED on `feature/sphere-followups` unless noted.

### Done + integrated
- **Emergent world:** cubed-sphere chemistry substrate (one conserved H₂O; DEFS reaction engine; biomass/
  photosynthesis; rock/mineral unified; GPU water-particle render). Solar terminator, geothermal **hot core +
  temperate surface via crust insulation**, water cycle, snow line, carbon loop.
- **All disasters DISSOLVED** into the substrate (Volcano/Meteor/Tornado/Hurricane/Earthquake/Thunderstorm-
  Lightning) — momentum/ejecta + charge→bolt + shock + local heat/vapor injection primitives; disaster actors
  are seeds/visuals only. Emergent phenomenon **event tracker** feeds the streamer + telemetry.
- **Outer-Wilds N-body gravity + moving-frame solar system:** meteors are test particles (orbit / flyby /
  slingshot / launch anywhere); the planet carries a heliocentric orbital state driving the **sun across the
  sky, seasons (23.5° tilt), and insolation** (orbit-distance² × atmospheric dust → **bake / freeze / impact
  winter**); a **moon** orbits the planet; a meteor **volley knocks the planet toward the sun or out of the
  system** (momentum). Debris/ejecta perf-bounded (pooled). Full literal planet-flight = 0.5.
- **Living, learning creatures:** clustered herds + permanent **kinship graph** + sticky leadership;
  **value-based cognition** (multi-sense reward valence — pain/fear/suffocation/cold; drive-modulated risk
  tolerance; learned-lethal **veto**; social aversion spread; **followers learn too** → ~95% of the population
  learns, not just leaders). Family-tree inspector. **Sustainable ecosystem** (renewable pasture, capped
  breeding, prey pyramid — stable ~130). Fish eat bugs/shrimp (aquatic web given a bottom).
- **The game:** campaign **progression** (start constrained → unlock overview → orbit → geosync → **solar-
  system view** capstone) · **Sandbox** mode · gamified **HUD** (objectives/progress/unlock toasts) ·
  **main menu + settings** · **quality settings** (Graphics Potato/Low/Medium/High/Ultra + separate Sim/AI
  category, numeric sliders, per-setting tooltips) · **save/load** (full world + learned cognition + kinship +
  progression, slot-based) · in-UI **tutorial** (first-run campaign) + **help/reference** (controls auto-gen
  from the hotkey registry, codex, tooltips) · **hotkeys** (digit-select palette + full map) · audio/music
  (salted; silent in editor/debug, on in the release) · human **huts**.
- **The local-LLM showcase (the identity):** click a creature → its **actual on-device reasoning** (thought
  inspector) + the streamer; **LLM-thinking control** (per-creature/group on/off + highlight/select who's
  thinking/queued).
- **Model UX:** in-game **downloader** (ungated Q4, size + EMA ETA) + **model management** (HF-cache reuse,
  bring-your-own GGUF, rich inference config).
- **Release/tooling:** native **itch export** (presets + build script + `docs/EXPORT.md`; boots standalone) ·
  **credits** screen + `AUTHORS`/`CREDITS.md`/`THIRD_PARTY_LICENSES.md` (Kenney, Quaternius, Zylann/godot_voxel,
  engine, models) · **quickstart node** + identity/origin README + demos ladder · **crash-on-quit fixed**
  (native `LAProcess._Exit`, rc 0) · GPU teardown/RID cleanup · 3D-query port (sphere-correct field reads) ·
  perf (**vegetation MultiMesh instancing**, playable default) · **30s trailer script** (`docs/TRAILER.md`).

### 0.3 remaining (the tail)
- [~] **Emergent decomposition + fish fix** (running) — carcasses decompose via a warmth/moisture-gated
  bacterial bloom into the existing detritus→fertility+CO₂ loop (mummification/permafrost fall out free); fish
  no longer suffocate in shallows. (#74 + polish)
- [ ] **Insects + flowers + bees** (#76, next — de-hacking, NOT a feature) — bugs/shrimp eat real biomass/
  detritus (drop the `restock`-from-nowhere hack); add a land-insect layer; flowers + more plants; **bee↔flower
  pollination mutualism** (visiting spreads pollen → pollinated flowers spread). Broadens the web for stability.
- [ ] **Rebuild the native extension** (#71) — activate the `LAProcess`/clean-quit primitive in the shared bin;
  verify rc 0 end-to-end. (CI/release build does this automatically for the shipped build.)
- [ ] **Shoot the 30s trailer** (per `docs/TRAILER.md`) + a few looping GIFs for the itch page/README.
- [x] **0.3 shipped** — released as **0.3.1** on `main` (tagged `v0.3.1`; macOS + Linux builds on the GitHub
  release). `0.3-dev` retired; development continues on `0.4-dev`.

---

## 0.4 — THE EMERGENT PLANET (current release — the physical world as the star)

The substrate is genuinely **~70% there**; almost every gap below is **coupling / read-out of fields already
simulated**, not new systems (full audit + file:line detail: the domain-audit synthesis). Guiding: dissolve-
don't-patch · emergent-everything · perf-first · Big-O + activity-bubble LOD · **fakery = the LOD tier** (full
sim in the compute-bubble; cheap analytic stand-ins for distant/dormant/offscreen, re-materialize on approach).

**3 KEYSTONES (everything leans on these):**
- **A — Erosion re-land. SHIPPED.** *(Corrected 2026-07-29. This entry said for weeks that the pickup kernel
  "doesn't exist", and it does.)* `sim/material/kernels3d/erosion_pickup_sphere3d.glsl`, driven by
  `sim/material/sphere_passes/ErosionPickupPass.gd`, registered at `MaterialSphereGPU3D.gd:51` immediately before
  `ReactionsPass` so M3 SETTLE reads the freshly-scoured `susp` in the same step. `susp` is a live phase in the
  mineral ledger, not a dead one. Still owed is the BEHAVIOURAL proof that deltas, beaches, canyons and
  floodplains actually form over geological time, which needs C's fast-forward before it can be observed.
- **B — Moisture→vegetation→albedo. THE ONE GENUINELY OWED KEYSTONE.** *(Visual half SHIPPED in Wave-1 biome
  color.)* Sim half still owed and confirmed still owed on 2026-07-29: `grep -n moisture
  MaterialReactions3D.gd` returns one comment about H₂O conservation and nothing else, so a dry plateau greens
  like a rainforest.

  **The gap is bigger than this entry said, and the fix is not small.** *(Corrected 2026-07-29. This read
  "R19's reactants are CO₂, FERT, light and temp" and prescribed "moisture as a third Liebig-limiting reactant
  beside FERT, plus a germination gate". Light is NOT a reactant — that was the record's own header comment
  being read as if it were the code.)* R19 is
  `_rec(BILINEAR, PHOTO_RATE, CO2, [[CO2, 1.0], [FERT, FERT_UPTAKE_COST]], …, GATE_SURFACE, 0.0, TEMP)`
  (`MaterialReactions3D.gd:220`), i.e. `x = PHOTO_RATE * co2 * temp`, and `:215` says what `temp` is doing
  there in as many words: *"temp = the daylight proxy; the day side is warmer → fixes more"*. **Photosynthesis
  is being driven by the temperature field standing in for the sun.** So a hot desert fixes carbon at night, a
  bright cold polar summer barely fixes any, lava and wildfires feed plants, and volcanic-dust dimming only
  suppresses growth second-hand through cooling.

  It is a plumbing gap, not a design choice, and the kernel admits it: *"NEAR_GROUND / DAYLIGHT: no live record
  needs them yet (would require radial+sun_dir bindings)"* (`reactions_sphere3d.glsl:186`). Both already exist
  in the driver — `heat3d_solar_sphere3d.glsl` computes real per-cell insolation as
  `max(0, dot(cell_radial, sun_dir))`, `radial` is a bound per-cell buffer, and `sun_dir` is already a pass-
  context value (`ThermalPass.gd:150`, `:285-287`). Likewise the `soil` water table is a real channel in the
  conserved H₂O ledger (`MaterialSphereGPU3D.gd:29`, `MaterialFieldLedger3D.gd:104`) with **no biological
  consumer at all** — it feeds infiltration, baseflow and springs only. So Keystone B is: bind real light and
  soil water into the reaction engine, make R19 light-driven with CO₂/water/nutrient as Liebig limits and
  transpiration as a conserving soil→moisture transfer, and delete the temp-as-daylight proxy. Adding a
  moisture cap on top of the proxy would have cemented it.
- **C — Activity-bubble field LOD. SHIPPED IN ITS CHEAP FORM; the asymptotic half is owed.** *(Corrected
  2026-07-29. This entry said "Not built".)* `sim/material/kernels3d/activity_sphere3d.glsl` +
  `sphere_passes/ActivityPass.gd`, registered at `MaterialSphereGPU3D.gd:55` before FireDustPass, computing a
  wake-bubble plus camera-proximity relevance channel, with an `LA_NO_ACTIVITY_LOD=1` A/B knob. But the second
  half of the old sentence is still true: gating is per-cell stride and early-out, so every kernel still
  dispatches the full grid and cells merely bail. That saves ALU, not dispatch or bandwidth. CLAUDE.md sanctions
  the early-out form as the floor, so this is a deliberate stopping point rather than a relic. **Before building
  the O(active) indirect-dispatch version, run the `LA_NO_ACTIVITY_LOD=1` A/B that already exists** and find out
  whether the shipped gating buys measurable frame time. That measurement decides whether the rewrite is worth it.

**TIERS** (SIMULATE = emerge from substrate · FAKE = justified LOD/cosmetic · [✓]=shipped this session):
- **T1 (do first, small):** hot springs (in flight) · moon tides [FAKE] [✓] · altitude lapse [✓] · default-look MSAA/grade [✓ partial] · moisture growth-gate (Keystone B sim half).
- **T2 (core systems):** biome coloration [✓] · **erosion pickup kernel (Keystone A, L)** · weathering + lithification (2 DEFS records) · Coriolis + orographic wind [✓] · snow render from real `_snow` field + honest 0°C freeze · sea ice at poles [✓] · fertility→growth loop [✓ closed 2026-07-23, fertility-uptake session — R19 photosynthesis now consumes FERT as a Liebig-limiting reactant] · emergent river supply (highland baseflow + snowmelt) · **radiative-sink fix** (the one un-dissolved band-aid — lets volcanism be frequent without baking the planet).
- **T3 (visual polish):** cel-shading [✓] · scattering sky [✓] · sphere-aware ocean [✓] · cloud→ground shadows · re-enable sun shadows · grass/ground-cover [FAKE] · climate-typed flora envelopes · glacier flow (retarget slump to `_snow`) · cheap strata [FAKE] · lava tubes (edge-cooling — in flight).
- **T4 (bake + livability):** **activity-bubble LOD (Keystone C, L)** → geotime `--geotime=N` bake → bake-then-freeze orchestration (snapshot path exists) · season/year retune.

**FAKE ledger (deliberate):** tides · far/orbit ocean (mid/ground MUST be real) · accretion (see-once) · plate
tectonics (keep kinematic Voronoi; true tectonics = 0.5) · grass/clouds/strata · **static sea + static lakes (the
livability anchor — a fully-conserved cycle drains land dry).**
**Livability risks:** volcano thermal runaway (→ radiative sink) · high-`--fast` field desync (→ Keystone C) ·
land drains dry (→ spring baseflow) · erosion mass drift (→ cap by stream-power, verify vs `mineral_total`).

**SEQUENCE:** Phase-0 seam ownership (4 shared files: `MaterialReactions3D`, `VoxelTerrainTriplanar.gdshader`,
`heat3d_solar_sphere3d.glsl`, sphere GPU host) — one owner each, consumers staged. Then fan out lanes (Wave-1
climate/terrain-look/sky-ocean SHIPPED; Wave-2 = erosion Keystone A + activity-LOD Keystone C, staged behind the
host-touching fire-balance/hot-springs merges). Critical path: Keystone B all-the-way-through the shader (biggest
"one lawn → distinct places") + Keystone A (highest-leverage sim add) + Keystone C (unlocks the literal formation arc;
if it slips, 0.4 still ships a livable+beautiful+stable planet — "start-to-finish" degrades to climate/ecology settling).

---

## 0.5 — THE LIVING CREATURES (moved from 0.4 — their entire life cycle)

Where 0.3 went broad (the game + emergent world), **0.4 goes deep on the creatures themselves — the whole arc
of a life**, all emergent (one substrate, reaction engine, config over `if species==X`). The creatures are the
star (local LLMs driving the minds). **This section is the approved, sequenced plan** (idea bank:
`docs/0.4_CREATURE_FEATURES.md`; split plan: `docs/0.4_PARALLELIZATION_GUIDE.md`).

> **2026-07-29: the memory/social substrate for this release already exists and is now reachable.**
> `graph/BackstoryGraphService.gd` is wired to `LocalAgent` (see "Next — pick up here", item A). It
> supplies factions with dated membership (the real version of `family_id`), persistent per-creature
> goals with state across days (the long-horizon intention the per-tick drive stack lacks), oral
> knowledge with transmission lineage and hop counts, and per-creature belief that can contradict world
> truth. Design the signal system with that in hand: the "deception" the scope note expects to fall out
> is `upsert_npc_belief` disagreeing with `upsert_world_truth`, and "dialects" are lineage distortion
> across hops. Nothing here needs a model. It is SQLite; only semantic recall wants embeddings.

**Scope decisions (locked):** full living-creatures release, **sequenced** (no single centerpiece) · build ONE
**general signal system first**, then every call/scent/display composes in (deception/dialects fall out) ·
**heritable, not yet evolving** (offspring inherit/blend; no mutation/selection loop pushed) · the **pet
companion is later/stretch** (ecosystem + communication richness first).

**Standing rule (user directive):** whenever a phase gives the chance, **add chemistry to the substrate** (new
conserved substances / DEFS reaction records) and **rip out hand-coded systems** that should be emergent —
don't route around them. This is the definition of done, not scope creep. Concrete 0.4 targets the exploration
already found: Phase 1 deletes the ad-hoc `match call_type` comms branches (`Creature.gd:992-1003`) + per-type
`EcologyStimulus` methods → one emergent signal+learned-meaning path; Phase 3 adds digestion/microbiome/soil
**as DEFS reactions** (chemistry), not hand-coded metabolism; personality/diet become heritable genome config,
not `if species==X`. See [[dissolve-dont-patch]].

### Reuse-vs-build ground truth (from code exploration — anchors)
| Concern | Verdict | Anchor |
|---|---|---|
| Learning core (`reinforce_cue`, `decide`, `learn_and_veto`, reward/valence, veto, social `observe`) | reuse, **generalize off `LocalAgentCreature`** | `cognition/Cognition.gd` (545/144/201/278/227/424) |
| Slow brain (LLM + teacher, budget, perception scans) | reuse, generalize | `cognition/CognitionScheduler.gd:73,220` |
| Kinship graph + `family_id` · Leadership/leader-pin (= pet's "player as Leader") | reuse as-is | `ecology/KinshipGraph.gd` · `actors/creature/CreatureLeadership.gd` |
| Genome (crossover+mutate exist; `eye_fov`/`sense_radius` acuity already heritable) | reuse, **extend** (add personality + diet genes) | `cognition/Genome.gd` (22/92/113) |
| Scent field (5 GPU channels evolve on-device: prey/predator/blood/food/alarm) | **partial — finish CPU wiring** (~4 sites) | GPU live `EcoSurfacePass.gd:205`; stubbed `MaterialField3D.gd:908-937`, `MaterialFieldSphereStep3D.gd:124-145` |
| Sound calls / scare bus (ad-hoc per-type today) | reuse, **generalize** | `ecology/EcologyStimulus.gd:96-144`, `Creature.gd:979-1003` |
| Perception spatial index · Shock/charge read+emit (charge lacks `gradient()`) | reuse as-is | `actors/creature/SpatialIndex.gd` · `MaterialShock3D.gd`, `MaterialField3D.gd:817,1149` |
| Generic signal/stimulus + learned-meaning layer | **must build** (the Phase-1 spine) | only ad-hoc `EcologyStimulus.gd` |
| `Creature.gd` god-file (1042; every workstream routes through it) | reuse, **split #1** | `actors/Creature.gd` |
| Graded life stages / body growth (binary `is_mature()` only) · courtship/gestation | **must build** | `Creature.gd:1017`, `EcologyService.gd:485` |

### Phase 0 — FOUNDATIONS (serialized, one-owner; FIRST, so the fan-out stays parallel)
- [ ] Split `Creature.gd` → modules under `actors/creature/` (hand/carry/throw · damage/death/fling · think-LOD ·
  movement · social/calls · life-stage · nesting-glue · state-tint); split `EcologyService.gd` → Spawner/
  Breeding/Plants/Aquatic (guide Wave 0a).
- [ ] **Generalize cognition off `LocalAgentCreature`** — a small duck-typed cognizer interface + `cognition/adapters/`
  per actor kind (unblocks bee/fish/pet minds). Keep `reinforce_cue` verbatim.
- [ ] **Finish the scent-field wiring** — scatter `_f._scent` in `_apply_readback` (+ `"scent"` in driver
  `read()`), implement `scent_at`/`scent_gradient` (5-packed `base=ch*cell_count`), `deposit_*` → seed +
  `_scent_dirty`, dirty-gated `set_field("scent", …)` upload. Same pattern shock/charge already use.
- [ ] **Extend `Genome`** — add personality/temperament gene(s) + heritable diet/appearance; mutation modest.
- [ ] **Goal-directed foraging: FIND + STEER (user-flagged, foundational — do via workflow/subagents).** Two
  primitives every forager / hunter / pollinator needs and lacks today: **(A) sense the nearest edible** — query
  the shared 3D spatial index by the creature's diet → a target; **(B) steer locomotion toward a chosen
  direction/target** (goal-seek, not just wander/flee). Right now forage has NO food-seeking steer, so a hungry
  bee can't approach a flower (0.3 fell back to proximity pollination). Add both to the generalized cognition +
  radial locomotion so true nectar-seeking, grazing-toward-pasture, and pursuit hunting fall out emergently.

### Phase 1 — THE SIGNAL SPINE (build once; communication emerges)
- [ ] One general **Signal** system: emit (a typed record: medium + payload + intensity) into a medium
  (scent/sound/shock/charge/posture/touch) → perceive (via `LASpatialIndex` + field reads) → **meaning is the
  learned response** (`reinforce_cue`). Refactor the ad-hoc `EcologyStimulus` methods + `Creature.hear_call`
  `match` branches into this path; each concrete signal (alarm scent, mating call, threat display) becomes a
  **data record**, not code. Honest-vs-deceptive signalling, dialects, skepticism fall out.

### Phase 2 — FAN OUT over the spine (Workflow — each workstream = "config a signal + a learned response")
- [ ] **W-COMMS:** scent trails, alarm/mating/contact/food calls, visual displays/postures, touch/grooming,
  seismic (shock), electric (charge + `charge_gradient()`), bioluminescence.
- [ ] **W-SOCIAL:** dominance hierarchy (extend leadership), cooperation (pack hunt/mobbing/sentinel/
  alloparenting), bonding/alliances/reciprocity, play, territory (scent boundaries), migration, culture-spread.
- [ ] **W-FISH minds** (generalized cognition via a fish adapter). **W-BEES** learning + pollinator-driven
  flower selection (needs bee cognition + scent — both unblocked by Phase 0; coordinate with 0.3 #76).
- [ ] **W-TRAITS:** circadian/dormancy (hibernation/torpor/estivation — compose with compute-bubble LOD),
  thermoregulation, crypsis/mimicry, predator/prey tactics, foraging/caching, parental care/teaching, disease/
  parasites, personality-driven behavior, emotional states, habituation.
- [ ] **W-LIFECYCLE:** graded life stages + body-growth curves, courtship/mating (→ kinship mate edge), aging/
  senescence.

### Phase 3 — THE NUTRIENT / METABOLIC CYCLE (#75 flagship)
- [ ] Digestion over time (efficiency set by the microbiome; herbivores need gut flora) + gut-microbiome benefit +
  excretion/pooping (→ soil detritus/fertility + spreads gut bacteria) + soil bacteria/nitrogen-fixers (→ plants
  grow) + death decomposition (0.3 shipped the field-side taste). Bacterial **roles as DEFS reactions**;
  conserved matter food→energy+waste→soil→plants→food. **Prereq status (corrected 2026-07-23, closed same
  day — fertility-uptake session):** the WHOLE detritus→fertility→growth chain is now DONE:
  `CreatureExcretion` deposits real feces detritus (fixed same session — it previously only wrote a scent
  cue despite claiming otherwise), R15 fungus-decompose produces fertility, and **R19 photosynthesis now
  consumes FERT as a second, Liebig-limiting reactant** (`MaterialReactions3D.gd`, `FERT_UPTAKE_COST`) — soil
  fertility genuinely gates plant growth on barren ground without destabilizing already-vegetated land
  (tuned + verified via same-seed A/B, see the session note above). What's still open for THIS phase is the
  narrower remainder: digestion-over-time (a gut buffer instead of instant `feed()`), the microbiome
  efficiency scalar, and nitrogen-fixer bacteria as a genuinely new DEFS reaction (R-NFIX) — the loop-closing
  part is done, the deeper metabolism modeling is not.

### Phase 4 — THE PET COMPANION (stretch — end of 0.4 or 0.5)
- [ ] Large animal + player pinned as permanent **Leader** + **operant conditioning** (`reinforce_cue`) +
  non-verbal need/emotion readout UX. "Not a special system" — the shared richness focused on one bonded
  individual. Only if the ecosystem lands with room.

### Phase 5 — REUSABLE CREATURE NODE + perf/platform (deferred)
- [ ] **Reusable creature NODE (#dual-purpose gap)** — decouple `Creature` behind small interfaces + a default
  adapter so a bare "AgentCreature" works standalone (rules-based) and lights up with a sim + a model.
- [ ] **Async/partial GPU field readback** (#72 — dominant field cost; speeds every verify). **HTML5 web-export
  spike** (#44 — browser-local LLM via WASM/WebGPU + `JavaScriptBridge`, chat/agent first). **Composition-per-
  cell** (#30 — DEFS ~80% there; thin slice when a metal/ore/salt feature is wanted).

### Chemistry to add + hand-coded to rip out (specifics — the standing rule, grounded)
**New DEFS reactions/channels** (`material/MaterialReactions3D.gd`, `_rec(rate_model, k, driver, reactants[],
products[], gate_mask, threshold, driver2)`; slots biomass/O₂/CO₂/detritus/fungus/fertility already exist — the
carbon loop **R15 fungus-decompose** `detritus+O₂→CO₂+fertility` and **R20 respiration** `biomass+O₂→CO₂+detritus`
already close it):
- **Excretion → soil (mostly REUSE):** creatures deposit feces into the existing **detritus** channel
  (`deposit_detritus`) → **R15** already rots it → fertility. Only add a faster **R-MANURE** (BILINEAR decompose
  on a new `manure` slot) if leaf-litter rate is too slow for feces to enrich noticeably.
- **Nitrogen fixation → fertility (GENUINELY NEW):** add an atmospheric **nitrogen** slot + **R-NFIX**
  `nitrogen(air)→fertility(soil)`, BILINEAR/CONST gated (`gate_mask`) on legume-biomass × moisture (the N-fixer
  bacterial role the user named). Conserved (draws from the N pool); makes fertility actually replenish → plants
  regrow. Without this the loop leaks fertility and can't sustain.
- **Death decomposition = UNIFY, do NOT re-add:** a carcass becomes **biomass/detritus in the field** → the
  existing **R20 + R15** rot it → CO₂ + fertility. No new reaction.
- **Digestion + gut microbiome = per-creature metabolism, NOT a field CA** — lives in `CreatureMetabolism`
  (gut buffer: ingested biomass → energy + waste over time, efficiency × microbiome scalar); only its **waste
  output** deposits into field detritus. State this boundary so it isn't mis-built as a DEFS record.

**Hand-coded systems to rip out → emergent** (delete + route through substrate/cognition):
- **Comms (Phase 1):** `Creature.gd:992-1003` `hear_call` `match call_type` branches + per-type
  `EcologyStimulus` methods (`broadcast_call`/`broadcast_scare`, :96-144) → ONE signal record + `reinforce_cue`
  learned meaning.
- **Eating (Phase 3):** instant `feed()`→energy (`Creature.gd:1031` `feed`/`food_profile`/`nutrition`) →
  digestion-over-time gut buffer × microbiome efficiency.
- **Death decomposition (Phase 3):** the bespoke `CreatureRagdoll` `MICROBE_SEED`/`DECOMP_RATE_PER_SEC` bloom
  (0.3's field-side taste) → carcass = biomass/detritus rotted by R20+R15; delete the constants.
- **Breeding (Phase 2 W-LIFECYCLE):** population-tick `EcologyService._tick_breeding` (:485, every 2 s fraction +
  `pop_cap`) → emergent per-creature courtship/mate-seeking + gestation; population regulated by food/energy/
  space, not a global cap.
- **Fish (Phase 2 W-FISH):** brainless config-band swim logic in `Fish.gd` → generalized cognition via a fish
  adapter. **Any `if species==X`** → genome/config (the new personality/diet genes).

### Confirmed field/GPU bugs to fix in the 0.4 field pass (from the 0.3 bug-hunt — deferred as substrate-risky)
- [ ] **Combustion O₂/CO₂ written to the wrong ping-pong half** (`sphere_passes/FireDustPass.gd:82`) — bind o2/co2
  to the BACK half in the fire uniform set so the in-place consume/emit lands on the buffer transport wrote.
- [x] **`deposit_detritus`→GPU + detritus readback + full fertility loop** (`MaterialField3D.gd:1139`) —
  **RESOLVED** as of the 2026-07-23 repo-hygiene audit: `detritus_peak`/`fungus_peak`/`fertility_peak` are all
  live nonzero GPU reads now (R15 fungus-decompose runs, `CreatureExcretion` deposits feces into detritus/
  fertility). Dated historical record of the original 0.3 bug-hunt finding, kept for context — do NOT
  re-investigate this from scratch. The ONE piece still open is plant **uptake**: nothing consumes
  `fertility_at` to modulate growth yet (see Phase 3 above, corrected same session).
- [ ] **Fuel channel allocated to zeros, never populated** (`MaterialField3D.gd:325`) — seed fuel from biomass on
  surface cells + upload, so the fire kernel has something to burn (combustion currently has no fuel substrate).
- [ ] **Organically-grown storm charge can cross breakdown but never fire a bolt** (`MaterialCharge3D.gd:63`) —
  give grown charge the same wake safety-net as injected charge (set a wake flag when accumulated charge exceeds
  threshold) so natural-storm lightning isn't lost to the strided-probe blind spot.
- [ ] **Energy chemistry 0.4 deepening:** the 0.3 muscle-lactate/conserve-drive is the first step — deepen into full
  ATP / glycogen / O₂-gated aerobic-vs-anaerobic chemistry (ties into the nutrient cycle + DNA-driven metabolism).

### Orchestration + verification
Phase 0 = serialized (splits + generalize + wiring). Phases 1→2 = **Workflow fan-out** (`pipeline()`
implement→verify per workstream; worktree isolation; per-agent pre-write contract + behavioural SIM_REPORT gate;
adversarial verify for correctness-sensitive bits). Main thread integrates/merges/gates. Verify behaviourally:
`scripts/smoke_check.sh` while iterating; a long `--run-frames=1500`/`--fast` run + `--shoot` at each phase gate
(population stable, herds/kinship intact, no NaN/runaway, fps good; scent round-trips, a signal's meaning is
learned-not-branched, fish/bees learn, the nutrient loop conserves matter). Windowed launch for the pet.

---

## 0.6 — THE FULL SOLAR SYSTEM (moved from 0.5 by the 2026-07-12 pivot; 0.4=planet, 0.5=creatures)

0.3 shipped the **moving-frame** solar system: the sim stays centred on the planet, but a real heliocentric
orbital STATE drives the sun across the sky, seasons (axial tilt), insolation (bake/freeze/impact-winter), a
moon, and momentum knock-out-of-orbit. 0.5 makes the system **literal + navigable**:
- [ ] **Literal planet flight through space** — migrate the GPU field/ocean to a **moving-frame body-local**
  representation so the planet node can actually translate (not just its orbital state). Unblocks everything
  below. (The one 0.3 relic: `MaterialField`/ocean/water are world-anchored at the planet's start.)
- [ ] **Full multi-body physics** — planets + moons + sun as first-class bodies on real orbits; fly between
  them; land on the moon (give it terrain/field); N-body for the bodies themselves, not just test particles.
- [ ] **Solar-system view renders the real orbits** (the campaign capstone) from the body states.
- [ ] **Persist + save** the orbital state; barycentre drift; slingshot missions; comets.

## How to run / verify
- **Non-interactive (off-screen, focus-safe, SILENT audio) — always use the wrapper:**
  `scripts/run_sim_offscreen.sh --path . addons/local_agents/game/VoxelWorld.tscn -- --run-frames=N`
  → one `SIM_REPORT={…}` line (gauges: fps/field_ms/physics_ms/leaders/followers/…; field/population/cognition
  sections). `--shoot=<png>` for a screenshot; `--campaign`/`--sandbox` to boot the sim in a mode; disaster
  triggers `--auto-{meteor,volcano,lightning,tornado,thunderstorm,hurricane,earthquake}`; `--auto-select`.
  `LA_RES=WxH` sets resolution; `LA_NO_STREAMER=1` skips the LLM streamer; `LA_NO_AUDIO=0`/`--audio` forces
  audio on in dev. Acceptance is BEHAVIOURAL (aggregates sane, no NaN/runaway, fps good) — no CPU↔GPU parity.
- **Gotcha:** a NEW `.gd` `class_name` / `.gdextension` / new `.glsl` registers only after an editor scan:
  `godot --headless --path . --editor --quit-after 400`. Native changes (e.g. `LAProcess`) need the extension
  rebuilt (CI `build-extension.yml` or the local build).
- **Lint/tests:** `scripts/agent_harness.sh <lint|fast|bounded|extension>`; `scripts/check_max_file_length.sh`.

## Where everything lives
- **Front end:** `scenes/menu/` (MainMenu · SettingsMenu + Graphics/Sim sections · CreditsMenu · HelpMenu/tabs ·
  GameSettings/GameMode/GameSave). **Game systems:** `scenes/simulation/voxel/game/` (GameProgression ·
  WorldSaveState/Controller). **Composition root:** `VoxelWorld.gd` (extract-only). **Quit:** `scenes/AppExit.gd`
  + native `LAProcess`.
- **THE substrate:** `material/MaterialField3D.gd` (thin facade, extract-only) + modules `MaterialSphereGPU3D`
  (GPU host) · `sphere_passes/*` · `kernels3d/*_sphere3d.glsl` (authoritative) · `MaterialField{Queries,Inject,
  Snapshot}3D` · `Material{Ejecta,Charge,Shock}3D` · `MaterialReactions3D` (DEFS) · `WaterParticles` ·
  `mesh/VegetationRenderer`.
- **Actors:** `actors/{Creature,Fish,Plant,Tree,Rock,Nest,Food}` + `actors/creature/*` (leadership/metabolism/
  flocking/think/senses/nesting/ragdoll/field-forces); disasters `actors/{Meteor,Volcano,…}` (dissolved →
  seeds/visuals). **Cognition:** `cognition/*` (value-based policy + sparing local-LLM slow brain).
  **Ecology:** `ecology/{EcologyService,EcologySpawner,KinshipGraph}`. **Events/streamer:** `events/*`,
  `streamer/*`. **UI:** `ui/*` (HUD, thought panel, debug, tutorial). **Data:** `data/species/**/*.json`.
- **Reusable addon (dev tool):** `agents/` (LocalAgent + Agent3D) · `runtime/` · `ui/ModelManager*` ·
  `examples/` (AgentQuickstart, demos, DemoLauncher). **Design:** `EMERGENCE.md`, `docs/TRAILER.md`, `docs/EXPORT.md`.

## Guiding principle
**dissolve-don't-patch + emergent-everything** — one substrate, universal rules, named phenomena fall out;
removing a hack to make behavior emergent is the definition of done. See `EMERGENCE.md`.

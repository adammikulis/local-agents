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
### ⚑ INTEGRATION ROUND (2026-07-30, latest) — gravity + terrain-to-field merged, three substrate bugs found

Three worktree-isolated tracks landed and were integrated. **CI green; `0.4-dev` at `c4f16a9`.**

**Merged: the star is a real gravity body.** `LAStar` had no `center()`, so every gravity loop's
`has_method("center")` guard silently skipped it and meteors felt zero solar pull, while the planet's orbit
ran on a separate `SUN_MU` in unrelated units and the visible star sat at a decorative
`SUN_SCENE_DISTANCE = 1200`. Four numbers, four different suns, all gone. The frame is planetocentric and in
free fall, so `LAGravity` subtracts each body's pull on the frame origin and what survives is the tidal
differential: measured +0.114 sunward at r=640 and anti-sunward on the far side, which is the correct
signature and not a global shove. Orbit holds 11880..12122 (2.0%) identically at 700 s and 2100 s.

**An adversarial verify pass caught a real defect in that work, after I had already merged it.** The G cache
validated only that the remembered instance id was still *alive*, never that it was still the reference body.
`reference_body()` falls back to max mass until something declares `is_gravity_reference()`, and the star
outweighs the planet ten to one, so one gravity query in the window between the star registering and the
planet registering latched surface gravity at 1.37 against the intended 55.0, permanently and silently. The
commit that introduced it claimed the opposite, that keying on instance id killed a load-order race; there was
no such race, because the old guard was `if _g_const > 0.0` and a failed calibration returned -1, which
retried. Fixed in `c4f16a9`, with `test_gravity_calibration.gd` as a regression test that is mutation-checked:
reverting the fix fails it with "got 1.372879". Nothing in the shipped boot opened the window, which is
exactly why it needed a test and not a comment.

**Merged: terrain destruction reaches the substrate.** `carve_sphere` only moved the godot_voxel SDF, so a
crater was a hole you could stand in that water would not pool into. `resample_terrain` had zero callers and
wrote `_solid`, which `SolidDerivePass` recomputes from `rock_fill` every step, so wiring it up as written
would have looked correct and done nothing. It now writes `rock_fill`, and the excavated bedrock is moved
rather than deleted: one conserving transfer per cell into sediment and dust, giving impact winter with no
impact-winter code.

**Correction to how that was measured, because it cost me a wrong conclusion.** The default sandbox run spawns
**no meteors at all**. `phenomenon/impact` in a plain run comes from `LAThresholdDetector` inferring an impact
from a heat spike, not from any `Meteor` node. My first integration run therefore reported `crater_cells 0`
with 10 "impacts" logged, and I briefly took that as the merge being broken. Pass `--auto-barrage` (or
`--auto-meteor`). With it, at seed 4242 / `--fast=2` / 150 frames / field_step 746: `crater_cells 110`,
`crater_water 66.8`, `rock_shrinks 95`, `mineral_inject_moved 115.08`, `dust_total 46.38`.
Separately: that track's own commit message quotes one run out of five whose numbers disagree wildly at the
same field_step (`crater_cells` 1, 2, 101, 114, 175). Treat its figures as one draw, not a measurement.

**Verified substrate bug: the neighbour table is not slot-opposite reciprocal.** Confirmed independently on
`0.4-dev` with a from-scratch probe rather than the reporting branch's own `validate()`: at res 24, **5760 of
407808 links (1.412%)** have B listing A in some slot other than the opposite one, producing **5760 send slots
no cell ever reads** and **5680 read twice**. Every 2-pass gather kernel here (soil, water, slump, lava)
computes inflow as `send[neighbour*6 + OPPOSITE(slot)]`, so this destroys mass at the cube-face seams and
duplicates it elsewhere. Measured downstream as `darcy_lost` of -2.13/step in the soil budget. `_seam()`
stitches by nearest direction and cannot promise opposition, because the local (a,b) axes rotate across a face
boundary. Kernel slot order is `[0]=in, [1]=-a, [2]=+a, [3]=-b, [4]=+b, [5]=out`, so the pairs are 0↔5, 1↔2,
3↔4. `validate()` reported `symmetric = true` throughout because it only checked that B lists A *somewhere*.

**Found, not yet fixed: `add_field_sparse` applies nothing in this build.** 1515 per-cell add edits reached it
and it returned 0.0 for every one, while `move_field_sparse` works on the same buffers. That means
`add_water_pooled`'s flood surge has never delivered its water.

---
### ⚑ PHYSICAL-PLANET SESSION (2026-07-30, later) — rotation MERGED, energy balance WIP

Follow-on to the audit below. Addressing the four structural fakes it named. **CI green throughout.**

**MERGED: the planet turns.** Spin was gated behind `not _input.manual_rotate()`, which is
`not (_auto_spin or _geosync)` with both false — so it only ever turned if the player pressed K. It was
disabled to hide a frame mismatch (a world-fixed field against a spinning body smeared an accretion cone
into an arc). The field is **body-local** now. Reparenting would not have worked: the cell↔world mapping
is pure arithmetic off `grid.center` and never consults a transform, so the frame lives in the only two
functions that cross world↔cell space — all ~49 call sites go through them unchanged. `sun_dir`,
`camera_pos` (a POINT, so the origin offset comes out before rotating) and `spin_axis` are transformed to
match. **`ctx["spin_axis"]` had never been set by anything**, so every wind band was referenced to world
+Y while the real axis is 23.5° away. Measured: `night_frac` now spans 0.337→0.614 over 200 frames where
the old clock read `{cur:0.3, min:0.3, max:0.3}` forever. Seasons follow for free — the obliquity was
always there; what was missing is that without spin, day and year are the same period.

**WIP on `feature/energy-balance` (3 commits, DO NOT MERGE).** The mechanism is real; the calibration is
not. Every prescribed temperature target is gone: the surface does `dT = (absorbed − σεT⁴)·dt/C` with
albedo (nothing computed reflectivity anywhere before) and heat capacity from existing channels; the
`ATMOS_RELAX` anchor is deleted; the ocean thermostat and the hot-spring gate that existed only to escape
it are deleted; the core is a bounded flux instead of an infinite Dirichlet clamp. `FREEZE_TEMP` is 0.0 —
the first band-aid gone because the root was fixed.

Three measurements worth keeping, in order of usefulness:
1. **Cutting the solar constant 20% moved the global mean by ONE degree.** The sun was never the dominant
   term. Dimming it to hit an Earth-like number would have been fitting a constant to an outcome; it was
   reverted.
2. **With every prescriber removed the floor sat at 11.06 °C — and the old `AMBIENT_NIGHT` was 13.0.**
   That constant was approximately the GEOTHERMAL equilibrium. The fake had been tracking a real effect at
   the wrong scale.
3. Two conductivities were letting the interior flood the surface. `ROCK_CONDUCT` 0.004→0.0002 (floor
   11.06→9.82), then `VOID_CONDUCT` 0.016→0.0015 (floor 9.82→**4.27**). The second is the vindication of
   *deleting* the anchor rather than tuning it: at 0.096/step over six bonds the atmosphere equilibrated
   globally in ~10 steps — it conducted like a metal, which is exactly the homogenisation the anchor's own
   comment complained about. Real air is an insulator; Earth moves heat poleward by wind, which this sim
   already advects.

**Still short:** floor 4.27 °C, above freezing, so snow and sea ice are zero. Buoyancy mixing and the
ground-hug cells' rock coupling are the next suspects, in that order. Ecosystem unbothered throughout
(176 creatures, 400 trees).

**A JET STREAM IS ONE TERM AWAY, and it is worth knowing before designing anything.** Wind is ALREADY 3D
per cell (`vel_x` tangent A, `vel_y` redefined as outward-radial, `vel_z` tangent B) across 20 radial
shells — height-varying wind is representable today. What is missing is that
`wind_pressure_sphere3d.glsl` is `p = P0 − K_T·(temp − T_REF)`: purely per-cell, no neighbour reads, no
air mass, no density, **no altitude term**. So pressure does not fall with height and the atmosphere has
no vertical structure. A jet stream IS the thermal wind, `∂u/∂z ∝ −(g/fT)·∂T/∂y`, and two of its three
ingredients now exist — a real meridional gradient (from removing the anchor and cutting conduction) and
Coriolis with the correct spin axis. Add hydrostatic pressure and the jet falls out of machinery already
present. Then DELETE `u = −BASE_WIND·cos(3·lat)` in `wind_step_sphere3d.glsl`, an analytic cosine standing
in for a Hadley cell — the same shape as the anchor already removed. Tell that it is load-bearing:
`WeatherSystem` was deliberately weakened so it "must not overpower the field's own latitude bands".

### ⚑ CONSERVATION + FROZEN-FAKES SESSION (2026-07-30) — merged to `0.4-dev`, CI green

Started as "read HANDOFF and do it", became an audit of what this simulation freezes in the name of
performance. Nine merges. **CI passed for the first time in this history** — it had failed on every push
since at least 2026-07-11.

**CI was red for months, and the gates were worse than red — they were vacuous.** `ripgrep` is not
installed on the GitHub runner and never was in the apt list, so `check_max_file_length.sh` printed
"rg: command not found" three times, ended with an empty file list, said "No matching files found" and
**exited 0**. `check_no_direct_refcounted_invocation.sh` wrapped its `rg` in `|| true` and reported
"passed" the same way. Both examined ZERO files on every push while two files sat over the limit. The one
step that genuinely failed required the log to contain `Cognition trace isolation test passed`, from a
test pruned in `e14c79d`. Also fixed: CI ran Godot 4.6 against a 4.7 project; a `perf-benchmarks` job ran
`tests/run_perf_benchmarks.gd`, which does not exist (Godot exits 0 on a missing script, so it burned ~21
minutes a push reporting success for nothing); the "no fallback paths" gate grepped three files under
`simulation/`, a directory renamed to `sim/`; and five lint gates never ran in CI at all. New
`scripts/lib_require.sh` makes a gate that cannot run FAIL (exit 2), never pass. `agent_harness.sh lint`
is now the single list and CI calls it. **Also: an agent session's scratchpad path was committed as the
default log dir**, and `mktemp -t` without X's is BSD-only — both broke the runner.

**`--fast=N` did nothing at all, and every measurement that leaned on it is suspect.** `Engine.time_scale`
had two owners: `parse_cmdline()` applied the flag at `VoxelWorld.gd:177`, then `LAVoxelTimeControl` was
built ~114 lines later and its `_ready()` reset the global to 1.0×. A runtime probe under `--fast=8` read
back `time_scale 1.000` with delta exactly 1/60; matched 300-frame runs gave 135 field steps at
`--fast=1` versus 113 at `--fast=8`. Fixed to one owner. Now 114 → **5705** field steps, 0.06 → **3.97
sim days**, and the day-rollover path executed for the first time. **CAVEAT: at `--fast>=4` the
population dies** (150 frames: `--fast=2` holds 180 creatures, `--fast=4` reaches 0). Creatures tick on
scaled delta while the field is capped by `max_physics_steps_per_frame`. **Use `--fast=2`.**

**Night did not exist.** `LAVoxelSkyCycle` latches `_planet_mode` and returns before `_advance_clocks()`,
so `time_of_day` stayed at its seed: the gauge reads `{"cur":0.3,"min":0.3,"max":0.3}` across a whole run.
`is_night()` answered FALSE for every creature, forever — diurnal animals never rested, nocturnal ones
never woke, and the `night` bit in the learned-policy signature was constant, so **half the signature
space was unreachable and every heuristic any creature has learned is a daytime heuristic**.
`LACreatureLod`'s cost model documents "a fraction of the population is always asleep"; it was not.
Dissolved rather than repaired: `is_night_at(pos)` is `dot(local_up, sun_dir) < 0`. The terminator was
physical the whole time. New `night_frac` (0.479) and `resting_frac` (0.441) gauges.

**Water conservation is now instrumented and mostly honest.** Nothing measured it before —
`smoke_check.sh` only asserts h2o is finite and non-zero, so a run losing half the planet's water passed.
The four ledger legs used four different cell predicates, so any transfer crossing the static boundary
minted or destroyed ledger mass while the GPU buffers stayed conserving. Unified. New gauges:
`h2o_closed_total`, `h2o_drift_per_step`, `static_water_total`, `soil_stranded`, `h2o_inject_minted`,
`h2o_displaced`, `h2o_buried`, `h2o_stale_rewind`. Storms no longer mint water (`add_vapor` is a real
transfer; shortfall reported, `h2o_inject_minted` 0.00). Injections no longer overwrite the live GPU
buffer with a one-frame-stale CPU mirror (`h2o_stale_rewind` measures what that used to destroy: ~15
units a run). `MineralStamp3D` displaces water out of cells it solidifies instead of stranding it.
**Keystone C's asymptotic half started**: compacted active-cell list + indirect dispatch, proven on
`lava_phase`.

**The photosynthesis "-93% biomass regression" was not one.** The old R19 was gated `GATE_SURFACE`, which
on a shell means the TOP OF THE ATMOSPHERE. Measured: biomass at the sky skin 2334, **at the ground skin
0.0**. All primary production was happening in the stratosphere. Comparing that total to ground biomass
is comparing a bug to its fix. Trees and plants are identical across the change (400/400, 439/439).
`PHOTO_WATER_COST` retuned 0.2 → 0.05, which gives MORE vegetation and **six times** the wet/dry contrast:
a cost that heavy makes the water cap bind everywhere, flattening the contrast it exists to create. Same
trap as `FERT_UPTAKE_COST`, which was cut 25× for the same reason.

**What is still frozen, ranked by how much it distorts the sim** (full audit in the session log):
1. **No radiative sink anywhere.** `heat3d_solar` relaxes toward a prescribed target; its own comment says
   that "mirrors radiative cooling to space", and `ATMOS_RELAX = 0.14` is deliberately tuned to OUTVOTE
   real conduction. The ocean is a thermostat dragged to `SST_SURFACE = 26.0` by fiat. The core is an
   infinite constant-temperature source. **Four separate band-aids exist because of this**: `FREEZE_TEMP`
   moved to 12.5 °C because 0 °C "can never fire here", a whole `HOT_SPRING_GATE` invented to escape the
   thermostat, arc volcanoes "kept rare so sustained volcanic heat doesn't accumulate", and
   `CLOUD_OPACITY_CAP = 0.22` clipping a real feedback to stop a snowball runaway. One fix deletes all four.
2. **There are no seasons and, by default, no planet rotation.** `ctx["spin_axis"]` is never set by anyone,
   so the field's pole is world +Y while the planet spins about a 23.5° axis; the heliocentric orbit runs
   entirely in the XZ plane, so the sub-solar latitude is pinned at the equator forever. `SystemOrbits`
   documents seasons it structurally cannot produce. Spin is off by default and is explicitly FROZEN for
   the seabed-volcano demo to hide a field-vs-terrain frame mismatch.
3. **The Star is not in the `gravity_body` group** (`Star.gd` never calls `add_to_group`), so meteors feel
   planet + moon and ZERO solar gravity, while the planet's orbit runs on a separate `SUN_MU` in
   disconnected units — against `Gravity.gd`'s stated HARD PRINCIPLE of "no hardcoded single-centre
   gravity anywhere". One line.
4. **`resample_terrain` has zero callers**, so every meteor crater exists in the mesh and the collision but
   not in the physics. Water will not pool in it.

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
**REMAINING (pick up in this order):**
- **#24 — the dynamic sea, half-done on `feature/dynamic-sea` (2 WIP commits, DO NOT MERGE YET).** The
  `_static` mask is gone: nothing seeds it, every cell is dynamic, all 53 sites keyed on it are dead
  branches awaiting deletion. Conservation improved 6x (`h2o_drift_per_step` -0.145 -> -0.024,
  `static_cells` 0), creatures held, `field_ms` 5.2 -> 10.2 (the honest cost of 3480 newly-simulated
  cells — the active-cell compaction landed for `lava_phase` is what should absorb it). The seabed freeze
  in `soil_sphere3d.glsl` was replaced with the physics it faked: the spring outlet head now includes the
  neighbour's standing water.
  **BLOCKER: `soil_total` still drains, 684 at field_step 53 to 51.8 at 746, root cause unknown.** All
  three transfer legs traced by hand; none should do it. The old 3479 was ITSELF mostly fake (seed 0.3 x
  ~11600 regolith cells, unmoved for 746 steps — nearly the whole "aquifer" was frozen seabed). DO NOT
  target 3479. A fan-out agent is instrumenting the kernel's legs so the drain names itself.
- **#25 — `--fast>=4` kills the population.** Creatures tick on `Engine.time_scale`-scaled delta while the
  field is bounded by `max_physics_steps_per_frame`, so consumption outruns regrowth. Measured, 150
  frames: `--fast=2` holds 180 creatures and biomass 8939; `--fast=4` reaches 1.56 sim days with 0
  creatures. 0.4's listed "high-`--fast` field desync" risk, now reproducible because the flag works.
  **Use `--fast=2` for everything until this is fixed.**
- **#26 — the energy balance is WIP on `feature/energy-balance` (3 commits).** Mechanism complete,
  calibration short: floor 4.27 C, still above freezing, so snow and sea ice are zero. Buoyancy mixing and
  the ground-hug cells' rock coupling are the next suspects, in that order. See the physical-planet
  session entry above for the three measurements that got it there.
- **#27 — accretion cone with spin ON, then delete the freeze.** The `--auto-seavolcano` spin freeze and
  `Volcano.ISLAND_FREEBOARD = 14.0` exist because a world-fixed field smeared a cone into an arc. The field
  is body-local now so the cause is gone, but the capstone was not re-run. Verify the cone builds at ONE
  spot with spin on, then delete both.
- **A4 — dogfood: rebuild `VoxelWorld` -> Anima.** Refactor the 730-line inline `VoxelWorld._ready` to
  COMPOSE from `SimWorld` + the reusable nodes, and RENAME the game `VoxelWorld` -> **Anima**. HELD for
  direct/supervised handling — it rebuilds the composition root, so it needs launched-window verification.

**Branch/worktree state (2026-07-30):** `0.4-dev` is the integration branch and CI is GREEN on it.
Outstanding feature branches: `feature/dynamic-sea` (#24) and `feature/energy-balance` (#26), both WIP and
deliberately unmerged. `sorting.py` at repo root is the maintainer's, untracked — leave it.

### ⚑ STANDING FACTS — engine limits and deferrals rescued from six deleted session logs

Six completed session logs (LIBRARY-REFACTOR 07-12, PERF-FIRST 07-22, RELEVANCE-LOD 07-23, REPO-HYGIENE
07-23, FERTILITY-UPTAKE 07-23, FIELD-READBACK 07-23, THOUGHT-PANEL 07-24) were DELETED on 2026-07-30 —
about 360 lines of finished narrative whose work is merged and whose shipped features are already listed
under "Shipped in 0.4 so far". What follows is everything in them that is still LIVE, which is the only
reason any of it survives. Do not re-derive these.

**Engine limits, measured here, still true:**
- **`buffer_get_data_async` returns STALE data** for compute-shader-written buffers on Godot 4.4+ (open
  engine bug [#105256](https://github.com/godotengine/godot/issues/105256)). Do not use it to fix readback.
  Forking the engine was considered and explicitly rejected.
- **There is NO GPU-side execution timer in this build.** `gpu_ms` is always `0.00`; `field_dispatch_ms`
  measures CPU-side command RECORDING, not shader execution. `capture_timestamp` is illegal while a compute
  list is open (fixed), but `get_captured_timestamps_count()` still reads 0 in this driver even for the
  smallest case. Metal's `get_captured_timestamp_gpu_time` always returns 0 regardless; Vulkan/MoltenVK
  works, and `LA_RENDER_DRIVER=vulkan` exists for a one-off diagnostic. **So read fps/`field_ms` as
  directional only, and never claim a dispatch-side perf win from them.**
- `field_readback_ms` (~4.4-4.7 ms) dominates `field_dispatch_ms` (~0.13-0.19 ms) by 25-30x, so
  dispatch-side savings stay invisible until readback is addressed.

**Keystone C deferrals, with the reasons, so nobody re-attempts the unsafe ones.** The old "extend the
gate to the other 8 passes" instruction was WRONG as written — several of those passes are continuous
planetary forcings, not sparse events, and gating them on an activity bubble silently disables them
almost everywhere. Still deliberately ungated: `magma_buoy_sphere3d.glsl` (its 2-pass donor/receiver
transfer loses mass under per-thread gating — needs wake-on-inject first), `AtmospherePass` (the ocean is
a perpetual unconditional source), `ReactionsPass` (background biology is active almost everywhere —
would need per-record gate bits), `EcoSurfacePass` (mixed sparsity, already cheap), `SolidDerivePass`
(runs before relevance exists), and the continuous legs of `ThermalPass`/`GasWindPass`.

**Still owed on readback:** GPU-side reduction kernels for the `report()` aggregates that read back a FULL
per-cell array just to sum it on the CPU — `hot_cell_count`, `active_cells`/`mean_relevance`, `soil_total`,
`sediment_total`/`susp_total`, `_open_temp_stats`, `mineral_total`, `scent_cell_count`, in that order of
callsite frequency x array size. Likely the larger remaining lever. Measure with `--bench=readback`.

**Determinism caveat:** even with a fixed `--seed=`, back-to-back runs are close but NOT bit-identical
(229 vs 225 creatures at the same frame). Most likely physics-tick/real-delta coupling. A fixed physics
timestep decoupled from wall-clock is the natural fix if bit-exact reproducibility is ever needed.


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

## 0.3 — THE CARETAKER GAME (SHIPPED as 0.3.1, tagged `v0.3.1` on `main`)

*(Heading corrected 2026-07-30: this said "current release — nearly done" long after 0.3.1 shipped. The
feature list below is kept as the record of what the game contains, not as a work list. Three items in its
tail were never done and are NOT 0.3 blockers — insects/flowers/bees (#76), rebuilding the native
extension (#71), and shooting the trailer. Treat them as backlog against a future release, not as
outstanding work on a shipped one.)*

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

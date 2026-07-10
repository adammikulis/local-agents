# TODO / Roadmap — Local Agents (voxel-planet caretaker sim)

Master tracker. Main scene: the game boots to `scenes/menu/MainMenu.tscn`; the flagship sim is
`scenes/simulation/voxel/VoxelWorld.tscn`. Read `CLAUDE.md` + `EMERGENCE.md` first.

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
- **Dual-purpose:** a reusable Godot dev tool (the `LocalAgentsAgent` LLM node) AND a full game that is the
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
- [ ] **Final full-sim verify → merge `feature/sphere-followups` → `0.3-dev` → tag 0.3.**

---

## 0.4 — THE LIVING CREATURES (next release — their entire life cycle)

Where 0.3 went broad (the game + emergent world), **0.4 goes deep on the creatures themselves — the whole arc
of a life**, all emergent (one substrate, reaction engine, config over `if species==X`), realistic within our
confines. The creatures are the star (local LLMs driving the minds).

- [ ] **FLAGSHIP — the living nutrient cycle** (#75): rework digestion (food → gut → energy **over time**,
  efficiency set by the microbiome; herbivores need gut flora to digest plants) + **gut-microbiome benefits**
  (a per-creature microbe scalar aids digestion/health while alive) + **excretion / pooping** (waste → soil
  detritus/fertility + spreads gut bacteria) + **soil bacteria / nitrogen-fixers** (enrich fertility → plants
  grow) + **death decomposition** (the same microbiome overgrows on death; 0.3 ships the field-side taste). A
  handful of bacterial ROLES as substrate reactions; conserved matter (food → energy + waste → soil → plants →
  food). Big systemic feature — re-balance the ecosystem after.
- [ ] **Plant life cycle** — blooming as a real reproductive STAGE: grow → **bloom** → pollinated (bees/wind) →
  seed → sprout → age → die → decompose. Config `reproduction mode`: `flower` (bloom, most angiosperms —
  grasses/broadleaf trees/crops/flowers), `cone` (conifers — wind pollen, no bloom), `spore` (ferns/mosses/
  fungus). Bees boost the flowering ones; wind is the fallback.
- [ ] **Diverse flowers + LEARNING bees + pollinator-driven selection** — each flower species: a distinct
  **scent** (deposited into the scent field), look, and **bloom-time** window (dawn/dusk stagger). Bees LEARN
  which flowers pay off via the existing reinforcement cognition (scent cue → nectar reward → preference) and
  forage by **smell, not sight**. Emergent payoff nobody scripts: bees favor certain traits → pollinate those
  more → those flowers spread → **pollinator-driven selection of flower traits emerges.** (Needs bees to carry
  cognition — same extension as fish minds.)
- [ ] **Trainable Creature companion** (#48) — a large animal that sees the player as its permanent **Leader**
  (reuse the leadership/follower-adoption); shaped by **operant conditioning** — player reward/punish feeds the
  existing `reinforce_cue` learning. Black & White-style. Minimal bespoke code.
- [ ] **Fish cognition** — fish are currently brainless config-band swimmers; give them the same value-based
  cognition the land animals have, so the aquatic life learns too.
- [ ] **Rest of the animal life arc** — growth/juvenile→adult stages + visuals, courtship/mating, aging/
  senescence effects, disease (pathogen-bacteria overgrowth).
- [ ] **Reusable creature NODE (dual-purpose gap)** — only `LocalAgentsAgent` (the LLM node) is drop-in today;
  the sim actors are coupled to the voxel sim (injected terrain/field/ecology/cognition, no `.tscn`). Decouple
  Creature behind small INTERFACES + a lightweight default adapter so a bare "AgentCreature" node works
  standalone (rules-based) and lights up with a sim + a model — a thinking creature a dev can drop into any
  Godot game. Makes the dual-purpose promise fully real.

### 0.4 perf / platform (deferred, not blocking)
- [ ] **Async/partial GPU field readback** (#72) — the per-step full-grid GPU→CPU readback is the dominant field
  cost; async/partial readback cuts it without reducing grid resolution (recover full climate fidelity at high
  fps). Core field-architecture change.
- [ ] **HTML5 web export spike** (#44) — the repo's open issue. Native GDExtension + subprocess llama-server
  can't web-export; but browser-local LLMs are now feasible (wllama/WebLLM/transformers.js via WASM/WebGPU). A
  web-target LLM backend via `JavaScriptBridge`, starting with the chat/agent quickstart (not the full GPU
  planet). Ship 0.3 as native download; this is the follow-on.
- [ ] **Composition-per-cell (metals/ores)** (#30) — the DEFS engine is ~80% there (slot registry); build the
  thin slice only when a metal/ore/salt feature is wanted.

---

## How to run / verify
- **Non-interactive (off-screen, focus-safe, SILENT audio) — always use the wrapper:**
  `scripts/run_sim_offscreen.sh --path . addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --run-frames=N`
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
- **Reusable addon (dev tool):** `agents/` (LocalAgentsAgent + Agent3D) · `runtime/` · `ui/ModelManager*` ·
  `examples/` (AgentQuickstart, demos, DemoLauncher). **Design:** `EMERGENCE.md`, `docs/TRAILER.md`, `docs/EXPORT.md`.

## Guiding principle
**dissolve-don't-patch + emergent-everything** — one substrate, universal rules, named phenomena fall out;
removing a hack to make behavior emergent is the definition of done. See `EMERGENCE.md`.

# CLAUDE.md

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

### EVERY CONSERVATION VIOLATION IS ADDRESSED OR EXEMPTED. THOSE ARE THE ONLY TWO OUTCOMES.

**Maintainer's standing directive, and it is a rule about PHYSICS, not about scope.** Anything that violates
conservation of matter or energy must be **addressed** — fixed — or **exempted**. Exemption is the
maintainer's to grant and nobody else's. There is no third outcome.

**"It is out of scope" IS NOT AN EXEMPTION.** Neither is "that is 0.5 work", "not this track", "a different
subsystem owns it", "it predates me", or "it is recorded in `HANDOFF.md`". Those are scheduling statements,
and **scope is a separate axis from physics.** A violation does not become acceptable because the file it
lives in is scheduled for a later release. If you catch yourself routing a conservation violation into a
backlog, you are exempting it on the maintainer's behalf, which you may not do.

This does not conflict with "fix it AND report it" above. FIXING needs no permission; that is the job. What
needs permission is any path that ends with the violation still live — including deferring it, including
filing it, including deciding it belongs to someone else.

**This wording is the maintainer's correction of a weaker version I wrote**, which said violations need
"explicit approval before you proceed". That framing let scope back in through the side door: within one turn
of writing it I fenced an agent's contract to a single creature-layer violation and left two more parked as
"0.5", which is precisely the move the rule exists to forbid. Addressed or exempted. Nothing else.

**How this was learned.** The substrate creates matter from nothing, and nobody ever asked whether that was
acceptable — it was inherited, described in a tracker as "minting", repeated in agent contracts, and treated
as a background condition rather than a decision. The plan built on top of it was to ADD ANOTHER SOURCE. At no
point was the maintainer asked "is it alright that this violates conservation of matter", by anyone, despite
realism being the stated first goal of the entire project. The failure was not choosing badly. It was never
presenting the choice.

**So, in practice:**
- When you find a physics violation, SURFACE IT AS A DECISION, not as a line in a report. Name the physical
  law, say what the code does instead, and say what fixing it would cost. Then wait.
- "It was already like that" is not consent. Neither is a tracker entry, a code comment, or a previous
  agent's report. Only the maintainer's answer is consent.
- If you are deferring a violation because you are mid-task on something else, that IS the decision that
  needs approval. Say which violation you are leaving live and for how long.
- A euphemism is not a disclosure. "Minting", "not conserving", "drift", "prescriber", "stand-in", "interim"
  — if the plain-language version is "this creates matter from nothing" or "this makes heat appear", use the
  plain-language version when you surface it.

### RULE ZERO POINTS AT EVERYTHING, AND AT THE ENGINE MOST OF ALL. NOTHING HAS TO NOMINATE A TARGET.

**Unless something is written here as an explicit exception, Rule Zero applies to it.** It is not a checklist
you run against the items a document happens to list. If you find yourself reasoning "nothing pointed me
there", you have already failed it — that sentence describes waiting to be told, which is the opposite of the
rule.

**And it applies HARDEST to the engine — the substrate, the reaction table, the integrator, the conservation
machinery — not to the constants those things carry.** A wrong constant is one lie. A wrong ENGINE is a
PERMISSION: it licenses every record ever written against it, in the past and in the future, and no quantity
of correctly-sourced constants redeems it. Constants are the cheapest thing to audit and the least valuable.

**The case that proves it, and it is the worst defect found in this project so far: THE SUBSTRATE CREATES
MATTER FROM NOTHING, BY CONSTRUCTION.** The DEFS reaction engine is a rate table, not a chemistry —
`rec()` takes reactants and products as independent lists with hand-written coefficients and nothing relates
them; `RELAX_TARGET` has no reactant at all, so only its product credit runs; and there is no load-time
validation anywhere, only comments asserting conservation. Every carbon atom that has ever existed in this
simulation was conjured by one record. An agent read `RELAX_TARGET`'s own definition — *"signed; no reactant;
product = driver"* — QUOTED IT IN A PLAN, and did not stop. A reaction with no reactant is matter from
nothing. It then planned to fix a nitrogen shortage by **adding another source**, and the maintainer caught it.

**Two habits follow, and they are cheap:**
- **Translate the euphemism before you accept the claim.** That defect was recorded here for weeks as
  "minting", which makes creating matter sound like an accounting discrepancy — something a better ledger
  catches. Written as "the simulation creates carbon atoms from nothing" it is unmissable. If a phrase lets
  you think about a physics violation without picturing the physics, restate it and re-read your plan.
- **Distrust FRAMINGS, not just facts.** Verifying that a cited file exists is easy and this repo does it
  well. The expensive errors live in the sentence that told you what KIND of problem you have. A tracker,
  a task description, and a prior agent's report are all claims. So is this file.

**Do this UNPROMPTED, on every file you open — including files you only opened to read.** Every item above
was visible in code an agent had already read. Surfacing something is not reviewing it. If you notice a
reality violation while doing something else, **FIX IT *AND* REPORT IT that turn — not one or the other.**
"Or" is an invitation to file a note and move on, which is the lazy route and the one taken by default.
Reporting without fixing leaves the defect in the code; fixing without reporting hides it from the
maintainer. Do both. Do not route around it because it is not your current task — routing around it is the
failure mode, and it is the most common one.

*(Moved here 2026-08-11. It opens by saying "This outranks every other rule in this file" and it sat at line 591, two thirds of the way down, behind five hundred lines of process. A file whose layout contradicts its own stated priority teaches the wrong order to anyone who skims it — and skimming is the normal case.)*

# RULE 1 — DELETE IT. DO NOT PRESERVE IT. THIS OUTRANKS EVERYTHING BELOW.

**If it is wrong, delete it.** Not behind a flag, a mode, a default, an alias, a pad, or a fallback. A switch
that keeps broken behaviour reachable is the same defect with a switch on it. There is no "keep it for
compatibility" here — there are no downstream consumers.

**Ask whether the thing exists in the real world. If it does not, there is nothing to preserve.** Seas are
not static. Mass does not move without its heat. A gas does not ignore the wind. Water does not vanish when
it reaches the ocean. When the answer is "reality has no such thing", delete it — do not parameterise it.

# RULE 2 — YOU PRESERVE NUMBERS, NOT CODE. THAT IS THE ONE THAT KEEPS GETTING PAST RULE 1.

**Rule 1 is obeyed on files and violated on values.** An agent will delete a whole kernel and then carry a
calibrated constant forward untouched, because deleting a file feels like progress and changing a number
feels like cheating. The three things actually protected here are always the same:

- **calibrated constants** — tolerances, ceilings, allowances, "measured X" values;
- **the measurement configuration** — which flags a test run uses, what a baseline was taken with;
- **comparability with past runs**, which is the real motive: a preserved ceiling preserves the meaning of
  every number already reported against it. **The instinct is not attachment to the code. It is attachment
  to one's own previous output still being interpretable.**

**A MEASURED VALUE IS A FACT ABOUT A RUN THAT NO LONGER EXISTS.** The run is gone, the substrate changed,
and the number is a fossil. It is not a bar, and "it was measured" is not provenance — provenance is *what
it was measured against, and is that thing still there*.

**THE TELLS, and every one of them is real, from 2026-08-11, written by me and thought to be rigour:**
- *"a unit conversion, not a re-tuning — nothing was loosened"*, about six ceilings whose every underlying
  run was already known unreadable. Preserving them read as discipline; it was the defect.
- *"we can't default to `--bare` because it changes the numbers"* — about numbers already known to be wrong.
  **The numbers being wrong is the reason to iterate faster, not slower.**
- Any sentence containing *previously*, *still*, *parity*, *unchanged*, *so the comparison holds*, *so the
  baseline stays valid*. That clause is the sound of a fossil being defended.

**AND THE DEFERENCE FAILURE, which is the same mechanism pointed at the maintainer.** He said "never
maintain compat with something you KNOW is wrong" and "you have carte blanche" — and the `--bare` refusal
happened anyway. It was not defiance. It was a REASON, manufactured in the moment, for why an explicit
instruction did not apply to this case. **If you catch yourself constructing an argument for why an
instruction should not apply here, that argument IS the defect.** Do the thing. There is no case where a
number you already know is wrong is worth defending against an instruction to change it.

**WHAT TO DO INSTEAD, mechanically:**
1. An allowance is **zero unless derived**. A conserved substance drifts at zero; the only tolerance a
   ledger is entitled to is arithmetic noise, and that is computed from the format and the cell count, not
   chosen. `LAMaterialFieldConservation3D.noise_floor()` is the worked example.
2. When a subsystem changes, every calibrated number downstream of it is **invalid until re-measured** —
   not "still roughly right". Say it is invalid; do not carry it.
3. Preserve *questions*, never *answers*. "What was this measuring?" survives a rewrite. "0.28" does not.

# RULE 3 — NAME THE CONSTRAINT AS A LAW OR A DECISION. OUT LOUD. EVERY TIME.

**There is already a rule saying "X can't, because Y" is usually false here, and it does not work.** It
asks you to NOTICE, and noticing requires already suspecting — by the time the sentence "the fix is not one
line because Y" is being written, Y has already been accepted. The rule fires after the decision it exists
to prevent. So this one demands an OUTPUT instead, because an output can be checked and a state of mind
cannot.

**WHENEVER YOU DESCRIBE A CONSTRAINT, CLASSIFY IT IN THE SAME BREATH:**

> **LAW** — physics, or the platform. *Headless Godot returns null from
> `create_local_rendering_device()`, so a GPU field needs a window.* Verified today, not assumed; even a law
> gets re-checked when it is load-bearing and old.
>
> **DECISION** — somebody typed it. Then answer three things: **who, when, and does the reason still hold?**
> *`run_sim_offscreen.sh` exited 126 on any conservation violation — a decision, made when the debt table
> tolerated today's drift, and it stopped holding the moment the ceilings became float noise.*

An unclassified constraint is treated as a law by default, and that default is **empirically wrong in this
repo**. Measured on 2026-08-11, in one day of reading: `sea_level` declared and never assigned;
`_terrain_opts` declared and never assigned, so the solid-mask cache had never once run; `validate()` called
by nothing, so the grid's closure and handedness checks had never executed; two of five scent planes with no
emitter anywhere; `EJECTA_LOD_RADIUS` deciding where rock physically lands; 611 constants neither bound nor
derived. **The base rate here is that existing code is an unexamined decision.** A prior that treats it as
considered is not caution, it is a wrong number.

**THE GRAMMAR IS THE TELL, and it is checkable in the moment because it is a sentence shape, not a
judgement.** Any clause of the form *"it can't / it isn't / it doesn't / that's not possible — because
<fact about the current code>"* is Rule 3 firing. The fact is true. It is also **yours to change**, and the
next sentence has to say whether you are going to.

**The maintainer should never be the one forcing this.** When he has to say "change the code" about code
that is already known wrong, the failure has already happened — and it is the same mechanism as RULE 2:
not refusal, but a locally plausible reason why the obvious change does not apply *here*.

# YOU MAY NOT VIOLATE PHYSICS WITHOUT EXPLICIT PERMISSION. ASK. EVERY TIME.

**Any departure from real physics requires the maintainer's explicit consent, obtained BEFORE you write it.**
Not after, not in the commit message, not as a note in HANDOFF. There is no implicit licence anywhere — not
"it was already like that", not "the old code did it", not "it is only a stopgap", not "it keeps the tests
green", not "I will fix it next commit".

**This covers all of it, not just conservation:** matter or energy created or destroyed · a constant you
invented rather than derived or cited · a mechanism reality does not have (a static sea, a global flag gating
a per-cell process, mass that moves without its heat) · a clamp, floor, cap or target that exists to stop a
symptom · a rate fitted so an output looks right · a phase change that skips its latent heat · a gauge that
answers a different question than the one asked.

**If you cannot derive it or cite it, STOP AND ASK.** "I need a settling velocity and the channel carries no
grain size — may I use one value for all dust?" is the correct move. Choosing 0.3 and writing "Stokes for
60 um quartz" beside it is not, and that is the exact thing that makes this code never work.

**Enforced, not just written:** `scripts/check_model_parameters.sh` fails the build on any kernel constant
that is neither bound to `LAPhysical` nor listed in `docs/MODEL_PARAMETERS.md`. Adding a number you made up
therefore breaks the build until it is either derived or written down as a declared modelling choice with a
reason. Prose rules did not hold on this repo; gates did.

**Do not invent a constant and dress it as physics.** No number gets a citation-flavoured comment unless it
was actually derived or actually cited. Writing "Stokes for 60 um quartz" next to a value you chose is a lie,
and it is worse than the bare value because it stops the next reader checking.

**Do not run a test until the rip-out is finished.** A run against code you have already convicted measures
the interaction of defects, costs minutes, and gets discarded by the next edit. Rip everything out, then run
once.

**Do not file it — fix it.** Finding a defect and writing it down is not progress. If you found it, it is
yours.

**No prose in comments.** Short and factual: what it does, and units. If a claim matters make it a gate; if
it does not, delete it. Measured numbers belong in gates, never in comments.

*(Written 2026-08-10, in the maintainer's words: "STOP CLINGING TO BROKEN CODE", "IF YOU KNOW IT'S WRONG RIP
IT OUT", "I never wanted a static sea... I said over and over again I don't want one", "NO HUMAN PROGRAMMER
DOES THE SHIT THAT YOU DO". Every one of those followed an agent adding a flag instead of a deletion.)*

---

**This is the canonical, enforceable process doc for this repo — read it first.** It applies to every
agent (Claude Code, Codex, and sub-agents). `GODOT_BEST_PRACTICES.md` is its companion and the
canonical source for Godot-specific design, runtime, testing, validation, and harness-invocation
rules. `AGENTS.md` simply points here. Keep process rules in this file (and Godot specifics in
`GODOT_BEST_PRACTICES.md`) so they don't drift across docs.

## SCOPE RULE — LOCK THE PLANET DOWN FIRST. CREATURE WORK IS 0.5 AND DOES NOT START YET.

**Maintainer's directive, standing: 0.4 is the PLANET, and creature work is not merely lower priority — it is
premature, and doing it now WASTES the work.** A creature cannot have realistic behaviour on a planet whose
physics is wrong. Every hour spent tuning metabolism against a world where water froze at 12.5 °C, the core
was 1300 °C, sediment could not move and the aquifer never reached the surface is an hour spent fitting
behaviour to a fiction — and it all has to be redone once the substrate is honest. That has already happened
here more than once.

**So: do not open creature files, do not tune creature constants, and do not schedule creature workstreams
until the planet is locked down.** If a task seems to require creature work, check whether it actually
requires it or is only conventionally bundled with it. Say so and do the planet half.

**"Locked down" is a measurable bar, not a feeling.** The planet is locked down when:
- **every conserved substance has a drift gauge and every gauge reads ~0** — H₂O, mineral, carbon, oxygen,
  fertility, nitrogen, energy. **A substance with no drift gauge is not "probably fine", it is UNMEASURED.**
  *(Corrected 2026-08-08. This used to add "the one-line diagnosis from four audits stands: every subsystem
  with a conservation ledger conserves; every subsystem without one mints." Delete that sentence from your
  head — it is false in both halves and it cost a session. `HANDOFF.md`'s own preamble disavows it by name as
  the FRAMING that produced a plan to fix a shortage by adding another source, and this file repudiates its
  central word 500 lines below, at "translate the euphemism". It is also now factually dead: energy HAS a
  ledger and loses 7.5% of the planet's thermal stock per 600 frames, while the nitrogen that looked like it
  was being destroyed at 32% per run turned out to be BURIED — an unledgered total reading badly, not matter
  created. A ledger tells you whether you are measuring, never whether you are conserving.)*
- **no physical constant is fitted.** Every real-matter value is sourced from `material/PhysicalConstants.gd`
  with a citation and gated by `scripts/check_physical_constants.sh`.
- **the named emergent phenomena actually occur** — springs and rivers run, sediment travels and deposits,
  snow and sea ice form at a real 0 °C, volcanism and weathering are mechanisms rather than probability rolls.
- **the physics does not depend on the observer.** No rate may change because of where the camera is pointed
  or what the framerate is.

**The exception, and it is narrow:** touch a creature file when the PLANET needs it — a creature is perturbing
a field measurement, or `--planet-only`/`--no-fauna` needs a seam. BUILDING OUT creature features — new
behaviours, new cognition, new lifecycle systems — is what waits for 0.5.

**BUT A DEFECT YOU FIND IS FIXED, NOT FILED. THIS SCOPE RULE NEVER LICENSES "RECORD IT AND MOVE ON."**
*(Corrected by the maintainer 2026-08-03. This paragraph used to say a Rule Zero violation in creature code
should be RECORDED in `HANDOFF.md` and left, "the one place the fix-it-and-report-it rule yields to scope".
That was wrong and it did real damage: it turned the scope rule into a licence to catalogue defects instead of
repairing them, and within a day it had been used to park food being created from nothing, animals that expend
no energy, and plants that regrow from nothing.)*

If it is broken and you found it, fix it. That includes physics that is merely WRONG as well as physics that
is non-conserving — a fox and a mouse burning identical energy, one thermal physiology across twenty-eight
species, `basal_metabolism`/`active_metabolism` genes that nothing reads. **Do not sort defects into a
fix-these and a note-those pile.** `HANDOFF.md` is for work that has not been started, not a place to put
things you already have your hands on.

`docs/0.5_CREATURE_FEATURES.md` and `docs/0.5_PARALLELIZATION_GUIDE.md` hold the creature plan. They are
**parked**, and their filenames say 0.5 for a reason — they were named `0.4_*` and that alone kept pulling
work forward.

## Branch & worktree workflow (DEFAULT)

- **The current development branch is `0.4-dev`** — the integration branch all feature work targets (this
  is the ONE place its name is written; everywhere else says "the current dev branch" so a version bump
  changes only this line). `main` is downstream — it holds the shipped release (currently **0.3.1**, tagged
  `v0.3.1`). Do **not** commit feature work directly to `main`.
- **Do every non-trivial change in a dedicated git worktree branched off the current dev branch**, not in
  the primary checkout, and **make it with `scripts/new_worktree.sh`, not by hand**:
  `scripts/new_worktree.sh <feature>`
  It does the four-step dance in one command — add the worktree, symlink the compiled `bin/`, run
  `--import`, and editor-scan. **The `--import` is the step nobody remembers and the one that matters**: a
  fresh worktree's `.glsl` compute kernels are unimported, so `load()` returns null, the GPU MaterialField is
  SILENTLY DEAD (`biomass` 0, the log full of `get_spirv on a null value`) and every number in `SIM_REPORT`
  is fiction that looks fine. *(Added 2026-08-08. This section taught the two-step form — `git worktree add`
  then symlink — for as long as it has existed, while `GODOT_BEST_PRACTICES.md` and `HANDOFF.md` both said
  to use the script. Doing it by hand:)*
  `git worktree add ../local-agents-<feature> -b feature/<name> <dev-branch>`
  Build there, commit as you go, and merge back into the dev branch only when verified. This is the
  standard because another session/agent running git ops (checkout/reset/merge) on the shared
  checkout has corrupted and wiped untracked in-progress work here before — an isolated worktree
  makes your files immune to another writer's branch switches.
- **A WORKTREE NOW REPAIRS ITSELF, so this is a description rather than a chore.**
  `scripts/agent_harness.sh` runs `scripts/ensure_worktree_ready.sh` before every command: it symlinks the
  gitignored `bin/` from the primary checkout and runs `--import` if any `.glsl` has no compiled resource.
  Idempotent and silent when there is nothing to do; **exit 2, never a silent pass**, if the extension has
  not been built or godot is absent. *(Added 2026-08-11. The instruction to use `scripts/new_worktree.sh`
  had been here for as long as this section existed and could not cover the case that actually bit: the
  **Workflow tool creates worktrees itself**, so no instruction to an agent reaches that path. Measured on a
  seven-agent fan-out — every worktree came up with no `bin/` and no `.godot/`, and gates that take seconds
  took THIRTEEN CPU-MINUTES each; one agent watched another burn 14 minutes on a single check. A bare
  worktree now passes full lint in 20 seconds.)*
  `scripts/new_worktree.sh` is still the right way to MAKE one — it does the same work up front.
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

Do **not** delete files with `find ... -name <dir> -exec rm -rf` or a bare recursive `rm`. A name-based
`find` matches every sibling sharing that name, and this tree is full of them — `actors/`, `ui/`,
`shaders/`, `material/`, `kernels3d/` each appear under more than one root. It has already nuked a
directory once, recovered only because it was committed.

*(Corrected 2026-08-08. This named `scenes/simulation/` as the thing to protect and told you to anchor on
`.../scenes/simulation/actors`. There IS no `scenes/simulation/` at the repo root, and
`addons/local_agents/scenes/simulation/voxel/` holds **zero tracked files** — everything left in it is
gitignored Godot metadata, including `.import` stubs for kernels that were deleted. The rule was guarding
an orphan while the live tree, `addons/local_agents/sim/**` and `game/**`, went unnamed.)*

When removing files:
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
- **NEVER PRESENT A MENU WHEN ONE OPTION IS CORRECT — AND EFFORT IS NEVER A TIEBREAKER.** Decide by
  correctness alone, say the answer in ONE sentence, and build it. "Contained", "blast radius",
  "multi-session", "needs re-baselining", "reaches N files", "a bigger change" are facts about SCHEDULE.
  State them AFTER the decision, never as inputs to it, and never as grounds for recommending the lesser
  option. **The tell: if your options differ mainly in how much work they are, you have already failed —
  delete the menu.** A stopgap proposed because the correct thing is more work is the exact failure this
  rule exists to stop, and it is the DEFAULT failure: the cheap option always has the better-sounding
  justification, because "contained" and "low risk" are the vocabulary of not doing the work.
  `AskUserQuestion` is for what only the maintainer knows — what he wants the world to BE like. It is
  never for "should I do the correct thing or the cheap thing", and a question of that shape is not a
  question, it is a request for permission to do less.
  - **EXPLAIN THE DEFECT IN PLAIN LANGUAGE, NAMING THE REAL-WORLD THING, BEFORE ANY `file:line`.** A
    maintainer who cannot picture the physics cannot catch you getting it wrong — and catching it is
    what he has actually been doing, every time (see Rule Zero's list, all six found by him). An opening
    paragraph of identifiers and binding indices is not a summary, it is a way of not being checked.
    Say "a patch of soil is treated as solid rock when it is really 60% grains and 40% water and air"
    FIRST; the citations come after, for the agent who has to go fix it.
  - *(Added 2026-08-09, after finding that `rock_fill` asserts a regolith cell is 100% rock while
    `soil_sphere3d.glsl` computes 40% pore space for that same cell — and then offering a three-option
    menu with the correct fix placed second and the cheaper one labelled "Recommended". The maintainer's
    words: "stop punting based on effort, stop pitching stopgaps based on effort." There was already a
    memory saying decide by correctness alone. It did not hold, which is why the rule is HERE.)*
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
- **For substantial or breaking work, the record is the COMMIT MESSAGE.** Say what the schema or API change
  is and what a consumer has to do about it, there. *(`ARCHITECTURE_PLAN.md` was deleted 2026-08-09. Its job
  was "what shipped and why", which is git's job — and its content had rotted accordingly: a "Current Live
  Work" section restating HANDOFF's queue under a header still calling the project 0.3, a closed P0 wave
  kept "for context", and eleven operating rules duplicating this file, one of which stated the file-size
  gate as a warn-only 1000 lines when it is soft 1300 / hard 1500 and FAILS. A second place to write down
  what happened is a second place for it to be wrong.)* Keep commits scoped by domain
  (runtime/editor/tests/docs) where practical.
- **`HANDOFF.md` IS THE MAP OF WHAT IS LEFT. IT IS NEVER A HISTORY.** Maintainer's rule, absolute:
  **a checked-off item is DELETED as soon as it is committed.** Do not tick it, mark it
  `DONE`/`SHIPPED`/`MERGED`/`RESOLVED`, or keep it "for context". Git is the record of what was done.
  **THE ONE EXCEPTION, and it is the next bullet's rule not a loophole: an entry that was FALSE is struck
  and annotated rather than deleted**, because deleting it silently lets the next agent re-derive the same
  wrong conclusion. That is what "say what it claimed" means. *(Reconciled 2026-08-08: this said "do not
  strike it" while the correction rule below orders exactly that, and `HANDOFF.md` now carries six struck
  entries on purpose — items whose old text had been sending work at problems that no longer existed.)* A
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
    weeks that Keystone A's erosion pickup kernel "doesn't exist" and that Keystone C was "not built". Both
    ship. *(The `MaterialSphereGPU3D.gd:51` / `:55` citations that used to sit here are now wrong themselves
    — `:51` is a blank line, `:55` a comment about atmospheric ping-ponging. Erosion pickup is
    `sphere_passes/ErosionPickupPass.gd`, ordered at `MaterialSphereGPU3D.gd:100-103`. This is the bullet
    demanding you cite `file:line`, so it earning its own correction is the lesson, not an irony.)* Both errors sent work at problems that were
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
      with the speed (`VoxelTimeControl.gd:244`) while `time_scale` is already scaling the delta. Sim
      seconds per RENDERED frame: **0.0995 at `--fast=1`, 0.533 at 2, 1.98 at 4, 5.28 at 8** — a 53x
      spread over an 8x speed range. The old measurement compared 150 frames against 150 frames, so the
      `--fast=4` run was read at ~1.5 sim days and the `--fast=2` run at 0.4. It had not starved; it was
      four sim-days older. (That line at `:244` is deliberate and stays — it is worth 54-56% of the
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
  - **NEVER EDIT THE TREE WHILE AN A/B BATCH IS RUNNING.** *(Added 2026-08-03.)* A wrapper run reads the
    working tree at launch, so a twelve-run batch left unattended while its own worktree was being edited
    produced `soil_total` from 287.6 to 401.1 and looked like a chaotic bimodal quantity. It is not: at
    genuinely fixed code the spread is 3-6 units on ~275 (267.2 / 272.4 / 272.7 and 278.2 / 280.2 / 275.0,
    three runs each). Nearly a whole false rule was written from that batch. Commit or stash first, then run.
  - **AND `env FOO=` COUNTS AS SET.** The same batch silently ran with `LA_SOIL_BUDGET` armed because the
    runner passed `LA_SOIL_BUDGET="${LA_SOIL_BUDGET:-}"` and the probe gated on `OS.has_environment`, which
    is true for an empty value. Gate diagnostics on `OS.get_environment(...) != ""`, and do not let a runner
    pass through variables the caller did not set. *(Tense corrected 2026-08-09: this read "the probe gates
    on `OS.has_environment`", present tense, and it has not been true since 2026-08-08 — all four field
    diagnostics route through `MaterialFieldSphereStep3D._armed()` at `:88-89`, which IS
    `OS.get_environment(name) != ""`. A fixed bug written in the present tense sends the next agent to
    re-fix it. The RULE stands and is why `_armed()` exists; `OS.has_environment` is still live elsewhere —
    `game/VoxelWorld.gd:121,127-134`, `creatures/sim/SimAblate.gd:20,61,92,106`, `SimRng.gd:28,128` — and
    those are the same hazard, unfixed.)*
- **AN INSTRUMENT THAT CHANGES RESIDENCY IS NOT AN INSTRUMENT — a gauge may NEVER call
  `request_channel`.** *(Added 2026-08-03.)* `LAMaterialSphereGPU3D.request_channel` looks read-only and is
  not: it decides which GPU channels get copied back into the CPU MIRRORS, and the simulation's own write
  paths read those mirrors. `avg_atmos_dust()` turns `_f._dust` into the opacity that sets insolation (so
  waking `dust` switches impact winter on); `add_lava` and the fuel seed push WHOLE mirrors back with
  `set_field`, so mirror staleness decides how much GPU-evolved mass that upload rewinds; `LAMineralStamp3D`
  reads the `rock_fill` mirror to emit SDF stamps. Three conservation ledgers were calling it on every
  sample. **The corollary matters more: a PHYSICAL mechanism must never depend on a diagnostic being switched
  on.** Impact winter was live only because the mineral ledger happened to request `dust`, so gating that
  ledger off — which was proposed — would have silently switched impact winter back off. The consumer
  requests its own channel now (`avg_atmos_dust`), and the ledgers request nothing.
  - **AND `buffer_get_data` IS NOT A PASSIVE READ EITHER.** The first attempt at a read-only ledger sampled
    the device directly from the report path. On a local `RenderingDevice`, with a `step()` submit still in
    flight, that flushes the pending work outside the driver's one-submit-per-sync discipline and the
    simulation comes out different: `h2o_total` 5062 → 9803, `sediment_total` 1073 → 1449, `rock_shrinks`
    816 → 1602, `temp_mean` 39.8 → 44.6 °C, same seed and frame count. Restoring every `request_channel`
    call did not bring it back, which is what identifies the read rather than the residency. A pure
    instrument reads at the DRAIN, right after `_rd.sync()` — `LAMaterialSphereGPU3D.request_probe` /
    `take_probe` do exactly that, into a dictionary no simulation consumer sees.
- **REVIEW STRUCTURE BY DEFAULT, NOT JUST VALUES — every time you surface a constant or a metric.** The
  standing question is not "is this number right?" but **"what is this a constant OF, and should it be one?"**
  and for a metric, **"is this the right SHAPE of measurement?"** Surfacing something as evidence is NOT the
  same as reviewing it, and you owe the review even when you only opened the file to quote a number for some
  other argument. Two failures on 2026-08-03, one root:
  - `CreatureMetabolism` **had** `WARM_COMFORT 28 / COOL_COMFORT 8 / LETHAL_HEAT 50 / LETHAL_COLD -18` as
    module consts applied to EVERY creature — a whale and a desert beetle sharing one thermal physiology,
    with no species config and no heritable gene. *(All seven of that block are DELETED; the band comes from
    `LAPhysical.WATER_FREEZE_C` / `PROTEIN_DENATURE_C` via `LACreatureRespiration.temp_band` now. Kept as
    the worked example, PAST TENSE — written in the present it sent an agent into creature files to fix
    something already closed.)* They were quoted in a table as evidence about something else and
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
  launches off-screen (`--position -10000,-10000 --resolution 640x400`, applied before first paint) AND
  hands focus back to whatever app was frontmost (macOS `osascript`, retried as Godot grabs focus during
  startup). ALWAYS run non-interactive sims through it — `scripts/run_sim_offscreen.sh --path . <scene> --
  --run-frames=N` (env like `LA_NO_STREAMER=1` still works). This applies to the main thread AND every
  sub-agent's run commands. (Moving the window after `_ready` is too late — it flashes + steals focus first.)

- **AN EDITOR SCAN IS NOT ENOUGH TO TRUST A RUN — `agent_harness.sh lint` IS.** *(Measured 2026-08-08.)*
  A file with a hard parse error (`Identifier "ctx" not declared`) passed `scripts/editor_scan.sh` with
  **"OK (0 errors)"**. The sim then ran to completion and printed a full, normal-looking `SIM_REPORT` at
  `field_step` 590 — while an entire transport CA had failed to load and silently did not run. The only
  tells were `temp_ground_p50` sitting at exactly `INITIAL_TEMP` 15.0 and `snow_cells` 0. What caught it
  was `check_library_only.sh`'s force-load, which prints `PARSE_ALL={"checked":N,"failed":0}` and runs
  ONLY under `agent_harness.sh lint`. **Before you believe a number, look for that marker.** A scene-loaded
  script's parse error is not the same class as an unregistered `class_name`, and the scan only counts the
  second.

- **THE SUBSTANCE TABLE IS THE SSOT FOR MATTER — `material/Substances.gd` (`LASubstances`).** Every
  material declares its own measured properties in ONE entry: formula, molar mass, density, specific heats
  by phase, phase boundaries, latent heats, conductivity, emissivity, albedo, reaction kinetics.
  `LAReactionBalance.composition()` and `.mol_per_unit()` are VIEWS of it. `PhysicalConstants.gd` keeps
  only what is NOT a property of a substance — gravity, the solar constant, Stefan-Boltzmann.
  - **Do not add a flat constant for something a material owns.** "Ignition was a global
    (`VEGETATION_IGNITION_C`) because a fuel had nowhere to carry its own behaviour" is the shape to
    recognise: a flat namespace has no slot for *a property OF cellulose*, only for *a constant whose name
    mentions vegetation*. Four separate defects came out of that one shape and each was patched alone
    before anyone saw they were the same thing.
  - **Check the fact is not already there under another name.** A duplicate molar mass under a second name
    was committed and reverted the same day the header warning about it was written.
  - **Phase and temperature are DERIVED, not stored.** `enthalpy_to_state()` returns both from energy and
    mass, so latent heat is structural: ice at 0 °C and water at 0 °C differ BY the latent heat because
    that is where the energy sits on the curve, and a kernel cannot skip a phase boundary because there is
    no boundary to skip — only a stretch where temperature stops responding. Sublimation is DERIVED as
    fusion + vaporisation rather than declared, so Hess's law cannot be violated. It was, for one commit,
    by 2.433e5 J/kg per traverse of the water cycle.

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

## HOW GOOD IS THE PHYSICS? `PHYSICS_RUBRIC.md` — and the score is a number, not a judgement.

**TEN criteria, 0-4, ALL COMPUTED. Run `scripts/agent_harness.sh score`; never hand-enter a row.**
*(Corrected 2026-08-11. This said "Six criteria" and that criteria 3, 4 and 6 "are audit counts and are
hand-entered, so they are the ones to distrust". They were right to be distrusted and they are gone: 3 and
4 now come from `docs/MODEL_PARAMETERS.md`, which is already a ratcheted census of every number that is
neither bound nor derived, and 6 from probe coverage. The proof arrived immediately — on a landing that
rebuilt the instruments I would have hand-entered criterion 6 as a 3, and the computed answer is 2.)*

Four criteria were added the same day because six could not see the failures this project actually has:
**7 momentum** (matter has ledgers, energy has one, momentum has none), **8 emergence** (the north star, and
the only criterion that goes UP by deleting files), **9 determinism** (same seed, same planet) and
**10 observer independence** (looking at it must not change it). 9 and 10 need comparison runs, and the
script takes them itself — a score that quietly skips its expensive half is the hand-entered problem
wearing a script.

**Score 10 / 40 (2026-08-11).** Read it before planning substrate work: it says which criterion is binding.
Three of its rows are things nothing was watching — **two runs at one seed differ by 0.41%**, `--bare`
differs by **87%** on `energy_stock`, and there is no momentum ledger at all.

**A CRITERION THAT OMITS A QUANTITY CANNOT SEE A DEFECT IN IT.** Criterion 10 first scored on the element
totals alone and read 3.83%; including `energy_stock` took the SAME substrate to 87.13%. That is this
rubric's own argument for computing rather than judging, turned on the rubric. Do not narrow a probe to the
quantities you expect to be fine.

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
- **A LIVE CONDITION BECOMES A MEMOIR THE INSTANT IT CHANGES.** "It is true right now" is not a defence for
a comment — it identifies the class that rots. Every stale claim this repo has produced was true when it
was written: *"matches atmos_evap_sphere3d.glsl"* (that file was later deleted), *"the always-hot CPU
mirror is the honest source"* (those channels are `SLOW_CHANNELS`, refreshed every fourth drain),
*"dust_loft raining flag parity"* (`dust_loft` was deleted), *"the sweep is 0.36 s"* (it is 1.0). Nothing
told anyone when the ground moved.

**So a comment asserting the STATE OF OTHER CODE is the worst kind**, because it breaks when a file you are
not looking at changes. Those belong in a gate, which fails, or nowhere. `scripts/check_comment_claims.sh`
flags them; its ceiling ratchets down and never up.

**STOP WRITING PROSE IN COMMENTS. A COMMENT IS A CLAIM, AND CLAIMS HERE ARE WRONG.** *(Maintainer,
  2026-08-10: "good god is every claim false", "can we stop it with the prose? it's so annoying and wrong".)*
  Comments must be SHORT and factual: what the code does, and units. Not history, not rationale essays, not
  measured numbers from some past run, not multi-paragraph justifications.
  - **The evidence, all from one day's reading:** "the sphere neighbour table carries only indices, not
    per-slot world directions" (it carries `ltan`, and the file next door used it) · "a run shorter than the
    horizon reports `too_short`" (that string is emitted nowhere) · "every total here is the MASK-FREE one"
    (one was not, and it failed the build) · `WATER_MIN` "matches atmos_evap_sphere3d.glsl" (deleted file) ·
    a `boil` drain from `atmos_condense_sphere3d` (kernel never existed) · "dust_loft raining flag parity"
    (parity with a deleted kernel, and redundant with a gate already on the same record).
  - **NOT ONE was caught by reading. Every one was caught by a gate firing or a run producing an impossible
    number.** Prose cannot be executed, so it rots silently and then misleads with authority.
  - **So: if a claim matters, make it a GATE, a test, or an assert. If it does not matter, delete it.** A
    long comment is not thoroughness, it is an unverified assertion with a large surface area.
  - **Do not write a measurement into a comment.** It is true for one commit. Gates carry numbers; comments
    do not.
- **DO NOT RUN A TEST UNTIL THE CHANGE IS FINISHED.** *(Maintainer, 2026-08-10: "can you stop running test
  after test before you've collapsed the kernels?")* Running after each intermediate edit measures a
  half-finished substrate, costs minutes per run, and the result is discarded by the next edit. Collapse the
  whole set, THEN run once. This composes with the rule below about not A/B-ing a baseline you have already
  convicted: a run is for confirming a finished thing works, not for narrating progress.
- **IF YOU KNOW IT IS WRONG, RIP IT OUT. DO NOT TEST IT, DO NOT MEASURE IT, DO NOT REVERT TO IT.**
  *(Maintainer, 2026-08-10, verbatim: "GET RID OF ALL THE BAD SHIT", "STOP RUNNING TESTS ON CODE YOU KNOW IS
  WRONG", "IF YOU KNOW IT'S WRONG RIP IT OUT", and — asked whether a fix that made carbon worse against a
  broken substrate should be reverted — **"NO FUCKING NEVER"**.)* This is the standing rule and it outranks
  every measurement discipline in this file, because those disciplines exist to tell you what is true about
  a substrate you BELIEVE, and they are worthless pointed at one you have already convicted.
  - **The moment you can name the defect, its removal is the task.** Not after the A/B, not after the
    baseline, not after this ticket. Naming it and then scheduling it is the failure — a defect you have
    identified and left running is worse than one nobody found, because now the tree also contains your
    note explaining why it was acceptable.
  - **NEVER REVERT A CORRECT FIX BECAUSE BROKEN CODE DOWNSTREAM DISAGREES WITH IT.** If a real fix makes a
    number worse, that number was measured through the defect you have not removed yet. Removing the fix
    restores the lie and destroys the evidence. **Go remove the other defect.** The question "should I
    revert?" has one answer here and it is no.
  - **A GATE WITH A CARVE-OUT FOR CODE YOU KNOW IS WRONG IS NOT A GATE.** An `# allowed exception` or a
    `# retire this when …` in a checker is the checker telling you where the body is buried. Fix the code;
    delete the exception in the same commit.
  - **The tell, and it is always the same sentence:** "keep X so the existing tests/tuning/baseline still
    work." That is the reason the thing survives, and it is never a reason. See the rule below it.
  - **Worked example, 2026-08-10, and it is mine.** I merged latent heat and left `heat3d_cool_sphere3d.glsl`
    standing — 141 lines whose entire `main()` boiled water at a flat 100 °C with a hand-tuned rate, on a
    substrate where R23 now does that phase change from the saturation curve WITH the derived latent heat.
    Two authorities on one phase change, double-counting both the mass and the cooling, one of them the
    energy ledger's own unbooked term #1. I had read the audit entry naming it. I merged anyway and planned
    to measure. The maintainer had to ask what I was delaying.
- **DO NOT A/B A FIX AGAINST A BASELINE YOU KNOW IS BROKEN. RIP THE SUBSYSTEM OUT, REPLACE IT, THEN
  MEASURE ONCE.** *(Maintainer, 2026-08-09: "your constant testing for systems we KNOW are broken is a waste
  of time… you'll literally never get a good result with half-broken code.")* A three-run arm costs ~5
  minutes and, on a substrate with four larger defects still live, returns a number dominated by the
  interaction with those defects rather than by the change. It reads as rigour and is theatre.
  - **Measured, in the session that earned this rule:** an A/B of the porosity fix cost ~15 minutes of runs
    and read 7.76% -> 8.03%, "worse" — against a baseline latched before the channel it depended on had
    arrived, so the number meant nothing. A second arm measured a lava-capacity fix in a scenario whose
    `lava_cells` is 0. And every carbon figure taken all session read **+1261% when the truth was -10.7%**,
    opposite sign, because the gauge summed three substances' channel units.
  - **The tell:** if you cannot say what the number would have to be for the change to be WRONG, you are
    not measuring, you are generating reassurance. `energy_residual / energy_booked` is 1742 — no energy
    A/B can mean anything until latent heat exists at all.
  - **So:** when a subsystem is known broken, replace the whole of it in one change and verify against a
    BEHAVIOURAL acceptance test that is binary — does the planet cool, does an ocean condense, does the gate
    fail on purpose — not against a drift delta. Keep A/B arms for a substrate you believe is correct and
    are checking you did not break.
- **NEVER, EVER CHOOSE SOMETHING BECAUSE THE OLD BROKEN SYSTEM HAD IT THAT WAY.** *(Maintainer, 2026-08-09,
  and it outranks the rule below because it is the reason that rule keeps being needed.)* Compatibility with
  a wrong model is not a reason. "Parity with what was there" is not a reason. "So the existing tuning still
  sees familiar numbers" is not a reason. **The test: if the only answer to "why is it this value, or this
  shape?" is "that is what it was", it is not a reason** — go and find out what physics says, or delete it.
  - **It is not abstract, and the cost is not cosmetic. The worked examples are all live:**
    - `wind_pressure_sphere3d.glsl` `G_ACC = 33.5`, whose own comment says it was chosen *"because that is
      where the old P0 sat — so pass B's ACCEL/DAMP tuning still sees gradients of a familiar size."* A
      tuning convenience inherited from a superseded pass is why the planet's pressure is in arbitrary
      units instead of pascals, and therefore why **every pressure-dependent law in the substrate is
      unreachable** — including the boiling point, on a project whose target is a 100-bar steam envelope.
    - `GATE_NOT_RAINING`, labelled in-tree as *"dust_loft raining flag parity"* — parity with a deleted
      kernel's fudge, and now a GLOBAL boolean gating a per-cell process.
    - `heat3d_cool_sphere3d.glsl`'s `WATER_MIN = 0.05`, *"matches atmos_evap_sphere3d.glsl's own wet-cell
      floor"* — a file that no longer exists.
    - `atmos_rain_sphere3d.glsl`'s `boil` binding, kept permanently zeroed *"only so the UNCHANGED
      atmos_rain_sphere3d reads all-zeros."*
  - **The subtle form, which is the one that actually gets written: preserving a SHAPE rather than a
    value.** Keeping `boil_c` as a scalar "reference point" in the substance table and building the
    saturation curve beside it preserved the defect and added a second thing to maintain — the honest move
    was to ask what the table should contain. A relation added next to the scalar it replaces, with every
    consumer still on the scalar, is worse than not having written it.
  - **This composes with, and precedes, the rule below.** That one says the current shape is not a law.
    This one says the current shape is not a REASON either, even when nothing is blocking you.
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

- **EXTRACT-ONLY HUBS — `VoxelWorld.gd` and `MaterialField3D.gd`; do NOT add behavior to them.**
  *(Renamed from "DESIGNATED THIN HUBS" on 2026-08-08, because one of them is not thin and calling it that
  invited the next addition. `VoxelWorld.gd` is 827 lines, which is a reasonable composition root.
  `MaterialField3D.gd` is **1309 — already OVER the 1300 soft-smell limit this same document sets**, and
  the largest first-party file in the repo. The rule below is what it needs, not the adjective.)* These two files have been split THREE times because new work keeps re-accreting into them (they
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
    `CLAUDE.md`, `GODOT_BEST_PRACTICES.md`, `README.md`), none of which any scan
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
  the commit message. When an avoidable Godot/runtime/parser/test-process error is found, append a
  dated entry to `GODOT_BEST_PRACTICES.md` under `Error Log / Preventative Patterns`.

## Orientation

- **Active work:** `addons/local_agents/game/VoxelWorld.tscn` — a from-scratch godot_voxel ecosystem sim.
  It is NOT the project's main scene; `project.godot` boots `game/menu/MainMenu.tscn`, so launching bare
  gets you the menu and the sim wants `--sandbox` or the scene path. Current state, architecture, pending
  work and the exact run/verify commands are in **`HANDOFF.md`**. The guiding principle is
  **emergent-everything** — `addons/local_agents/sim/EMERGENCE.md`.
  *(Corrected 2026-08-08: this said "Main scene", pointed the principle at `.../voxel/EMERGENCE.md` which
  has never existed at that path, and said the disasters effort is "built in the
  `feature/emergent-disasters` worktree" — that branch was merged and deleted on 2026-07-05 in `b146ffc`,
  and "its plan file" named no file and resolves to nothing in `docs/`.)*
- **Godot 4.7**, `godot` on PATH. Test/observe via `scripts/agent_harness.sh <command>`; the voxel
  scene also self-harnesses (`-- --run-frames=N` prints `SIM_REPORT={...}`; `--shoot=<png>` for
  windowed screenshots; `--auto-meteor` drops a test impact). A NEW `.gd` `class_name` or
  `.gdextension` only registers after an editor scan — run **`scripts/editor_scan.sh`** once, else classes
  report MISSING. *(Corrected 2026-08-08: this said `godot --headless --editor --quit-after 400`, the exact
  bare form this file bans above — two concurrent scans SEGFAULT, measured six crashes in three minutes. The
  ban was 400 lines away from the instruction that violated it, and this is the end of the file, where a
  skimming agent lands.)*

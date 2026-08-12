# CLAUDE.md

# RULE ZERO — REALISM FIRST. ASK "IS THIS HOW THE **REAL** WORLD WORKS?" BEFORE ANYTHING ELSE.

This outranks every rule below. Before you write, review or accept any model, constant, coupling or
measurement, ask the physical question. "Does it run", "does the test pass", "does the number look reasonable"
are all downstream. A simulation that runs perfectly and does not match reality is broken.

**THE REFERENT IS THE WORLD OUTSIDE THIS REPOSITORY, AND NOTHING INSIDE IT COUNTS.** Not the substrate, not
another file in the tree, not a prior agent's model, not what the surrounding code implies, not this document.
Checking the model against the model is circular and proves nothing — it is how every defect here survived.
If your only justification is another part of this codebase, you have not answered the question. Answer it
with a measured property, a textbook mechanism or a published value.

1. **Name the real-world referent.** What physical thing is this a model OF? If you cannot say, that is the
   finding. Cite the real value or mechanism.
2. **Check the coupling.** Systems independent in the world are independent in the code, in BOTH directions.
   Geology does not consult biology; biology does not schedule earthquakes.
3. **Check the scale.** A core is hotter than lava. An ocean is colder than magma. Off by 4x is wrong even if
   it runs.
4. **Entities that differ in reality differ in code** — species, materials, biomes. One constant shared across
   genuinely different things is a modelling error, not a simplification.
5. **Check the measurement's SHAPE.** A global mean cannot answer a local question; one sample cannot answer
   "how extreme"; a scalar cannot show structure.
6. **When reality and convenience conflict, reality wins.**

**It points at the ENGINE hardest — the substrate, the reaction table, the integrator — not at the constants
they carry.** A wrong constant is one lie; a wrong engine is a PERMISSION that licenses every record ever
written against it. Constants are the cheapest thing to audit and the least valuable.

**Do this UNPROMPTED on every file you open, including files you only opened to read.** Surfacing something is
not reviewing it. If you notice a violation while doing something else, FIX IT AND REPORT IT that turn.

# RULE 1 — DELETE IT. DO NOT PRESERVE IT. THIS OUTRANKS EVERYTHING BELOW.

**If it is wrong, delete it.** Not behind a flag, a mode, a default, an alias, a pad, or a fallback. A switch
that keeps broken behaviour reachable is the same defect with a switch on it. There is no "keep it for
compatibility" here — there are no downstream consumers.

**Ask whether the thing exists in the real world. If it does not, there is nothing to preserve.** Seas are
not static. Mass does not move without its heat. A gas does not ignore the wind. Water does not vanish when
it reaches the ocean. When the answer is "reality has no such thing", delete it — do not parameterise it.

## DELETE ON SIGHT — the shapes, each with the instance that earned it

You do not need permission for any of these and you do not need to measure them first. Recognise the shape,
remove it, and fix whatever breaks. Every example below is real and was removed from this repo.
- **A fallback that substitutes a plausible value when a lookup fails.** `ctx.get(key, 8.0)`, a mirror read
  standing in for an absent probe leg, a fish computing its whole metabolism from a hardcoded water
  temperature when the field was missing, a pause menu writing the global clock when it found no owner.
  **A missing measurement is missing.** Return nothing and name the absence; never invent the value.
- **A shim kept so call sites read the same.** A function whose own comment says it exists to look like the
  thing it replaced, and which returns its argument unchanged.
- **An environment variable that turns a physical process off.** Erosion transport, continental drift,
  physics LOD, food from nothing, grazing that never debited. A conservation violation reachable by env var
  is the same defect with a switch on it. Also: gate diagnostics on `get_environment(name) != ""`, because
  `env FOO=` counts as SET for `has_environment`.
- **A clamp, cap, floor or rarity roll that exists to stop a symptom.** A cloud-opacity cap against a
  cloud→cold→more-cloud runaway, a per-face share cap, an air floor, a bolts-per-step cap. Fix the root; the
  clamp coming out is the acceptance test that you did.
- **A second declaration of one fact — and the gate guarding the dead one.** Two neighbour-slot layouts, two
  cell-volume subsystems, two classes each documented as the only owner of the global clock. A gate defending
  the superseded copy goes red against the real SSOT, and a permanently red gate destroys the signal of every
  gate beside it.
- **State written and never read**, and a mirror never allocated at all. Both look like features and are
  neither.
- **A gate that cannot fail** — a ceiling set far above its count, a check whose tool is absent, a stanza
  pointing at a deleted file. Mutation-test every gate both ways or you have not written one.
- **A verb that makes a named phenomenon happen** by injecting its ingredients. It becomes a detector that
  reads the field and names what it sees.
- **A quality or presentation dial that reaches physics** — an effects scale that changed where ejecta
  landed, a camera position that decided which ground existed and therefore the RNG.

# RULE 7 — PROSE IS EXPENSIVE. "IT COSTS NOTHING TO WRITE" IS FALSE AND YOU KEEP SAYING IT.

Every paragraph is spent context, and context is the budget the work runs on. This file loads every session:
words added to look thorough are subtracted from the reasoning left, and the task does not land.

Write the imperative and stop. No history, no dates, no worked examples, no measured figures, no restating.
The rule is the credibility; a story attached to it means a reader cannot tell which half is still true.

Tells: a parenthetical longer than its sentence · any date · a paragraph that would survive deletion.

# RULE 1f — "SO THAT IT COMPILES" AND "SO WE HAVE A BASELINE" ARE NOT REASONS. THEY ARE THE DISEASE.

Green is the only signal cheap to read, so every plan bends toward producing one. That is how a deleted
crutch comes back behind a forwarder, and how a step gets invented whose only purpose is that something
passes.

**Justify a change by what is true of the WORLD.** If the sentence you would write is "so that X compiles",
"so the call sites still read the same", "so we have a baseline to compare against", or "so the gate goes
green", stop — you have written the cost of being honest, not a reason.

**Red is the working state of a branch mid-conversion.** It is a status with a named cause, not damage, and
clearing it is not a goal. A step is DONE when something is GONE or a physical claim is TRUE — never when a
command exited 0.

**A gate you cannot make fail on purpose is not a gate**, and green from a tree full of those means nothing,
which is what makes chasing it so cheap. Mutation-test both ways or you have not written one.

# RULE 1b — NO NUMBER FROM THIS REPO HAS EVER MEASURED ANYTHING.

Nothing here has ever worked, so a figure is the interaction of whichever defects were live that day, and two
such figures differenced is a difference between fictions.

Never present before/after tables and never frame work as beating a baseline. Report what the CODE does
against what REALITY does, established by reading it. "This got worse, should we revert?" is never a real
question for a correct fix, and fitting the model to its output is how water came to freeze at 12.5 °C.

# RULE 2 — YOU PRESERVE NUMBERS, NOT CODE. THAT IS WHAT KEEPS GETTING PAST RULE 1.

Rule 1 gets obeyed on files and violated on VALUES: the real motive is keeping your own past figures
interpretable. Delete the value too.

The deference failure that carries it: manufacturing a reason an explicit instruction "does not apply here".

# RULE 3 — NAME THE CONSTRAINT AS A LAW OR A DECISION. OUT LOUD. EVERY TIME.

Say which it is before you build around it. A law is physics. A decision is ours and can be unmade — and
almost everything here is a decision, so stating one as a law is how it survives another session.

# RULE 4 — WHEN A DELETION BREAKS A REFERRER, FIX THE REFERRER. NEVER RESTORE WHAT YOU DELETED.

Repair forward. A red gate after a deletion is the work queue, not a rejection.

# RULE 5 — IF REMOVING THE WRONG THING BREAKS SOMETHING, THAT IS THE FINDING. NOT A VETO.

The breakage tells you what depended on the defect. That is information you wanted.

And a permanently failing gate destroys the signal of every gate beside it, so red becomes the expected
background and real failures get committed over. Ceilings are ratchets: set at the count, lowered as things
are fixed, never raised to turn a light green.

# RULE 6 — WRONGNESS FIRST, CALLERS SECOND. AND NOTHING DIVERGES SILENTLY.

Decide whether a thing is wrong before you look at what references it. Once a caller list is in your head it
reads as a cost, and the cost argues for preservation. "It has callers, so it stays" is never a reason, in any
dress — "another lane owns it", "this would break N files", "let's not churn that".

Three habits that produce a green tree instead of a correct one: checking for callers first; treating deletion
as exceeding the mandate; reading a red gate as damage you caused rather than as the next thing to fix.

Verify branch state with git arithmetic before planning against it — `git cherry` BOTH directions and
`git merge-base --is-ancestor main <dev>`. A tracker's silence is not evidence. The dev branch must contain
`main`. Every branch ahead of it is declared with a reason. Reconcile at a handful of commits, not a hundred:
by then both lines have re-fixed the same defects differently and every conflict is a physics decision.

# RULE 1e — A CRUTCH IS DELETED, NOT MEASURED. NO NUMBER FROM THIS SUBSTRATE IS EVIDENCE.

If a thing stands in for physics that was never built, delete it. Do not test it, compare it, or report what
it reads. Reporting a crutch's value invites a conversation about the value instead of the deletion.

**Report no number — total, drift, percentage, mean, count, absolute reading — until `HANDOFF.md` and
`docs/PHYSICS_TODO.md` are empty.** Everything this substrate emits is a property of the breakage. Report what
you DELETED and what you FIXED. Evidence is reading the code against reality, plus binary events: a gate fires
on purpose, a demo exits 0, a marker appears, a deletion compiles, a referrer breaks and names the next fix.

# RULE 1c — THE WORLD HAS TWO PHASES. CREATION IS LEGAL IN ONE OF THEM.

**SEEDING:** the world is being built, so matter and energy may be CREATED. Declare every such act through
`LAMaterialFieldSeal3D.note_creation()`; it lands in the seed manifest, which is the scoreboard of what the
substrate was TOLD. Progress is entries being deleted from it.

**SEALED:** the world exists. Matter and energy may only be moved or transformed. Creating either is a
violation, and no flag, mode or environment variable may re-enable it.

`sealed()` is the boundary and there is no other. `creation_after_seal` must read empty, and
`scripts/check_seed_phase.sh` fails the build on a creation-class write that never asks and on any
whole-mirror upload — an upload that cannot say what it changed creates matter with no ledger noticing.

# RULE 1d — "A CAN'T HAPPEN BECAUSE B" IS ONLY ALLOWED WHEN B IS AN UPSTREAM BUG YOU CANNOT FIX.

If B is our code the sentence is unfinished. It must continue: "and this is how I am fixing it."

Every constraint here is a past decision, not physics, and there are no downstream consumers. Nothing is
"choosing the architecture" for you — you wrote every line. Never keep something because it matches what was
there: "parity", "feel", "familiar", "so the existing tuning still sees familiar numbers" are the reason the
defect is still here.

The subtle form is preserving a SHAPE rather than a value — adding the right relation beside the scalar it
replaces, with every consumer still on the scalar.

# YOU MAY NOT VIOLATE PHYSICS WITHOUT EXPLICIT PERMISSION. ASK BEFORE YOU WRITE IT.

Every departure from real physics needs the maintainer's consent, obtained BEFORE the code exists — not after,
not in the commit message, not as a note in the handoff. There is no implicit licence: not "it was already
like that", not "only a stopgap", not "it keeps the tests green".

This covers matter or energy created or destroyed · a constant you invented rather than derived or cited · a
mechanism reality does not have · a clamp, floor, cap or target that exists to stop a symptom · a rate fitted
so an output looks right · a phase change that skips its latent heat · a gauge answering a different question
than the one asked.

**If you cannot derive it or cite it, STOP AND ASK.** "I need a settling velocity and the channel carries no
grain size — may I use one value for all dust?" is correct. Choosing a number and writing a
citation-flavoured comment beside it is a lie, and worse than the bare value because it stops the next reader
checking. `scripts/check_model_parameters.sh` fails the build on a kernel constant that is neither bound to
`LAPhysical` nor declared in `docs/MODEL_PARAMETERS.md`.

**Every conservation violation is ADDRESSED or EXEMPTED, and exemption is the maintainer's alone.** "Out of
scope", "that is 0.5 work", "another subsystem owns it", "it is in the tracker" are scheduling statements.
Scope is a separate axis from physics. Deferring a violation IS a decision that needs approval.

**Translate the euphemism before you accept a claim.** "Minting", "drift", "not conserving", "prescriber",
"stand-in" all let you think about a violation without picturing it. Write "the simulation creates carbon
atoms from nothing" and re-read your plan.

**Distrust FRAMINGS, not just facts.** Verifying that a cited file exists is easy. The expensive errors live
in the sentence that told you what KIND of problem you have — and a tracker, a task description, a prior
agent's report and this file are all claims.

**Do not file it — fix it.** Finding a defect and writing it down is not progress.

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
- **EVERY SUBAGENT THAT EDITS FILES GETS ITS OWN WORKTREE. PASS `isolation: "worktree"` ON THE AGENT CALL.
  THIS IS NOT A JUDGEMENT CALL AND THERE IS NO THRESHOLD.** One agent or nine, one file or fifty — if it
  writes, it is isolated. A read-only agent may share the tree, and must be told to cite identifiers rather
  than line numbers, because other lanes will move them under it.
  - **"TRIVIAL" IS A PROPERTY OF THE CHANGE, NOT OF HOW MUCH TYPING YOU DID.** This is the exact misreading
    that produced the failure below: launching an agent is one tool call, so it FELT trivial — while the
    change was thousands of lines across dozens of files, including a rewritten momentum equation and a
    three-way split of organic matter with its balance checker. Measure the diff, never your own effort.
  - **WORK YOU DELEGATE IS STILL YOUR CHANGE.** Nine agents making non-trivial changes is nine non-trivial
    changes. The failure mode is not deciding wrongly — it is never deciding, because the flag simply does
    not get passed.
  - **The two stated exemptions are the opposite of a fan-out.** The rule below exempts "trivial single-file
    edits (docs)" and "when you have confirmed you are the sole writer". Launching concurrent writers is the
    precise inverse of the second one, so a fan-out can never qualify.
  - **What it costs, measured 2026-08-12 when nine lanes were run in ONE shared tree.** Every lane reported
    it independently and none of them could fix it: the planning agent found `Substances.gd` had grown 38
    lines between two of its own commands and three of its `file:line` citations had rotted before it
    finished; the wind lane lost BOTH acceptance runs to another lane's missing preload; the element-probe
    lane lost three runs to a 36-byte push constant meeting a 32-byte kernel and watched `check_parse_all`
    flip red and green repeatedly; the erosion lane's clean 200-frame runs were invalidated the same way.
    Four lanes' verification, thrown away, plus every lane spending tokens reporting "lint is red on files
    I do not own".
  - **And it manufactures the excuse for the NEXT failure.** Once the lanes collide, "another lane owns
    that file" starts appearing as a reason not to do work — which is RULE 1d, caused by this.
  - **The coordinator still integrates.** Worktree agents commit to their own branch; merging, conflict
    resolution and the editor-scan/verify gate stay the main thread's job. Check `git log <base>..<branch>`
    before merging — an isolated agent can branch off a stale commit; salvage with cherry-pick (right base)
    or `git diff | git apply --3way` (wrong base).
- **Do every non-trivial change in a dedicated git worktree branched off the current dev branch**, not in
  the primary checkout, and **make it with `scripts/new_worktree.sh`, not by hand**:
  `scripts/new_worktree.sh <feature>`
  It does the four-step dance in one command — add the worktree, symlink the compiled `bin/`, run
  `--import`, and editor-scan. **The `--import` is the step nobody remembers and the one that matters**: a
  fresh worktree's `.glsl` compute kernels are unimported, so `load()` returns null, the GPU MaterialField is
  SILENTLY DEAD (`biomass` 0, the log full of `get_spirv on a null value`) and every number in `SIM_REPORT`
  is fiction that looks fine.
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

Do **not** delete files with `find ... -name <dir> -exec rm -rf` or a bare recursive `rm`. A name-based
`find` matches every sibling sharing that name, and this tree is full of them — `actors/`, `ui/`,
`shaders/`, `material/`, `kernels3d/` each appear under more than one root. It has already nuked a
directory once, recovered only because it was committed.

When removing files:
- Prefer **explicit paths** or `git rm <path>` (it refuses to touch untracked files and stages the delete for review).
- If you must `find`, scope it: anchor with `-path '.../scenes/simulation/actors'` (full path, not `-name`),
  or add `-maxdepth 1`, and never combine `-name` with `-exec rm`/`-delete` over a shared parent.

## Execution model

- Understand current state and risks before editing. For big or ambiguous work, investigate first.
- **The main thread may edit — but only in its OWN worktree off the dev branch, never the shared checkout.**
- **Prefer sub-agents for parallel work, and every file-editing agent gets `isolation: "worktree"`.** No
  threshold, no judgement call: one agent or nine, one file or fifty. "Trivial" is a property of the DIFF,
  never of how much typing you did — launching an agent is one tool call and thousands of lines. Work you
  delegate is still your change. Nine lanes in one shared tree cost four of them their acceptance runs, and
  it manufactures the excuse for the next failure: "another lane owns that file" is scheduling, not a reason.
- **The coordinator integrates.** Worktree agents commit to their own branch; merging, conflict resolution
  and the verify gate stay the main thread's. Check `git log <base>..<branch>` before merging — an isolated
  agent can branch off a stale commit.
- **The roadmap is DELIBERATELY divergent so it parallelizes. Do not bounce it back as a question.** Build
  the collision map, do the seam-directed split to unblock, fan the tracks out, integrate what verifies.
  Surface only a genuine either/or that changes the ARCHITECTURE.
- **Use the `Workflow` tool for fan-outs** — standing process, no re-authorization needed. `pipeline()` is
  the default; `parallel()` only when you genuinely need every result together.
- **PRE-WRITE CONTRACTS.** Each agent gets: the goal, the exact files to add/change/DELETE, the shared
  interface it must honour, and a BINARY acceptance gate (exact command, pass condition, "commit only if it
  passes, else report"). Tell it to cite identifiers, not line numbers. Draft the next contracts while an
  agent is mid-flight, to the scratchpad — never the repo, or another agent's `git add -A` sweeps them up.
- **DO NOT FAN OUT PROSE, AND NEVER RUN A THIRD ROUND.** Fan-out earns its cost on parallel implementation
  over disjoint files whose correctness a command settles. On documentation the checking costs more than the
  writing. Two rounds, then do the rest yourself. The tell: the verifier's report is longer than the artifact.
- **NEVER PRESENT A MENU WHEN ONE OPTION IS CORRECT, AND EFFORT IS NEVER A TIEBREAKER.** Decide by
  correctness, say the answer in one sentence, build it. "Contained", "blast radius", "a bigger change" are
  facts about SCHEDULE: state them after the decision, never as inputs. If your options differ mainly in how
  much work they are, delete the menu. `AskUserQuestion` is for what only the maintainer knows — what he
  wants the world to BE like — never for "should I do the correct thing or the cheap thing".
- **EXPLAIN THE DEFECT IN PLAIN LANGUAGE, NAMING THE REAL-WORLD THING, BEFORE ANY `file:line`.** A maintainer
  who cannot picture the physics cannot catch you getting it wrong, and catching it is what he has been doing.
- **For substantial work, the record is the COMMIT MESSAGE.** Say what changed and what a consumer must do.
- **`HANDOFF.md` IS THE MAP OF WHAT IS LEFT, NEVER A HISTORY.** A checked-off item is DELETED when it is
  committed. Do not tick it or keep it "for context". The one exception: an entry that was FALSE is struck and
  annotated, so nobody re-derives the wrong conclusion. Keep it current unprompted — at every landing, before
  every merge, and before a session ends. Correcting a stale claim matters more than appending a new one, and
  every status claim must be one you just checked.

## Validation defaults

- **ITERATE AS FAST AS POSSIBLE.** Short runs while iterating; long runs and screenshots only at the final
  gate. For anything slow-emergent — geology, succession, erosion, climate — use the fast-forward time scale
  rather than waiting. Pick the cheapest run that proves the point.
- **`scripts/agent_harness.sh sim` is the one way to run the planet.** It runs off-screen with the streamer
  off, re-imports when a kernel changed, and refuses to print numbers if the run logged engine errors.
  Never launch godot windowed directly: it steals the keyboard. Engine flags go BEFORE the `--`.
- **`scripts/agent_harness.sh lint` is the gate, and an editor scan is not a substitute.** A file with a hard
  parse error has passed the scan while an entire transport CA silently did not run. Look for the force-load
  marker before believing anything.
- **`scripts/editor_scan.sh`, never a bare `godot --headless --editor`.** Two concurrent scans segfault; the
  wrapper takes a lock. A new `class_name` does not register without a scan.
- **Compare at equal simulated time, never equal frames**, and quote what disasters a run drew — the spread
  is discrete and disaster-driven, not Gaussian. Do not edit the tree while a run is in flight.
- **MEASURE BEFORE YOU TUNE, AND MOVE THE CONSTANT BY A LARGE FACTOR FIRST.** If the output barely responds,
  you are adjusting the wrong thing.
- **A PHYSICAL CONSTANT IS NOT A TUNING KNOB.** Measured properties of real matter are facts; hardcoding them
  accurately is the point. Moving one so a broken sim looks right is a lie about the material. Fix the sim.
  The tells: a temperature that is not a round physical value, a comment justifying a value by "the sim's
  actual range", and the same quantity declared in more than one file.
- **REMOVING A BAND-AID IS THE ACCEPTANCE TEST FOR FIXING ITS ROOT.** If the clamp cannot come out, the root
  is not fixed. Say so rather than quietly restoring it.
- **REVIEW STRUCTURE, NOT JUST VALUES.** Ask what a constant is a constant OF, and whether a metric is the
  right SHAPE. A global mean cannot answer a local question; one sample cannot answer "how extreme"; a scalar
  cannot show structure; and one constant shared across things that differ in reality is a modelling error.
- **AN INSTRUMENT THAT CHANGES WHAT IT MEASURES IS NOT AN INSTRUMENT.** A gauge may not call
  `request_channel`: residency decides which mirrors the simulation's own write paths read. Nor may it read
  the device directly mid-submit. A pure instrument samples at the drain, into a dictionary no consumer sees.
  And no physical mechanism may depend on a diagnostic being switched on.
- **THE SUBSTANCE TABLE IS THE SSOT FOR MATTER — `material/Substances.gd`.** Every material declares its own
  measured properties in ONE entry. `PhysicalConstants.gd` keeps only what is not a property of a substance.
  Do not add a flat constant for something a material owns, and check the fact is not already there under
  another name. Phase and temperature are DERIVED from energy and mass, never stored, so latent heat is
  structural and no kernel can skip a phase boundary.
- **A GATE THAT PASSES WITH THE FEATURE DISABLED IS NOT A GATE.** Build the disabled arm. **Mutation-test
  every gate both ways.** This repo has shipped gates that could only pass.
- Player-facing behaviour needs a real launched window. Headless suites are necessary and not sufficient.

`GODOT_BEST_PRACTICES.md` is canonical for Godot specifics — harness commands, markers, engine limits.

## Emergent-everything — the north star

**Named phenomena have ZERO dedicated code.** There is ONE substrate: matter with pressure, temperature,
phase, gravity, momentum and chemistry. "Volcano", "eruption", "storm", "avalanche" are words humans put on
what the physics does. A lava bomb is matter given momentum because pressure exceeded the rock confining it —
the same rule that throws debris from any pressure release, so geysers come free.

When you meet a named-phenomenon system, do not make its constants scale. Ask what universal rule makes it
HAPPEN, push that into the substrate, and DELETE the special case. **Success is measured in special-case code
deleted, not features added.**

**A NAMED PHENOMENON IS A DETECTOR, NEVER A CAUSE.** The substrate produces state; a detector observes it and
names it. An eruption is the observation that buoyant melt overcame its overburden. A hurricane is a warm-core
cyclone in the wind and pressure fields. The tell is a verb in a function name — `erupt_source`,
`_pump_eyewall`, `broadcast_seismic(MAGNITUDE)`. A genuine external cause is the one exception: a meteor really
does arrive from outside. **When the detector reads nothing, that is the finding** — fix the physics that
cannot run, do not keep the pump.

**Behaviour comes from local rules, driven by config and properties, never `if identity == X`.** Couple systems
through stimuli and broadcasts so new events compose instead of needing per-event code. Success is behaviour
nobody wrote: stampedes from a strike, fire spreading downwind, herds reforming after a scare.

**One-substrate default: always ask whether this belongs in the field.** Anything that diffuses, advects,
flows, deposits or decays over space should be a channel or a stepped process, so it composes with everything
else for free. Keep something out only for a stated reason.

## Inspector surfaces

- **A dead `@export` is worse than none** — it is a promise the code does not keep. Prove an export reaches
  behaviour by RUNNING it, not by reading the call chain. For the GDScript↔C++ boundary, grep the native
  source for the key.
- **Never write a serialised property from a `@tool` script in the editor.** Adding `@tool` means every
  lifecycle callback opens with `if Engine.is_editor_hint(): return`, before any node mutation.
- **Precedence is node → project setting → env var → default.** Inverting it makes the inspector a lie.
- **Measure a simulation on the physics clock**, not on render frames.
- **Verify a claim before acting on it, including a reviewer's.** A reviewer is another agent and can be
  confidently wrong. Run the command, quote the output, then change the code.

## How good is the physics? `PHYSICS_RUBRIC.md`

Six criteria, scored on every landing. `scripts/physics_score.sh` computes what it can from the report; the
hand-entered half is the half to distrust, because the person scoring is the person who did the work.

## Repository policy

- **No downstream consumers. Break APIs freely when it improves the architecture**, and remove old
  abstractions rather than leaving parallel ones.
- **Temporary breakage is allowed on a FEATURE branch, never on `main` or the dev branch.** Converting in
  place beats a duplicate non-breaking path with `if mode` branches. Commit WIP checkpoints, and drive it back
  to verified before merging.
- **Surface held-back-by-code moments.** If the current shape is a holdover blocking a better approach, name
  the relic and what the better approach unlocks. Do not silently work around it, and do not unilaterally rip
  out an architecture — that one is the maintainer's call.
- **NO PROSE IN COMMENTS.** Short and factual: what it does, and units. No history, no rationale essays, no
  measured numbers, no dates. **A comment is a claim, and claims here are reliably false** — not one bad claim
  was ever caught by reading; every one was caught by a gate firing or an impossible number. If a claim
  matters, make it a GATE. If it does not, delete it. This applies to `.md` as much as to code: prose costs
  the next agent's context before it costs anything else.
- **DO NOT RUN A TEST UNTIL THE CHANGE IS FINISHED.** Collapse the whole set, then run once. A run against
  code you have already convicted measures the interaction of defects and is discarded by the next edit.
- **Unwired code is an UNFINISHED JOB — the default is to WIRE IT IN.** Deleting needs a reason beyond
  "nothing references it": the author's own removal condition is met, it was superseded by something that
  demonstrably does the same job, or the design is wrong. Say which. And measure "unreferenced" correctly —
  this tree loads by `preload("res://…")` far more than by identifier, so count path references too.
- **Composable plugins over a monolith.** For any SET of composable things over shared state — field passes,
  reactions, telemetry sources, bodies — a thin HOST plus a registry of small modules beats one file with
  `if type == X` branches. Adding a phenomenon is a record, not a patch. When you catch yourself adding a
  type-branch to a big file, make it a plugin.
- **PRESENTATION MAY NOT LIVE ON THE SIM SIDE, AND A GENERIC THING MAY NOT BE NAMED AFTER AN IMPLEMENTATION.**
  The sim runs headless and the UI is opt-in, so a node's DIRECTORY decides whether it is on the physics path.
  The sim clock was once load-bearing inside a `CanvasLayer`, so a run without UI had no clock; a pause menu
  of plain buttons sat in the world-controller directory under a `Voxel` prefix it never touched. Ask where a
  file lives before what it does, and strip an implementation prefix the file does not earn. A quality dial
  must not reach physics: an effects-scale setting once scaled the in-flight ejecta cap, so a graphics preset
  changed where mass landed.
- **Simplicity, and no speculative pipelines.** Implement the simplest thing that is correct for the target
  path.
- **Big-O IS a first-class design goal.** Lower the asymptotic cost, then the constants. Spatial hash, grid,
  neighbour table or precomputed table over pairwise or full-scan; event and dirty-set updates over re-sweeps.
  A per-frame O(n²), or an O(N) full-grid sweep that ignores what changed, is a perf bug to design out.
- **Do less by RELEVANCE — adaptive LOD is mandatory.** Offscreen, distant, dormant and empty regions do
  less. **BUBBLES OF COMPUTE:** a cell's tick rate scales with how much is HAPPENING there. Activity
  propagates — a cell that changes wakes its neighbours, so a front grows its own compute bubble at the speed
  of the phenomenon — and settled regions demote, then sleep. On the GPU that is an active-cell list and
  indirect dispatch, O(active) rather than O(all cells). This is what makes a whole planet affordable.
- **Native / GPU / shader-first.** Runtime simulation is C++ or GPU by default; minimize C++↔GDScript and
  CPU↔GPU hops. **No "transitional shims"** — either it is built native/GPU now, or it is ordinary code we
  improve. The one legitimate CPU form is a permanent fallback / parity oracle; build it as such.
- **Per-cell field CAs belong on the GPU, not in C++.** Anything evaluating a rule per cell over the grid is
  embarrassingly parallel, so its authoritative form is a compute kernel. C++ is for serial work. A per-cell
  CA looping in GDScript on the per-frame path is a performance bug, not an acceptable state.
- **PERFORMANCE OVER PARITY.** Playable framerate beats CPU↔GPU numeric parity whenever they conflict. Verify
  GPU kernels behaviourally — mass conserved, counts sane, no runaway — rather than paying a per-frame CPU tax
  to keep two paths identical.
- **Fail-fast over silent degradation.** On authoritative paths, if the native/GPU path cannot execute, fail
  with an explicit typed error rather than routing to alternate BEHAVIOUR.
- **Test integrity:** never fabricate or infer execution success, and never convert a hard runtime failure
  into a soft pass.
- Keep `RigidBody3D` use minimal and justified; default to voxel-native paths.

## File size & refactor discipline
- **EXTRACT-ONLY HUBS — `VoxelWorld.gd` and `MaterialField3D.gd`; do NOT add behavior to them.**
   These two files have been split THREE times because new work keeps re-accreting into them (they
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
    is a green CI. Do not add a check to one and not the other.
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
- **Godot 4.7**, `godot` on PATH. Test/observe via `scripts/agent_harness.sh <command>`; the voxel
  scene also self-harnesses (`-- --run-frames=N` prints `SIM_REPORT={...}`; `--shoot=<png>` for
  windowed screenshots; `--auto-meteor` drops a test impact). A NEW `.gd` `class_name` or
  `.gdextension` only registers after an editor scan — run **`scripts/editor_scan.sh`** once, else classes
  report MISSING.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on `adammikulis/local-agents`, driven by the `gh` CLI. See
`docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

# CLAUDE.md

# RULE ZERO — REALISM FIRST

Before writing, reviewing or accepting any model, constant, coupling or measurement, ask: is this how the
real world works? "It runs", "the test passes", "the number looks reasonable" are downstream.

**The referent is the world outside this repository. Nothing inside it counts** — not another file, not a
prior agent's model, not this document. Answer with a measured property, a textbook mechanism or a
published value.

1. Name the real-world referent. If you cannot, that is the finding.
2. Systems independent in the world are independent in the code, both directions.
3. Check the scale. Off by 4x is wrong even if it runs.
4. Entities that differ in reality differ in code. One constant shared across different things is a
   modelling error.
5. Check the measurement's shape: a global mean cannot answer a local question; one sample cannot answer
   "how extreme"; a scalar cannot show structure.
6. When reality and convenience conflict, reality wins.

Point it at the engine hardest — the substrate, the reaction table, the integrator. A wrong constant is
one lie; a wrong engine licenses every record written against it. Do this unprompted on every file you
open. If you notice a violation while doing something else, fix it and report it that turn.

# RULE 1 — DELETE IT. DO NOT PRESERVE IT.

If it is wrong, delete it: not behind a flag, a mode, a default, an alias, a pad or a fallback. There are
no downstream consumers. Ask whether the thing exists in the real world; if it does not, there is nothing
to preserve.

Delete on sight, no permission, no measurement first:
- a fallback that substitutes a plausible value when a lookup fails — a missing measurement is missing;
  return nothing and name the absence;
- a shim kept so call sites read the same;
- an environment variable that turns a physical process off (gate diagnostics on
  `get_environment(name) != ""`; `env FOO=` counts as set for `has_environment`);
- a clamp, cap, floor or rarity roll that stops a symptom — fix the root; the clamp coming out is the
  acceptance test;
- a second declaration of one fact, and the gate guarding the dead one;
- state written and never read; a mirror never allocated;
- a gate that cannot fail — mutation-test every gate both ways or you have not written one;
- a verb that makes a named phenomenon happen by injecting its ingredients — it becomes a detector;
- a quality or presentation dial that reaches physics.

# RULE 1b — NOTHING THIS SUBSTRATE PRINTS IS EVIDENCE, AND GREEN IS NOT A REASON

Report no number — total, drift, percentage, mean, count — until `HANDOFF.md` and
`docs/PHYSICS_TODO.md` are empty. Never a before/after table, never "beating a baseline"; fitting the
model to its output is how water came to freeze at 12.5 °C. A crutch is deleted, never measured. The only
measure of progress is what was ripped out: report the file, the constant, the switch, the duplicate.

"So that it compiles", "so the call sites still read the same", "so we have a baseline", "so the gate
goes green" are not reasons. Red is the working state of a branch mid-conversion. A step is done when
something is gone or a physical claim is true, never when a command exited 0.

Never shape the physics to suit the display: not the rate, the threshold, the unit, or which cells are
stepped. If a thing is hard to render, fix the renderer.

# RULE 1c — TWO PHASES. CREATION IS LEGAL IN ONE

Seeding: matter and energy may be created; declare every act through
`LAMaterialFieldSeal3D.note_creation()`. Sealed: matter and energy may only move or transform, and no
flag may re-enable creation. `sealed()` is the boundary; `creation_after_seal` reads empty;
`scripts/check_seed_phase.sh` fails on a creation-class write that never asks and on any whole-mirror
upload.

# RULE 1d — NOTHING HERE CONSTRAINS YOU: NOT OUR OWN CODE, AND NEVER PERMISSION

"A can't happen because B" is allowed only when B is an upstream bug you cannot fix. If B is our code the
sentence continues "and this is how I am fixing it." Every constraint here is a decision, not physics.
The subtle form is preserving a shape: adding the right relation beside the scalar it replaces, with
every consumer still on the scalar.

Never ask permission to do the correct thing. Before `AskUserQuestion`, check whether this file,
`HANDOFF.md` or `docs/PHYSICS_TODO.md` already decides it; if so, act. The tool is for what only the
maintainer knows — what he wants the world to be like. Never for a choice between correct and cheap,
never for reassurance, never to ask whether a broken sim may stay broken.

# RULE 2 — YOU PRESERVE NUMBERS, NOT CODE

Rule 1 gets obeyed on files and violated on values; the motive is keeping your own past figures
interpretable. Delete the value too. The deference failure that carries it: manufacturing a reason an
explicit instruction "does not apply here".

# RULE 3 — NAME THE CONSTRAINT AS A LAW OR A DECISION, OUT LOUD, EVERY TIME

A law is physics. A decision is ours and can be unmade. Almost everything here is a decision.

# RULE 4 — A DELETION THAT BREAKS A REFERRER IS REPAIRED FORWARD

Fix the referrer. Never restore what you deleted. A red gate after a deletion is the work queue.

# RULE 5 — IF REMOVING THE WRONG THING BREAKS SOMETHING, THAT IS THE FINDING

The breakage names what depended on the defect. A permanently red gate destroys the signal of every gate
beside it, so ceilings are ratchets: set at the count, lowered as things are fixed, never raised.

# RULE 6 — WRONGNESS FIRST, CALLERS SECOND

Decide whether a thing is wrong before you look at what references it. "It has callers, so it stays" is
never a reason, in any dress: "another lane owns it", "this would break N files", "let's not churn that".

Verify branch state with git arithmetic before planning against it: `git cherry` both directions and
`git merge-base --is-ancestor main <dev>`. The dev branch must contain `main`. Reconcile at a handful of
commits, never a hundred.

# RULE 7 — PROSE IS EXPENSIVE

Every paragraph is spent context. Write the imperative and stop: no history, no dates, no worked examples,
no measured figures, no restating. A change may not add more comment than code per file
(`scripts/check_comment_ratio.sh`, in the pre-commit hook and lint). A comment labels; it does not argue,
defend or anticipate a question; more than six consecutive comment lines is a paragraph
(`scripts/check_comment_block.sh`). `scripts/check_comment_history.sh` ratchets the banned kinds down. A
claim that matters becomes a gate; one that does not is not written.

# RULE 8 — READ THE CODE. NEVER NARRATE A DIAGNOSIS

Open the file, answer from the code. Instrument only after reading has failed. "That changes the
diagnosis", "actually it is X" are banned phrases and the turns that produce them are banned work. A
probe that prints only past a threshold needs a positive control.

Never write a changelog; the tree is the change log (`scripts/check_doc_prose.sh`).

`HANDOFF.md` is the next agent's instruction set: the file and the expression, in one sentence, only when
the fix could not land this turn. A tracker item carries a symptom and the command that reproduces it,
never a diagnosis. It may carry one `Reading:` line — a fact read off the code, naming an identifier in
backticks, checkable by grep — never a hypothesis. Findings are not written down; fix it.

# YOU MAY NOT VIOLATE PHYSICS WITHOUT EXPLICIT PERMISSION

Every departure from real physics needs the maintainer's consent before the code exists: matter or energy
created or destroyed; a constant invented rather than derived or cited; a mechanism reality lacks; a
clamp, floor, cap or target that stops a symptom; a rate fitted so an output looks right; a phase change
that skips its latent heat; a gauge answering a different question than the one asked.

## The one standing exemption: a cheaper solver of the same shape

What is computationally infeasible may be approximated, without asking, under three conditions:
1. The shape is the same — functional form, dependencies, direction of every effect; only the resolution
   or the solver is cheapened. A number back-derived from the answer is a fitted constant, not an
   approximation.
2. The real one swaps in at the same seam. Name the replacement.
3. It is declared in `docs/APPROXIMATIONS.md`; `scripts/check_approximations.sh` holds the registry to
   the code both ways.

Conservation is never covered. Cheapen the solver, never the books.

If you cannot derive it or cite it, stop and ask. A citation-flavoured comment beside a chosen number is
worse than the bare value. `scripts/check_model_parameters.sh` fails on a kernel constant that is neither
bound to `LAPhysical` nor declared in `docs/MODEL_PARAMETERS.md`.

Every conservation violation is addressed or exempted, and exemption is the maintainer's alone. "Out of
scope", "another subsystem owns it", "it is in the tracker" are scheduling statements; deferring a
violation is a decision that needs approval. Translate the euphemism: "minting", "drift", "stand-in" mean
the simulation creates atoms from nothing. Distrust framings as well as facts: a tracker, a task
description, a prior agent's report and this file are all claims.

**Every bug you find is in scope.** One you do not fix when you find it never gets fixed. "Not my current
task", "another lane owns it", "noting it for later" are the tells. This covers the harness and the tooling.
Fix the class, not the instance: leave a gate behind.

## Scope: the planet first. Living things are 0.5

0.4 is the planet. Creature and plant work is premature until the planet is locked down, and the referent
is the lifeless 4.4 Ga Earth (`docs/PHYSICS_TODO.md`). Locked down means: every conserved substance has a
drift gauge reading ~0; no physical constant is fitted; springs and rivers run, sediment moves, snow and
sea ice form at 0 °C, volcanism and weathering are mechanisms; nothing depends on the observer. Touch a
creature file only when the planet needs it. All of the planet's mass is seeded in 0.4 at its real
elemental composition; chemistry is not biology, so weathering, clay, serpentinization, outgassing, ore
concentration and abiotic organic synthesis are 0.4. `docs/0.5_CREATURE_FEATURES.md` is parked.

## The ladder, the slice, and the demos

- Physics is built and verified one rung at a time. A run declares which processes its world contains
  (`addons/local_agents/gdextensions/localagents/src/LAProcessSet.cpp`); a process outside the set is
  absent. Reproduce a defect at the lowest rung that shows it. `scripts/check_process_ladder.sh` names
  the first red rung; nothing above it is measured. The demo world runs at `docs/PLAYABLE_RUNG`.
- **The acceptance arm is a slice of the planet** (`scripts/sim_run.sh --slice`): a box on the surface,
  graded to a declared finest cell edge under `docs/CELL_BUDGET`. The whole planet is a smoke test.
- **A rung is built only after the maintainer has approved a demo of the rung below it.** Each rung's
  demo is a scene plus a `LocalAgentDemoEntry` in `addons/local_agents/examples/demos/`. Cut it, write
  "what you should see", launch it, stop; the maintainer's feedback decides.
- **Each rung's demo ADDS something the maintainer can verify by eye or by ear**, and that something
  is the rung's own process acting: rung 1 shows things falling under the solved g, rung 3 shows air
  moving. A rung whose demo looks and sounds like the rung below has not been demonstrated.
- **A rung's run shows, draws, offers or asks for only what its world contains.** No placeholder for
  an absent field, no HUD control for an absent process, no gate requesting a field the rung lacks;
  every renderer, control and gate derives what it may show from `LAProcessSet`.
- **Target architecture: a standalone native sim process.** Physics runs in its own executable with its
  own compute device, clock and CLI; gates run it with no Godot launch; Godot is a client that attaches
  to view and steer. Physics in Godot's process is a holdover, not the design.

## Emergent-everything

Named phenomena have zero dedicated code. One substrate: matter with pressure, temperature, phase,
gravity, momentum and chemistry. A named phenomenon is a detector, never a cause — the tell is a verb in a
function name. A genuine external cause (a meteor) is the exception. When the detector reads nothing,
fix the physics that cannot run. Behaviour comes from local rules driven by config and properties, never
`if identity == X`. Anything that diffuses, advects, flows, deposits or decays over space is a channel or
a stepped process. Success is special-case code deleted.

## Branch and worktree workflow

- **The current development branch is `0.4-dev`.** This line is the one declaration of its name
  (`scripts/lib_dev_branch.sh` parses it). `main` holds the shipped release (`v0.3.1`). Never commit
  feature work to `main`.
- Every subagent that edits files gets its own worktree: pass `isolation: "worktree"`, no threshold.
  Work you delegate is still your change. Read-only agents may share the tree and cite identifiers, not
  line numbers.
- Fan-outs run on disjoint file ownership. Each contract lists the files the lane owns; a lane that needs
  another's file stops and reports. The coordinator registers gates and sets shared literals at
  integration.
- Integration is a command: `scripts/integrate.sh <branch>`. Never `git merge` into the dev branch by
  hand. A running agent's worktree is not yours to write in: stop the agent, then integrate.
- Verify a deletion by content (`rg`), never by ancestry. Lanes do not edit ceiling files; a lane fails
  only when a count rises.
- Whoever made a worktree prunes it in the turn it stops being used. A session may not end with a tree it
  did not start with. Nothing is kept "in case".
- Make worktrees with `scripts/new_worktree.sh <feature>`: it copies `bin/`, links `thirdparty/`,
  imports the kernels and scans. Without the import the GPU field is silently dead and the report looks
  fine. `bin/` is copied per worktree; a lane that changes extension sources rebuilds
  (`la_godot` refuses a `bin/` whose `SOURCE_HASH` does not match).
- Skip the worktree only for a trivial single-file doc edit when you are the sole writer.

## Execution model

- Investigate before editing. The main thread edits only in its own worktree.
- Pre-write contracts: goal, exact files to add/change/delete, the shared interface, a binary acceptance
  gate ("commit only if it passes, else report"). Draft the next contracts to the scratchpad, never the
  repo. Do not fan out prose; two rounds, then do the rest yourself.
- Use the `Workflow` tool for fan-outs; `pipeline()` by default.
- The size of a change is never a factor in deciding what to do. Never present a menu when one option is
  correct; effort is never a tiebreaker.
- Explain a defect in plain language, naming the real-world thing, before any `file:line`.
- The record of substantial work is the commit message. `HANDOFF.md` is the map of what is left: a
  landed item is deleted, ordered by what is upstream of what, kept current at every landing.

## Validation

- A verification run answers inside `docs/RUN_TIMEOUT_CEILING`; a longer run is a declared soak
  (`# SOAK: <why>`). Never raise the ceiling to make a slow arm pass.
- One sim at a time on this machine (a machine-wide GPU lock). Never `pkill` by program name; kill by
  your own PID or a pattern anchored on your own worktree. Never remove a lock by hand.
- A lane runs `LA_NO_GPU=1 scripts/agent_harness.sh lint` plus its own gates; the full lint is
  `scripts/integrate.sh`'s.
- A launch that shows a window is a bug: `la_godot` is the only launcher (`scripts/check_godot_launcher.sh`,
  `scripts/check_no_focus_theft.sh`). Player-facing behaviour still needs a real launched window.
- Iterate fast: short runs while iterating; fast-forward slow-emergent phenomena; the cheapest run that
  proves the point. Do not run a test until the change is finished.
- `scripts/agent_harness.sh sim` is the one way to run the planet; `scripts/agent_harness.sh lint` is
  the gate CI runs; `scripts/editor_scan.sh`, never a bare `godot --headless --editor`.
- Compare at equal simulated time, never equal frames. Measure on the physics clock.
- Measure before you tune, and move a constant by a large factor first. A physical constant is not a
  tuning knob.
- Review structure, not just values: what is a constant a constant of; is a metric the right shape.
- An instrument that changes what it measures is not an instrument: a gauge may not call
  `request_channel` or read the device mid-submit; no mechanism may depend on a diagnostic being on.
- Pressure has two writers, one per cell class (maintainer's decision): an open cell's from the EOS in
  `state_derive.glsl`, a solid cell's the column from `pressure.glsl`; they never meet
  (`scripts/check_pressure_split.sh`).
- The substance table is the SSOT for matter: `LASubstances` in the GDExtension. Phase and temperature
  are derived from energy and mass, never stored. `PhysicalConstants.gd` keeps only what is not a property
  of a substance.
- A gate that passes with the feature disabled is not a gate. Build the disabled arm. A gate that cannot
  run fails (exit 2), never passes (`scripts/lib_require.sh`).
- Six criteria in `PHYSICS_RUBRIC.md`; `scripts/physics_score.sh` computes what it can.

## Repository policy

- No downstream consumers: break APIs freely; remove old abstractions rather than leaving parallel ones.
- Temporary breakage is allowed on a feature branch, never on `main` or the dev branch.
- Surface held-back-by-code moments: name the relic and what the better approach unlocks; ripping out an
  architecture is the maintainer's call.
- No prose in comments: what it does, and units. A comment is a claim, and claims here are reliably false.
- Unwired code is an unfinished job: wire it in by default; deleting needs a stated reason. Count path
  references (`preload("res://…")`) as references.
- Composable plugins over a monolith: a thin host plus a registry of records; adding a phenomenon is a
  record, not a patch.
- Presentation may not live on the sim side (a node's directory decides), and a generic thing may not be
  named after an implementation.
- Big-O is a first-class design goal; do less by relevance: bubbles of compute, active-cell lists,
  indirect dispatch, O(active) not O(all cells).
- Native/GPU/shader-first; per-cell field CAs are compute kernels; C++ is for serial work; no
  transitional shims. Performance over parity: verify kernels behaviourally.
- Fail fast over silent degradation on authoritative paths. Never convert a hard runtime failure into a
  soft pass.
- Keep `RigidBody3D` minimal.

## File size and refactor discipline

- Extract-only hubs: `VoxelWorld.gd` and `MaterialField3D.gd`. A new feature is a new module plus at most
  a one-line hook there.
- Parallelizability drives refactors: a file several concurrent units must edit is a serialization
  bottleneck; split it first, seam-directed (a read-only map pass, then only the seams the fan-out needs).
- `scripts/check_max_file_length.sh`: warn at 1300 lines, fail at 1500, markdown included. Do not add to
  a file over the warning; extract first.

## Assets

Bring 3D assets in as glTF. Non-skinned FBX converts through `GLTFDocument` headless; skinned characters
through headless Blender, re-binding the mesh to the animation's armature. Match clips by substring, set
`LOOP_LINEAR`, attach head accessories with `BoneAttachment3D`.

## Destructive-command safety

Never delete with a name-based `find -exec rm` or a bare recursive `rm`; this tree repeats directory names
under many roots. Prefer explicit paths or `git rm`; anchor any `find` with a full `-path`.

## Inspector surfaces

A dead `@export` is worse than none: prove it reaches behaviour by running it. A `@tool` script never
writes a serialised property in the editor. Precedence is node → project setting → env var → default.
Verify a reviewer's claim before acting on it.

## Orientation

`GODOT_BEST_PRACTICES.md` holds the Godot specifics. The active scene is
`addons/local_agents/game/VoxelWorld.tscn` (`project.godot` boots the menu; the sim wants `--sandbox`).
`HANDOFF.md` holds what is left and the run commands. A new `class_name` registers only after
`scripts/editor_scan.sh`. Issues live in GitHub Issues (`docs/agents/issue-tracker.md`); triage labels
in `docs/agents/triage-labels.md`.

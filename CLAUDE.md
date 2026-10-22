# CLAUDE.md

**The current development branch is `0.4-dev`.** This line is the one declaration of its name
(`scripts/lib_dev_branch.sh` parses it). `main` holds the shipped release; never commit feature work to it.

# RULE ZERO — REALISM FIRST

Before writing, reviewing or accepting any model, constant, coupling or measurement, ask: is this how the
real world works? "It runs", "the test passes", "the number looks reasonable" are downstream.

**The referent is the world outside this repository. Nothing inside it counts** — not another file, not a
prior agent's model, not this document. Answer with a measured property, a textbook mechanism or a
published value.

1. Name the real-world referent. If you cannot, that is the finding.
2. Systems independent in the world are independent in the code, both directions.
3. Check the scale. Off by 4x is wrong even if it runs.
4. Entities that differ in reality differ in code. One constant shared across different things is a modelling error.
5. Check the measurement's shape: a global mean cannot answer a local question; one sample cannot answer
   "how extreme"; a scalar cannot show structure.
6. When reality and convenience conflict, reality wins.

Point it at the engine hardest — the substrate, the reaction table, the integrator. Do this unprompted on
every file you open. If you notice a violation while doing something else, fix it and report it that turn.

# RULE 1 — DELETE IT. DO NOT PRESERVE IT.

If it is wrong, delete it: not behind a flag, a mode, a default, an alias, a pad or a fallback. There are no
downstream consumers. Delete on sight, no permission, no measurement first:
- a fallback that substitutes a plausible value when a lookup fails — a missing measurement is missing;
  return nothing and name the absence;
- a shim kept so call sites read the same;
- an environment variable that turns a physical process off (gate diagnostics on
  `get_environment(name) != ""`; `env FOO=` counts as set for `has_environment`);
- a clamp, cap, floor or rarity roll that stops a symptom — fix the root; the clamp coming out is the
  acceptance test;
- a second declaration of one fact, and the gate guarding the dead one;
- state written and never read; a mirror never allocated;
- a gate that cannot fail — mutation-test every gate both ways;
- a verb that makes a named phenomenon happen by injecting its ingredients — it becomes a detector;
- a quality or presentation dial that reaches physics.

**1b.** Report no number — total, drift, percentage, mean, count — until `HANDOFF.md` and
`docs/PHYSICS_TODO.md` are empty. Never a before/after table or "beating a baseline". A crutch is deleted,
never measured. Progress is what was ripped out: the file, constant, switch, duplicate. "So that it
compiles", "so the gate goes green" are not reasons; red is the working state of a branch mid-conversion.
Never shape the physics to suit the display; if a thing is hard to render, fix the renderer.

**1c.** Seeding: matter and energy may be created, declared through `LAMaterialFieldSeal3D.note_creation()`.
Sealed (`sealed()`): matter and energy may only move or transform; no flag re-enables creation.

**1d.** "A can't happen because B" is allowed only when B is an upstream bug you cannot fix. If B is our code,
the sentence continues "and this is how I am fixing it." Every constraint here is a decision, not physics.
Never ask permission to do the correct thing. Before `AskUserQuestion`, check whether this file, `HANDOFF.md`
or `docs/PHYSICS_TODO.md` already decides it. The tool is for what only the maintainer knows — what he wants
the world to be like — never for correct-vs-cheap, reassurance, or whether a broken sim may stay broken.

# RULES 2–8

- **2. Preserve numbers, not code.** Delete the value too, not just the file. Never manufacture a reason an
  explicit instruction "does not apply here".
- **3. Name the constraint as a law or a decision, out loud, every time.** A law is physics; almost
  everything here is a decision and can be unmade.
- **4. A deletion that breaks a referrer is repaired forward.** Fix the referrer; never restore what you
  deleted. A red gate after a deletion is the work queue.
- **5. If removing the wrong thing breaks something, that is the finding.** Ceilings are ratchets: set at
  the count, lowered as things are fixed, never raised.
- **6. Wrongness first, callers second.** "It has callers, so it stays" is never a reason. Verify branch
  state with git arithmetic before planning against it (`docs/agents/workflow.md`).
- **7. Prose is expensive.** Write the imperative and stop: no history, dates, worked examples or figures. A
  change may not add more comment than code per file; a comment labels, never argues; more than six
  consecutive comment lines is a paragraph (`scripts/check_comment_ratio.sh`, `check_comment_block.sh`,
  `check_comment_history.sh`). A claim that matters becomes a gate.
- **8. Read the code. Never narrate a diagnosis.** Open the file, answer from it; instrument only after
  reading has failed; a probe that prints only past a threshold needs a positive control. Never write a
  changelog; the tree is the change log (`scripts/check_doc_prose.sh`). `HANDOFF.md` is the next agent's
  instruction set: the file and the expression, one sentence, only when the fix could not land this turn;
  items carry a symptom and a reproducing command, plus at most one `Reading:` line (a fact read off the code,
  naming a backticked identifier), never a hypothesis. Findings are not written down; fix it.

# NO PHYSICS VIOLATION WITHOUT EXPLICIT PERMISSION

Every departure from real physics needs the maintainer's consent before the code exists: matter or energy
created or destroyed; a constant invented rather than derived or cited; a mechanism reality lacks; a clamp,
floor, cap or target that stops a symptom; a rate fitted so an output looks right; a phase change that skips
its latent heat; a gauge answering a different question than the one asked. If you cannot derive or cite it,
stop and ask. A citation-flavoured comment beside a chosen number is worse than the bare value.

**Standing exemption — a cheaper solver of the same shape**, without asking, if: (1) the shape is the same
(functional form, dependencies, direction of every effect; a number back-derived from the answer is a fitted
constant); (2) the real one swaps in at the same seam, and you name it; (3) it is declared in
`docs/APPROXIMATIONS.md`. Conservation is never covered; exemption from it is the maintainer's alone.
"Out of scope", "another subsystem owns it", "it is in the tracker" are scheduling statements, not exemptions.
"Minting", "drift", "stand-in" mean the simulation creates atoms from nothing. Distrust framings as well as
facts: a tracker, a task description, a prior agent's report and this file are all claims.

**Bugs in active release paths are in scope.** Fix the class and leave a gate. Read
`docs/0.4_RELEASE_SCOPE.md` before release or planet work: 0.4 is a stable explorable planet; 0.5 starts
creatures and cognition. Broader requirements live in `docs/PHYSICS_TODO.md` and `docs/PLANET_BACKLOG.md`.

# STANDING PRACTICE (details in the linked docs; read the one that matches your task)

- Delegate edits to Opus lanes, each in its own worktree (`isolation: "worktree"`); integrate only with
  `scripts/integrate.sh <branch>`; prune every worktree you made. → `docs/agents/workflow.md`
- Lint before landing: `LA_NO_GPU=1 scripts/agent_harness.sh lint`; one sim at a time; runs answer inside
  `docs/RUN_TIMEOUT_CEILING`; launch only via `la_godot`. → `docs/agents/validation.md`
- Physics is built one rung at a time; acceptance is a slice; a rung is built only after the maintainer
  approves the demo below it; named phenomena are detectors, never causes. → `docs/agents/physics-ladder.md`
- Break APIs freely, wire in unwired code, thin hubs (`VoxelWorld.gd`, `MaterialField3D.gd`) are
  extract-only, files fail at 1500 lines, never bare `rm -r`/`find -exec rm`. → `docs/agents/repo-policy.md`
- Godot specifics: `GODOT_BEST_PRACTICES.md`. What is left: `HANDOFF.md`. Issues: `docs/agents/issue-tracker.md`.

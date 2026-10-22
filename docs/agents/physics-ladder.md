# The ladder, the slice, the demos, emergence

## Ladder and slice
- Physics is built and verified one rung at a time. A run declares which processes its world contains
  (`addons/local_agents/gdextensions/localagents/src/LAProcessSet.cpp`); a process outside the set is absent.
  Reproduce a defect at the lowest rung that shows it. `scripts/check_process_ladder.sh` names the first red
  rung; nothing above it is measured. The demo world runs at `docs/PLAYABLE_RUNG`.
- The acceptance arm is a slice of the planet (`scripts/sim_run.sh --slice`): a box on the surface, graded to a
  declared finest cell edge under `docs/CELL_BUDGET`. The whole planet is a smoke test.
- Target architecture: a standalone native sim process with its own compute device, clock and CLI; gates run it
  with no Godot launch; Godot is a client that attaches to view and steer. Physics in Godot's process is a
  holdover, not the design.

## Demos
- A rung is built only after the maintainer has approved a demo of the rung below it. Each rung's demo is a
  scene plus a `LocalAgentDemoEntry` in `addons/local_agents/examples/demos/`. Cut it, write "what you should
  see", launch it, stop; the maintainer's feedback decides.
- Each rung's demo ADDS something the maintainer can verify by eye or by ear: the rung's own process acting
  (rung 1 things falling under the solved g, rung 3 air moving). A debug overlay drawing a field's direction
  and magnitude counts. A rung whose demo looks and sounds like the rung below has not been demonstrated.
- A rung's run shows, draws, offers or asks for only what its world contains. No placeholder for an absent
  field, no HUD control for an absent process, no gate requesting a field the rung lacks; every renderer,
  control and gate derives what it may show from `LAProcessSet`.

## Emergent-everything
Named phenomena have zero dedicated code. One substrate: matter with pressure, temperature, phase, gravity,
momentum and chemistry. A named phenomenon is a detector, never a cause; the tell is a verb in a function name.
A genuine external cause (a meteor) is the exception. When the detector reads nothing, fix the physics that
cannot run. Behaviour comes from local rules driven by config and properties, never `if identity == X`.
Anything that diffuses, advects, flows, deposits or decays over space is a channel or a stepped process.
Success is special-case code deleted.

## Substrate facts
- The substance table is the SSOT for matter: `LASubstances` in the GDExtension. Phase and temperature are
  derived from energy and mass, never stored. `PhysicalConstants.gd` keeps only what is not a property of a
  substance.
- `scripts/check_model_parameters.sh` fails on a kernel constant neither bound to `LAPhysical` nor declared in
  `docs/MODEL_PARAMETERS.md`. Approximations are registered in `docs/APPROXIMATIONS.md`
  (`scripts/check_approximations.sh`).

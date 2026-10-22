# Validation and runs

- A verification run answers inside `docs/RUN_TIMEOUT_CEILING`; a longer run is a declared soak
  (`# SOAK: <why>`). Never raise the ceiling to make a slow arm pass.
- One sim at a time on this machine (a machine-wide GPU lock). Never `pkill` by program name; kill by your own
  PID or a pattern anchored on your own worktree. Never remove a lock by hand.
- A lane runs `LA_NO_GPU=1 scripts/agent_harness.sh lint` plus its own gates; the full lint is
  `scripts/integrate.sh`'s.
- A launch that shows a window is a bug: `la_godot` is the only launcher (`scripts/check_godot_launcher.sh`,
  `scripts/check_no_focus_theft.sh`). Player-facing behaviour still needs a real launched window.
- Iterate fast: short runs while iterating; fast-forward slow-emergent phenomena; the cheapest run that proves
  the point. Do not run a test until the change is finished.
- `scripts/agent_harness.sh sim` is the one way to run the planet; `scripts/agent_harness.sh lint` is the gate
  CI runs; `scripts/editor_scan.sh`, never a bare `godot --headless --editor`.
- Compare at equal simulated time, never equal frames. Measure on the physics clock.
- Measure before you tune, and move a constant by a large factor first. A physical constant is not a tuning knob.
- Review structure, not just values: what is a constant a constant of; is a metric the right shape.
- An instrument that changes what it measures is not an instrument: a gauge may not call `request_channel` or
  read the device mid-submit; no mechanism may depend on a diagnostic being on.
- Pressure has two writers, one per cell class (maintainer's decision): an open cell's from the EOS in
  `state_derive.glsl`, a solid cell's the column from `pressure.glsl`; they never meet
  (`scripts/check_pressure_split.sh`).
- A gate that passes with the feature disabled is not a gate. Build the disabled arm. A gate that cannot run
  fails (exit 2), never passes (`scripts/lib_require.sh`).
- Ten criteria in `PHYSICS_RUBRIC.md`; `scripts/physics_score.sh` computes what it can.
- Seed phase: `scripts/check_seed_phase.sh` fails on a creation-class write that never asks
  `LAMaterialFieldSeal3D.note_creation()` and on any whole-mirror upload.
- Verify before presenting: test the exact link, command, build or demo you hand the user, in their setup.

# Validation and runs

- A verification run answers inside `docs/RUN_TIMEOUT_CEILING`; a longer run is a declared soak
  (`# SOAK: <why>`). Never raise the ceiling to make a slow arm pass.
- One sim at a time on this machine (a machine-wide GPU lock). Never `pkill` by program name; kill by your own
  PID or a pattern anchored on your own worktree. Never remove a lock by hand.
- Every gate in `scripts/gates.toml` is `fast` (starts no engine) or `slow` (launches one, reads the capture one
  made, or needs a device), derived from `kind`, `launches` and `capture_reader`; a `fast` gate that launches fails.
  `scripts/agent_harness.sh lint` runs the fast tier and nothing else, which is what the pre-commit hook and a lane
  run; `lint --slow` runs the slow tier; `lint --all` runs both, which is CI's and the nightly's.
- `scripts/integrate.sh` runs the fast tier plus exactly the slow gates its diff reaches
  (`lint --all --affected-by <dev>`): a slow gate is selected when a changed path matches its `inputs`, its script
  or a lib it names, or its row, or when it declares none; it prints each selection and the path, and starts no
  engine for a diff no slow gate reads. A slow row declares `inputs`; the exceptions are
  `docs/SLOW_GATES_WITHOUT_INPUTS`, which only falls (`check_gate_tiers`).
- The fast tier answers inside `docs/LINT_FAST_SECONDS_CEILING` (`check_lint_fast_budget`); a gate that makes it
  slower is made cheaper or becomes a slow row. `check_launch_count` counts the slow tier's launches.
- A gate that overruns fails with `LINT_SLOW: <gate> ran <t>s against <budget>s`: the budget is five times its entry
  in `docs/GATE_SECONDS` (never under 10 s), or 30 s fast and 300 s slow with no entry. The file only falls;
  `scripts/write_ceilings.sh` writes it from a passing lint.
- `lint --only NAME` runs one gate whatever its tier.
- A gate row may declare `inputs` in `scripts/gates.toml`: globs of every file its verdict reads. While those
  bytes, its script and libs, its row and the LA_* environment are unchanged it prints `LINT_CACHED` instead of
  running. Integration and CI read no cache; `--no-cache` runs every gate. Declare `inputs` only for a verdict
  that is a function of file bytes, never for one that reads the index, history, a clock or the launch ledger;
  `check_gate_inputs` and `check_gate_cache` hold the rule.
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

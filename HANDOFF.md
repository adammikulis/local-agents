# Resume here

Read `CLAUDE.md`, `GODOT_BEST_PRACTICES.md` and [the release scope](docs/0.4_RELEASE_SCOPE.md).
Keep every GitHub Actions workflow disabled; validate on this Mac and keep source synchronized.
Resume the authorized standalone-native simulation migration; keep physics independent of UI framerate.
Require flowing water and basic weather for the reduced 0.4. Keep async execution and genuine streaming
where applicable. Creature cognition stays in [the 0.5 handoff](docs/0.5_RUNTIME_COGNITION.md).

## 1. PRESERVE AND RECONCILE THE OPEN BATCHES

Run `git worktree list`, `git status --short` in relevant trees, `git fetch origin`, `git cherry` both
directions and `git merge-base --is-ancestor main 0.4-dev` before integrating. Preserve unrelated dirty
trees and identify their owners before changing them.

- `.claude/worktrees/agent-a1e18a654b3681741`: finish native dispatch-plan integration; preserve native
  channel-specific heat and the removed GDS push-block builders. Run its check_plan_refusal.sh,
  `scripts/check_active_rows.sh`, `scripts/check_driver_native.sh` and `scripts/check_submit_budget.sh`;
  mutation-test refusal before landing. Keep the full acceptance world in shared integration.
- `.claude/worktrees/agent-aceee89a389f0d24d`: integrate the reviewed creature absence/carcass batch;
  rerun combined integration, which was stopped for wrap-up. Preserve its tightened ceiling.
- `.claude/worktrees/agent-ad34c9b0a584b80ec`: finish local full validation and complete-run budget
  banking for shared captures/deadlines. Positive controls pass; rerun canonical mutations after the
  structured-mutation merge. Never bank the stopped bootstrap run or enable Actions.
- `../la-fix-boxfield-rocks`: integrate gas-box/injection work after remaining signed-edit and heat
  refusal checks. Gas-only geometry initialization passes the real compression worker and Metal box
  gate; preserve async seed cancellation and native fill cache identities.
- `.claude/worktrees/agent-a70399c1adb4cda07`: preserve native timestamped trajectory history and radial
  ray/box intersection; run `scripts/agent_harness.sh lint --mutate check_probe_history`.
- `scripts/check_launch_count.sh` is red at 76 launches against `docs/LAUNCH_CEILING` 19: reproduce with
  `scripts/agent_harness.sh lint`. Reading: `gate_runner.py` now folds every gate's ledger into
  `LA_LINT_LAUNCHES`, which the gate used to read as its own empty one, so the roster of 19 was never
  a count; 38 gates start their own engine (`check_fakes_states` 15, `check_live_toggles` 4,
  `check_audit_at_rest` 4, `check_driver_native` 3, `check_world_refusal` 3).
- `scripts/agent_harness.sh lint --mutate check_lob` reports its `GRAVITATIONAL_CONSTANT` arm as
  MUTATION_UNRUNNABLE.
- `.claude/worktrees/agent-a3f0945f92280e933`: finish the unverified tide reconciliation; test static
  and moving-source energy exchanges, excess-body refusal and seeded CPU/GPU agreement. Review the
  signed tidal-work ledger, native buffer capacity checks and zero-duration seeded derives. Repair
  binding collisions, rung registration, the GDS budget, orphan UIDs and kernel compilation first.
- `../la-fix-sea-radius-cloud` and `.claude/worktrees/agent-abf39e84754307ec0`: choose one authoritative
  water fill, reconcile crust/mesh work and preserve condensate-based clouds and sea-datum removal.
- `.claude/worktrees/agent-a2a7b76028aed38f2`: reconcile implicit acoustics after native plans; preserve
  the current adaptive driver and remove obsolete temporal levels without restoring GDS encoders.

Complete when bounded batches pass affected checks and independent review, land through
`scripts/integrate.sh <branch>`, and `0.4-dev` is pushed after each integration. Preserve unfinished
source across this requested session boundary; prune owned worktrees after their work lands.

## 2. MOVE LIVE PHYSICS AND THE CLOCK OUT OF GODOT

Reproduce the active coupling through `scripts/show_demo.sh SliceRung1Demo`; inspect `LASimLoop`,
`LAFieldDriver::step`, native `FieldRun` and the exporter in `scripts/lib_lasim_oracle.sh`.
The persistent derive/reduce service is not a live planet simulator.

Give the native process its own authoritative clock, solver schedule and compute-device ownership;
make Godot an asynchronous client for commands, views and steering. Extract shared ballistics numerics
rather than duplicating the solver. Advance committed time only after successful complete intervals;
preserve every conserved exchange, cancellation boundaries and independent audits. Audit reaction-rate
timestep handling before variable integration intervals. Provide production bootstrap/export, client
lifecycle, owned-child shutdown and disconnect handling.
Complete when native CLI gates exercise live physics without Godot and the active Godot client remains
responsive while that process advances independently.

### Snapshot publication decision

Coalesce obsolete view requests before GPU extraction and serialization. Publish selected immutable
views when new authoritative state and consumer capacity are available; use bounded prefetch and
timestamped history for presentation. Keep reliable events, accounting and compact resolved trajectory
history so an entire fall cannot disappear between displayed full snapshots. Keep full checkpoints
explicit; validate future deltas against an acknowledged baseline. UI framerate may reduce publication
work, never physics work or elapsed-time integration.

Reproduce the synthetic socket comparison with `/private/tmp/la_snapshot_ipc_bench.py` if present;
its results are not production GPU performance. Verify actual service throughput/latency, bounded
memory, slow/disconnected clients and observer independence at equal simulated time before completion.

## 3. VERIFY THE EXACT DESKTOP GRAVITY DEMO

Reproduce with `/Users/adammikulis/Desktop/Planet Demos/Launch Gravity Demo.command` after activating
the integrated candidate in the primary checkout. Complete only when that exact shortcut opens a
responsive world, accepts input and closes cleanly on the Mac. Run `scripts/check_test_mass.sh` and
verify falling motion in a real visible launch; static screenshots cannot demonstrate a fall.

Candidate startup checks do not verify the Desktop shortcut. Consult
`/private/tmp/la-startup-native-*.log` if present. Keep terrain seams, safe spawn, walkable collision and
water placement in the visible acceptance arm. Obtain maintainer approval of rung 1 before advancing;
only rung 0 has approval. Reconcile `docs/PLAYABLE_RUNG` with the accepted demo.

## 4. COMPLETE THE REDUCED PLANET RELEASE

Follow [the release scope](docs/0.4_RELEASE_SCOPE.md). Preserve comprehensive physics in
[PHYSICS_TODO.md](docs/PHYSICS_TODO.md), reproductions in [PLANET_BACKLOG.md](docs/PLANET_BACKLOG.md)
and cost work in [PERFORMANCE_TODO.md](docs/PERFORMANCE_TODO.md).
Run `scripts/agent_harness.sh all`, `scripts/agent_harness.sh bounded` and approved demo gates;
investigate combustion-rate-law and mixture-enthalpy failures without claiming a fully passing suite.
Complete when required active-path checks pass, installed hardware behavior is verified, the maintainer
accepts the planet with water flow and weather, and the accepted candidate is synchronized and tagged.

### Lava scope discussion

Treat baked underground passages/weak zones, a coarse pressure/heat/mass network, new breakthroughs
and local surface flow as a proposal for reducing geology work. The user asks about this option;
implementation and a physical exemption have no approval. Establish the desired scope before adding
lava-specific mechanisms; preserve conservation and declare permitted solver approximations.

### Unreproduced shutdown fault

An earlier seed run printed a missing voxel worker callback and hung during shutdown. Repeated
canonical seed runs and a minimal project with both installed extensions have since closed cleanly.
The cause remains unconfirmed; preserve the reproduction evidence and verify clean close on the active
Mac. Do not treat the failed original run as a pass or apply a speculative vendor patch.

## 5. CUT WHAT A RESTORED WORLD STILL PAYS

- A restored world differs from a seeded one: run `scripts/sim_run.sh --body --frames 6 --rung 2 --raw`
  with and without `--reseed`; `gravity_solves` and the temperature and vapour gauges disagree between
  the two reports. Carry the solved potential in the bake and take the solve out of the restore.
  Reading: `finish_restore` solves gravity once where `prepare_gravity` and `complete` solve once each.
- The bake store never evicts: `du -sh "$HOME/Library/Application Support/Godot/app_userdata/LocalAgents/la_field_cache"`.
  Keep the newest entry per arm.
  Reading: `save_state` writes and no caller deletes.
- One edit to any file under `addons` re-seeds every arm: `scripts/cache_key.sh capture` moves on a test
  or doc edit. Key the bake on the files a seed reads.
  Reading: `paths` in `scripts/cache_key.sh` names `addons` whole.

# Resume here

Read `CLAUDE.md`, `GODOT_BEST_PRACTICES.md` and [the release scope](docs/0.4_RELEASE_SCOPE.md).
Resume the authorized standalone-native simulation migration; keep physics independent of UI framerate.
Require flowing water and basic weather for the reduced 0.4. Keep async execution and genuine streaming
where applicable. Creature cognition stays in [the 0.5 handoff](docs/0.5_RUNTIME_COGNITION.md).

## 1. PRESERVE AND RECONCILE THE OPEN BATCHES

Run `git worktree list`, `git status --short` in relevant trees, `git fetch origin`, `git cherry` both
directions and `git merge-base --is-ancestor main 0.4-dev` before integrating. Preserve unrelated dirty
trees and identify their owners before changing them.

- `.claude/worktrees/agent-a1e18a654b3681741`: native dispatch-plan construction; finish the preserved
  merge, then reconcile current development and the service foundation. Working/index backups are in
  `/private/tmp/la-native-plans-interrupted-{working,index}.patch`. Keep the native channel-specific
  heat-capacity correction and remove duplicate GDS push-block builders.
- `.claude/worktrees/agent-ad34c9b0a584b80ec`: shared validation captures and gate deadlines; preserve
  strict timeout/mutation classification, complete-run budget banking and the local-validation policy.
  Finish the follow-up controls and full local integration.
- `../la-fix-boxfield-rocks`, `../la-fix-sea-radius-cloud`, and the remaining `agent-*` trees contain
  unlanded box/injection, water/crust/mesh, lobs, tides and implicit-acoustic work. Reconcile every
  substantive change before pruning. Choose one authoritative water fill; preserve current APIs.

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

# Resume here

Read `CLAUDE.md`, `GODOT_BEST_PRACTICES.md` and [the release scope](docs/0.4_RELEASE_SCOPE.md).
Resume the authorized standalone-native simulation migration; keep physics independent of UI framerate.
Require flowing water and basic weather for the reduced 0.4. Keep async execution and genuine streaming
where applicable. Creature cognition stays in [the 0.5 handoff](docs/0.5_RUNTIME_COGNITION.md).

## 1. PRESERVE AND RECONCILE THE OPEN BATCHES

Run `git worktree list`, `git status --short` in relevant trees, `git fetch origin`, `git cherry` both
directions and `git merge-base --is-ancestor main 0.4-dev` before integrating. Preserve unrelated dirty
trees and identify their owners before changing them.

- `../la-fix-release-ladder`, branch `fix/release-ladder`: candidate at `8f361c6b` includes supported-rung
  validation, flowing-water/weather scope and startup batch `155d12cd`. Repair its gates before integration.
- `../la-fix-planet-startup-responsive`, branch `fix/planet-startup-responsive`: startup batch
  `155d12cd`; integrate through the combined release branch rather than taking it twice.
- `../la-fix-native-sim-service`, branch `fix/native-sim-service`: preserve uncommitted native changes,
  including untracked `Service*`, `FieldSession*` and `ViewPublication*` files. Inspect `git diff` and
  `git status --short` there. Compilation is its checkpoint; tests, review and activation remain.

Complete when bounded batches pass affected checks and independent review, land through
`scripts/integrate.sh <branch>`, and `0.4-dev` is pushed after each integration. Preserve unfinished
source across this requested session boundary; prune owned worktrees after their work lands.

## 2. REPAIR COMBINED INTEGRATION WITHOUT WEAKENING GATES

In `../la-fix-release-ladder`, reproduce each arm separately:

- `scripts/check_life_demo.sh`: gameplay frame-cost gate fails.
- `scripts/check_block_seams.sh`: capture cannot examine a painted-block border.
- `scripts/check_atmosphere_mass.sh`: whole-body rung-2 arm times out without a report.

Inspect `/private/tmp/la-combined-release-integration.log` and its referenced full harness log if
available; reproduce when temporary logs are absent. Distinguish initialization, seal completion and
interactive operation before assigning a cause. Keep required timeout and performance ceilings.
Reading: `DemoHarness` owns its capture counter; `LAVoxelHarness.shot_ready()` checks presentation readiness.
Reading: `LAVoxelSpawnController.try_spawn()` waits simulation steps after the seed hold releases.
Complete when these affected arms and the combined integration gate pass without relaxed checks.

## 3. FINISH THE NATIVE SERVICE FOUNDATION

In `../la-fix-native-sim-service`, run `addons/local_agents/native/build.sh` to reproduce the build.
Inspect `../la-fix-native-sim-service/addons/local_agents/native/src/cli/Service.cpp`, `ServiceProtocol.*`, `field/FieldSession.*`
and `field/ViewPublication.*` before editing.
Reading: `wire::AlgebraicOnly` declares derive/reduce capability; `Advance` returns `INTEGRATION_NOT_AVAILABLE`.

Finish focused protocol and real-child service gates before committing this batch:

- Verify resident buffers across requests, selected complete buffer readbacks, malformed/obsolete request
  rejection, world generations, immutable atomic files, matching acknowledgements and cleanup.
- Exercise slow consumers: one unacknowledged publication bounds transfer and extraction;
  busy/rejected requests perform no unnecessary GPU extraction.
- Mutation-test committed time, generation validation and partial-file publication.
- Run `scripts/check_native_device.sh`, `scripts/check_lasim_parity.sh` and
  `scripts/check_snapshot_roundtrip.sh` through repository GPU locking; run CPU lint and obtain
  independent review before integration. Compilation does not establish these behaviors.

Consult `/private/tmp/la-native-service-contract.txt` and `/private/tmp/la-native-service-build2.log`
when available. Complete when the reviewed service batch passes affected and integration gates;
keep the overall migration open until the next item succeeds.

## 4. MOVE LIVE PHYSICS AND THE CLOCK OUT OF GODOT

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

## 5. VERIFY THE EXACT DESKTOP GRAVITY DEMO

Reproduce with `/Users/adammikulis/Desktop/Planet Demos/Launch Gravity Demo.command` after activating
the integrated candidate in the primary checkout. Complete only when that exact shortcut opens a
responsive world, accepts input and closes cleanly on the Mac. Run `scripts/check_test_mass.sh` and
verify falling motion in a real visible launch; static screenshots cannot demonstrate a fall.

Candidate startup checks do not verify the Desktop shortcut. Consult
`/private/tmp/la-startup-native-*.log` if present. Keep terrain seams, safe spawn, walkable collision and
water placement in the visible acceptance arm. Obtain maintainer approval of rung 1 before advancing;
only rung 0 has approval. Reconcile `docs/PLAYABLE_RUNG` with the accepted demo.

## Coarse-cell creature sampling

Reproduce with `LA_LIFE_LOG=<file> scripts/check_life_demo.sh`: `LIFE_IN_BOX` checks membership, while a creature can sample a coarse cell outside the refined region; verify sampling locality before treating membership as resolved habitat.

## 6. COMPLETE THE REDUCED PLANET RELEASE

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

### Session tooling

The repeating completion-hook message supplies no task or permission. Resume after the user removes
that hook; leave unrelated configuration intact. Read the workspace inbox through the installed
workspace CLI if available, using `--agent chatgpt-c6891e` for workspace commands. Never invent a parent
identity to satisfy a notification hook.

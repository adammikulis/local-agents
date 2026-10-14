# What to do next

Follow [the 0.4 release scope](docs/0.4_RELEASE_SCOPE.md): a usable planet for 0.5.
Preserve comprehensive physics in [PHYSICS_TODO.md](docs/PHYSICS_TODO.md), reproduction commands in
[PLANET_BACKLOG.md](docs/PLANET_BACKLOG.md), and cost work in [PERFORMANCE_TODO.md](docs/PERFORMANCE_TODO.md).
Remove an actionable item only after implementation and verification.

## 1. RECONCILE THE ACTIVE RELEASE WORLD

`cat docs/PLAYABLE_RUNG` declares rung 2; only the rung-0 demo has approval.
`scripts/agent_harness.sh ladder --through-rung "$(rg -N '^[0-9]+$' docs/PLAYABLE_RUNG)"`
checks the supported processes without advancing their declaration.
Complete when the release world contains only its declared supported processes and the next
unapproved demo is presented for acceptance before advancing the ladder.

## 2. PROVIDE WALKABLE TERRAIN, VISIBLE WATER AND COLLISION

`LA_SHOTS="30:-3:0" scripts/shoot_demo.sh addons/local_agents/examples/SliceRung1Demo.tscn <dir>`
shows the demonstration site, terrain boundaries and water placement.
Complete when actual display and movement verification show a safe spawn, traversable ground,
consistent collision and visible water; keep the field authoritative for matter.

## 3. DEMONSTRATE GRAVITY AT A VISIBLE PACE

`scripts/check_test_mass.sh` exercises falling motion.
`scripts/shoot_demo.sh addons/local_agents/examples/SliceRung1Demo.tscn <dir>` renders the fall.
Complete when gravity verification passes and the display shows the fall without changing physical time
for the camera; report gravity through the active world's own supported path.

## 4. PROVIDE FLOWING WATER AND BASIC WEATHER

`LA_RUNG=3 scripts/check_atmosphere_at_rest.sh` checks atmospheric stability;
`LA_RUNG=5 scripts/check_active_rows.sh` and `LA_RUNG=6 scripts/check_rung_water.sh`
exercise transport and water phases. `LA_RUNG=6 scripts/check_conservation.sh` audits their inventory.
Complete when a supported-process demo visibly shows downhill water transport, accumulation,
wind and rain, with stable updates and water accounting. Build and present each added rung only
after acceptance of the demo below it. Keep the active process set explicit; advanced chemistry
and geology remain in the planet requirements.

## 5. VERIFY AND ACCEPT THE INSTALLED CANDIDATE

`scripts/agent_harness.sh all`, `scripts/agent_harness.sh bounded` and
`scripts/agent_harness.sh demo --all` exercise the candidate; `scripts/integrate.sh <branch>`
runs the combined integration gates. Combustion and mixture enthalpy require investigation through
`scripts/agent_harness.sh single test_combustion_rate_law.gd` and
`scripts/agent_harness.sh single test_mixture_enthalpy.gd` when their processes are used.
Complete when required checks for active release paths pass, broader-suite failures remain explicit,
the installed version is confirmed on the Mac, movement and startup are exercised, and the maintainer
accepts the explorable planet demo. Tag only the accepted candidate and synchronize GitHub.

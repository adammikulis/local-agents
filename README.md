# Local Agents (Godot)

Current project focus is a deterministic 3D simulation vertical slice with ecology, mammals, and inspectable chemical smell fields.

## Current Scope

- `PlantRabbitField` scene as the active sandbox.
- Edible plants as small thin green capsules with staged growth and flowering.
- Rabbits as white spheres that forage, flee, eat plants, digest seeds, and reseed via poop.
- Mammal smell behavior generalized via profile resources (rabbits and villagers share the same contract, with different sensitivities).
- Smell and wind simulated on a shared sparse voxel field (clean break from active hex runtime path).
- Click selection + inspector panel + spawn UI (targeted spawn and random spawn).
- Camera controls for simulation editing (orbit/pan/zoom + right-click pan).
- Debug overlays for smell, wind, and temperature with translucent voxel rendering.

## Core Runtime Model

### Shared Voxel Infrastructure

- `addons/local_agents/simulation/VoxelGridSystem.gd`
- Used by:
  - `SmellFieldSystem`
  - `WindFieldSystem`
  - `EcologyController` edible indexing/debug views

### Chemistry-Driven Smell

Plants and mammals emit chemical mixtures, not generic `food`/`danger` tags.

Examples currently modeled:
- Plant/flower compounds: `hexanal`, `cis_3_hexenol`, `linalool`, `benzyl_acetate`, `phenylacetaldehyde`, `geraniol`, `methyl_salicylate`.
- Taste/defense compounds: `sugars`, `tannins`, `alkaloids`.
- Mammal/waste compounds: `ammonia`, `butyric_acid`, `2_heptanone`.

Mammals convert these into behavior using weighted sensitivity profiles (`MammalProfileResource`).

### Wind and Decay

- Smell advects with wind direction/intensity when enabled.
- Smell decays over time.
- Rain increases decay.
- Wind field evolves spatially from base wind + terrain/temperature effects.

## Field Controls

Inside `PlantRabbitField`:

- `LMB`: select actor / place spawn (when spawn mode active)
- `Esc` or `RMB`: cancel spawn mode back to select
- Spawn mode auto-resets to select after placing one entity
- Mouse wheel: zoom
- `MMB drag`: orbit
- `Shift + MMB drag`: pan
- `RMB drag`: pan

Bottom HUD supports:
- `Select`
- `Spawn Plant`
- `Spawn Rabbit`
- `Spawn Random` with user-set counts

Right HUD shows inspector payload for selected entities.

## Debug Views

Debug overlay roots:
- `SmellDebug`
- `WindDebug`
- `TemperatureDebug`

Rendering style:
- Smell: translucent chemical voxel overlays.
- Temperature: translucent blue-to-red voxel spectrum.
- Wind: translucent directional vector markers.

## Key Scenes and Scripts

- Scene: `addons/local_agents/scenes/simulation/PlantRabbitField.tscn`
- Controller: `addons/local_agents/scenes/simulation/controllers/PlantRabbitField.gd`
- Ecology orchestration: `addons/local_agents/scenes/simulation/controllers/EcologyController.gd`
- Plant actor: `addons/local_agents/scenes/simulation/actors/EdiblePlantCapsule.gd`
- Rabbit actor: `addons/local_agents/scenes/simulation/actors/RabbitSphere.gd`
- Villager actor: `addons/local_agents/scenes/simulation/actors/VillagerCapsule.gd`

## Run

```bash
godot --path . --editor
```

Project is configured to launch `PlantRabbitField` as main scene.

Headless smoke boot:

```bash
godot --headless --no-window --path . addons/local_agents/scenes/simulation/PlantRabbitField.tscn --quit
```

## Tests

Core harness:

```bash
godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd --skip-heavy
```

Targeted deterministic checks include:
- `addons/local_agents/tests/test_smell_field_system.gd`
- `addons/local_agents/tests/test_wind_field_system.gd`

## Notes

- Runtime is intentionally scene-first and resource-driven.
- Required systems should fail fast rather than silently fallback.
- `ARCHITECTURE_PLAN.md` tracks breaking changes and migration status.

# Local Agents — Usage

`local-agents` is two things in one Godot addon:

1. A **reusable local-agent library** — `LocalAgent` nodes driven by a local LLM (offline), a memory graph, and
   a decoupled creature-behaviour stack (fast/slow brain) you can drop into any project.
2. The **Anima game** — an emergent voxel-planet ecosystem simulation built on top of that library.

This document covers how to consume the library, the two adapter contracts the behaviour stack talks through,
the creature injection quartet, adding a species by JSON, and three copy-paste quickstarts.

---

## Agent library vs. the Anima game (the boundary)

The addon is **one addon, but the game is deletable.** The core library never references the game, so you can
copy `addons/local_agents/`, delete the game, and keep a fully-working local-agent toolkit.

**CORE library dirs** (the reusable toolkit — never reference the game):

| dir | what |
| --- | --- |
| `agents/` | `LocalAgent`, `LocalAgent3D` — the LLM-driven agent nodes |
| `agent_manager/` | `AgentManager` autoload (agent registry / lifecycle) |
| `graph/` | `LocalAgentGraph` — a nodes/edges memory resource |
| `runtime/` | GDExtension loader + runtime glue |
| `api/`, `configuration/`, `models/` | LLM client API, config, model management |
| `editor/` | the in-editor Local Agents panel |
| `gdextensions/` | the compiled native runtime |

**GAME dirs** (the optional Anima game — safe to delete):
`scenes/`, `scenes/simulation/`, `audio/`, `voices/`, `assets/`, and the game-only controllers/UI under them.

**Autoloads (`project.godot`).** Only **`AgentManager`** is core. **`GameMode`** and **`AppExit`** are game-only
(they live under `scenes/`). A consumer copying just the library into their own project should register **only
`AgentManager`** and must **not** add `GameMode`/`AppExit`.

**Consumer quickstart (library only):**

1. Copy `addons/local_agents/` into your project's `addons/`.
2. (Optional) delete `addons/local_agents/scenes/` and everything game-specific under `simulation/` — the core
   plugin degrades gracefully: it registers the agent nodes and never top-level-`preload`s a game script, so a
   missing game tree is a clean skip, not a parse error.
3. Enable the **Local Agents** plugin (Project → Project Settings → Plugins). Register only the `AgentManager`
   autoload.
4. Drop a **LocalAgent** node into a scene and talk to it (quickstart 1 below).

> The editor plugin registers `LocalAgent`, `LocalAgent3D`, `LocalAgentGraph` unconditionally, and registers the
> game nodes (`Creature`, `Sim World`) only when their scripts are present (presence-guarded `load()`), so the
> Add-Node menu stays clean whether or not the game tree is installed.

---

## The two adapter contracts (duck-typed surfaces)

The creature behaviour stack is decoupled from the world through two **duck-typed** interfaces. To support a new
kind of cognizer or a new terrain, you *provide the methods* — you never patch the actor.

### 1. Cognizer contract (`LACognizerAdapter`)

`LACognition` (the per-creature brain) talks to whatever is cognizing **only** through `LACognizerAdapter` — it
never names a `Creature` field directly. Any actor that exposes this read-only surface reuses the brain unchanged:

- **drives:** `energy`/`max_energy`, `hydration`/`max_hydration`, `health`/`max_health`
- **body:** `global_position`; `breath_capacity` + `_breath`; `_panic_timer`; `_material` (temp probe)
- **control:** `llm_enabled` (slow-brain opt-out)
- **social:** `species`, `family_id`; the neighbour scan + each neighbour's `get_cognition()`

### 2. Terrain contract (duck-typed; `LAFlatGroundTerrain` and `LAVoxelTerrainService`)

A creature talks to its terrain only through this surface, so it can stand on a flat floor **or** a voxel planet
with the same code. The full method surface (both adapters implement it identically in shape):

```
up_at(pos) -> Vector3            # local "up" at a world point
planet_center() -> Vector3       # centre all radial math is measured from
sea_radius() -> float            # world radius of the sea shell (<=0 / -INF ⇒ no sea)
surface_point(dir) -> Vector3    # world point where centre→dir meets the ground (NAN-vec if none)
surface_radius(dir) -> float     # distance centre→that surface point (NAN if none)
ground_point(pos) -> Vector3     # the ground point directly below a world point
altitude_at(pos) -> float        # height above local ground (>0 air, <0 underground)
is_planet() -> bool              # radial-up planet (false for flat)
is_ready_at(pos) -> bool         # is the ground under pos queryable
raycast_terrain(from,dir,max) -> Dictionary   # {hit, position, normal}
carve_sphere(pos, r) -> void     # destructive edit (no-op on flat ground)
```

- `LAFlatGroundTerrain` — a plane at `y = ground_y` (+Y up). The standalone/library terrain.
- `LAVoxelTerrainService` — the cubed-sphere planet (owned by `LAPlanetBody`).

`Creature.setup()` **defaults** `terrain` to a fresh `LAFlatGroundTerrain` when none is injected, so a bare
creature never null-derefs its movement path.

---

## The injection quartet (wiring a Creature)

A `Creature` (class `LACreature`) has **one** hard dependency (terrain) and **three optional** injectors. All
three optional wires are `has_method`-guarded, so a creature runs fine with none of them (pure fast brain):

| call | injects | absent ⇒ |
| --- | --- | --- |
| `setup(terrain, config, genome=null)` | terrain (required) + species config | terrain defaults to `LAFlatGroundTerrain` |
| `set_material_field(field)` | the shared `LAMaterialField3D` substrate (heat/water/scent) | no field reads (comfort/scent/drink neutral) |
| `set_ecology(service)` | the `LAEcologyService` (broadcasts, births, calls) | no ecology broadcasts |
| `set_cognition_scheduler(sched)` | the shared slow-brain (`LACognitionScheduler`) | fast/reinforced brain only, no LLM escalation |

**Standalone shortcut.** `Creature.setup_standalone(config_source, opts={})` gives a library user a one-call
drop-in: it supplies an `LAFlatGroundTerrain` and leaves all three optional injectors unset (that absence *is*
the pure-fast-brain default). `config_source` may be a Dictionary, a `.json` path, a species id (`"rabbit"`), or
`""` (a generic walker). `opts` may carry `{ground_y, cognition_scheduler}`. The `Creature.tscn` prefab
self-configures on drop-in when its `standalone_on_ready` export is set.

---

## Add a species via JSON

Species stats live in `addons/local_agents/scenes/simulation/voxel/data/species/<class>/<kind>.json` (clustered by
taxonomic folder: `mammals/`, `birds/`, `insects/`, `people/`, `aquatic/`, `plants/`). Drop a new file in and it
loads automatically — the taxonomic class is inferred from the folder. Example `mammals/otter.json`:

```json
{
  "species": "otter", "diet": "carnivore", "speed": 4.2, "size": 0.5,
  "color": [0.35, 0.25, 0.18], "sense_radius": 10.0,
  "preys_on": ["fish"], "flees_from": ["fox"], "herd": false,
  "max_energy": 90.0, "metabolism": 2.0, "max_age": 120.0
}
```

JSON can't hold Godot types, so the loader (`LASpeciesLibrary`) converts on read: `"color": [r,g,b(,a)]` → `Color`,
and `"preys_on"`/`"flees_from"` string arrays → `PackedStringArray`. Load a config with
`LASpeciesLibrary.load_config("otter")`, or a config from an explicit path with `LASpeciesLibrary.load_path(path)`.
`setup_standalone("otter")` resolves the id for you.

---

## Quickstarts

### 1. Drop a `LocalAgent` (chat with a local LLM)

```gdscript
extends Node

func _ready() -> void:
    var agent := LocalAgent.new()      # or add a LocalAgent node in the editor
    add_child(agent)
    agent.think_completed.connect(func(result): print(result))
    agent.think_async("Say hello in one short sentence.")
```

`think_async` runs off the render thread and delivers on `think_completed`. (With no local model installed the
agent runs its offline/teacher fallback.) See `examples/AgentQuickstart.tscn` for a full UI.

### 2. A thinking `Creature` on flat ground (no planet)

```gdscript
extends Node3D

const CreatureScene := preload("res://addons/local_agents/scenes/simulation/voxel/actors/Creature.tscn")

func _ready() -> void:
    var creature := CreatureScene.instantiate()
    creature.standalone_on_ready = false
    add_child(creature)
    creature.global_position = Vector3(0, 2, 0)
    creature.setup_standalone("rabbit")   # flat-ground terrain + pure fast brain
```

Add a `StaticBody3D` floor + a `Camera3D` and the rabbit senses, idles, and wanders on the plane with no
`MaterialField` at all. Runnable demo: `scenes/simulation/voxel/examples/ThinkingCreatureDemo.tscn`.

### 3. A whole planet from one `Sim World` node

```gdscript
extends Node3D

const SimWorldScript := preload("res://addons/local_agents/scenes/simulation/voxel/world/SimWorld.gd")

func _ready() -> void:
    var sim := SimWorldScript.new()
    sim.world_type = LASimWorld.WorldType.SPHERE   # or FLAT
    sim.radius = 180.0
    add_child(sim)                                  # builds planet + field + ecology + spawns life
    # add your own Camera3D framing sim.planet_body().center()
```

`LASimWorld` composes the planet body, the `MaterialField`, the ecology, and the spawn behind one node — no game
shell (HUD/menus/disasters/save). Its export surface:

| export | mode | meaning |
| --- | --- | --- |
| `world_type` | both | `SPHERE` (planet) or `FLAT` (box world) |
| `radius`, `ocean_bias`, `grid_res`, `grid_depth`, `caves_enabled`, `tides_enabled` | SPHERE | planet bounds + toggles |
| `flat_extent`, `flat_cell_size`, `ground_y` | FLAT | box extent + field cell size + floor height |
| `auto_spawn`, `initial_counts`, `forest_clusters`, `build_on_ready` | both | population + build control |

Runnable demo: `scenes/simulation/voxel/examples/SimWorldPlanetDemo.tscn`.

---

## Demos

All demos are listed in `examples/DemoLauncher.tscn` (reachable from the main menu's **Examples** button):
quickstart chat, agent-drives-actions, two agents converse, chat UI, 3D agent, graph memory, plus the three
library showcases above and the flagship voxel planet. Each also self-harnesses headless:
`scripts/run_sim_offscreen.sh --path . <demo.tscn> -- --run-frames=120`.

# API: simulation nodes

Part of the [API reference](API.md).

## Simulation nodes

### LocalAgentCreature

`addons/local_agents/creatures/Creature.gd`, extends `CharacterBody3D`, `@tool`.

One flexible creature driven by a species config. Behaviour is emergent from local rules: flee larger hunters, hunt prey, scavenge
carrion, eat plants, panic at felt or heard events, flock with same-kind neighbours, and live or die on an energy budget. `@tool` is
here only so the inspector can show configuration warnings: `_ready`, `_process` and `_physics_process` are the script's only engine
callbacks and each returns immediately in the editor, so an editor-placed creature stays inert.

Instance `addons/local_agents/creatures/Creature.tscn` rather than attaching the script. That scene stores `standalone_on_ready =
true`, so a creature dragged into a scene configures itself.

#### Exports, group Standalone
- `standalone_on_ready` (bool, default `false` on the script, `true` in the scene). Configure this creature from its species file
  during `_ready()`, with a flat-ground terrain at Ground Y. Turn it off when a world will call `setup()` for it instead.
- `standalone_species` (String, default `""`). A species id such as `rabbit`, `fox` or `bird`, backed by
  `addons/local_agents/creatures/species/**/<id>.json`. A `res://` path ending in `.json` also works. Blank uses the built-in
  generic walker. It is a plain String because `@export_enum` cannot offer an empty option, so the editor plugin supplies a
  dropdown instead.
- `ground_y` (float, default `0.0`, range -1000.0 to 1000.0, suffix m). World Y of the flat ground plane when running standalone.

#### Exports, group Cognition
- `llm_enabled` (bool, default `true`). Let this creature escalate novel situations to the language model. It needs a scheduler
  injected before it can do anything, and with no scheduler this costs nothing, because escalations resolve on the heuristic
  teacher.

#### Setup
```gdscript
func setup(_terrain, _config: Dictionary, _genome_arg = null) -> void
func setup_standalone(config_source = {}, opts: Dictionary = {}) -> void
func set_cognition_scheduler(s) -> void
func set_ecology(e) -> void
func set_material_field(w) -> void
```

`setup()` is the world path: it expresses the species config onto this individual, builds the body, and constructs the per-creature
modules. `setup_standalone()` is the library drop-in path: a flat floor and none of the sim's optional services, so a pure
fast-brain animal you can put in any scene. Its `config_source` may be a Dictionary, a `.json` path, a species id, or `""` for the
generic walker, and `opts` may carry `ground_y` and `cognition_scheduler`.

#### Stimuli and damage
```gdscript
func add_fear(source_pos: Vector3, intensity: float) -> void
func hear_call(source_pos: Vector3, from_species: String, call_type: String, caller) -> void
func take_damage(amount: float, cause: String = "", impulse: Vector3 = Vector3.ZERO) -> void
func on_struck() -> void
func die(cause: String = "", impulse: Vector3 = Vector3.ZERO) -> void
func fling(impulse: Vector3) -> void
func apply_field_force(force: Vector3, delta: float) -> void
```

`add_fear()` ignores a non-positive intensity, otherwise clamps the panic duration to between 0.6 and 7.0 seconds and forces a
decision on the next frame. `take_damage()` subtracts from `health`, deposits blood scent into the material field when one is
attached, calls `die()` at zero, and otherwise flings the body when the impulse is longer than 3.0. `die()` does not delete the node
or spawn a corpse: the creature becomes a carcass in place, falls, and rots.

`fling()` shoves a living creature with a physics impulse, so the shadow takes over, it tumbles, then it stands back up. It is
decoupled from dying. `apply_field_force()` applies a continuous force in world units per second over `delta`, which is the wind and
momentum advection path, and is inert while the creature is held, ragdolling or a carcass.

#### Carrying and querying
```gdscript
func hold_begin() -> void
func hold_end() -> void
func throw(velocity: Vector3) -> void
func is_held() -> bool
func is_hunter() -> bool
func is_mature() -> bool
func debug_heading() -> Vector3
func refresh_state_tint() -> void
static func set_behavior_highlight(category: String, col: Color, on: bool) -> void
func get_cognition()
func get_genome()
func get_family_id() -> int
func get_inspector_payload() -> Dictionary
func feed(amount: float) -> float
func food_profile() -> Dictionary
func nutrition() -> float
```

`is_held()` is true while held or ragdolling. `is_hunter()` is true for a carnivore, or for an omnivore with a non-empty `preys_on`.
`debug_heading()` returns the current steering heading, or `Vector3.ZERO` while held, ragdolling or a carcass. `feed()`,
`food_profile()` and `nutrition()` are the carcass food contract, only meaningful once dead, and `feed()` returns the energy
actually removed. `get_cognition()` and `get_genome()` have no declared return type.

#### Runtime state worth reading
These are plain variables, not exports, written by `setup()` from the species config: `species` (String, `"creature"`), `diet`
(String, `"herbivore"`), `speed` (float, `3.0`), `size` (float, `0.5`), `preys_on` (PackedStringArray), `energy` and `max_energy`
(float, `100.0`), `health` and `max_health` (float, `100.0`), `hydration` and `max_hydration` (float, `100.0`), `age` (float,
`0.0`), `max_age` (float, `90.0`), `metabolism` (float, `2.2`), `thirst_rate` (float, `1.0`), `breath_capacity` (float, `6.0`),
`breathes` (String, `"air"`, meaning lungs, against `"water"` for gills), `family_id` (int, `0`).

#### Configuration warnings
Delegated to `addons/local_agents/creatures/creature/CreatureWarnings.gd`:

- Standalone Species names an id with no species file, listing the known ids and where to add one.
- Standalone Species names a `.json` path that does not exist.
- Standalone Species is set but Standalone On Ready is off, so it will be ignored.

### LocalAgentCreatureSpawner

`addons/local_agents/creatures/CreatureSpawner.gd`, extends `Node3D`, `@tool`.

Type how many of each species you want, press play, and you get a population of standalone creatures scattered around this node,
optionally standing on a floor it builds for you. The creatures it makes are standalone ones: a flat-ground terrain at `ground_y`,
no material field, no ecology, no planet. Assign `cognition_scheduler` and turn on `llm_enabled` to also let them escalate to a
language model. `_ready()` returns immediately in the editor, so a spawner in an open scene never populates it.

#### Exports, group Population
- `counts` (Dictionary[String, int], default `{"rabbit": 5}`). Species id to how many, using the file names under
  `addons/local_agents/creatures/species/**/<id>.json`. A blank id is not valid. Assigning from code works directly, but
  `set("counts", {...})` with an untyped literal is silently dropped, so pass a typed local if you go through `set()`.

#### Exports, group Placement
- `area_extent` (Vector3, default `Vector3(16.0, 0.0, 16.0)`). Full width, height and depth in metres of the box creatures scatter
  inside, centred on this node. Creatures snap to the ground either way.
- `ground_y` (float, default `0.0`, range -1000.0 to 1000.0, suffix m). World Y of the ground plane, and where the convenience floor
  is built.
- `spawn_on_ready` (bool, default `true`).
- `placement_seed` (int, default `0`, range 0 to 65535 or greater). The same seed lays the scene out identically every run. Species
  are sorted before scattering, so the layout does not depend on the order you typed the rows.

#### Exports, group Convenience
- `build_floor` (bool, default `true`). Build a visible, collidable square floor at Ground Y, so a spawner alone is a runnable
  scene.
- `floor_size` (float, default `80.0`, range 1.0 to 500.0, suffix m).
- `floor_color` (Color, default `Color(0.32, 0.45, 0.28)`).

#### Exports, group Cognition
- `cognition_scheduler` (LocalAgentCognitionScheduler, default `null`).
- `llm_enabled` (bool, default `false`). Passed to each spawned creature, which keeps it unless its species file overrides it.

#### Methods
```gdscript
func spawn() -> void
func spawned() -> Array[Node]
func clear() -> void
```

`spawn()` calls `clear()` first, so calling it twice replaces the population rather than stacking a second one on top. `spawned()`
returns the creatures this spawner made that are still alive, since a starved or eaten one frees itself. `clear()` removes every
creature this spawner made and leaves the convenience floor in place.

#### Configuration warnings
- Counts is empty.
- A Counts key is blank.
- A Counts key names an unknown species, reusing the creature's own species validation.
- A Counts value is 0 or less.
- Area Extent has a negative component, or is flat in both X and Z so everything spawns on one spot.
- Llm Enabled is on with no scheduler assigned here.
- A scheduler is assigned but Llm Enabled is off.

### LocalAgentCognitionScheduler

`addons/local_agents/creatures/cognition/CognitionScheduler.gd`, extends `Node`.

The shared slow brain throttle. Every creature escalates rare or uncertain situations here, and this one node decides for the whole
world whether there is budget to resolve another deliberation right now, resolves it off the physics frame, and writes a training
trace. Two backends resolve an escalation: the shared `LocalAgentLlmClient` runs a function-calling request off the frame and hands
back the chosen tool call, and the heuristic teacher is a synchronous rule-of-thumb whose callback is deferred, so it too never
blocks. The teacher is the offline path and also the source of training traces when no model is loaded.

Drop it into a scene next to a `LocalAgentLlmService`, pick that service in `llm_service`, and every creature in `adopt_group` is
wired to it on ready, including creatures spawned later. That is the whole hookup.

#### Exports, group Model
- `llm_service` (LocalAgentLlmService, default `null`). Leave it empty, or leave the service disabled, and every escalation resolves
  with the heuristic teacher.
- `enabled` (bool, default `true`). Off sends every escalation straight to the teacher, which is the cheapest way to A/B the model
  against the rules of thumb.

#### Exports, group Budget
- `max_in_flight` (int, default `2`, range 1 to 16). Concurrent resolutions across the whole world.
- `max_requests_per_second` (float, default `4.0`, range 0.1 to 60.0, suffix /s). Escalations over the ceiling are dropped, and
  those creatures keep the action their fast brain already picked.
- `highlight_linger_ms` (int, default `1200`, range 0 to 10000, suffix ms). How long the thinking or queued highlight stays on a
  creature after its consult resolves. Display only.

#### Exports, group Training traces
- `write_traces` (bool, default `true`). Append one JSONL line per resolved escalation.
- `trace_dir` (String, default `"user://"`). A plain String rather than `@export_dir`, because that picker is `res://`-scoped and
  cannot express this default.
- `trace_filename` (String, default `"functiongemma_traces.jsonl"`). Lines are appended, never overwritten.

#### Exports, group Auto-adopt
- `adopt_group` (StringName, default `&"la_creatures"`). Creatures in this group are wired to this scheduler automatically. Clear it
  to wire them yourself with `set_cognition_scheduler()`.

#### Signal
- `degraded(reason: String)`. Emitted once per scheduler, the first time an escalation falls back to the teacher. `reason` names the
  cause and the fix. It is a signal rather than a print because the fallback fires per creature per second and would flood the
  console.

#### Methods
```gdscript
func setup(options: Dictionary = {}) -> void
func request(creature, cognition, sig: Dictionary, innate_action: String) -> bool
func is_thinking(c) -> bool
func is_queued(c) -> bool
func stats() -> Dictionary
func total_calls() -> int
```

`setup()` overrides the exports from code. Recognised keys: `enabled`, `llm_service`, `llm_client`, `trace_path`, `max_in_flight`,
`max_rps`. `request()` is the escalation entry point called by a creature's cognition: it returns true when the request was
accepted, meaning a result will come back asynchronously, and false when the global budget is full and the caller stays on the fast
path. It never blocks the physics frame.

`is_thinking()` and `is_queued()` are O(1) and drive a highlight. Thinking is exact while the escalation is in flight and then
lingers for `highlight_linger_ms`. Queued means the creature wanted to escalate but the budget was full. `stats()` returns
`{"in_flight": int, "total_calls": int, "llm_calls": int, "teacher_calls": int, "dropped": int}`. On leaving the tree the scheduler
prints one summary line naming how the escalations were actually resolved. This node has no configuration warnings.

### LocalAgentSimWorld

`addons/local_agents/sim/SimWorld.gd`, extends `Node3D`, `@tool`.

The one-node facade for a self-contained world. Pick a `world_type`, set its bounds, and call `spawn_world()`, or let it run on
`_ready()`. It composes the controllers the game's simulation composes behind a small export surface, and drives them with its own
`LASimLoop`. Instance `LASimWorldView` under it for its look. `@tool` is only for the configuration warnings: every lifecycle
callback returns early in the editor, so dropping the node in a scene never starts building a planet.

A SPHERE world is a planet body, its star, a field box around the body, the orbit and the ecology. The loop holds simulated time while
the field seeds, then each step turns the body on its measured spin, advances the orbit, which places the star and publishes its
irradiance at the body, steps the field and steps the ecology. The field's solar input is that star's light, so the insolation physics
is the game's. The field steps on a compute device, so SPHERE needs a RenderingDevice: without one, which is every `--headless` run,
`spawn_world()` pushes `GPU_REQUIRED` and builds nothing. A FLAT world is a ground plane and a box field volume; its loop steps the
ecology, and nothing seeds or steps its field.

godot_voxel is optional, and this node is where that is enforced. SPHERE is built out of the `zylann.voxel` GDExtension. FLAT is
not, and keeps working in a project that never installed it. Asking for SPHERE without the extension builds nothing and pushes a
`VOXEL_BACKEND_REQUIRED` error, because the repo convention is an explicit typed failure over silent degradation. The enum is
`WorldType { SPHERE, FLAT }`.

#### Signal
- `world_built`. `spawn_world()` finished: `terrain()`, `material_field()` and `ecology()` are live.

#### Exports, group World
- `world_type` (WorldType, default `SPHERE`). SPHERE builds a planet from godot_voxel's signed-distance terrain inside a Cartesian
  field box. FLAT builds a ground plane plus a box field volume and needs nothing beyond this addon.
- `build_on_ready` (bool, default `true`).
- `world_seed` (int, default `1337`). Terrain generation and every random draw this node makes derive from it.

The processes a world contains are settled before it is built: an explicit process set on the command line, else the rung that
`--rung=N`, the project setting `local_agents/sim/process_rung`, `LA_RUNG` or `res://docs/PLAYABLE_RUNG` names, in that order. A
project with none of them runs every process.

#### Exports, group Sphere bounds, subgroup Shape
- `body_seed` (String, default `planet`). Which row of `LABodySeeds` the world is built from. The radius is not an export: it
  follows from that row's mass and composition, and the relief follows the hypsographic curve in `LAPlanetShape`.
- `caves_enabled` (bool, default `true`).
- `tides_enabled` (bool, default `false`). Passed straight through to the planet body. Nothing reads it yet, because this facade
  builds no ocean shell.

#### Exports, group Sphere bounds, subgroup Field grid
- `grid_res` (int, default `20`, range 8 to 64, suffix cells). Root cells along one edge of the box. Where `res://docs/CELL_BUDGET`
  declares a budget, as this repository does, the build refines the band around the surface, halving its cells while the total stays
  under that budget.

#### Exports, group Sphere bounds, subgroup Slice
- `slice_cells` (Vector3i, default `Vector3i.ZERO`). Cells per axis of a slice box laid on the body instead of a box around the
  whole planet. Zero lays no slice here, and the project setting or `LA_SLICE_BOX` can still configure one; the node wins when set.
- `slice_cell_size_m` (float, default `4000.0`, suffix m). The slice box's coarsest cell edge.
- `slice_fine_m` (float, default `4000.0`, suffix m). The finest edge the slice refines to: `slice_cell_size_m` halved a whole
  number of times.
- `slice_offset_m` (Vector3, default `Vector3.ZERO`). The slice box's centre from the body centre in the body frame. Its direction is
  the slice's local vertical, so it must be nonzero.

#### Exports, group Wiring
- `star` (LAStar, default `null`). The star the body orbits. SPHERE only. Left unset, the build makes the star `LABodySeeds`
  declares, as a child named `Star`, and sets it here.

#### Exports, group Flat bounds
- `flat_extent` (Vector3, default `Vector3(120.0, 40.0, 120.0)`, range 1 to 2000 or greater per axis, suffix m). Size of the box
  field volume, centred horizontally on this node with its floor at Ground Y.
- `flat_cell_size` (float, default `5.0`, range 0.5 to 25.0 or greater, suffix m). Must be greater than 0: the build divides the
  extent by it.
- `ground_y` (float, default `0.0`, range -500.0 to 500.0, suffix m).

#### Exports, group Population
- `auto_spawn` (bool, default `true`). Spawn the starting ecology as soon as the world is built and its ground is queryable.
- `initial_counts` (Dictionary[String, int], default `{}`). How many of each kind to found the world with. Empty uses
  `DEFAULT_COUNTS`, which is `{"rabbit": 14, "fox": 3, "bird": 10, "plant": 40}`. Keys are `plant`, `rock` and `tree`, which the
  ecology instances directly, or any species id under `addons/local_agents/creatures/species/` (`rabbit`, `fox`, `bird`,
  `villager`, `mouse`, `trout` and the rest). An unknown key pushes a warning and spawns nothing. Same typed-Dictionary caveat as
  the spawner's `counts`.
- `forest_clusters` (int, default `6`, range 0 to 64 or greater, suffix clusters). SPHERE only. A FLAT world gets its plants from
  `initial_counts`.

#### Methods
```gdscript
static func has_voxel_backend() -> bool
func spawn_world() -> void
func spawn_life() -> void
func planned_cell_count() -> int
func seed_radius() -> float
func field_cell_size_m() -> float
func material_field() -> Variant
func ecology() -> Variant
func terrain() -> Variant
func planet_body() -> Variant
func actors_root() -> Node3D
func has_built() -> bool
func has_spawned() -> bool
```

`has_voxel_backend()` is `ClassDB.class_exists("VoxelLodTerrain")` and is safe to call from the editor. `spawn_world()` is
idempotent, and refuses with an error for SPHERE without godot_voxel or a RenderingDevice, for a non-positive `flat_cell_size`, for
a slice that does not fit and for a grid whose neighbour links are not reciprocal. `spawn_life()` places the founding population now,
bypassing the auto gate. A SPHERE spawn otherwise waits for the body to have a radius, plus a few settle ticks.

`planned_cell_count()` is `grid_res ** 3` for SPHERE, the root lattice before any refinement, and the extent divided by the cell size
on each axis for FLAT. It returns 0 when the settings cannot produce a grid. `seed_radius()` is the radius the seeded matter fills
before it is laid down, and `field_cell_size_m()` is the root cell edge in metres. The five accessors return null until
`spawn_world()` succeeds, and `terrain()` is duck-typed: a voxel terrain service for SPHERE, a flat ground adapter for FLAT.

#### Configuration warnings
- World Type is Sphere but godot_voxel is not installed.
- Flat Cell Size is 0 or less.
- Flat Extent has a zero or negative component.
- Auto Spawn is on but Build On Ready is off.
- Star is set but World Type is Flat.
- The settings ask for more than `SLOW_BUILD_CELLS` (250000) field cells, naming the count.

### LocalAgentFieldBox

`addons/local_agents/sim/material/FieldBox.gd`, extends `Node3D`.

The material field in box mode as a node. It owns a material field as a child rather than extending it, so the inspector surface lives
out here and the field hub stays untouched. Instance `LAFieldBoxSliceView` under it to draw a plane of its cells. The box is laid
once, when the node starts, axis-aligned and centred on the node's global position in X and Z with its floor at the node's height.
Moving the node later does not move the box.

The box holds no matter. Nothing seeds, activates or steps a box-mode field, so `add_heat_energy()` adds nothing and returns 0, and
`temp_at()` reads NAN in every cell. Pair the node with a `LocalAgentDemoHarness` whose `report_source` is this node for the standard
`-- --run-frames=N` report line.

#### Exports, group Volume
Every property in this group is read once when the node starts. Changing one later does not resize a running field.

- `extent` (Vector3, default `Vector3(60.0, 40.0, 60.0)`). Size of the box in world units.
- `cell_size` (float, default `5.0`, range 0.5 to 20.0, suffix m). Cells per axis is `extent / cell_size`, rounded, at least one.
- `origin_offset` (Vector3, default `Vector3.ZERO`). Shifts the box from the node, in world units. At zero the box is centred on the
  node in X and Z with its floor at the node's height.

#### Exports, group Heat source
- `heat_enabled` (bool, default `true`). Off leaves the volume to whatever you drive through `field()`.
- `heat_source_w` (float, default `2000.0`, range 0.0 to 1e6, suffix W). Power per source cell.
- `heat_burst_s` (float, default `10.0`, range 0.0 to 6000.0, suffix s). Seconds of the physics clock the source runs before
  switching off. 0 never stops.
- `heat_source_cells` (Vector3i, default `Vector3i(3, 1, 3)`). Source footprint in cells, centred on the floor.

Each physics tick the source asks `add_heat_energy()` for `heat_source_w` times the tick's length in every source cell.

#### Methods
```gdscript
func field() -> Node
func dims() -> Vector3i
func cell_point(ix: int, iy: int, iz: int) -> Vector3
func demo_report() -> Dictionary
```

`field()` returns the material field this node owns, and `dims()` its cells along X, Y and Z, zero before the field is built. The
field takes world positions:

```gdscript
func add_heat_energy(world_pos: Vector3, joules: float, radius: float = 0.0) -> float
func temp_at(pos: Vector3) -> float
```

`cell_point(ix, iy, iz)` is the world centre of a cell straight from the field, so `temp_at()` or `add_heat_energy()` at that point
lands on exactly that cell. The field's own `world_to_cell(pos) -> int` gives the linear index of a position.

`demo_report()` returns `frames`, `cells`, `dims` (a `"WxHxD"` string), `top_start`, `top_now`, `bottom_now` and `flowed` (true when
the top is more than 0.5 degrees above where it started). Temperatures are snapped to two decimals. Before the field exists the report
carries `frames` and `cells` only. This node has no configuration warnings.

## Views

A view is a scene under `game/render/` that reads a simulation node's state and draws it.

### LASimWorldView

`addons/local_agents/game/render/SimWorldView.gd`, extends `Node3D`, `@tool`. Instance `game/render/SimWorldView.tscn`, which
authors the `Sun` light and sets Terrain Material to `game/render/VoxelTerrainMaterial.tres`.

A `LocalAgentSimWorld`'s look. When the world is built it hands the terrain its material and hides the star's own light, and every
frame it aims `Sun` the way the star's light travels, star to body. A FLAT world has no star, so `Sun` keeps its authored pose.

#### Exports, group Wiring
- `sim_world` (LocalAgentSimWorld, default `null`). The world this view dresses.

#### Exports, group Terrain
- `terrain_material` (ShaderMaterial, default `null`, set by the scene). The planet's surface material. `VoxelTerrainMaterial.tres`
  is local to scene, so each instance draws its own copy and a uniform set on one world's terrain stays that world's. The game's
  `LARenderLayer` takes the same file.

#### Configuration warnings
- Sim World is unset.
- Terrain Material is unset.
- No DirectionalLight3D named `Sun` under the view.

### LAFieldBoxSliceView

`addons/local_agents/game/render/FieldBoxSliceView.gd`, extends `MultiMeshInstance3D`, `@tool`. Instance
`game/render/FieldBoxSliceView.tscn`, which authors the MultiMesh, its cube and the unshaded vertex-colour material.

One plane of a `LocalAgentFieldBox`'s cells, a cube per cell tinted by its temperature above `LABodySeeds.surface_temp_c()`, in one
draw call however many cells it covers. It lays each cube on the field's own cell centre in its own frame and lays out again when it
moves. Hide the node to stop it reading the field.

#### Exports, group Wiring
- `field_box` (LocalAgentFieldBox, default `null`). The box whose field this view draws.

#### Exports, group Slice
- `slice_axis` (String, default `"Z"`, `@export_enum("X", "Y", "Z")`). Z gives a vertical wall facing the camera, Y a horizontal
  floor plan.
- `slice_position` (float, default `0.5`, range 0.0 to 1.0). 0 is the low face of the box, 1 the high face.
- `cube_fill` (float, default `0.85`, range 0.05 to 1.0). Cube edge as a fraction of the field's cell edge. 1.0 makes the cubes
  touch.

#### Exports, group Colour
- `color_span` (float, default `60.0`, range 1.0 to 400.0, suffix C). Degrees above ambient that reach `hot_color`.
- `cold_color` (Color, default `Color(0.15, 0.2, 0.5)`). A cell at ambient.
- `hot_color` (Color, default `Color(1.0, 0.35, 0.1)`). A cell `color_span` degrees above ambient, or hotter.

#### Configuration warnings
- Field Box is unset.
- No MultiMesh to draw into.

---

[Back to the API reference index](API.md)

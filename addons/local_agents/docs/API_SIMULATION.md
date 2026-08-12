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

The one-node facade for a self-contained ecosystem sim. Pick a `world_type`, set its bounds, and call `spawn_world()`, or let it run
on `_ready()`. It composes the existing controllers behind a small export surface and adds no behaviour of its own. `@tool` is only
for the configuration warnings: every lifecycle callback returns early in the editor, so dropping the node in a scene never starts
building a planet.

godot_voxel is optional, and this node is where that is enforced. SPHERE is built out of the `zylann.voxel` GDExtension. FLAT is
not, and keeps working in a project that never installed it. Asking for SPHERE without the extension builds nothing and pushes a
`VOXEL_BACKEND_REQUIRED` error, because the repo convention is an explicit typed failure over silent degradation. The enum is
`WorldType { SPHERE, FLAT }`.

#### Exports, group World
- `world_type` (WorldType, default `SPHERE`). SPHERE grows a cubed-sphere planet and needs godot_voxel. FLAT builds a ground plane
  plus a box field volume and needs nothing beyond this addon.
- `build_on_ready` (bool, default `true`).

#### Exports, group Sphere bounds, subgroup Shape
- `radius` (float, default `250.0`, range 25.0 to 2000.0 or greater, suffix m). Relief, feature size and the field shell all scale
  from this. The numbers were tuned at 250, so 500 gives the same looking planet at twice the size.
- `ocean_bias` (float, default `3.0`, range -30.0 to 60.0, suffix m). How far the whole surface is pushed inward before relief is
  added, so a larger number means more ocean. Negative pushes outward for a drier planet.
- `caves_enabled` (bool, default `true`).
- `tides_enabled` (bool, default `false`). Passed straight through to the planet body. Nothing reads it yet, because this facade
  builds no ocean shell.

#### Exports, group Sphere bounds, subgroup Field grid
- `grid_res` (int, default `20`, range 8 to 64, suffix cells). Field cells along one edge of the box. Doubling it multiplies the
  grid by eight.

#### Exports, group Sphere bounds, subgroup Lighting
- `sun_enabled` (bool, default `true`). Add a fixed DirectionalLight3D so the field's solar pass has a real sun. SPHERE only.

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
func material_field() -> Variant
func ecology() -> Variant
func terrain() -> Variant
func planet_body() -> Variant
func actors_root() -> Node3D
func has_built() -> bool
func has_spawned() -> bool
```

`has_voxel_backend()` is `ClassDB.class_exists("VoxelLodTerrain")` and is safe to call from the editor. `spawn_world()` is
idempotent, and refuses with an error for SPHERE without godot_voxel and for a non-positive `flat_cell_size`. `spawn_life()` places
the founding population now, bypassing the auto gate. A SPHERE spawn otherwise waits for the top-of-planet patch to mesh and
collide, plus a few settle ticks.

`planned_cell_count()` is `grid_res ** 3` for SPHERE, and the extent divided by the cell size on each axis
for FLAT, so a host can size a world before building it. It returns 0 when the settings cannot produce a grid. The five accessors
return null until `spawn_world()` succeeds, and `terrain()` is duck-typed: a voxel terrain service for SPHERE, a flat ground adapter
for FLAT.

#### Configuration warnings
- World Type is Sphere but godot_voxel is not installed.
- Flat Cell Size is 0 or less.
- Flat Extent has a zero or negative component.
- Auto Spawn is on but Build On Ready is off.
- The settings ask for more than `SLOW_BUILD_CELLS` (250000) field cells, naming the count.

### LocalAgentFieldBox

`addons/local_agents/sim/material/FieldBox.gd`, extends `Node3D`.

The material field sandbox as a node. Drag it in, press play, and you get a volumetric field in box mode with a heat source at its
floor and a plane of cubes tinted by the live temperature, so you can watch warmth diffuse and rise. It owns a material field as a
child rather than extending it, so the inspector surface lives out here and the field hub stays untouched. Coordinates are local to
this node, so the box and its cubes move with its transform.

Box mode is a pure CPU substrate and runs anywhere, headless included. Only the slice visual needs a display, and it is skipped and
reported when there is none. Pair the node with a `LocalAgentDemoHarness` whose `report_source` is this node for the standard `--
--run-frames=N` report line.

#### Exports, group Volume
Every property in this group is read once when the node starts. Changing one later does not resize a running field.

- `extent` (Vector3, default `Vector3(60.0, 40.0, 60.0)`). Size of the simulated box in world units.
- `cell_size` (float, default `5.0`, range 0.5 to 20.0, suffix m). Cells per axis is `extent / cell_size`, so smaller is finer and
  slower.
- `origin_offset` (Vector3, default `Vector3.ZERO`). At zero the box is centred on X and Z with the centres of its floor cells at y
  = 0.

#### Exports, group Heat source
- `heat_enabled` (bool, default `true`). Off gives an inert volume you drive yourself by calling `add_heat()` on `field()`.
- `heat_per_frame` (float, default `40.0`, range 0.0 to 500.0, suffix C). Degrees injected per physics frame per source cell.
- `heat_burst_frames` (int, default `40`, range 0 to 6000, suffix frames). Frames the source runs before switching off. 0 never
  stops.
- `heat_source_cells` (Vector3i, default `Vector3i(3, 1, 3)`). Source footprint in cells, centred on the floor.

Heat goes in on the physics clock, which is the clock the field steps on, so the energy deposited by a given run does not vary with
the display framerate.

#### Exports, group Slice view
- `show_slice` (bool, default `true`). The plane of cubes that makes the field visible.
- `slice_axis` (String, default `"Z"`, `@export_enum("X", "Y", "Z")`). Z gives a vertical wall facing the camera, Y gives a
  horizontal floor plan.
- `slice_position` (float, default `0.5`, range 0.0 to 1.0). 0 is the low face of the box, 1 the high face.
- `cube_fill` (float, default `0.85`, range 0.05 to 1.0). Cube edge as a fraction of `cell_size`. 1.0 makes the cubes touch.
- `color_span` (float, default `60.0`, range 1.0 to 400.0, suffix C). Temperature above ambient that reaches `hot_color`. Smaller is
  a more sensitive display.
- `cold_color` (Color, default `Color(0.15, 0.2, 0.5)`). A cell at ambient.
- `hot_color` (Color, default `Color(1.0, 0.35, 0.1)`). A cell `color_span` degrees above ambient, or hotter.

The whole slice is one MultiMeshInstance3D, so it costs one draw call however many cells it covers.

#### Methods
```gdscript
func field() -> Node
func cell_dims() -> Vector3i
func demo_report() -> Dictionary
```

`field()` returns the material field this node owns, so you can drive the volume yourself. The three calls you want first do not
share a coordinate convention, so read the signatures before you pass anything:

```gdscript
func add_heat(world_pos: Vector3, amount: float, radius: float = 0.0) -> void
func temp_at(pos: Vector3) -> float
func add_water_cell(ix: int, iy: int, iz: int, amount: float) -> void
```

`add_heat()` and `temp_at()` take a position in the field's frame, which is this node's local space, with the floor of the box at
y = 0 and the box centred on X and Z unless Origin Offset moves it. `add_water_cell()` takes integer cell indices instead, and does
nothing for an out-of-bounds or solid cell. To go between the two, `cell_world_pos(ix, iy, iz) -> Vector3` gives the position of a
cell and `world_to_cell(pos) -> int` gives the linear index of a position, so a point from `cell_world_pos()` handed to `temp_at()`
lands on exactly the cell it came from.

`add_heat()`'s `radius` argument does nothing in box mode. The radius walk needs the cubed-sphere neighbour table, so a box field
heats the single cell at `world_pos` whatever radius you pass. Loop over the cells you want instead.

`demo_report()` returns `frames`, `cells`, `dims` (a `"WxHxD"` string), `top_start`, `top_now`, `bottom_now`, `flowed` (true when
the top is more than 0.5 degrees above where it started), `slice_instances`, and `slice_skipped` (the reason string, empty when the
visual was drawn). Temperatures are snapped to two decimals. Before the field exists the report omits `dims`, `slice_instances` and
`slice_skipped`. This node has no configuration warnings.

---

[Back to the API reference index](API.md)

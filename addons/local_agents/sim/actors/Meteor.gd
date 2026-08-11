@tool
class_name LAMeteor
extends Node3D

## A meteor is NOT a scripted explosion. It is a falling hot fast rock (a seed/marker + visual) whose
## impact seeds the shared substrate ONCE. Everything downstream emerges with zero meteor code:
##   • emit_shock radiates a seismic wave (tremor + felt panic);
##   • eject throws molten mass as ballistic ejecta parcels that arc under radial gravity and re-deposit
##     (the debris fling and the ejecta blanket both fall out of the field, with no per-actor chunk code);
##   • add_charge ionises the air above the crater → the field's breakdown discharges a bolt (the same
##     charge→bolt primitive a storm feeds);
##   • add_heat dumps the kinetic+thermal energy as a molten spike (crater glows, vegetation ignites);
##   • broadcast_scare / damage_sphere / disturb_ground panic, kill and slump via the shared stimuli;
##   • the crater itself emerges from the existing carve + ejecta redeposit.
##
## Deleted vs the old scripted meteor: `_spawn_debris_chunks` (22 RigidBody3D debris chunks with random
## velocities), `_impact_material_palette`, `_spawn_impact_fx` (one-shot burst particles + flash light) and
## `_make_debris_mesh`. A "debris chunk", a "crater", a "shockwave" are all just words for what the one
## substrate does. The actor is now seed + falling visual + one impact→substrate call.
## (Explicit types only, no ':=' inferred typing.)

# --- Tunables -----------------------------------------------------------------
const SPAWN_HEIGHT: float = 140.0          # fallback drop height when launched with no camera origin
const START_SPEED: float = 70.0            # initial fall speed (units/s) for the fallback drop
const LAUNCH_SPEED: float = 150.0          # fallback launch speed only if no gravity body exists yet
const MAX_SPEED: float = 600.0             # cap so a slingshot can't run away numerically
const ESCAPE_RADIUS_MULT: float = 30.0     # free the rock once it coasts this many body-radii out (left the system)
const MAX_LIFETIME: float = 240.0          # absolute lifespan cap so long-lived orbiters eventually clear
const METEOR_MASS_SCALE: float = 400.0     # mass = size³ × this; momentum = mass × velocity → planet orbital impulse
const IMPACT_RADIUS: float = 10.0          # carve radius — large & dramatic
const DAMAGE_SCALE: float = 1.6            # ecology damage radius = radius * this
const BODY_RADIUS: float = 1.4
# --- Heating ------------------------------------------------------------------
# A meteor has no fixed temperature. It arrives cold and heats by ramming air, so how hot it gets is
# an outcome of how fast and how steeply it came in, not a constant anyone typed. There was a flat
# 1600 °C here, injected on impact no matter whether the rock fell from orbit at 600 u/s or was lobbed
# at 150, and a separate hardcoded orange for the visual, so the look and the physics could disagree
# about the same rock.
#
# Convective entry heating goes as air density times the cube of speed, and the body radiates back
# toward ambient. Those two lines are the whole model. What falls out: a fast steep entry goes
# white-hot and lights the ground under it, a slow graze barely reddens, a rock that never meets the
# atmosphere stays dark, and a big rock hits harder than a small one at the same speed because the
# impact term carries its mass.
const AMBIENT_TEMP_C: float = -60.0        # what it starts at and relaxes toward
const ENTRY_HEAT_GAIN: float = 4.23e-6     # scales rho * v^3 into °C/s; ~1600 °C at MAX_SPEED in thick air
const RADIATIVE_COOL: float = 0.55         # per second, fraction of the excess over ambient shed again
const MAX_SURFACE_TEMP_C: float = 3000.0   # cap, so a runaway entry cannot inject absurd heat
# Air density is READ FROM THE FIELD, not modelled here. The substrate already simulates a 3D oxygen
# channel, so `o2_at()` at the meteor's own position is how much air there is to ram, and it composes
# for free: a thin atmosphere heats meteors less, a region stripped by an eruption heats them less
# right there, and a planet with no air at all never lights one up. A local scale-height formula would
# have been a second, disagreeing atmosphere living inside this actor.
const AIR_REFERENCE_O2: float = 0.21       # the o2 level treated as full thickness, so rho is a ratio
# On impact the remaining kinetic energy also goes into the ground — as a real E = 1/2 m v^2 in joules, see
# `_impact_energy_j()`. The two constants that used to live here (`KINETIC_HEAT_GAIN = 0.004` scaling v^2 into
# degrees, and `MAX_IMPACT_TEMP_C = 2500` capping the result) are DELETED: neither was a property of anything,
# and together they let one strike add up to 2500 °C to every one of ~150 cells with no energy behind it.
const FX_LINGER: float = 1.8               # seconds of FX after impact before free

enum State { IDLE, FALLING, IMPACTED }

var _terrain: Object = null                # LAVoxelTerrainService (duck-typed)
var _ecology: Object = null                # LAEcologyService (duck-typed)
var _state: int = State.IDLE
var _velocity: Vector3 = Vector3.ZERO
var _surface_temp: float = AMBIENT_TEMP_C   # °C, integrated during flight; drives both glow and impact heat
var _body_material: StandardMaterial3D = null
var _target: Vector3 = Vector3.ZERO
var _fall_time: float = 0.0
var _fx_time: float = 0.0
var _impact_point: Vector3 = Vector3.ZERO
var _spawned_at: Vector3 = Vector3.ZERO
var _guided: bool = false                  # true = FPS-style homing projectile; false = ballistic drop

var _body: MeshInstance3D = null
var _glow: OmniLight3D = null
var _trail: GPUParticles3D = null
var _picker: StaticBody3D = null

# Per-meteor size (randomized on launch): scales the rock, crater, heat, blast and ground shake so
# strikes vary from small bright pebbles to landscape-cratering giants.
var _size: float = 1.0


func _ready() -> void:
	add_to_group("selectable")
	_build_visuals()


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology


## Effective impact radius for THIS meteor (base * its random size), FLOORED AT THE SUBSTRATE'S RESOLUTION.
##
## A crater smaller than one field cell cannot exist in the physics. The field samples cell CENTRES, so a
## carve that fails to engulf one flips no cell from rock to void: `resample_terrain`'s `is_solid` probe still
## reads solid everywhere, its excavation loop `continue`s on every cell, and no bedrock is moved into the
## loose phases. The SDF mesh is far finer than the field grid, so the crater still LOOKS carved — which is
## why this went unnoticed.
##
## A SCALE CHANGE INTRODUCED IT, not this constant. When the planet went to radius 500, `PLANET_SCALE` was
## applied to world-gen geometry including cell_size (8.0 * PLANET_SCALE = 16 world units) but NOT to
## interaction radii, which kept their radius-250 values. IMPACT_RADIUS 10 was comfortably super-cell at the
## old 8-unit cell and became sub-cell at 16. Measured over 600 frames with --auto-meteor: six impacts,
## `crater_cells` 0, `crater_mass` 0.0, `crater_sea` 0 — and `crater_mass` is exactly the number the mineral
## ledger's own documentation names as the cross-check that a strike MOVED rock rather than deleting it.
##
## Floored against the LIVE cell size rather than re-scaled by PLANET_SCALE on purpose: it then stays correct
## at any future world scale and at any grid resolution, including the Low/High quality presets that change
## `grid_res_per_face` underneath it. 1.5 cells guarantees the centre cell is engulfed even when the impact
## point lands at a cell corner.
const MIN_CRATER_CELLS: float = 1.5

func _radius() -> float:
	var want: float = IMPACT_RADIUS * _size
	var cell: float = 0.0
	if _ecology != null and _ecology.has_method("material_field"):
		var field: Object = _ecology.material_field()
		if field != null and field.has_method("cell_size"):
			cell = float(field.cell_size())
	return maxf(want, cell * MIN_CRATER_CELLS)


## Launch toward `target`. If `from_pos` is finite it fires FROM THAT POINT (the camera / screen
## centre) like an FPS projectile, streaking straight out and homing onto the target so it always
## lands on the click point; otherwise it falls ballistically from above the target. Size is
## randomized each launch so strikes vary in scale.
func launch(target: Vector3, from_pos: Vector3 = Vector3(INF, INF, INF), size_scale: float = 1.0) -> void:
	_target = target
	# Base random variation scaled by the caller's size hint: the spawn brush passes a factor derived
	# from its radius, so growing the brush (Ctrl + wheel) flings a bigger, more cratering rock. Clamped
	# so a maxed brush can't produce a runaway crater.
	_size = clampf(LASimRng.for_domain("planet").randf_range(0.55, 2.3) * size_scale, 0.2, 8.0)
	if is_finite(from_pos.x) and is_finite(from_pos.y) and is_finite(from_pos.z):
		# Player-fired: leave the camera along the aim ray and then COAST under real N-body gravity — aim
		# tangential to a body and it settles into ORBIT, aim inward and it strikes, aim fast/outward and it
		# escapes. Launch at the local circular-orbit speed so a sideways flick actually orbits.
		var aim: Vector3 = target - from_pos
		if aim.length() < 0.001:
			aim = Vector3.DOWN
		aim = aim.normalized()
		_spawned_at = from_pos + aim * 3.0
		_guided = true
		var vcirc: float = LAGravity.circular_speed(get_tree(), _spawned_at)
		_velocity = aim * (vcirc if vcirc > 1.0 else LAUNCH_SPEED)
	else:
		# Auto/ambient drop: spawn radially "up" (away from the nearest body's core) above the target and
		# fall inward, so ballistic strikes head straight at the planet instead of drifting toward world -Y.
		var up0: Vector3 = _up_at(target)
		var tangent: Vector3 = up0.cross(Vector3.RIGHT)
		if tangent.length() < 0.01:
			tangent = up0.cross(Vector3.FORWARD)
		tangent = tangent.normalized()
		var lateral: Vector3 = tangent * LASimRng.for_domain("planet").randf_range(-24.0, 24.0) + up0.cross(tangent).normalized() * LASimRng.for_domain("planet").randf_range(-24.0, 24.0)
		_spawned_at = target + up0 * SPAWN_HEIGHT + lateral
		_guided = false
		var dir: Vector3 = _target - _spawned_at
		if dir.length() < 0.001:
			dir = -up0
		_velocity = dir.normalized() * START_SPEED
	global_position = _spawned_at
	# Bigger rock = bigger visual body, glow and trail.
	if _body != null:
		_body.scale = Vector3.ONE * _size
	if _glow != null:
		_glow.omni_range = 30.0 * _size
	_fall_time = 0.0
	_state = State.FALLING
	if _trail != null:
		_trail.emitting = true


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	match _state:
		State.FALLING:
			lines.append("Status: falling")
			lines.append("Speed: %.0f u/s" % _velocity.length())
			var alt: float = _terrain.altitude_at(global_position) if _terrain != null and _terrain.has_method("altitude_at") else global_position.y
			lines.append("Altitude: %.0f" % alt)
		State.IMPACTED:
			lines.append("Status: impacted")
			lines.append("Crater radius: %.0f" % _radius())
		_:
			lines.append("Status: idle")
	lines.append("Target: (%.0f, %.0f, %.0f)" % [_target.x, _target.y, _target.z])
	return {"title": "Meteor", "lines": lines}


func _physics_process(delta: float) -> void:
	match _state:
		State.FALLING:
			_step_fall(delta)
		State.IMPACTED:
			_fx_time += delta
			if _fx_time >= FX_LINGER:
				queue_free()


func _step_fall(delta: float) -> void:
	_fall_time += delta
	# Coast as a TEST PARTICLE under the summed N-body gravity of every body in the system (Outer-Wilds
	# style). Symplectic Euler: nudge velocity by the local acceleration, then advance. Orbits, flybys and
	# slingshots emerge — no homing, no single-centre / world-axis assumption.
	_velocity += LAGravity.acceleration_at(get_tree(), global_position) * delta
	if _velocity.length() > MAX_SPEED:
		_velocity = _velocity.normalized() * MAX_SPEED

	_step_entry_heat(delta)

	var next_pos: Vector3 = global_position + _velocity * delta
	var impact: Dictionary = _detect_impact(global_position, next_pos)
	if bool(impact.get("hit", false)):
		_impact_point = impact.get("point", next_pos)
		global_position = _impact_point
		_on_impact()
		return

	global_position = next_pos
	if _velocity.length() > 0.01:
		var vdir: Vector3 = _velocity.normalized()
		var up_hint: Vector3 = _up_at(global_position)
		look_at(global_position + _velocity, up_hint if absf(up_hint.dot(vdir)) < 0.98 else Vector3.UP)

	# Missed everything and either drifted for ages or left the system — free it. (Never force a phantom
	# impact here: that is what used to kill orbits before they could form.)
	if _fall_time > MAX_LIFETIME or _escaped():
		queue_free()


## How much air there is to ram, as a fraction of a full atmosphere, read straight out of the field's
## oxygen channel. 0 when there is no field or no air, so a meteor in vacuum never heats.
func _air_density_at(pos: Vector3) -> float:
	if _ecology == null or not _ecology.has_method("material_field"):
		return 0.0
	var field: Object = _ecology.material_field()
	if field == null or not field.has_method("o2_at"):
		return 0.0
	return clampf(float(field.o2_at(pos.x, pos.y, pos.z)) / AIR_REFERENCE_O2, 0.0, 1.0)


## The two lines that replace the old fixed temperature. Heating goes as air density times the cube of
## speed, cooling as the excess over ambient. Nothing here knows what a "meteor" is, so the same rule
## would heat anything else moving fast through air.
func _step_entry_heat(delta: float) -> void:
	var speed: float = _velocity.length()
	var rho: float = _air_density_at(global_position)
	var gain: float = ENTRY_HEAT_GAIN * rho * speed * speed * speed
	var excess: float = _surface_temp - AMBIENT_TEMP_C
	_surface_temp = clampf(_surface_temp + (gain - RADIATIVE_COOL * excess) * delta,
		AMBIENT_TEMP_C, MAX_SURFACE_TEMP_C)
	_apply_heat_visual()


## The look follows the temperature rather than being set once at spawn, so a rock visibly lights up on
## the way in and a slow one never does.
func _apply_heat_visual() -> void:
	if _body_material != null:
		LAHeatGlow.apply(_body_material, _surface_temp)
	if _glow != null:
		var lit: bool = _surface_temp >= LAHeatGlow.GLOW_MIN
		_glow.visible = lit
		if lit:
			_glow.light_color = LAHeatGlow.emission(_surface_temp)
			_glow.light_energy = LAHeatGlow.energy(_surface_temp) * _size


## THE IMPACTOR'S MASS, in kilograms, from its own geometry and the density of the rock it is made of.
##
## The actor already carried a second, incompatible mass claim — `METEOR_MASS_SCALE = 400.0`, "mass = size³ ×
## this", used for the orbital impulse at :335. That number is in no units at all, so the rock the orbit feels
## and the rock the ground feels were different rocks. This one is a real mass: a sphere of basalt of the
## body's own radius. (The orbital-impulse line is left alone here — it belongs to the gravity/orbit track —
## but it should be reading this.)
func _impact_mass_kg() -> float:
	var r: float = BODY_RADIUS * _size
	return LAPhysical.ROCK_DENSITY_KG_M3 * (4.0 / 3.0) * PI * r * r * r


## WHAT THE GROUND ACTUALLY RECEIVES, IN JOULES: the kinetic energy the rock still had, plus the heat stored
## in its body by entry friction. Both are properties of this rock on this trajectory, and both stop existing
## when it stops — that is what "the impact's heat is the impactor's energy" means.
##
## THIS REPLACES A TEMPERATURE, AND THE DIFFERENCE IS THE WHOLE POINT. `_impact_temp_c()` returned a NUMBER OF
## DEGREES (skin temperature plus `KINETIC_HEAT_GAIN * v² * size`, capped at 2500) which `add_heat` then added
## to EVERY cell in a bubble of radius `r * 2.2` — roughly 150 cells at the shipped grid. So one strike raised
## a hundred and fifty cells by up to two and a half thousand degrees each, out of nothing, and the amount did
## not depend on how much rock there was to heat. `KINETIC_HEAT_GAIN` and `MAX_IMPACT_TEMP_C` were the two
## constants holding that in a plausible-looking range; neither is a property of anything, and both are gone.
##
## WHAT THE HONEST NUMBER SAYS, stated here so nobody re-derives it as a bug: a 2.8 m basalt rock is about
## 33,000 kg, and at this game's impact speeds (150-600 m/s) it carries 0.4-6 GJ of kinetic energy against a
## bubble of basalt whose heat capacity is of order 1e12 J/K. The temperature rise is hundredths of a degree.
## That is CORRECT — real impact melting needs meteoric speed, 11-72 km/s, not 600 m/s — and it means the
## glowing crater was never a consequence of the impact, it was a typed-in temperature. If incandescent
## craters are wanted back, the thing to change is the entry speed, which is a real physical quantity, not the
## heat, which is an outcome.
func _impact_energy_j() -> float:
	var m: float = _impact_mass_kg()
	var speed: float = _velocity.length()
	var kinetic: float = 0.5 * m * speed * speed
	# Entry friction genuinely heats the body, and that heat arrives with it. Treated as the whole mass at the
	# skin temperature, which is an OVER-estimate (only a thin skin gets that hot and most of it radiates away
	# on the way down) — deliberately, so this cannot be accused of hiding energy the rock really brought.
	var thermal: float = m * LAPhysical.ROCK_SPECIFIC_HEAT_J_KGK * maxf(0.0, _surface_temp - AMBIENT_TEMP_C)
	return kinetic + thermal


## Radial "up" (away from the nearest gravity body's core) at a world point — the dominant body, else the
## terrain planet, else world up. Used for the ballistic spawn + orientation so nothing assumes world +Y.
func _up_at(pos: Vector3) -> Vector3:
	var b: Object = LAGravity.dominant_body(get_tree(), pos) if is_inside_tree() else null
	if b != null and b.has_method("center"):
		var r: Vector3 = pos - (b.center() as Vector3)
		if r.length() > 0.001:
			return r.normalized()
	if _terrain != null and _terrain.has_method("up_at"):
		return _terrain.up_at(pos)
	return Vector3.UP


## True once the meteor has coasted far beyond the dominant body's reach (it left the system).
func _escaped() -> bool:
	var b: Object = LAGravity.dominant_body(get_tree(), global_position)
	if b == null or not (b.has_method("center") and b.has_method("radius")):
		return false
	var far: float = maxf(float(b.radius()), 1.0) * ESCAPE_RADIUS_MULT
	return global_position.distance_to(b.center() as Vector3) > far


## Returns {"hit": bool, "point": Vector3}. Tries surface_height, then a swept
## raycast, then a fallback target plane so it always resolves.
func _detect_impact(from: Vector3, to: Vector3) -> Dictionary:
	var no_hit: Dictionary = {"hit": false, "point": Vector3.ZERO}

	if _terrain != null and _terrain.has_method("altitude_at"):
		var alt: float = _terrain.altitude_at(to)             # height above the local ground (radial); <0 = below
		if not is_nan(alt) and alt <= 0.0:
			var sp: Vector3 = _terrain.ground_point(to) if _terrain.has_method("ground_point") else to
			return {"hit": true, "point": (to if is_nan(sp.x) else sp)}

	if _terrain != null and _terrain.has_method("raycast_terrain"):
		var seg: Vector3 = to - from
		var dist: float = seg.length()
		if dist > 0.0001:
			var res: Dictionary = _terrain.raycast_terrain(from, seg / dist, dist + BODY_RADIUS)
			if bool(res.get("hit", false)):
				return {"hit": true, "point": res.get("position", to)}

	if _terrain == null and to.y <= _target.y:
		return {"hit": true, "point": Vector3(to.x, _target.y, to.z)}

	return no_hit


func _on_impact() -> void:
	_state = State.IMPACTED
	_fx_time = 0.0

	# MOMENTUM into the planet's orbit: a big/fast strike (or a sustained volley) perturbs the orbital velocity —
	# enough of it knocks the planet onto a decaying orbit into the sun, or past escape velocity out of the system.
	# Impulse = meteor mass (∝ size³) × its impact velocity. Emergent from the same momentum the ejecta uses.
	var orbits: Node = get_tree().get_first_node_in_group("system_orbits")
	if orbits != null and orbits.has_method("apply_impulse"):
		orbits.apply_impulse(_velocity * (METEOR_MASS_SCALE * _size * _size * _size))

	var r: float = _radius()                                   # size-scaled crater
	if _terrain != null and _terrain.has_method("carve_sphere"):
		_terrain.carve_sphere(_impact_point, r)
		# ...and TELL THE SUBSTRATE the rock is gone. carve_sphere only edits the godot_voxel SDF, which is the
		# mesh and the collision; the field's own bedrock channel is what decides where water may pool and air
		# may sit. Without this second call the crater was a hole you could stand in that the physics still
		# treated as solid rock. resample_terrain re-reads the freshly carved SDF as its shape oracle and moves
		# the excavated bedrock into the loose mineral phases, so the strike relocates mass instead of deleting
		# it. Slightly wider than the carve so the cells straddling the rim are re-read too (they stay solid
		# unless the carve actually reached them — the is_solid probe, not this radius, decides).
		if _ecology != null and _ecology.has_method("material_field"):
			var substrate: Object = _ecology.material_field()
			if substrate != null and substrate.has_method("resample_terrain"):
				substrate.resample_terrain(_impact_point, r * 1.5)
	if _ecology != null and _ecology.has_method("damage_sphere"):
		_ecology.damage_sphere(_impact_point, r * DAMAGE_SCALE)
	# Big splash if it struck water.
	if _ecology != null and _ecology.has_method("material_field"):
		var water: Object = _ecology.material_field()
		if water != null and water.has_method("is_water_at") and water.is_water_at(_impact_point):
			water.splash(_impact_point, 3.5 * _size)
			# White-hot rock hitting water flashes to steam — sizzle + a steam hiss.
			LAAudioDirector.emit(get_tree(), "sizzle", _impact_point)
			LAAudioDirector.emit(get_tree(), "steam", _impact_point)
	# Terror shockwave: everything that hears/feels the impact panics and flees.
	if _ecology != null and _ecology.has_method("broadcast_scare"):
		_ecology.broadcast_scare(_impact_point, r * 6.0, 1.0)
	# The strike hands the ground the ENERGY it arrived carrying (kinetic + the heat entry friction put in the
	# body). The substrate divides that by the heat capacity of the rock and air it landed on, so how hot the
	# crater gets is an OUTCOME of how fast and how heavy the rock was and what it hit — not a temperature
	# anyone typed. Vegetation that crosses the ignition temperature still catches fire from it; it just has to
	# earn the temperature now.
	if _ecology != null and _ecology.has_method("material_field"):
		var field: Object = _ecology.material_field()
		if field != null and field._inject != null and field._inject.has_method("add_heat_energy"):
			field._inject.add_heat_energy(_impact_point, _impact_energy_j(), r * 2.2)
		# The impact IS a shock source + an ejecta source — both are the substrate's own primitives now (no
		# per-actor wave/debris code). emit_shock radiates a seismic wave (tremor + panic); eject throws molten
		# debris parcels that arc under radial gravity and re-deposit on landing (a glowing ejecta blanket).
		if field != null and field.has_method("emit_shock"):
			field.emit_shock(_impact_point, 2.0 + _size * 2.0)
		if field != null and field.has_method("eject"):
			var up: Vector3 = (_impact_point - field._origin).normalized() if "_origin" in field else Vector3.UP
			field.eject(_impact_point, 0.4 * _size, 900.0 * _size, up * 0.6)
			# Hypervelocity impact IONISES the air above the crater — a charge seed the field's breakdown then
			# discharges as a bolt (the same charge→bolt primitive a storm feeds; here from impact plasma).
			if field.has_method("add_charge"):
				# Scale the seed with meteor size (same idiom as emit_shock above) so a small strike stays at or
				# below the field's dielectric breakdown (~6.0) and barely sparks, while a large one seeds a real
				# storm — and cap it just above breakdown so even the biggest impact never dumps the 4-bolts/step
				# barrage. _size in [0.55, 2.3]: small ~ 5.4 (sub-breakdown, 0 bolts), mid ~ 7.5 (one or two bolts),
				# large capped at 9.0.
				field.add_charge(_impact_point + up * 20.0, minf(4.0 + _size * 2.5, 9.0), r)
	# Shake the ground: steep terrain in the blast radius slumps downhill under gravity (a meteor into
	# a mountainside triggers a slide — pure material physics, no landslide code).
	if _ecology != null and _ecology.has_method("disturb_ground"):
		_ecology.disturb_ground(_impact_point, r * 2.0, _size)

	if _body != null:
		_body.visible = false
	if _glow != null:
		_glow.visible = false
	if _trail != null:
		_trail.emitting = false
	if _picker != null:
		_picker.queue_free()
		_picker = null

	# Procedural impact boom (presentation only; resolves the AudioDirector by group). The flash, debris
	# fling and ejecta blanket are no longer scripted here — they emerge from the eject/add_heat/add_charge
	# seeds above (glowing ejecta parcels + molten crater glow + a discharge bolt).
	LAAudioDirector.emit(get_tree(), "meteor_impact", _impact_point)


func _build_visuals() -> void:
	# Molten core mesh with a bright emissive material.
	_body = MeshInstance3D.new()
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = BODY_RADIUS
	sphere.height = BODY_RADIUS * 2.0
	_body.mesh = sphere
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.3, 0.28)
	# Cold rock. Its incandescence is applied per frame from _surface_temp, which starts at ambient and
	# only rises if the thing actually rams air on the way in.
	_body_material = mat
	_body.material_override = mat
	add_child(_body)

	_glow = OmniLight3D.new()
	_glow.light_energy = 6.0
	_glow.omni_range = 30.0
	_glow.visible = false
	add_child(_glow)
	_apply_heat_visual()

	_trail = GPUParticles3D.new()
	_trail.emitting = false
	_trail.amount = 240
	_trail.lifetime = 1.1
	_trail.draw_pass_1 = _make_trail_mesh()
	var tp: ParticleProcessMaterial = ParticleProcessMaterial.new()
	tp.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	tp.emission_sphere_radius = BODY_RADIUS * 0.8
	# Particles are emitted with almost no velocity so they hang in the air where the fireball WAS,
	# leaving a burning trail behind the moving meteor. They shrink and darken over their life.
	tp.direction = Vector3(0.0, 1.0, 0.0)
	tp.spread = 40.0
	tp.initial_velocity_min = 0.5
	tp.initial_velocity_max = 4.0
	tp.gravity = Vector3(0.0, 4.0, 0.0)          # hot embers loft a little as they trail
	tp.scale_min = 0.7
	tp.scale_max = 1.8
	tp.scale_curve = _trail_scale_curve()        # taper to nothing so it reads as a tapering tail
	tp.color = Color(1.0, 0.6, 0.18)
	tp.color_ramp = _fire_ramp()                 # white-hot -> orange -> smoke over the ember's life
	_trail.process_material = tp
	add_child(_trail)

	# Selection collider (layer 2) so it can be picked while falling.
	_picker = StaticBody3D.new()
	_picker.collision_layer = 2
	_picker.collision_mask = 0
	var col: CollisionShape3D = CollisionShape3D.new()
	var cs: SphereShape3D = SphereShape3D.new()
	cs.radius = BODY_RADIUS * 1.2
	col.shape = cs
	_picker.add_child(col)
	add_child(_picker)


# White-hot at birth (just off the fireball) fading through orange to dark smoke as each ember ages —
# the classic burning-reentry tail.
func _fire_ramp() -> GradientTexture1D:
	# Alpha fades from a hazy-hot core to fully transparent smoke, so the trail is translucent — you
	# see terrain through it and it dissolves rather than reading as a solid ribbon.
	var g: Gradient = Gradient.new()
	g.set_color(0, Color(1.0, 0.95, 0.7, 0.75))
	g.add_point(0.35, Color(1.0, 0.55, 0.12, 0.5))
	g.add_point(0.7, Color(0.6, 0.16, 0.05, 0.22))
	g.set_color(1, Color(0.12, 0.11, 0.11, 0.0))
	var tex: GradientTexture1D = GradientTexture1D.new()
	tex.gradient = g
	return tex


# Embers start full-size and shrink to nothing, so the trail tapers to a point behind the meteor.
func _trail_scale_curve() -> CurveTexture:
	var c: Curve = Curve.new()
	c.add_point(Vector2(0.0, 1.0))
	c.add_point(Vector2(1.0, 0.0))
	var tex: CurveTexture = CurveTexture.new()
	tex.curve = c
	return tex


func _make_trail_mesh() -> Mesh:
	var m: SphereMesh = SphereMesh.new()
	m.radius = 0.5
	m.height = 1.0
	m.radial_segments = 6
	m.rings = 3
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.1)
	mat.emission_energy_multiplier = 4.0
	mat.albedo_color = Color(1.0, 0.5, 0.1)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.material = mat
	return m

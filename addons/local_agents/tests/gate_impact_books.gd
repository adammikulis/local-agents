extends SceneTree

## ONE IMPACT ENERGY, PARTITIONED. The shares LAMeteor hands out must sum to the impactor's own kinetic
## energy, and a parcel's kilograms must be sized at the cell that was debited, not at the one it lands in.

const SRC_CELL: int = 0
const DST_CELL: int = 1
const SRC_VOLUME_M3: float = 1000.0
const DST_VOLUME_M3: float = 8000.0                # one refinement level coarser than the source
const LAUNCH_SPEED_M_S: float = 20.0
const STEP_S: float = 0.001
const MAX_STEPS: int = 200000
# The floor the parcels arc over: a box of cells, solid below y = 0, so a landing is a cell the integrator
# entered rather than a radius compared in float32 at six million metres.
const FLOOR_N: int = 16
const FLOOR_CELL_M: float = 10.0
const LAUNCH_Y_M: float = 5.0
const REL_BOUND: float = 1.0e-5


class StubGrid extends RefCounted:
	var vols: PackedFloat32Array = PackedFloat32Array()

	func cell_volumes() -> PackedFloat32Array:
		return vols


class StubInject extends RefCounted:
	var landed_units: float = 0.0
	var landed_src: PackedInt32Array = PackedInt32Array()
	var heat_j: float = 0.0
	var heat_radius: float = -1.0

	func land_ejecta(src_cell: int, _world_pos: Vector3, mass: float) -> void:
		landed_units += mass
		landed_src.append(src_cell)

	func add_heat_energy(_world_pos: Vector3, joules: float, radius: float = 0.0) -> float:
		heat_j += joules
		heat_radius = radius
		return joules


## The one cell the parcels are thrown out of, and a coarser cell everywhere else — the graded grid on
## which sizing a parcel at its destination gives a different answer from sizing it at its source.
class StubField extends RefCounted:
	var _origin: Vector3 = Vector3.ZERO
	var _grid: StubGrid = null
	var _inject: StubInject = null
	var _silicate: PackedFloat32Array = PackedFloat32Array()
	var _cell_count: int = 2
	var launch: Vector3 = Vector3.ZERO

	func world_to_cell(pos: Vector3) -> int:
		return SRC_CELL if pos.distance_to(launch) < 0.5 else DST_CELL


var _fail: int = 0
var _walked: bool = false
var _body_mass_kg: float = 0.0
var _body_radius_m: float = 0.0
# HELD, not built inline: LABallistics keeps the grid it was handed, and a temporary one is freed under it.
var _floor: LAVoxelGrid = null


func _say(msg: String) -> void:
	printerr(msg)
	_fail += 1


func _e(v: float) -> String:
	return String.num_scientific(v)


func _close(a: float, b: float, bound: float = REL_BOUND) -> bool:
	return absf(a - b) <= bound * maxf(absf(a), absf(b))


func _process(_delta: float) -> bool:
	if _walked:
		return true
	_walked = true
	_body_mass_kg = float(LABodySeeds.of("planet").get("mass_kg", 0.0))
	_body_radius_m = LABodySeeds.seed_radius_m("planet")
	if not (_body_mass_kg > 0.0 and _body_radius_m > 0.0):
		printerr("The seeded planet has no measured mass or radius: nothing arrives at it and nothing falls.")
		quit(2)
		return true
	var rows: PackedStringArray = PackedStringArray()
	rows.append(_partition_arm())
	rows.append(_parcel_arm())
	print('IMPACT_BOOKS={%s,"failures":%d}' % [",".join(rows), _fail])
	quit(1 if _fail > 0 else 0)
	return true


func _surface_g() -> float:
	return LAPhysical.GRAVITATIONAL_CONSTANT * _body_mass_kg / (_body_radius_m * _body_radius_m)


## The lowest speed a meteoroid can arrive at: the body's own escape speed (Ceplecha et al. 1998).
func _arrival_speed() -> float:
	return sqrt(2.0 * LAPhysical.GRAVITATIONAL_CONSTANT * _body_mass_kg / _body_radius_m)


## Melosh (1989) eq. 7.8.4 for rock into rock at normal incidence, stated here rather than read out of
## LAMeteor: an expectation the gate borrows from the code under test measures nothing.
func _transient_radius(impactor_r: float, speed: float, g: float) -> float:
	return 0.5 * 1.161 * pow(2.0 * impactor_r, 0.78) * pow(speed, 0.44) * pow(g, -0.22)


## ARM A — the three shares of one impact energy, over five decades of impactor size.
func _partition_arm() -> String:
	var worst_sum: float = 0.0
	var worst_ejecta: float = 0.0
	var worst_surface: float = 0.0
	var min_heat_frac: float = 1.0
	var g: float = _surface_g()
	var speed: float = _arrival_speed()
	for e in range(0, 6):
		var impactor_r: float = pow(10.0, float(e) - 1.0)
		var mass: float = LAPhysical.ROCK_DENSITY_KG_M3 * (4.0 / 3.0) * PI * pow(impactor_r, 3.0)
		var energy: float = 0.5 * mass * speed * speed
		var crater_r: float = _transient_radius(impactor_r, speed, g)
		var thrown: float = LAPhysical.ROCK_DENSITY_KG_M3 * float(LAMeteor.cavity(crater_r)["volume_m3"])
		var p: Dictionary = LAMeteor.partition(energy, thrown, g, crater_r)
		var total: float = float(p["heat_j"]) + float(p["excavation_j"]) + float(p["ballistic_j"])
		worst_sum = maxf(worst_sum, absf(total - energy) / energy)
		worst_ejecta = maxf(worst_ejecta,
			absf(float(p["ejecta_j"]) - float(p["excavation_j"]) - float(p["ballistic_j"])) / energy)
		# The ballistic share is the thrown mass at sqrt(g R): the 45-degree launch whose range is the rim.
		var surface_v: float = sqrt(2.0 * float(p["ballistic_j"]) / thrown)
		worst_surface = maxf(worst_surface, absf(surface_v - sqrt(g * crater_r)) / sqrt(g * crater_r))
		min_heat_frac = minf(min_heat_frac, float(p["heat_j"]) / energy)
	if worst_sum > REL_BOUND:
		_say("The shares of one impact energy do not sum to it: worst relative gap %s." % _e(worst_sum))
	if worst_ejecta > REL_BOUND:
		_say("The ejecta energy is not its excavation work plus its ballistic energy: %s." % _e(worst_ejecta))
	if worst_surface > REL_BOUND:
		_say("The ejecta does not reach the surface at sqrt(g R): %s." % _e(worst_surface))
	if min_heat_frac <= 0.0:
		_say("An impact owes more to its ejecta than it arrives with: heat share %.4f." % min_heat_frac)
	return '"sum_rel":%s,"ejecta_rel":%s,"surface_rel":%s,"min_heat_frac":%.4f' \
		% [_e(worst_sum), _e(worst_ejecta), _e(worst_surface), min_heat_frac]


## ARM B — a parcel's kilograms, its launch speed, and what one cell can give up.
func _parcel_arm() -> String:
	LABallistics.clear()
	_floor = _build_floor()
	LABallistics.set_field(_floor, _floor_gravity(), _floor_solid(), [])
	var grid: StubGrid = StubGrid.new()
	grid.vols = PackedFloat32Array([SRC_VOLUME_M3, DST_VOLUME_M3])
	var inject: StubInject = StubInject.new()
	var field: StubField = StubField.new()
	field._grid = grid
	field._inject = inject
	field._silicate = PackedFloat32Array([LASubstances.full_mol_m3("silicate"), 0.0])
	field.launch = Vector3(0.0, LAUNCH_Y_M, 0.0)
	if not (field._silicate[SRC_CELL] > 0.0):
		_say("The substance table gives silicate no full density, so the source cell holds nothing.")
		return '"parcel":"unmeasured"'

	var ejecta: LAMaterialEjecta3D = LAMaterialEjecta3D.new()
	root.add_child(ejecta)
	ejecta.setup(field)

	var unit_src: float = LAPhysical.MOLAR_MASS_CASIO3_KG_MOL * SRC_VOLUME_M3
	var unit_dst: float = LAPhysical.MOLAR_MASS_CASIO3_KG_MOL * DST_VOLUME_M3
	if _close(unit_src, unit_dst):
		_say("The two cells weigh a channel unit the same, so this arm cannot tell source from destination.")

	# A CELL CANNOT GIVE MORE MINERAL THAN IT HOLDS: ask for a million cells' worth, get one cell's.
	var have_kg: float = field._silicate[SRC_CELL] * unit_src
	var launched_j: float = ejecta.eject(field.launch, have_kg * 1.0e6, LAUNCH_SPEED_M_S)
	var want_j: float = 0.5 * have_kg * LAUNCH_SPEED_M_S * LAUNCH_SPEED_M_S
	if not _close(launched_j, want_j, 1.0e-3):
		_say("eject() launched %s J where the cell it debited holds %s J at that speed."
			% [_e(launched_j), _e(want_j)])

	# EVERY PARCEL LEAVES AT THE SPEED IT WAS GIVEN, m/s, and nothing divides an energy by a channel amount.
	var launched: int = ejecta.in_flight()
	if launched <= 0:
		_say("eject() threw nothing out of a cell full of mineral.")
		return '"parcel":"unlaunched"'
	var worst_speed: float = 0.0
	for i in range(launched):
		var st: Dictionary = LABallistics.state(ejecta._p_id[i])
		if st.is_empty():
			_say("A launched parcel has no state in the one integrator.")
			continue
		worst_speed = maxf(worst_speed, absf(float(st["speed"]) - LAUNCH_SPEED_M_S) / LAUNCH_SPEED_M_S)
	if worst_speed > 1.0e-4:
		_say("A parcel's launch speed is not the speed it was given: %s relative." % _e(worst_speed))

	# THE ARC. Every landing the integrator reports is handed on, and its own speed is what the parcel's
	# kinetic energy is sized from, so nothing here re-derives the flight.
	var per_kg: float = have_kg / float(launched)
	var expect_j: float = 0.0
	var steps: int = 0
	while ejecta.in_flight() > 0 and steps < MAX_STEPS:
		var rows: Array = LABallistics.step(STEP_S)
		for row: Dictionary in rows:
			var speed: float = float(row["speed"])
			expect_j += 0.5 * per_kg * speed * speed
		ejecta.on_bodies_landed(rows)
		steps += 1
	if ejecta.in_flight() > 0:
		_say("Parcels launched at %.1f m/s never came down in %d steps." % [LAUNCH_SPEED_M_S, steps])
	if inject.landed_src.size() != launched:
		_say("%d parcels launched and %d landed." % [launched, inject.landed_src.size()])
	for c in inject.landed_src:
		if c != SRC_CELL:
			_say("A parcel was booked back against cell %d, not the cell it was debited from." % c)
	if not _close(inject.landed_units * unit_src, have_kg, 1.0e-3):
		_say("The parcels carried %s kg out of a cell holding %s kg."
			% [_e(inject.landed_units * unit_src), _e(have_kg)])

	# THE LANDING HEAT IS THE PARCELS' OWN KINETIC ENERGY, in the kilograms they left the SOURCE with.
	if expect_j <= 0.0:
		_say("No parcel landed with a speed, so nothing sized the landing heat.")
		return '"parcel":"unlanded"'
	var heat_rel: float = absf(inject.heat_j - expect_j) / expect_j
	var dst_rel: float = absf(inject.heat_j - expect_j * (unit_dst / unit_src)) / expect_j
	if heat_rel > 1.0e-5:
		_say("The landing heat %s J is not the parcels' own %s J (relative %s)."
			% [_e(inject.heat_j), _e(expect_j), _e(heat_rel)])
	if dst_rel <= heat_rel:
		_say("The landing heat is sized at the destination cell, not at the cell that was debited.")
	if inject.heat_radius != 0.0:
		_say("A parcel's landing heat was spread over %.1f m instead of the cell it landed in."
			% inject.heat_radius)
	ejecta.queue_free()
	LABallistics.clear()
	LABallistics.clear_field()
	return '"launched_j_rel":%s,"speed_rel":%s,"heat_rel":%s,"dst_rel":%s,"unit_ratio":%.3f' \
		% [_e(absf(launched_j - want_j) / want_j), _e(worst_speed), _e(heat_rel), _e(dst_rel),
			unit_dst / unit_src]


func _build_floor() -> LAVoxelGrid:
	var g: LAVoxelGrid = LAVoxelGrid.new()
	var half: float = 0.5 * float(FLOOR_N) * FLOOR_CELL_M
	g.build(FLOOR_N, FLOOR_N, FLOOR_N, FLOOR_CELL_M, Vector3(-half, -FLOOR_CELL_M * 5.0, -half))
	return g


## The seeded body's own surface gravity, uniform over a box a few tens of metres tall.
func _floor_gravity() -> PackedFloat32Array:
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(_floor.cell_count * 3)
	for c in _floor.cell_count:
		out[c * 3 + 1] = -_surface_g()
	return out


func _floor_solid() -> PackedByteArray:
	var out: PackedByteArray = PackedByteArray()
	out.resize(_floor.cell_count)
	for c in _floor.cell_count:
		out[c] = 1 if _floor.cell_world_pos(c).y < 0.0 else 0
	return out

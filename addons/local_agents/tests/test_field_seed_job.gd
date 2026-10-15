extends RefCounted

const Snapshot: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSnapshot3D.gd")

class GridFixture extends LAVoxelGrid:
	var gate: Mutex = Mutex.new()
	var open: bool = true

	func set_open(value: bool) -> void:
		gate.lock()
		open = value
		gate.unlock()

	func is_open() -> bool:
		gate.lock()
		var value: bool = open
		gate.unlock()
		return value

	func cell_edges() -> PackedFloat32Array:
		var deadline: int = Time.get_ticks_msec() + 2000
		while not is_open() and Time.get_ticks_msec() < deadline:
			OS.delay_msec(1)
		return super.cell_edges()

class FieldFixture extends RefCounted:
	var _grid: LAVoxelGrid
	var _cell_count: int
	var _solid: PackedByteArray
	var _rock_fraction: PackedFloat32Array
	var _water_fraction: PackedFloat32Array
	var _surface_depth: PackedFloat32Array
	var _regolith: PackedByteArray
	var _t_rock: PackedFloat32Array
	var _pivot: Vector3
	var _sea_radius: float
	var _gravity: GravityFixture
	var _seal: LedgerFixture = LedgerFixture.new()
	var _mirrors: LAFieldMirrors
	var _gpu: GpuFixture = GpuFixture.new()
	var _body_measure: MeasureFixture = MeasureFixture.new()
	var _body_key: String = "planet"
	var _ready_sim: bool = false
	var _use_gpu: bool = true

	func sea_radius() -> float:
		return _sea_radius

class GravityFixture extends RefCounted:
	func up_table() -> PackedInt32Array:
		return PackedInt32Array()

class LedgerFixture extends RefCounted:
	var amounts: Dictionary = {}

	func note_creation(what: String, amount: float) -> bool:
		amounts[what] = float(amounts.get(what, 0.0)) + amount
		return true

class DeviceStub extends RefCounted:
	var _rd: RefCounted = RefCounted.new()

class MeasureFixture extends RefCounted:
	func measure(_field: Object, _axis: Vector3) -> void:
		pass

class GpuFixture extends DeviceStub:
	func _seed_regolith() -> void:
		pass
	func _seed(_name: String, _values: PackedFloat32Array) -> void:
		pass
	func _upload_mirror(_name: String) -> void:
		pass
	func seed_field(_name: String, _seal: Object) -> void:
		pass
	func mark_h_dirty() -> void:
		pass
	func derive_seeded(_initial: bool) -> void:
		pass

class ReadyStub extends RefCounted:
	var _gpu: DeviceStub = DeviceStub.new()
	var _use_gpu: bool = true
	var _ready_sim: bool = false


func run_test(_tree: SceneTree) -> bool:
	var readiness: ReadyStub = ReadyStub.new()
	if Snapshot.is_ready(readiness):
		push_error("unseeded field is available to snapshots")
		return false
	readiness._ready_sim = true
	if not Snapshot.is_ready(readiness):
		return false
	var field = FieldFixture.new()
	field._grid = GridFixture.new()
	field._grid.build(1, 2, 1, 1.0, Vector3.ZERO)
	field._cell_count = 2
	field._solid = PackedByteArray([1, 0])
	field._rock_fraction = PackedFloat32Array([1.0, 0.0])
	field._water_fraction = PackedFloat32Array([0.0, 0.0])
	field._surface_depth = PackedFloat32Array([0.5, -0.5])
	field._regolith = PackedByteArray([0, 0])
	field._t_rock = PackedFloat32Array([20.0, 20.0])
	field._pivot = Vector3.ZERO
	field._sea_radius = 1.0
	field._gravity = GravityFixture.new()
	field._mirrors = LAFieldMirrors.new()
	field._mirrors.alloc(PackedStringArray(LAChannels.rows().keys()), 2)
	field._mirrors.set_array("silicate", PackedFloat32Array([LASubstances.full_mol_m3("silicate"), 0.0]))
	var job = LAFieldSeedJob3D.new()
	var expected = job.capture(field, false)
	var gravity: PackedFloat32Array = PackedFloat32Array([0, 0, 0, 0, 0, 0])
	var balance: Dictionary = expected.run(gravity, false)
	if balance.is_empty():
		return false
	field._grid.set_open(false)
	var started: int = Time.get_ticks_msec()
	var began: bool = job.begin(field, gravity, false)
	var asynchronous: bool = Time.get_ticks_msec() - started < 1000 and not job.finished()
	field._grid.set_open(true)
	if not began or not asynchronous:
		push_error("native seed calculation blocked its caller")
		return false
	var before: PackedFloat32Array = field._mirrors.array("e_lith_j_m3")
	var deadline: int = Time.get_ticks_msec() + 2000
	while not job.finished() and Time.get_ticks_msec() < deadline:
		OS.delay_msec(1)
	if not job.finished():
		push_error("native seed worker did not finish")
		return false
	if field._mirrors.array("e_lith_j_m3") != before:
		push_error("worker mutated live field before publication")
		return false
	var actual: Dictionary = job.publish(field)
	var ok: bool = not actual.is_empty()
	for key in balance:
		ok = actual.get(key) == balance[key] and ok
	for name in field._mirrors.names():
		ok = field._mirrors.array(name) == expected._mirrors.array(name) and ok
	ok = field._seal.amounts == expected._seal.amounts and ok
	ok = field._seal.amounts.has("seed_energy_j") and ok
	ok = job.publish(field).is_empty() and ok
	for stage in range(3):
		ok = not job.complete(field, false) and ok
		ok = not Snapshot.is_ready(field) and ok
	ok = job.complete(field, false) and Snapshot.is_ready(field) and ok
	if not ok:
		push_error("worker seed differs from synchronous native seed, lost accounting")
	return ok

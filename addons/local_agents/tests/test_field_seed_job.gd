extends RefCounted

const Snapshot: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldSnapshot3D.gd")

class GridFixture extends LAVoxelGrid:
	var gate: Mutex = Mutex.new()
	var open: bool = true
	var entered: bool = false
	var volume_reads: int = 0

	func set_open(value: bool) -> void:
		gate.lock()
		if not value:
			entered = false
			volume_reads = 0
		open = value
		gate.unlock()

	func is_open() -> bool:
		gate.lock()
		var value: bool = open
		gate.unlock()
		return value

	func has_entered() -> bool:
		gate.lock()
		var result: bool = entered
		gate.unlock()
		return result

	func cell_volumes() -> PackedFloat32Array:
		gate.lock()
		volume_reads += 1
		gate.unlock()
		return super.cell_volumes()

	func cell_edges() -> PackedFloat32Array:
		gate.lock()
		entered = true
		gate.unlock()
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
	var accept: bool = true

	func note_creation(what: String, amount: float) -> bool:
		if not accept:
			return false
		amounts[what] = float(amounts.get(what, 0.0)) + amount
		return true

class DeviceStub extends RefCounted:
	var _rd: RefCounted = RefCounted.new()

class MeasureFixture extends RefCounted:
	func measure(_field: Object, _axis: Vector3) -> void:
		pass

class GpuFixture extends DeviceStub:
	var reject_derive: bool = false
	var rejected: bool = false
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
		rejected = reject_derive
	func refused(_what: String) -> bool:
		return rejected

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
	field._ready_sim = false
	field._body_measure = null
	var bodyless = LAFieldSeedJob3D.new()
	ok = bodyless.begin(field, gravity, false) and _wait(bodyless) and ok
	for stage in range(3):
		ok = not bodyless.complete(field, false) and not field._ready_sim and ok
	ok = bodyless.complete(field, false) and field._ready_sim and ok
	field._ready_sim = false
	ok = LAFieldSeedJob3D.finish_restore(field, false) and ok
	field._body_measure = MeasureFixture.new()
	field._seal.accept = false
	var refused = LAFieldSeedJob3D.new()
	ok = refused.begin(field, gravity, false) and ok
	ok = _wait(refused) and ok
	ok = refused.publish(field).is_empty() and ok
	for stage in range(5):
		ok = not refused.complete(field, false) and not field._ready_sim and ok
	ok = refused.failed() and ok
	field._seal.accept = true
	var cancelled = LAFieldSeedJob3D.new()
	field._grid.set_open(false)
	ok = cancelled.begin(field, gravity, false) and ok
	deadline = Time.get_ticks_msec() + 1000
	while not field._grid.has_entered() and Time.get_ticks_msec() < deadline:
		OS.delay_msec(1)
	ok = field._grid.has_entered() and ok
	cancelled.cancel()
	field._grid.set_open(true)
	ok = _wait(cancelled) and ok
	ok = field._grid.volume_reads == 0 and ok
	ok = cancelled.failed() and cancelled.publish(field).is_empty() and ok
	ok = not cancelled.complete(field, false) and not field._ready_sim and ok
	ok = LAFieldSeedJob3D.finish_restore(field, false) and ok
	field._gpu.reject_derive = true
	ok = not LAFieldSeedJob3D.finish_restore(field, false) and not field._ready_sim and ok
	field._gpu.rejected = false
	var device_refusal = LAFieldSeedJob3D.new()
	ok = device_refusal.begin(field, gravity, false) and ok
	ok = _wait(device_refusal) and ok
	for stage in range(5):
		ok = not device_refusal.complete(field, false) and not field._ready_sim and ok
	ok = device_refusal.failed() and ok
	var stepper = LAMaterialFieldSphereStep3D.new()
	stepper._f = field
	var seed_loop: LASimLoop = LASimLoop.new()
	_tree.root.add_child(seed_loop)
	seed_loop.set_physics_process(false)
	field.set_meta(stepper.FILL_META, {"pressure_pa": 101325.0})
	ok = not stepper.seed_tick() and seed_loop.failure == "SEED_GAS_FILL_INVALID" and ok
	ok = not field._ready_sim and seed_loop.step_index() == 0 and ok
	seed_loop.free()
	field.remove_meta(stepper.FILL_META)
	var fill: Dictionary = {"mole_fractions": {"n2": 1.0}, "pressure_pa": 101325.0}
	var reordered: Dictionary = {"pressure_pa": 101325.0, "mole_fractions": {"n2": 1.0}}
	var changed: Dictionary = {"mole_fractions": {"n2": 1.0}, "pressure_pa": 101325.000000001}
	ok = LAFieldFill.cache_key("fixture", fill, LABodySeeds.surface_temp_c()) == LAFieldFill.cache_key("fixture", reordered, LABodySeeds.surface_temp_c()) and ok
	ok = LAFieldFill.cache_key("fixture", fill, LABodySeeds.surface_temp_c()) != LAFieldFill.cache_key("fixture", changed, LABodySeeds.surface_temp_c()) and ok
	if not ok:
		push_error("worker seed publication, cancellation, device refusal or accounting failed")
	return ok


func _wait(job) -> bool:
	var deadline: int = Time.get_ticks_msec() + 2000
	while not job.finished() and Time.get_ticks_msec() < deadline:
		OS.delay_msec(1)
	return job.finished()

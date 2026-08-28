extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## GRAVITY SOLVED FROM THE MASS THAT IS THERE, on the device. Poisson relaxed by Jacobi sweeps over the
## cell's own faces, then g = -grad(phi). First in the chain: everything below it asks where down is.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/gravity_poisson.glsl"

## Field steps between solves. The solve warm-starts from the previous potential.
const SOLVE_EVERY: int = 2
## Residual, as a fraction of its own source, every solve converges to, and the iterations it may take.
const RESIDUAL_TOLERANCE: float = 1.0e-4
const MAX_ITERATIONS: int = 20000

## Floats each workgroup writes into the partials buffer — gravity_poisson.glsl PART_STRIDE.
const PART_STRIDE: int = 10
## gravity_poisson.glsl `moments`: 0 mass · 1..3 centre of mass · 4 mean |g| · 6 Gauss ratio.
const MOMENT_SLOTS: int = 7
const GROUP: int = 64
const PC_BYTES: int = 36

const MODE_FLAGS: int = 0
const MODE_DENSITY: int = 1
const MODE_MOMENTS: int = 2
const MODE_SEED: int = 3
const MODE_GRADIENT: int = 5
const MODE_FIELD_STATS: int = 7
const MODE_VERT_UP: int = 9
const MODE_VERT_DOWN: int = 10
const MODE_VERT_DOWN_KEY: int = 11
## The device's half of a solve: before the native solve, and after it.
const PRE_MODES: Array = [MODE_FLAGS, MODE_DENSITY, MODE_MOMENTS, MODE_SEED]
const POST_MODES: Array = [MODE_GRADIENT, MODE_VERT_UP, MODE_VERT_DOWN, MODE_VERT_DOWN_KEY, MODE_FIELD_STATS]

const PHI: String = "grav_phi"
const REF: String = "grav_ref"
const DENSITY: String = "grav_density"
const FLAGS: String = "grav_cellflag"
const MOMENTS: String = "grav_moments"
const PARTIALS: String = "grav_partials"
## The one vertical relation, published for every march in the tree. Inverse by construction.
const VERT_UP: String = "vert_up"
const VERT_DOWN: String = "vert_down"

var _pipe: RID = RID()
var _set: RID = RID()
var _moments: RID = RID()
var _gravity: RID = RID()
var _up_rid: RID = RID()
var _down_rid: RID = RID()
var _groups: int = 0
var _flagged: bool = false              # the boundary map is a property of the grid, built once
var _solves: int = 0
var _read_due: bool = false             # a solve is in flight; the next drain publishes it
var _mirror: PackedFloat32Array = PackedFloat32Array()
var _up: PackedInt32Array = PackedInt32Array()
var _down: PackedInt32Array = PackedInt32Array()
var _mean_g: float = 0.0
var _residual_rel: float = INF          # until a solve has been drained, the field is not answerable
var _last: Dictionary = {}              # what the last drain published; the step's report reads it
var _failed_announced: bool = false
## SLICE: centre xyz, radius, mass of the declared body. Empty = solve Poisson from the grid's own mass.
var _slab: bool = false                  # a slab carries the declared body's field, uploaded once
var _phi_rid: RID = RID()
var _iterations: int = 0
var _density_rid: RID = RID()
var _flags_rid: RID = RID()
var _base_edge: float = 0.0
var _origin: Vector3 = Vector3.ZERO


func _buffers(cc: int) -> Dictionary:
	var g: int = maxi(int(ceil(float(cc) / float(GROUP))), 1)
	# PHI is StateDerivePass's declaration: it weighs a cell's potential energy at rungs below this pass.
	return {
		DENSITY: maxi(cc, 1),
		FLAGS: maxi(cc, 1),
		MOMENTS: MOMENT_SLOTS,
		VERT_UP: maxi(cc, 1),
		VERT_DOWN: maxi(cc, 1),
		PARTIALS: g * PART_STRIDE}


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	if not _pipe.is_valid():
		return
	_groups = maxi(int(ceil(float(cc) / float(GROUP))), 1)
	_base_edge = grid_cell_size
	_origin = grid_origin
	var channels: PackedStringArray = LAMatterChannels.CHANNELS
	if channels.size() != LAMatterChannels.KERNEL_SLOTS:
		push_error("GravityPass: LAMatterChannels lists %d channels and matter_channels.glsli switches "
			% channels.size() + "on %d, so a substance would gravitate with no mass."
			% LAMatterChannels.KERNEL_SLOTS)
		return
	var props: PackedFloat32Array = LAMatterChannels.molar_masses()
	if props.size() != channels.size():
		return
	var props_ssbo: RID = _storage_buffer(props.to_byte_array())

	var want: PackedStringArray = channels.duplicate()
	want.append_array(PackedStringArray(["nbr", "pos", "gravity", PHI, DENSITY, FLAGS, MOMENTS, PARTIALS,
		VERT_UP, VERT_DOWN, REF, "slot_off", "face_partner", "cell_edge"]))
	var missing: PackedStringArray = LAMatterChannels.absent(bufs, want)
	if not missing.is_empty():
		push_error("GravityPass: no buffer for %s, so no cell would get a gravity."
			% String(", ").join(missing))
		return
	_moments = _single(bufs, MOMENTS)
	_phi_rid = _single(bufs, PHI)
	_density_rid = _single(bufs, DENSITY)
	_flags_rid = _single(bufs, FLAGS)
	_gravity = _single(bufs, "gravity")
	_up_rid = _single(bufs, VERT_UP)
	_down_rid = _single(bufs, VERT_DOWN)

	var entries: Array = []
	for i in channels.size():
		entries.append([LAMatterChannels.binding_of(i), _single(bufs, channels[i])])
	entries.append([14, props_ssbo])
	entries.append([15, _single(bufs, "nbr")])
	entries.append([16, _single(bufs, "pos")])
	entries.append([17, _single(bufs, FLAGS)])
	entries.append([18, _single(bufs, PHI)])
	entries.append([19, _single(bufs, DENSITY)])
	entries.append([20, _gravity])
	entries.append([21, _moments])
	entries.append([22, _single(bufs, PARTIALS)])
	entries.append([23, _single(bufs, VERT_UP)])
	entries.append([24, _single(bufs, VERT_DOWN)])
	entries.append([92, _single(bufs, "slot_off")])
	entries.append([93, _single(bufs, "face_partner")])
	entries.append([94, _single(bufs, "cell_edge")])
	entries.append([95, _single(bufs, REF)])
	_set = _uset(_pipe, entries)


func dispatch(_rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	ctx["gravity_self"] = 1.0 if _slab else 0.5
	if not _dispatchable() or not _set.is_valid():
		if not _failed_announced:
			_failed_announced = true
			push_error("GPU_REQUIRED: GravityPass has no pipeline, so gravity is never solved and every "
				+ "`above`/`below` read in the tree points nowhere. Usual cause: gravity_poisson.glsl was "
				+ "never imported — run `godot --headless --path . --import` in this worktree.")
		return
	if _slab:
		return
	# Only solve_converged dispatches; it owns the sequence around the native solve.
	var phase: String = String(ctx.get("gravity_solve", ""))
	if phase == "":
		return
	var plan: Array = []
	var modes: Array = PRE_MODES if phase == "pre" else POST_MODES
	for m in modes:
		if m == MODE_FLAGS and _flagged:
			continue
		plan.append([m, 0, 1 if m == MODE_MOMENTS or m == MODE_FIELD_STATS else groups])
	if phase == "pre":
		_flagged = true
	else:
		_solves += 1
		_read_due = true
	_issue(cl, plan, cc)


## THE SOLVE, CONVERGED: density, moments and the Dirichlet ring on the device; the potential by
## conjugate gradient in the extension over the same operator; gradient, verticals and residual on the
## device again. Returns the residual the device measured, or INF when nothing could be solved.
func solve_converged(rd: RenderingDevice, grid, cc: int, groups: int) -> float:
	if not _dispatchable() or not _set.is_valid() or _slab or grid == null:
		return INF
	var ctx: Dictionary = {"gravity_solve": "pre"}
	var cl: int = rd.compute_list_begin()
	dispatch(rd, cl, ctx, cc, groups)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var r: Dictionary = LAGravitySolve.solve_device(rd, grid, _density_rid, _phi_rid, _flags_rid,
		_moments, LAPhysical.GRAVITATIONAL_CONSTANT, RESIDUAL_TOLERANCE, MAX_ITERATIONS)
	if r.is_empty():
		return INF
	_iterations = int(r["iterations"])
	ctx["gravity_solve"] = "post"
	cl = rd.compute_list_begin()
	dispatch(rd, cl, ctx, cc, groups)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	_drain(rd)
	# The solve's own residual, in double over the full potential: the device holds only the deviation.
	_residual_rel = float(r["residual_rel"])
	_last["gravity_residual_rel"] = _residual_rel
	_last["gravity_cg_iterations"] = float(_iterations)
	return _residual_rel


## SLICE ONLY, once at the seed, after the body's field is uploaded: the vertical relation and |g| stats.
func dispatch_slab(_rd: RenderingDevice, cl: int, cc: int, groups: int) -> void:
	_slab = true
	if not _dispatchable() or not _set.is_valid():
		return
	_issue(cl, [[MODE_VERT_UP, 0, groups], [MODE_VERT_DOWN, 0, groups],
		[MODE_VERT_DOWN_KEY, 0, groups], [MODE_FIELD_STATS, 0, 1]], cc)
	_solves += 1
	_read_due = true


## One mode per entry, each followed by a barrier: a sweep reads what the sweep before it wrote.
func _issue(cl: int, plan: Array, cc: int) -> void:
	var pcs: Array = []
	var wgs: PackedInt32Array = PackedInt32Array()
	var args: Array = []
	var offs: PackedInt32Array = PackedInt32Array()
	for e: Array in plan:
		pcs.append(_push(int(e[0]), int(e[1]), cc))
		wgs.append(int(e[2]))
		args.append(RID())
		offs.append(0)
	_driver.run(cl, _pipe, [_set], pcs, wgs, args, offs, true)


func _push(mode: int, colour: int, cc: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(PC_BYTES)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, mode)
	pc.encode_u32(8, colour)
	pc.encode_u32(12, _groups)
	pc.encode_float(16, LAPhysical.GRAVITATIONAL_CONSTANT)
	pc.encode_float(20, _base_edge)
	pc.encode_float(24, _origin.x)
	pc.encode_float(28, _origin.y)
	pc.encode_float(32, _origin.z)
	return pc


## Read at the drain, and only on the steps a solve ran: g changes nowhere else.
func _drain(rd: RenderingDevice) -> Dictionary:
	if not _read_due or not _moments.is_valid():
		return _last
	_read_due = false
	var m: PackedFloat32Array = rd.buffer_get_data(_moments).to_float32_array()
	if m.size() < MOMENT_SLOTS:
		return {}
	_mean_g = m[4]
	_mirror = rd.buffer_get_data(_gravity).to_float32_array()
	_up = rd.buffer_get_data(_up_rid).to_int32_array()
	_down = rd.buffer_get_data(_down_rid).to_int32_array()
	_last = {
		"gravity_total_mass_kg": m[0],
		"gravity_mean_g": m[4],
		"gravity_residual_rel": _residual_rel,
		"gravity_cg_iterations": float(_iterations),
		"gravity_gauss_rel": m[6],
		"gravity_solves": float(_solves)}
	return _last


## Solved acceleration, flat cell*3, m/s^2. Empty until the first drain after the first solve.
func mirror() -> PackedFloat32Array:
	return _mirror


## THE ONE VERTICAL RELATION. `up_table` is the neighbour against gravity, `down_table` its scattered
## inverse; -1 where the march leaves the box, empty until the first drain.
func up_table() -> PackedInt32Array:
	return _up


func down_table() -> PackedInt32Array:
	return _down


## Mean |g| over the cells where gravity does not vanish, m/s^2.
func mean_g() -> float:
	return _mean_g


## Worst |laplacian(phi) - 4 pi G rho| over the source term: dimensionless, INF before the first drain.
func residual_rel() -> float:
	return _residual_rel

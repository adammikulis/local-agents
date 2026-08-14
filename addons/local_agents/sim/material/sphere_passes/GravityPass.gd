extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## GRAVITY SOLVED FROM THE MASS THAT IS THERE, on the device. Poisson relaxed red-black, one dispatch per
## colour, then g = -grad(phi) into the buffer every kernel already reads to know which way is down.
## First in the chain: everything below it asks where down is.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/gravity_poisson.glsl"

## Field steps between solves. The solve warm-starts from the previous potential.
const SOLVE_EVERY: int = 8
## Red-black sweeps per dispatch. Poisson is elliptic, so a fixed count is not a solve: the SEEDING solve
## relaxes until `residual_rel` falls, and the per-step solves track a warm-started field from there.
const SWEEPS: int = 8

## Floats each workgroup writes into the partials buffer — gravity_poisson.glsl PART_STRIDE.
const PART_STRIDE: int = 9
## gravity_poisson.glsl `moments`: 0 mass · 1..3 centre of mass · 4 mean |g| · 5 residual · 6 Gauss ratio.
const MOMENT_SLOTS: int = 7
const GROUP: int = 64
const PC_BYTES: int = 32

const MODE_FLAGS: int = 0
const MODE_DENSITY: int = 1
const MODE_MOMENTS: int = 2
const MODE_SEED: int = 3
const MODE_RELAX: int = 4
const MODE_GRADIENT: int = 5
const MODE_RESIDUAL: int = 6
const MODE_FIELD_STATS: int = 7

const PHI: String = "grav_phi"
const DENSITY: String = "grav_density"
const FLAGS: String = "grav_cellflag"
const MOMENTS: String = "grav_moments"
const PARTIALS: String = "grav_partials"

var _pipe: RID = RID()
var _set: Array = [RID(), RID()]        # one uniform set per ping-pong parity
var _moments: RID = RID()
var _gravity: RID = RID()
var _groups: int = 0
var _nx: int = 0
var _nxny: int = 0
var _flagged: bool = false              # the boundary/colour map is a property of the grid, so it is built once
var _solves: int = 0
var _read_due: bool = false             # a solve is in flight; the next drain publishes it
var _mirror: PackedFloat32Array = PackedFloat32Array()
var _mean_g: float = 0.0
var _residual_rel: float = INF          # until a solve has been drained, the field is not answerable
var _failed_announced: bool = false


func _buffers(cc: int) -> Dictionary:
	var g: int = maxi(int(ceil(float(cc) / float(GROUP))), 1)
	return {
		PHI: maxi(cc, 1),
		DENSITY: maxi(cc, 1),
		FLAGS: maxi(cc, 1),
		MOMENTS: MOMENT_SLOTS,
		PARTIALS: g * PART_STRIDE}


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	if not _pipe.is_valid():
		return
	_groups = maxi(int(ceil(float(cc) / float(GROUP))), 1)
	var channels: PackedStringArray = LAMatterChannels.CHANNELS
	if channels.size() != LAMatterChannels.KERNEL_SLOTS:
		push_error("GravityPass: LAMatterChannels lists %d channels and matter_channels.glsli switches "
			% channels.size() + "on %d, so a substance would gravitate with no mass."
			% LAMatterChannels.KERNEL_SLOTS)
		return
	var props: PackedFloat32Array = LAMatterChannels.rho_units()
	if props.size() != channels.size():
		return
	var props_ssbo: RID = _storage_buffer(props.to_byte_array())

	var want: PackedStringArray = channels.duplicate()
	want.append_array(PackedStringArray(["nbr", "pos", "gravity", PHI, DENSITY, FLAGS, MOMENTS, PARTIALS]))
	var missing: PackedStringArray = LAMatterChannels.absent(bufs, want)
	if not missing.is_empty():
		push_error("GravityPass: no buffer for %s, so no cell would get a gravity."
			% String(", ").join(missing))
		return
	if not _read_strides(bufs):
		return
	_moments = _single(bufs, MOMENTS)
	_gravity = _single(bufs, "gravity")

	for p in 2:
		var entries: Array = []
		for i in channels.size():
			entries.append([i, _half(bufs, channels[i], p, false)])
		entries.append([14, props_ssbo])
		entries.append([15, _single(bufs, "nbr")])
		entries.append([16, _single(bufs, "pos")])
		entries.append([17, _single(bufs, FLAGS)])
		entries.append([18, _single(bufs, PHI)])
		entries.append([19, _single(bufs, DENSITY)])
		entries.append([20, _gravity])
		entries.append([21, _moments])
		entries.append([22, _single(bufs, PARTIALS)])
		_set[p] = _uset(_pipe, entries)


## The grid's index layout, read off cell 0's own neighbour row: +Y lands nx away, +Z lands nx*ny away.
func _read_strides(bufs: Dictionary) -> bool:
	var head: PackedInt32Array = _rd.buffer_get_data(_single(bufs, "nbr"), 0, 6 * 4).to_int32_array()
	if head.size() < 6:
		return false
	_nx = head[LAVoxelGrid.S_POS_Y]
	_nxny = head[LAVoxelGrid.S_POS_Z]
	if _nx <= 0 or _nxny <= _nx or _nxny % _nx != 0:
		push_error(("GravityPass: cell 0's neighbour row gives nx=%d and nx*ny=%d, so the red-black "
			+ "colouring cannot be derived and the solve would relax adjacent cells together.")
			% [_nx, _nxny])
		return false
	return true


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set[parity].is_valid():
		if not _failed_announced:
			_failed_announced = true
			push_error("GPU_REQUIRED: GravityPass has no pipeline, so gravity is never solved and every "
				+ "`above`/`below` read in the tree points nowhere. Usual cause: gravity_poisson.glsl was "
				+ "never imported — run `godot --headless --path . --import` in this worktree.")
		return
	var step: int = int(_ctx_num(ctx, "step_index"))
	if step % SOLVE_EVERY != 0:
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipe)
	rd.compute_list_bind_uniform_set(cl, _set[parity], 0)
	var cell_m: float = _ctx_cell_size(ctx)
	if not _flagged:
		_flagged = true
		_run(rd, cl, MODE_FLAGS, 0, cc, cell_m, groups)
	_run(rd, cl, MODE_DENSITY, 0, cc, cell_m, groups)
	_run(rd, cl, MODE_MOMENTS, 0, cc, cell_m, 1)
	_run(rd, cl, MODE_SEED, 0, cc, cell_m, groups)
	for _s in SWEEPS:
		for colour in 2:
			_run(rd, cl, MODE_RELAX, colour, cc, cell_m, groups)
	_run(rd, cl, MODE_GRADIENT, 0, cc, cell_m, groups)
	_run(rd, cl, MODE_RESIDUAL, 0, cc, cell_m, groups)
	_run(rd, cl, MODE_FIELD_STATS, 0, cc, cell_m, 1)
	_solves += 1
	_read_due = true


## One mode, then a barrier: a colour reads what the other colour just wrote.
func _run(rd: RenderingDevice, cl: int, mode: int, colour: int, cc: int, cell_m: float, groups: int) -> void:
	var pc: PackedByteArray = _push(mode, colour, cc, cell_m)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, groups, 1, 1)
	rd.compute_list_add_barrier(cl)


func _push(mode: int, colour: int, cc: int, cell_m: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(PC_BYTES)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, mode)
	pc.encode_u32(8, colour)
	pc.encode_u32(12, _groups)
	pc.encode_float(16, cell_m)
	pc.encode_float(20, LAPhysical.GRAVITATIONAL_CONSTANT)
	pc.encode_u32(24, _nx)
	pc.encode_u32(28, _nxny)
	return pc


## Read at the drain, and only on the steps a solve ran: g changes nowhere else.
func _drain(rd: RenderingDevice) -> Dictionary:
	if not _read_due or not _moments.is_valid():
		return {}
	_read_due = false
	var m: PackedFloat32Array = rd.buffer_get_data(_moments).to_float32_array()
	if m.size() < MOMENT_SLOTS:
		return {}
	_mean_g = m[4]
	_residual_rel = m[5]
	_mirror = rd.buffer_get_data(_gravity).to_float32_array()
	return {
		"gravity_total_mass_kg": m[0],
		"gravity_mean_g": m[4],
		"gravity_residual_rel": m[5],
		"gravity_gauss_rel": m[6],
		"gravity_solves": float(_solves)}


## Solved acceleration, flat cell*3, m/s^2. Empty until the first drain after the first solve.
func mirror() -> PackedFloat32Array:
	return _mirror


## Mean |g| over the cells where gravity does not vanish, m/s^2.
func mean_g() -> float:
	return _mean_g


## Worst |laplacian(phi) - 4 pi G rho| as a fraction of the source term. Dimensionless, so a small value
## means the discrete Poisson equation is satisfied rather than that G is small. INF before the first drain.
func residual_rel() -> float:
	return _residual_rel

extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## GRAVITY SOLVED FROM THE MASS THAT IS THERE, on the device. Poisson relaxed by Jacobi sweeps over the
## cell's own faces, then g = -grad(phi). First in the chain: everything below it asks where down is.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/gravity_poisson.glsl"

## Field steps between solves. The solve warm-starts from the previous potential.
const SOLVE_EVERY: int = 2
## Sweeps per dispatch. Poisson is elliptic, so the seeding solve relaxes until `residual_rel` falls and
## the per-step solves track a warm-started field.
const SWEEPS: int = 128   # LA_APPROX: fixed_sweep_relaxation

## Floats each workgroup writes into the partials buffer — gravity_poisson.glsl PART_STRIDE.
const PART_STRIDE: int = 10
## gravity_poisson.glsl `moments`: 0 mass · 1..3 centre of mass · 4 mean |g| · 5 residual · 6 Gauss ratio.
const MOMENT_SLOTS: int = 7
const GROUP: int = 64
const PC_BYTES: int = 44

const MODE_FLAGS: int = 0
const MODE_DENSITY: int = 1
const MODE_MOMENTS: int = 2
const MODE_SEED: int = 3
const MODE_RELAX: int = 4
const MODE_GRADIENT: int = 5
const MODE_RESIDUAL: int = 6
const MODE_FIELD_STATS: int = 7
const MODE_MONOPOLE: int = 8
const MODE_VERT_UP: int = 9
const MODE_VERT_DOWN: int = 10
const MODE_APPLY: int = 11

const PHI: String = "grav_phi"
const PHI_NEXT: String = "grav_phi_next"
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
var _failed_announced: bool = false
## SLICE: centre xyz, radius, mass of the declared body. Empty = solve Poisson from the grid's own mass.
var _mono: PackedFloat32Array = PackedFloat32Array()


func _buffers(cc: int) -> Dictionary:
	var g: int = maxi(int(ceil(float(cc) / float(GROUP))), 1)
	# PHI is StateDerivePass's declaration: it weighs a cell's potential energy at rungs below this pass.
	return {
		DENSITY: maxi(cc, 1),
		FLAGS: maxi(cc, 1),
		MOMENTS: MOMENT_SLOTS,
		VERT_UP: maxi(cc, 1),
		VERT_DOWN: maxi(cc, 1),
		PHI_NEXT: maxi(cc, 1),
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
	var props: PackedFloat32Array = LAMatterChannels.molar_masses()
	if props.size() != channels.size():
		return
	var props_ssbo: RID = _storage_buffer(props.to_byte_array())

	var want: PackedStringArray = channels.duplicate()
	want.append_array(PackedStringArray(["nbr", "pos", "gravity", PHI, DENSITY, FLAGS, MOMENTS, PARTIALS,
		VERT_UP, VERT_DOWN, PHI_NEXT, "slot_off", "face_partner", "cell_edge"]))
	var missing: PackedStringArray = LAMatterChannels.absent(bufs, want)
	if not missing.is_empty():
		push_error("GravityPass: no buffer for %s, so no cell would get a gravity."
			% String(", ").join(missing))
		return
	_moments = _single(bufs, MOMENTS)
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
	entries.append([25, _single(bufs, PHI_NEXT)])
	entries.append([92, _single(bufs, "slot_off")])
	entries.append([93, _single(bufs, "face_partner")])
	entries.append([94, _single(bufs, "cell_edge")])
	_set = _uset(_pipe, entries)


func dispatch(_rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	ctx["gravity_self"] = 1.0 if not _mono.is_empty() else 0.5
	if not _dispatchable() or not _set.is_valid():
		if not _failed_announced:
			_failed_announced = true
			push_error("GPU_REQUIRED: GravityPass has no pipeline, so gravity is never solved and every "
				+ "`above`/`below` read in the tree points nowhere. Usual cause: gravity_poisson.glsl was "
				+ "never imported — run `godot --headless --path . --import` in this worktree.")
		return
	# The declared-monopole field is static: written once at the seed, never re-solved.
	if not _mono.is_empty():
		return
	var step: int = int(_ctx_num(ctx, "step_index"))
	if step % SOLVE_EVERY != 0:
		return
	var plan: Array = []
	if not _flagged:
		_flagged = true
		plan.append([MODE_FLAGS, 0, groups])
	plan.append([MODE_DENSITY, 0, groups])
	plan.append([MODE_MOMENTS, 0, 1])
	plan.append([MODE_SEED, 0, groups])
	for _s in SWEEPS:
		plan.append([MODE_RELAX, 0, groups])
		plan.append([MODE_APPLY, 0, groups])
	plan.append([MODE_GRADIENT, 0, groups])
	plan.append([MODE_VERT_UP, 0, groups])
	plan.append([MODE_VERT_DOWN, 0, groups])
	plan.append([MODE_RESIDUAL, 0, groups])
	plan.append([MODE_FIELD_STATS, 0, 1])
	_issue(cl, plan, cc)
	_solves += 1
	_read_due = true


## SLICE ONLY: the declared body the analytic field points at, set before the seed dispatch.
func set_monopole(centre: Vector3, r_body: float, m_kg: float) -> void:
	_mono = PackedFloat32Array([centre.x, centre.y, centre.z, r_body, m_kg])


## SLICE ONLY, once at the seed: write the declared body's monopole and its mean-|g| stats.
func dispatch_monopole(_rd: RenderingDevice, cl: int, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set.is_valid() or _mono.is_empty():
		return
	# The one vertical relation reads the gravity the monopole just wrote.
	_issue(cl, [[MODE_MONOPOLE, 0, groups], [MODE_VERT_UP, 0, groups], [MODE_VERT_DOWN, 0, groups],
		[MODE_FIELD_STATS, 0, 1]], cc)
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


func _push(mode: int, _colour: int, cc: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(PC_BYTES)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, mode)
	pc.encode_u32(8, _groups)
	pc.encode_float(12, LAPhysical.GRAVITATIONAL_CONSTANT)
	for i in 5:
		pc.encode_float(16 + i * 4, _mono[i] if i < _mono.size() else 0.0)
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
	_up = rd.buffer_get_data(_up_rid).to_int32_array()
	_down = rd.buffer_get_data(_down_rid).to_int32_array()
	return {
		"gravity_total_mass_kg": m[0],
		"gravity_mean_g": m[4],
		"gravity_residual_rel": m[5],
		"gravity_gauss_rel": m[6],
		"gravity_solves": float(_solves)}


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

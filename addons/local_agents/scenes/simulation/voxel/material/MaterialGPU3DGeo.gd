class_name LAMaterialGPU3DGeo
extends RefCounted

## GEOLOGICAL-tail GPU passes for LAMaterialGPU3D, extracted so the hot backend file stays under the size
## gate (the MaterialGPU3DPush precedent — a sibling module the backend calls into). Owns the per-cell CORES
## of the three slow geological field modules, each split exactly like LAVA (per-cell mass/flow math on GPU;
## the SDF/solid-mask geometry stamps stay a capped CPU tail):
##   EROSION  — erosion_deposit3d (deposit/settle suspended sediment on the fresh water flow) + erosion_advect3d
##              (gather-advect the suspended load downhill). The rock CARVE (SDF) stays MaterialErosion3D's tail.
##   SNOWICE  — snowice3d (per-column snowpack accrete/melt -> meltwater). The water FREEZE/THAW (SDF + solid
##              mask) stays MaterialSnowIce3D's tail.
##   MAGMA    — magma_buoy3d (two-pass buoyant overpressure up-flow of lava). The conduit PRESSURE-MELT (SDF +
##              solid mask) + deep-source feed stay MaterialMagma3D's tail.
##
## This module holds its OWN pipelines + resident buffers + ping-pong uniform sets; it shares the backend's
## RenderingDevice, masks (solid) + resident fields (water/sediment/temp/lava) by reaching into the passed
## backend `g` (g._rd, g.live_buffer/back_buffer, g._buf_solid, g._make_uniform, g._pipeline, ...). The new
## channels susp (erosion, ping-pong) + snow (snowice, per-column single) round-trip through the backend's
## set_field/end_frame via upload_/download_ here. (Explicit types only — no ':=' inferred typing.)

const EROSION_DEPOSIT_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/erosion_deposit3d.glsl"
const EROSION_ADVECT_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/erosion_advect3d.glsl"
const SNOWICE_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/snowice3d.glsl"
const MAGMA_BUOY_PATH: String = "res://addons/local_agents/scenes/simulation/voxel/material/kernels3d/magma_buoy3d.glsl"

# Push-constant encoders live in the shared Push module (dims_pc / fungus_pc / water_pc reused).
const Push: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/material/MaterialGPU3DPush.gd")

var _erosion_deposit_pipeline: RID = RID()
var _erosion_advect_pipeline: RID = RID()
var _snowice_pipeline: RID = RID()
var _magma_buoy_pipeline: RID = RID()

# Resident buffers OWNED here. susp = suspended sediment (ping-pong, advect is a gather). snow = per-column
# snowpack depth (single, in place). lava_scratch = magma buoy snapshot (single scratch).
var _buf_susp_a: RID = RID()
var _buf_susp_b: RID = RID()
var _buf_snow: RID = RID()
var _buf_lava_scratch: RID = RID()

var _erosion_deposit_set: Array[RID] = [RID(), RID()]
var _erosion_advect_set: Array[RID] = [RID(), RID()]
var _snowice_set: Array[RID] = [RID(), RID()]
var _magma_buoy_set: Array[RID] = [RID(), RID()]


## Compile the pipelines, size the resident buffers, and build the two ping-pong uniform sets per kernel.
## Called from LAMaterialGPU3D.setup() AFTER the backend's own _ensure_buffers (so g's fields/masks exist).
func setup(g) -> void:
	if g._rd == null or g._cell_count <= 0:
		return
	_erosion_deposit_pipeline = g._pipeline(EROSION_DEPOSIT_PATH)
	_erosion_advect_pipeline = g._pipeline(EROSION_ADVECT_PATH)
	_snowice_pipeline = g._pipeline(SNOWICE_PATH)
	_magma_buoy_pipeline = g._pipeline(MAGMA_BUOY_PATH)

	var zero: PackedFloat32Array = PackedFloat32Array()
	zero.resize(g._cell_count)
	var zbytes: PackedByteArray = zero.to_byte_array()
	_buf_susp_a = g._rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_susp_b = g._rd.storage_buffer_create(zbytes.size(), zbytes)
	_buf_lava_scratch = g._rd.storage_buffer_create(zbytes.size(), zbytes)
	# Snow is per-COLUMN (area = dim_x*dim_z).
	var area: int = g._dim_x * g._dim_z
	var col_zero: PackedFloat32Array = PackedFloat32Array()
	col_zero.resize(area)
	var col_bytes: PackedByteArray = col_zero.to_byte_array()
	_buf_snow = g._rd.storage_buffer_create(col_bytes.size(), col_bytes)

	# Register susp into the backend's ping-pong registry so live/back selection stays in lockstep with the
	# global parity flip (erosion_advect is a gather: reads live, writes back).
	g._fields["susp"] = [_buf_susp_a, _buf_susp_b]

	for p in [0, 1]:
		var susp_live: RID = g.live_buffer("susp", p)
		var susp_back: RID = g.back_buffer("susp", p)
		var water_back: RID = g.back_buffer("water", p)
		var sediment_live: RID = g.live_buffer("sediment", p)
		var temp_back: RID = g.back_buffer("temp", p)
		var lava_back: RID = g.back_buffer("lava", p)
		# Erosion DEPOSIT: 0=susp(live, rw in place), 1=sediment(live, += deposits), 2=water(back, post-flow), 3=solid.
		_erosion_deposit_set[p] = g._rd.uniform_set_create([
			g._make_uniform(0, susp_live), g._make_uniform(1, sediment_live),
			g._make_uniform(2, water_back), g._make_uniform(3, g._buf_solid)],
			g._shader_of(_erosion_deposit_pipeline), 0)
		# Erosion ADVECT (gather): 0=susp in(live, post-deposit), 1=susp out(back), 2=water(back), 3=solid.
		_erosion_advect_set[p] = g._rd.uniform_set_create([
			g._make_uniform(0, susp_live), g._make_uniform(1, susp_back),
			g._make_uniform(2, water_back), g._make_uniform(3, g._buf_solid)],
			g._shader_of(_erosion_advect_pipeline), 0)
		# Snow (per-column): 0=snow(single, in place), 1=temp(back post-heat), 2=water(back, += meltwater), 3=solid.
		_snowice_set[p] = g._rd.uniform_set_create([
			g._make_uniform(0, _buf_snow), g._make_uniform(1, temp_back),
			g._make_uniform(2, water_back), g._make_uniform(3, g._buf_solid)],
			g._shader_of(_snowice_pipeline), 0)
		# Magma buoy: 0=lava(back, rw), 1=scratch(single), 2=temp(back, carry-heat), 3=solid.
		_magma_buoy_set[p] = g._rd.uniform_set_create([
			g._make_uniform(0, lava_back), g._make_uniform(1, _buf_lava_scratch),
			g._make_uniform(2, temp_back), g._make_uniform(3, g._buf_solid)],
			g._shader_of(_magma_buoy_pipeline), 0)


# --- Per-frame channel round-trip (called from the backend's set_field / end_frame) ----------------

func upload_susp(g, arr: PackedFloat32Array) -> void:
	g.upload(g.live_buffer("susp", g._parity), arr)


func upload_snow(g, arr: PackedFloat32Array) -> void:
	g.upload(_buf_snow, arr)


func download_susp(g) -> PackedFloat32Array:
	return g.download(g.live_buffer("susp", g._parity))


func download_snow(g) -> PackedFloat32Array:
	return g.download(_buf_snow)


# --- Dispatch recording (called from LAMaterialGPU3D.step() at the marked seams) --------------------

## EROSION — after the water CA (reads the fresh post-flow water[back]): deposit/settle suspended sediment into
## the shared sediment channel, then gather-advect the suspended load one cell downhill. Assumes the caller
## added a barrier after the water pass (water[back] must be visible). Leaves a barrier for downstream reads.
func record_erosion(g, cl: int) -> void:
	if _erosion_deposit_pipeline == RID() or not _erosion_deposit_pipeline.is_valid():
		return
	var groups: int = g._groups()
	var p: int = g._parity
	g._rd.compute_list_bind_compute_pipeline(cl, _erosion_deposit_pipeline)
	g._rd.compute_list_bind_uniform_set(cl, _erosion_deposit_set[p], 0)
	g._rd.compute_list_set_push_constant(cl, Push.dims_pc(g), 16)
	g._rd.compute_list_dispatch(cl, groups, 1, 1)
	g._rd.compute_list_add_barrier(cl)                     # post-deposit susp visible to the advect gather
	g._rd.compute_list_bind_compute_pipeline(cl, _erosion_advect_pipeline)
	g._rd.compute_list_bind_uniform_set(cl, _erosion_advect_set[p], 0)
	g._rd.compute_list_set_push_constant(cl, Push.dims_pc(g), 16)
	g._rd.compute_list_dispatch(cl, groups, 1, 1)


## SNOWICE — after the heat chain (reads the post-heat temp[back]): per-column snowpack accrete/melt, meltwater
## into water[back]. Per-column dispatch. Caller supplies the surrounding barriers.
func record_snowice(g, cl: int) -> void:
	if _snowice_pipeline == RID() or not _snowice_pipeline.is_valid():
		return
	g._rd.compute_list_bind_compute_pipeline(cl, _snowice_pipeline)
	g._rd.compute_list_bind_uniform_set(cl, _snowice_set[g._parity], 0)
	g._rd.compute_list_set_push_constant(cl, Push.fungus_pc(g), 32)   # {dims, precip} — same layout as fungus
	g._rd.compute_list_dispatch(cl, g._col_groups(), 1, 1)


## MAGMA — after the lava flow+phase passes (reads/writes the post-phase lava[back] + temp[back]): two-pass
## buoyant overpressure up-flow (copy snapshot -> gather/apply). Caller supplies the surrounding barriers; a
## barrier separates the two passes.
func record_magma(g, cl: int) -> void:
	if _magma_buoy_pipeline == RID() or not _magma_buoy_pipeline.is_valid():
		return
	var groups: int = g._groups()
	var p: int = g._parity
	g._rd.compute_list_bind_compute_pipeline(cl, _magma_buoy_pipeline)
	g._rd.compute_list_bind_uniform_set(cl, _magma_buoy_set[p], 0)
	g._rd.compute_list_set_push_constant(cl, Push.water_pc(g, 0), 32)  # {dims, pass_id=0} — copy snapshot
	g._rd.compute_list_dispatch(cl, groups, 1, 1)
	g._rd.compute_list_add_barrier(cl)                     # snapshot visible to the gather
	g._rd.compute_list_bind_compute_pipeline(cl, _magma_buoy_pipeline)
	g._rd.compute_list_bind_uniform_set(cl, _magma_buoy_set[p], 0)
	g._rd.compute_list_set_push_constant(cl, Push.water_pc(g, 1), 32)  # {dims, pass_id=1} — gather/apply
	g._rd.compute_list_dispatch(cl, groups, 1, 1)


## Free this module's pipelines + resident buffers + uniform sets. Called from LAMaterialGPU3D.dispose()
## BEFORE the backend frees its RenderingDevice. Shaders are tracked by the backend (via g._pipeline) and
## freed in its dispose, so only the pipelines + buffers + sets are freed here.
func dispose(g) -> void:
	if g._rd == null:
		return
	for arr in [_erosion_deposit_set, _erosion_advect_set, _snowice_set, _magma_buoy_set]:
		for s in arr:
			if s.is_valid():
				g._rd.free_rid(s)
	_erosion_deposit_set = [RID(), RID()]
	_erosion_advect_set = [RID(), RID()]
	_snowice_set = [RID(), RID()]
	_magma_buoy_set = [RID(), RID()]
	for pipe in [_erosion_deposit_pipeline, _erosion_advect_pipeline, _snowice_pipeline, _magma_buoy_pipeline]:
		if pipe.is_valid():
			g._rd.free_rid(pipe)
	_erosion_deposit_pipeline = RID()
	_erosion_advect_pipeline = RID()
	_snowice_pipeline = RID()
	_magma_buoy_pipeline = RID()
	for buf in [_buf_susp_a, _buf_susp_b, _buf_snow, _buf_lava_scratch]:
		if buf.is_valid():
			g._rd.free_rid(buf)
	_buf_susp_a = RID()
	_buf_susp_b = RID()
	_buf_snow = RID()
	_buf_lava_scratch = RID()

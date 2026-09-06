extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"

## THE FREE SURFACE OF THE FIELD'S LIQUID, extracted on the device into mesh buffers. A detector: the
## renderer receives the mesh and owns no shape, and nothing in the field reads what this writes.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/mesh_extract.glsl"

## Set to examine every seam: an extra dispatch counts shared corners two cells disagree about.
const SEAM_CHECK_ENV: String = "LA_MESH_CHECK"

var _pipe: RID = RID()
var _set: RID = RID()
var _bufs: Dictionary = {}
## The last extracted surface: vertices, per-vertex attributes and triangle indices.
var verts: PackedFloat32Array = PackedFloat32Array()
var attrs: PackedFloat32Array = PackedFloat32Array()
var indices: PackedInt32Array = PackedInt32Array()


func _buffers(cc: int) -> Dictionary:
	# Four vertices and six indices per cell: a cell contributes at most one quad, so nothing overruns.
	return {"mesh_count": 4, "mesh_vert": cc * 12, "mesh_attr": cc * 12, "mesh_index": cc * 6}


func _setup(bufs: Dictionary, _cc: int) -> void:
	_bufs = bufs
	_pipe = _kernel(KERNEL_PATH)
	_set = _uset(_pipe, LABindings.set_for("mesh_extract.glsl", bufs, {}))


func dispatch(_rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or not _set.is_valid():
		return
	var centre: Vector3 = ctx.get("centre", Vector3.ZERO)
	var full: float = LASubstances.full_mol_m3("h2o")
	# WHAT ONE PLACE MEANS OUT HERE: a vertex stands a body radius from the centre, and float32 carries
	# 24 bits of that, so the step between one representable radius and the next is the resolution every
	# height in this mesh has. The box's own corner is the farthest cell from the centre.
	var step: float = _float32_step((grid_origin - centre).length()
		+ float(maxi(maxi(grid_dims.x, grid_dims.y), grid_dims.z)) * grid_cell_size)
	# The counters are zeroed, the cells walked, then the seams examined off what the walk read.
	var sets: Array = [_set, _set]
	var pcs: Array = [_push(cc, centre, full, step, 1), _push(cc, centre, full, step, 0)]
	var gs: PackedInt32Array = PackedInt32Array()
	gs.append(1)
	gs.append(groups)
	if OS.get_environment(SEAM_CHECK_ENV) != "":
		sets.append(_set)
		pcs.append(_push(cc, centre, full, step, 2))
		gs.append(groups)
	var rids: Array = []
	var offs: PackedInt32Array = PackedInt32Array()
	for _i in sets.size():
		rids.append(RID())
		offs.append(0)
	_driver.run(cl, _pipe, sets, pcs, gs, rids, offs, true)


## The gap between one float32 and the next at `v`: 24 bits of mantissa, so it is the value's own scale.
func _float32_step(v: float) -> float:
	return pow(2.0, floor(log(maxf(v, 1.0)) / log(2.0)) - 23.0)


func _push(cc: int, centre: Vector3, full: float, step: float, mode: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_float(4, centre.x)
	pc.encode_float(8, centre.y)
	pc.encode_float(12, centre.z)
	pc.encode_float(16, full)
	pc.encode_u32(20, cc)
	pc.encode_float(24, step)
	pc.encode_u32(28, mode)
	return pc


func _drain(rd: RenderingDevice) -> Dictionary:
	verts = PackedFloat32Array()
	attrs = PackedFloat32Array()
	indices = PackedInt32Array()
	if rd == null or not _bufs.has("mesh_count"):
		return {}
	var counts: PackedInt32Array = rd.buffer_get_data(_bufs["mesh_count"], 0, 16).to_int32_array()
	if counts.size() < 4:
		return {}
	var out: Dictionary = {"water_surface_quads": counts[0] / 4}
	if OS.get_environment(SEAM_CHECK_ENV) != "":
		out["mesh_seam_breaks"] = counts[2]
		out["mesh_seams"] = counts[3]
	if counts[0] <= 0 or counts[1] <= 0:
		return out
	verts = rd.buffer_get_data(_bufs["mesh_vert"], 0, counts[0] * 3 * 4).to_float32_array()
	attrs = rd.buffer_get_data(_bufs["mesh_attr"], 0, counts[0] * 3 * 4).to_float32_array()
	indices = rd.buffer_get_data(_bufs["mesh_index"], 0, counts[1] * 4).to_int32_array()
	return out

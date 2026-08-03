extends RefCounted

## Cubed-sphere GPU pass plugin: PLATE TRANSPORT — the crust is carried by the plate it sits on.
##
## Wires the ONE kernel plate_advect_sphere3d.glsl into the SphereGPU driver via the plugin contract
## (setup() once, dispatch() each step). Before this pass existed LAPlateTectonics rotated plate SEED POINTS
## and nothing else — it never touched the material field — so plate boundaries migrated across continents
## that had never moved. The kernel header carries the physics; this file is the wiring.
##
## PLACEMENT (MaterialSphereGPU3D.PASS_SCRIPTS): FIRST, ahead of SolidDerivePass. The transport edits
## `rock_fill`, and `solid` is DERIVED from rock_fill at the top of every step, so moving the crust before the
## derive is what makes the rest of the step (water, heat, reactions, the mineral stamp) see the crust where it
## now is rather than where it was. Nothing runs before it, so the shared `send` scratch is free; pass 0
## self-zeroes all six of its slots anyway, which is the contract WaterSlumpLavaPass and ErosionTransportPass
## also follow.
##
## TWO CHANNELS, ONE PIPELINE. rock_fill (a SINGLE buffer) and sediment (a ping-pong half) are the same
## conserved mineral in different phases and are carried by the same rule, so they are dispatched through one
## pipeline with different uniform sets rather than being special-cased in the kernel. Bedrock and its loose
## cover ride the plate together, which is what a continental margin does.
##
## Kernel binding -> bufs-key map (authoritative layout is plate_advect_sphere3d.glsl):
##   0 Field=<rock_fill | sediment[live]> · 1 Send=send · 2 Radial=radial · 3 Pos=pos · 4 Neigh=nbr ·
##   5 Plates=plates
## Push { uint cell_count, pass_id, n_plates, depth; float dt, cell_size, core_radius, max_mass; }, 32 bytes.
##
## `LA_NO_PLATE_ADVECT=1` holds the crust still while leaving the dispatch, the buffers and the plate table
## exactly as they are (n_plates is forced to 0, so pass 0 sends nothing and pass 1 is an exact no-op). It is
## the measurement control that lets crust motion be A/B'd against itself in ONE build, at one seed, on one
## machine — the arm this repo's measurement rules ask for. It is not a fallback: the sim always ships moving.
## (Explicit types only, no ':=' inferred typing.)

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/plate_advect_sphere3d.glsl"

var _rd: RenderingDevice = null
var _shader: RID = RID()
var _pipe: RID = RID()
var _set_rock: Array = [RID(), RID()]   # rock_fill is SINGLE, but pass 2 binds water (a pair) → one set per parity
var _set_sed: Array = [RID(), RID()]    # sediment is a ping-pong pair — one set per parity (live half)
var _enabled: bool = true


func setup(rd: RenderingDevice, bufs: Dictionary, _cc: int) -> void:
	_rd = rd
	if _rd == null:
		push_error("PlateAdvectPass: null RenderingDevice")
		return
	_enabled = OS.get_environment("LA_NO_PLATE_ADVECT") == ""

	var sf: RDShaderFile = load(KERNEL_PATH)
	if sf == null:
		push_error("PlateAdvectPass: plate_advect_sphere3d.glsl failed to load (editor import scan needed?)")
		return
	_shader = _rd.shader_create_from_spirv(sf.get_spirv())
	if not _shader.is_valid():
		push_error("PlateAdvectPass: shader compile failed (run --import after editing the .glsl)")
		return
	_pipe = _rd.compute_pipeline_create(_shader)

	var send_rid: RID = bufs.get("send", RID())
	var radial_rid: RID = bufs.get("radial", RID())
	var pos_rid: RID = bufs.get("pos", RID())
	var nbr_rid: RID = bufs.get("nbr", RID())
	var plates_rid: RID = bufs.get("plates", RID())
	var rock_rid: RID = bufs.get("rock_fill", RID())
	var sed_pair: Array = bufs.get("sediment", [RID(), RID()])
	if not plates_rid.is_valid() or not rock_rid.is_valid():
		push_error("PlateAdvectPass: driver did not provide the plates/rock_fill buffers")
		return

	var water_pair: Array = bufs.get("water", [RID(), RID()])
	# Every set also binds water + rock_fill, because pass 2 (the fluid displacement) shares this pipeline.
	# Water is bound LIVE: this pass runs first in the step, so the live half is last step's settled water and
	# is exactly what the water CA reads next. rock_fill is bound twice in the rock sets (as the carried channel
	# at 0 and as pass 2's solidity input at 7); that is a read of the same buffer, not an alias hazard, because
	# the two passes never run at the same time.
	for p in 2:
		_set_rock[p] = _build_set([
			[0, rock_rid], [1, send_rid], [2, radial_rid], [3, pos_rid], [4, nbr_rid], [5, plates_rid],
			[6, water_pair[p]], [7, rock_rid]])
		_set_sed[p] = _build_set([
			[0, sed_pair[p]], [1, send_rid], [2, radial_rid], [3, pos_rid], [4, nbr_rid], [5, plates_rid],
			[6, water_pair[p]], [7, rock_rid]])


func dispatch(rd: RenderingDevice, cl: int, parity: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if _rd == null or not _pipe.is_valid():
		return
	var n_plates: int = int(ctx.get("n_plates", 0)) if _enabled else 0
	# BEDROCK first, then its loose cover. Both are two dispatches (outflow, then gather) over the shared
	# `send` scratch, so the four are strictly ordered with a barrier between each.
	var rock_set: RID = _set_rock[parity]
	_carry(rd, cl, rock_set, ctx, cc, groups, n_plates)
	var sed_set: RID = _set_sed[parity]
	if sed_set.is_valid():
		_carry(rd, cl, sed_set, ctx, cc, groups, n_plates)
	# ...and then ONE displacement pass, after both mineral channels have settled, so it sees the rock where it
	# now is. Skipped entirely when the crust is not moving — with no advection nothing newly closes over water,
	# and the ordinary substrate owns whatever was already buried.
	if n_plates > 0 and rock_set.is_valid():
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, rock_set, 0)
		rd.compute_list_set_push_constant(cl, _push(ctx, cc, 2, n_plates), 32)
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


func dispose(rd: RenderingDevice) -> void:
	if rd == null:
		return
	for s in _set_rock:
		if s is RID and s.is_valid():
			rd.free_rid(s)
	_set_rock = [RID(), RID()]
	for s in _set_sed:
		if s is RID and s.is_valid():
			rd.free_rid(s)
	_set_sed = [RID(), RID()]
	if _pipe.is_valid():
		rd.free_rid(_pipe)
		_pipe = RID()
	if _shader.is_valid():
		rd.free_rid(_shader)
		_shader = RID()


# --- helpers ------------------------------------------------------------------

## One channel's transport: PASS 0 writes the outflow into `send`; barrier; PASS 1 gathers and applies in place.
func _carry(rd: RenderingDevice, cl: int, uset: RID, ctx: Dictionary, cc: int, groups: int, n_plates: int) -> void:
	if not uset.is_valid():
		return
	for pass_id in 2:
		rd.compute_list_bind_compute_pipeline(cl, _pipe)
		rd.compute_list_bind_uniform_set(cl, uset, 0)
		rd.compute_list_set_push_constant(cl, _push(ctx, cc, pass_id, n_plates), 32)
		rd.compute_list_dispatch(cl, groups, 1, 1)
		rd.compute_list_add_barrier(cl)


func _push(ctx: Dictionary, cc: int, pass_id: int, n_plates: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, pass_id)
	pc.encode_u32(8, maxi(n_plates, 0))
	pc.encode_u32(12, maxi(int(ctx.get("depth", 1)), 1))
	pc.encode_float(16, float(ctx.get("dt", 0.1)))
	pc.encode_float(20, float(ctx.get("cell_size", 1.0)))
	pc.encode_float(24, float(ctx.get("core_radius", 0.0)))
	pc.encode_float(28, float(ctx.get("max_mass", 1.0)))
	return pc


func _build_set(entries: Array) -> RID:
	var uniforms: Array = []
	for e in entries:
		var u: RDUniform = RDUniform.new()
		u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.binding = int(e[0])
		u.add_id(e[1])
		uniforms.append(u)
	return _rd.uniform_set_create(uniforms, _shader, 0)

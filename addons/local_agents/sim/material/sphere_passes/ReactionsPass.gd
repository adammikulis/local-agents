extends "res://addons/local_agents/sim/material/sphere_passes/SpherePass.gd"


## The generic reaction engine: one kernel over the whole record table (reactions_sphere3d.glsl).


const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/reactions_sphere3d.glsl"
const MOVES_STATE: bool = true   # reactions transform matter and energy

var _pipe: RID = RID()
var _n_records: int = 0
var _set: RID = RID()


func _setup(bufs: Dictionary, cc: int) -> void:
	_pipe = _kernel(KERNEL_PATH)
	if not _pipe.is_valid():
		return

	# Test-rig seam: a table under this key replaces the rung's records. The driver never sets it.
	var recs: Array = bufs.get("reaction_records", [])
	if recs.is_empty():
		recs = LAProcessSet.reaction_records()
	if recs.is_empty():
		push_error("ReactionsPass: the reaction table is EMPTY — every same-cell reaction is disabled. A load "
			+ "failure, not a configuration: check material/reactions/ and run scripts/editor_scan.sh.")
		return
	if recs.size() > LAReactionDefs.MAX_RECORDS:
		push_error("ReactionsPass: %d records exceed the kernel's MAX_RECORDS = %d; raise it in "
			% [recs.size(), LAReactionDefs.MAX_RECORDS] + "LAReactionDefs and regenerate.")
		return
	_n_records = recs.size()
	var defs_ssbo: RID = _storage_buffer(LAReactionDefs.serialize(recs))

	# Transport ran before this pass in the same submit, with a barrier between them, so every amount here
	# is what transport left. A reaction is same-cell, so it edits that amount in place.
	_set = _uset(_pipe, LABindings.set_for("reactions_sphere3d.glsl", bufs,
		{"reaction_defs": defs_ssbo}))


func dispatch(_rd: RenderingDevice, cl: int, ctx: Dictionary, cc: int, groups: int) -> void:
	if not _dispatchable() or _n_records <= 0 or not _set.is_valid():
		return
	# The solar kernel and the reaction engine must see the IDENTICAL sun, magnitude included: it carries
	# orbit-distance squared times atmospheric transmission, so what dims the sky suppresses photosynthesis
	# directly rather than second-hand through cooling.
	var sun_dir: Vector3 = ctx.get("sun_dir", Vector3(0.0, 1.0, 0.0))
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, _n_records)
	pc.encode_u32(8, 0)    # pad0 — no kernel-side dt; every rate_k carries its own timebase
	pc.encode_u32(12, 0)   # pad1 — no global rain gate
	pc.encode_float(16, sun_dir.x)
	pc.encode_float(20, sun_dir.y)
	pc.encode_float(24, sun_dir.z)
	pc.encode_u32(28, 0)   # pad2
	_driver.run(cl, _pipe, [_set], [pc], PackedInt32Array([groups]), [RID()],
		PackedInt32Array([0]), false)

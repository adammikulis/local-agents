class_name LAMaterialFieldSnapshot3D
extends RefCounted

## Save/restore of the material field's per-cell state.


## True once the field has activated its GPU driver.
static func is_ready(field) -> bool:
	return field != null and field._use_gpu and field._gpu != null and field._gpu.has_method("snapshot_channels")


## cell_count plus every GPU channel; empty when the GPU driver is not up.
static func capture(field) -> Dictionary:
	if not is_ready(field):
		return {}
	return {
		"cell_count": field._cell_count,
		"channels": field._gpu.snapshot_channels(),
	}


## Upload a capture() dict back to the GPU and re-seed the CPU mirrors; false on a shape mismatch.
static func restore(field, data: Dictionary) -> bool:
	if not is_ready(field) or data.is_empty():
		return false
	if int(data.get("cell_count", -1)) != field._cell_count:
		push_warning("LAMaterialFieldSnapshot3D: cell_count mismatch (%s vs %d), so the field is not restored" % [
			str(data.get("cell_count", -1)), field._cell_count])
		return false
	var channels: Dictionary = data.get("channels", {})
	if channels.is_empty():
		return false
	field._gpu.restore_channels(channels)
	# EVERY MIRROR THE CAPTURE CARRIES. A subset leaves the rest holding the pre-load world, and what
	# reads a mirror — the body's mass among them — then weighs two worlds at once.
	for name in channels.keys():
		field._mirrors.set_array(String(name), channels[name])
	field._atmos_dirty = true
	return true

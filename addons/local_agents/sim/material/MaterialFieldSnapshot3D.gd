class_name LAMaterialFieldSnapshot3D
extends RefCounted

## Save/restore of the material field's per-cell state.


## The field's CPU mirror for a channel, by the rule LAFieldCellMass3D reads them under: `_` and the
## channel's own name, the enthalpy channel under the name the field holds it by.
static func mirror_of(name: String) -> String:
	return "_e" if name == "e_j_m3" else "_" + name


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
		var arr: PackedFloat32Array = channels[name]
		var key: String = mirror_of(String(name))
		if arr.size() == field._cell_count and field.get(key) is PackedFloat32Array:
			field.set(key, arr)
	field._atmos_dirty = true
	return true

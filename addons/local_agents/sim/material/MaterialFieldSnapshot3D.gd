class_name LAMaterialFieldSnapshot3D
extends RefCounted

## Save/restore of the material field's per-cell state.

# Channel name -> the field's CPU mirror array property.
const CPU_MIRROR: Dictionary = {
	"h_j_m3": "_h", "h2o": "_h2o", "silicate": "_silicate", "fire": "_fire",
	"o2": "_o2", "co2": "_co2", "biomass": "_biomass", "cement": "_cement",
	"shock": "_shock", "charge": "_charge",
	"vel_x": "_vel_x", "vel_y": "_vel_y", "vel_z": "_vel_z", "fuel": "_fuel", "fungus": "_fungus",
	"detritus": "_detritus", "pressure": "_pressure",
}


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
	for name in channels.keys():
		var key: String = String(name)
		if not CPU_MIRROR.has(key):
			continue
		var arr: PackedFloat32Array = channels[key]
		if arr.size() == field._cell_count:
			field.set(CPU_MIRROR[key], arr)
	field._atmos_dirty = true
	return true

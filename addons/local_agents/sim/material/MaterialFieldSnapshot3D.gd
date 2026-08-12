class_name LAMaterialFieldSnapshot3D
extends RefCounted

## LAMaterialFieldSnapshot3D: save/restore of the ONE material field's heavy per-cell state, factored out of

# Channel name -> the field's CPU mirror array property. A channel with no CPU mirror still round-trips on
# the GPU via restore_channels().
const CPU_MIRROR: Dictionary = {
	"temp": "_temp", "water": "_water", "moisture": "_moisture", "lava": "_lava", "fire": "_fire",
	"o2": "_o2", "co2": "_co2", "biomass": "_biomass", "snow": "_snow", "dust": "_dust",
	"sediment": "_sediment", "rock_fill": "_rock_fill", "shock": "_shock", "charge": "_charge",
	"vel_x": "_vel_x", "vel_y": "_vel_y", "vel_z": "_vel_z", "fuel": "_fuel", "fungus": "_fungus",
	"detritus": "_detritus", "pressure": "_pressure",
}


## True once the field has activated its GPU driver — restore must wait for this (the driver is built lazily,
## a few frames after boot, once the terrain SDF is streamable). Save can also read it to fail gracefully.
static func is_ready(field) -> bool:
	return field != null and field._use_gpu and field._gpu != null and field._gpu.has_method("snapshot_channels")


## Capture the field's heavy state into a plain-data dict: cell_count (a grid-shape guard on restore) + every
## GPU channel. Empty dict when the GPU driver is not up (headless / not-yet-activated) — the caller treats an
## empty field block as "no field to restore" rather than crashing.
static func capture(field) -> Dictionary:
	if not is_ready(field):
		return {}
	return {
		"cell_count": field._cell_count,
		"channels": field._gpu.snapshot_channels(),
	}


## Restore a capture() dict: upload the channels back to the GPU and re-seed the field's CPU mirror arrays.
## Returns false (a no-op) when the field is not ready or the grid shape differs (a save from another grid
## resolution) — the caller keeps the freshly-booted field instead of a corrupt half-restore.
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
	# The atmosphere aggregate cache reads _moisture/_temp — invalidate it so the next query recomputes.
	field._atmos_dirty = true
	return true

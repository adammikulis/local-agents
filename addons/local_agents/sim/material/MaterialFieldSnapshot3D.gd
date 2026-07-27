class_name LAMaterialFieldSnapshot3D
extends RefCounted

## LAMaterialFieldSnapshot3D — save/restore of the ONE material field's heavy per-cell state, factored out of
## the extract-only LAMaterialField3D hub (same pattern as the query/inject/step modules: it reaches into the
## owning field `_f` for the GPU driver + CPU channel arrays). The field is the big blob a world-save persists:
## every GPU-resident channel (water/heat/moisture/rock_fill/lava/charge/snow/o2/co2/biomass/…) plus the CPU
## mirror arrays actor world-queries read between readbacks.
##
## CAPTURE reads the authoritative GPU buffers back through the driver's snapshot_channels(); RESTORE uploads
## them verbatim through restore_channels() AND re-seeds the field's CPU mirror arrays (crucially _temp/_water,
## which begin_frame re-uploads every step — leaving them stale would clobber the restored field on the very
## next frame). The solid/static masks are NOT saved: they re-derive deterministically from the (fixed-seed)
## terrain SDF + sea radius on boot, so a reload reproduces them exactly. (Explicit types only — no ':=' .)

# Channel name (as read back by the GPU driver) -> the field's CPU mirror array property, for the channels the
# field keeps a CPU copy of (actor queries + SIM_REPORT totals read these until the next GPU readback). Channels
# with no CPU mirror (susp/fert/dust_outscale/etc.) still round-trip on the GPU via restore_channels().
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
		push_warning("LAMaterialFieldSnapshot3D: cell_count mismatch (%s vs %d) — field not restored" % [
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

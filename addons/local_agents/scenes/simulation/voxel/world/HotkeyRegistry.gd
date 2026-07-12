class_name LAHotkeyRegistry
extends RefCounted

## LAHotkeyRegistry — the ONE source of truth for the voxel sim's keyboard shortcuts. It is pure DATA:
## a static catalog of {key, action, label, category} records plus the digit-select policy the spawn
## palette and its handler both read from, so the on-screen hint, the input router, and a future
## controls-reference screen all describe the same bindings and can never drift.
##
## Nothing here executes a shortcut — the existing owners still do that (LAVoxelInputController for the
## camera modes / pause, LAVoxelInteraction for selection + palette + brush + overlays, the HUD for its
## own toggles). This registry only NAMES the bindings and derives the spawn-palette digit assignments
## from the palette's own kind lists (LASpawnPaletteHud.LIFE_KINDS / DISASTER_KINDS), so adding a spawn
## entry re-labels its hotkey automatically. (Explicit types only — project rule: no ':=' inferred typing.)

# Category labels (sentence case) used to group the catalog for the controls-reference screen.
const CAT_LIFE: String = "Spawn — life"
const CAT_DISASTER: String = "Spawn — disasters"
const CAT_SELECTION: String = "Selection"
const CAT_VIEW: String = "Camera & view"
const CAT_OVERLAY: String = "Overlays"
const CAT_BRUSH: String = "Brush"
const CAT_COMPANION: String = "Companion (select a creature first)"
const CAT_INTERFACE: String = "Interface"

# The shift glyph (U+21E7) used in the compact key hints so "⇧1" reads at a glance on the palette buttons.
const SHIFT_GLYPH: String = "⇧"


## The full catalog: an ordered Array of {key, action, label, category} dictionaries. This is the accessor
## the help / controls-reference screen reads. Spawn rows are generated from the live palette kind lists so
## they always match the buttons; the rest are static bindings routed to the existing handlers.
static func hotkey_map() -> Array:
	var rows: Array = []

	# --- Spawn palette digit-select (derived from the palette's own kind ordering) ---
	var life: PackedStringArray = LASpawnPaletteHud.LIFE_KINDS
	for i in life.size():
		var kind: String = life[i]
		rows.append(_row(str(i + 1), "arm_" + kind, "Arm %s" % _kind_label(kind), CAT_LIFE))
	var dis: PackedStringArray = LASpawnPaletteHud.DISASTER_KINDS
	for j in dis.size():
		var dkind: String = dis[j]
		rows.append(_row("Shift+%d" % (j + 1), "arm_" + dkind, "Arm %s" % _kind_label(dkind), CAT_DISASTER))

	# --- Selection / cursor ---
	rows.append(_row("Esc", "select_cursor", "Cursor / select mode (and pause menu)", CAT_SELECTION))
	rows.append(_row("Tab", "select_next", "Cycle selection forward", CAT_SELECTION))
	rows.append(_row("Shift+Tab", "select_prev", "Cycle selection back", CAT_SELECTION))

	# --- Camera & view (owned by LAVoxelInputController) ---
	rows.append(_row("G", "view_geosync", "Toggle geosync camera", CAT_VIEW))
	rows.append(_row("F", "view_fly", "Toggle fly mode", CAT_VIEW))
	rows.append(_row("P", "view_solar", "Toggle solar-system view", CAT_VIEW))
	rows.append(_row("K", "view_auto_spin", "Toggle planet auto-spin", CAT_VIEW))

	# --- Field overlays ---
	rows.append(_row("V", "overlay_scent", "Toggle scent overlay", CAT_OVERLAY))
	rows.append(_row("T", "overlay_temp", "Toggle temperature heatmap", CAT_OVERLAY))

	# --- Spawn brush ---
	rows.append(_row("[", "brush_shrink", "Shrink spawn brush", CAT_BRUSH))
	rows.append(_row("]", "brush_grow", "Grow spawn brush", CAT_BRUSH))
	rows.append(_row("Ctrl + Wheel", "brush_size", "Resize spawn brush", CAT_BRUSH))

	# --- Companion / pet (owned by LAVoxelInteraction; act on the selected creature) ---
	rows.append(_row("B", "companion_feed", "Feed / pet the selected creature (tame it)", CAT_COMPANION))
	rows.append(_row("Y", "companion_select", "Set the selected creature as your companion", CAT_COMPANION))
	rows.append(_row("J", "companion_come", "Command: come", CAT_COMPANION))
	rows.append(_row("L", "companion_stay", "Command: stay", CAT_COMPANION))
	rows.append(_row("N", "companion_follow", "Command: follow", CAT_COMPANION))
	rows.append(_row("O", "companion_free", "Command: free (roam)", CAT_COMPANION))

	# --- Interface ---
	rows.append(_row("M", "audio_menu", "Toggle audio & music menu", CAT_INTERFACE))
	rows.append(_row("C", "streamer_toggle", "Show / hide streamer overlay", CAT_INTERFACE))
	rows.append(_row("H", "hud_toggle", "Show / hide HUD", CAT_INTERFACE))

	return rows


## Digit-select policy (single source shared by the palette label and the input router): the spawn kind a
## number key arms, or "" when the key maps to no palette slot. `shifted` selects the disasters cluster,
## otherwise life. 1..9 map to slots 0..8; 0 maps to slot 9 (so a tenth entry gets a key for free).
static func spawn_kind_for_key(keycode: int, shifted: bool) -> String:
	var index: int = -1
	if keycode == KEY_0:
		index = 9
	elif keycode >= KEY_1 and keycode <= KEY_9:
		index = keycode - KEY_1
	if index < 0:
		return ""
	var kinds: PackedStringArray = LASpawnPaletteHud.DISASTER_KINDS if shifted else LASpawnPaletteHud.LIFE_KINDS
	if index >= kinds.size():
		return ""
	return kinds[index]


## The bound key string for an action id ("" when the action is not in the catalog). Lets a tooltip or
## hint reuse the SAME key label the controls-reference screen shows, so an on-screen control and the
## reference never disagree about which key drives it.
static func key_for_action(action: String) -> String:
	for row in hotkey_map():
		if String(row.get("action", "")) == action:
			return String(row.get("key", ""))
	return ""


## The compact key hint for a palette button ("1".."9"/"0", or "⇧1".. for a disaster). "" when the kind is
## not on the palette. Drives the small number badge drawn on each button and its tooltip.
static func spawn_label(kind: String) -> String:
	var life: PackedStringArray = LASpawnPaletteHud.LIFE_KINDS
	var li: int = life.find(kind)
	if li >= 0:
		return _digit_for_slot(li)
	var dis: PackedStringArray = LASpawnPaletteHud.DISASTER_KINDS
	var di: int = dis.find(kind)
	if di >= 0:
		return SHIFT_GLYPH + _digit_for_slot(di)
	return ""


# Slot 0..8 -> "1".."9"; slot 9 -> "0"; beyond that no key (blank badge).
static func _digit_for_slot(slot: int) -> String:
	if slot >= 0 and slot <= 8:
		return str(slot + 1)
	if slot == 9:
		return "0"
	return ""


static func _row(key: String, action: String, label: String, category: String) -> Dictionary:
	return {"key": key, "action": action, "label": label, "category": category}


static func _kind_label(kind: String) -> String:
	return String(LASpawnPaletteHud.KIND_LABELS.get(kind, kind))

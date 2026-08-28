#!/usr/bin/env bash
# EVERY CONDENSED PHASE HAS A BULK MODULUS, because every real solid and liquid does. A channel whose
# substance declares none is read as incompressible, which makes its cell's mixture infinitely stiff and
# lets a signal cross it at any speed at all. Gases have no such modulus and a dissolved solute rides in
# its solvent, so neither is asked for one.
# EXIT 0 every condensed channel is measured * 1 one is not * 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_godot.sh"

PROBE="$ROOT/addons/local_agents/tests/zz_condensed_moduli.gd"
trap 'rm -f "$PROBE" "$PROBE.uid"' EXIT INT TERM
cat > "$PROBE" <<'GD'
extends SceneTree

func _init() -> void:
	var rows: Dictionary = LAChannels.rows()
	var table: Dictionary = LASubstances.table()
	var asked: int = 0
	var bare: PackedStringArray = PackedStringArray()
	for name in LAMatterChannels.CHANNELS:
		var row: Dictionary = rows.get(String(name), {})
		var id: String = String(row.get("substance", ""))
		if id.is_empty() or LAMatterChannels.GASES.has(id):
			continue
		if String(row.get("phase", "")) == "dissolved":
			continue
		asked += 1
		var s: Dictionary = table.get(id, {})
		var k: float = float(s.get("bulk_modulus_pa", s.get("bulk_modulus_solid_pa", 0.0)))
		if not (k > 0.0):
			bare.append("%s (%s)" % [String(name), id])
	print('CONDENSED_MODULI={"asked":%d,"bare":%d}' % [asked, bare.size()])
	if asked <= 0:
		printerr("no condensed channel was examined, so this gate asserts nothing.")
		quit(2)
		return
	if bare.size() > 0:
		printerr("condensed with no bulk modulus: %s" % String(", ").join(bare))
		quit(1)
		return
	quit(0)
GD

OUT="$(la_godot --headless --path "$ROOT" -s "res://addons/local_agents/tests/zz_condensed_moduli.gd" 2>&1)"
RC=$?
printf '%s\n' "$OUT" | grep -E '^CONDENSED_MODULI=|condensed with no bulk|no condensed channel' || true
printf '%s\n' "$OUT" | grep -q '^CONDENSED_MODULI=' || {
	echo "check_condensed_moduli: the probe published no reading, so the table was never read." >&2
	printf '%s\n' "$OUT" | tail -15 >&2
	exit 2
}
case "$RC" in
	0) echo "check_condensed_moduli: OK"; exit 0 ;;
	1) exit 1 ;;
	*) exit 2 ;;
esac

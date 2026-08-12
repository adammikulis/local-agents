#!/usr/bin/env bash
# =====================================================================================================
# SPHERE-GRID GEOMETRY GATE — the grid closes, and it reports how uneven it is.
#
# WHY THIS EXISTS. LASphereGrid.validate() checks that the neighbour table is closed, symmetric and
# reciprocal, that the tangent frame is right-handed at every cell, and now that the solid angles of all
# six cube faces sum to 4*pi. Every one of those checks was DEAD: nothing in the tree called validate().
# Its own comments describe it as "reported rather than left as a comment nobody re-checks", which is
# what a validator is for, but no caller means no check.
#
# THE GEOMETRY FACT IT PINS. This grid's cells are NOT the same size. Solid angle per column varies by
# ~4.9x between a face centre and a face corner, and cell volume grows as r^2 up the shell, so the
# largest cell is roughly 8x the volume of the smallest — and that ratio GROWS with resolution. Any code
# that sums a per-cell channel value without weighting by volume is not measuring an amount, and any
# transport that moves a fraction of one cell into a differently sized one does not move the matter it
# debited. This gate does not fix that; it publishes the number so it cannot be forgotten again.
#
# EXIT CODES. 0 pass · 1 a grid failed to validate · 2 the gate could not run, never a silent pass.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib_require.sh
source "$REPO_ROOT/scripts/lib_require.sh" 2>/dev/null || true
if declare -f require_tool >/dev/null 2>&1; then
  require_tool godot
elif ! command -v godot >/dev/null 2>&1; then
  echo "ERROR: godot not on PATH — a gate that cannot run FAILS, it does not pass." >&2
  exit 2
fi

PROBE_REL="addons/local_agents/tests/tmp_check_sphere_grid.gd"
PROBE="$REPO_ROOT/$PROBE_REL"
cleanup() { rm -f "$PROBE" "$PROBE.uid"; }
trap cleanup EXIT

cat > "$PROBE" <<'GD'
extends SceneTree

# Two shapes, because a bug in the closed-form solid angle that cancels at one resolution generally will
# not at another. Each row is {res, depth, core_radius, cell_size}.
const CASES: Array = [[8, 6, 400.0, 24.0], [16, 12, 400.0, 12.0], [32, 24, 400.0, 6.0]]

func _init() -> void:
	var script: GDScript = load("res://addons/local_agents/sim/sphere/SphereGrid.gd")
	var failed: int = 0
	for spec in CASES:
		var g = script.new()
		g.build(int(spec[0]), int(spec[1]), float(spec[2]), float(spec[3]))
		var v: Dictionary = g.validate()
		# The summed cell volumes must equal the analytic volume of the shell they tile. This is the check
		# that actually proves cell_volume(), rather than only proving the solid angles normalise.
		var r_lo: float = float(spec[2])
		var r_hi: float = r_lo + float(spec[1]) * float(spec[3])
		var shell: float = (4.0 / 3.0) * PI * (r_hi * r_hi * r_hi - r_lo * r_lo * r_lo)
		var summed: float = 0.0
		for c in g.cell_count:
			summed += g.cell_volume(c)
		var vol_rel_err: float = absf(summed - shell) / shell
		var ok: bool = bool(v["ok"]) and vol_rel_err < 1.0e-6
		if not ok:
			failed += 1
		print("GRID_CHECK={\"res\":%d,\"depth\":%d,\"ok\":%s,\"non_reciprocal\":%d,\"tangent_handed_min\":%.4f}" % [
			int(spec[0]), int(spec[1]), str(ok).to_lower(), float(v["solid_angle_err"]) * 1.0e9,
			vol_rel_err * 1.0e6, float(v["volume_ratio"]), int(v["non_reciprocal"]),
			float(v["tangent_handed_min"])])
	# TOTALS. A uniform channel of 1.0 everywhere must weigh exactly (shell volume x density), which is a
	# closed form and nothing to do with how the grid is diced. Then the same field summed FLAT — the way
	# every ledger does it today — is compared against it, so the size of that error is a measured number
	# rather than an argument.
	var g2 = script.new()
	g2.build(16, 12, 400.0, 12.0)
	var ones: PackedFloat32Array = PackedFloat32Array()
	ones.resize(g2.cell_count)
	ones.fill(1.0)
	var no_mask: PackedByteArray = PackedByteArray()
	var t_lo: float = g2.core_radius
	var t_hi: float = t_lo + float(g2.depth) * g2.cell_size
	var shell_m3: float = ((4.0 / 3.0) * PI * (t_hi * t_hi * t_hi - t_lo * t_lo * t_lo)
		* pow(LAPhysical.METRES_PER_MODEL_UNIT, 3.0))
	var want_kg: float = shell_m3 * float(LASubstances.table()["h2o"]["density"])
	var got_kg: float = LAFieldTotals.substance_kg(g2, ones, no_mask, LAFieldTotals.CELLS_ALL, "h2o")
	var kg_rel: float = absf(got_kg - want_kg) / want_kg
	# A field that is NOT uniform is where the flat sum diverges: put the substance only in the outer half,
	# which is what an atmosphere or an ocean surface actually looks like.
	var outer: PackedFloat32Array = PackedFloat32Array()
	outer.resize(g2.cell_count)
	for c in g2.cell_count:
		outer[c] = 1.0 if (c % g2.depth) >= (g2.depth / 2) else 0.0
	var err_uniform: float = LAFieldTotals.flat_sum_error(g2, ones, no_mask, LAFieldTotals.CELLS_ALL)
	var err_outer: float = LAFieldTotals.flat_sum_error(g2, outer, no_mask, LAFieldTotals.CELLS_ALL)
	if kg_rel > 1.0e-6:
		failed += 1
	print("TOTALS_CHECK={\"kg_rel_err_ppm\":%.4f,\"flat_err_uniform\":%.4f,\"flat_err_outer_half\":%.4f}" % [
		kg_rel * 1.0e6, err_uniform, err_outer])
	print("GRID_GATE={\"cases\":%d,\"failed\":%d}" % [CASES.size(), failed])
	quit(1 if failed > 0 else 0)
GD

out="$(cd "$REPO_ROOT" && timeout 180 godot --headless --path . -s "res://$PROBE_REL" 2>&1)"
rc=$?
echo "$out" | grep -E '^GRID_CHECK=|^TOTALS_CHECK=|^GRID_GATE=' || true

if ! echo "$out" | grep -q '^GRID_GATE='; then
  echo "ERROR: the grid probe produced no GRID_GATE marker — it did not run to completion." >&2
  echo "$out" | tail -20 >&2
  exit 2
fi
if echo "$out" | grep -q '"failed":0'; then
  echo "check_sphere_grid: OK (neighbour table closed/symmetric/reciprocal, tangent frame right-handed,"
  echo "                  solid angles sum to 4*pi, summed cell volumes match the analytic shell)"
  exit 0
fi
echo
echo "FAIL  the cubed-sphere grid does not validate. Every per-cell quantity is built on this geometry,"
echo "      so nothing downstream of it means anything until it closes."
exit 1

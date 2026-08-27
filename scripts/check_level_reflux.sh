#!/usr/bin/env bash
# THE BOOKS CLOSE ACROSS A LEVEL BOUNDARY. A fast cell subdivides its own timestep while its quiet
# neighbour steps once; the face between them runs on the coarser of the two clocks, so both sides write
# the same flux on the same substep. This rig drives a shut box into two temporal levels and holds every
# matter channel in it to its starting total: nothing may be created or lost at the seam.
# EXIT 0 clean · 1 the book opened, or the box never reached two levels · 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/lib_capture.sh"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/transport.glsl"
[ -f "$KERNEL" ] || { echo "ERROR: transport.glsl missing." >&2; exit 2; }
[ -f "$REPO_ROOT/scripts/run_sim_offscreen.sh" ] || { echo "ERROR: run_sim_offscreen.sh missing." >&2; exit 2; }

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_level_reflux_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

# An automated run's window is minimized; macOS clamps an off-view position back on screen.
const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")

const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/TransportPass.gd"
const CELL: float = 2000.0
const DT: float = 1.0
const P_IN: float = 101325.0
const T_C: float = 15.0
const TOL: float = 1.0e-5
# Matter crosses every face at this speed; the clock is not its business.
const V_M_S: float = 20.0
# The right half is stiff, so its own sound speed is what earns it a finer clock than the left half's.
const C_STIFF: float = 4000.0
const RHO_BULK: float = 10.0

var _rd: RenderingDevice = null
var _fails: int = 0


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		printerr("check_level_reflux: " + msg)
		_fails += 1


func _filled(n: int, v: float) -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a


func _f32(vals: PackedFloat32Array, owned: Array[RID]) -> RID:
	var b: PackedByteArray = vals.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	owned.append(r)
	return r


func _i32(vals: PackedInt32Array, owned: Array[RID]) -> RID:
	var b: PackedByteArray = vals.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	owned.append(r)
	return r


func _write(bufs: Dictionary, key: String, vals: PackedFloat32Array) -> void:
	var b: PackedByteArray = vals.to_byte_array()
	_rd.buffer_update(bufs[key], 0, b.size(), b)


func _total(bufs: Dictionary, key: String, cc: int) -> float:
	var a: PackedFloat32Array = _rd.buffer_get_data(bufs[key]).to_float32_array()
	var s: float = 0.0
	for c in cc:
		s += a[c]
	return s


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		printerr("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		quit(2)
		return
	var nx: int = 8
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(nx, 1, 1, CELL, Vector3(-0.5 * float(nx) * CELL, -0.5 * CELL, -0.5 * CELL))
	var cc: int = grid.cell_count
	var owned: Array[RID] = []
	var bufs: Dictionary = {}
	for name in LAChannels.channels():
		bufs[String(name)] = _f32(_filled(cc, 0.0), owned)
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(_filled(cc, 0.0), owned)
	for name in ["h_h2o", "h_silicate", "h_sensible", "cap_sensible", "celerity", "speed", "rad_w_m3",
			"bodyf_x", "bodyf_y", "bodyf_z", "grav_phi"]:
		bufs[name] = _f32(_filled(cc, 0.0), owned)
	bufs["gravity"] = _f32(_filled(cc * 3, 0.0), owned)
	bufs["nbr"] = _i32(grid.neighbours, owned)
	var ghost_tbl: PackedInt32Array = PackedInt32Array()
	ghost_tbl.resize(cc * LAVoxelGrid.SLOTS)
	ghost_tbl.fill(-1)
	bufs["ghost"] = _i32(ghost_tbl, owned)

	var p: RefCounted = (load(PASS_PATH) as GDScript).new()
	p.ghost_count = 0
	var want: Dictionary = p._buffers(cc)
	for key in want:
		var spec: Variant = want[key]
		var n: int = int(spec["n"]) if spec is Dictionary else int(spec)
		var indirect: bool = spec is Dictionary and bool(spec.get("indirect", false))
		var zeros: PackedByteArray = _filled(n, 0.0).to_byte_array()
		var r: RID = _rd.storage_buffer_create(zeros.size(), zeros,
			RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT if indirect else 0)
		owned.append(r)
		bufs[String(key)] = r

	# A shut box of moving matter: a gradient so there is something to carry, and a velocity step so the
	# right half's own courant asks for a finer clock than the left half's.
	var cel: PackedFloat32Array = PackedFloat32Array()
	var h2o: PackedFloat32Array = PackedFloat32Array()
	var o2: PackedFloat32Array = PackedFloat32Array()
	var co2: PackedFloat32Array = PackedFloat32Array()
	# A sheared momentum column beside the flow, so every row of the group leaves a NONZERO face flux:
	# a stale one a coarse neighbour never wrote this substep is then visible as matter appearing.
	var momz: PackedFloat32Array = PackedFloat32Array()
	var velz: PackedFloat32Array = PackedFloat32Array()
	var spd: PackedFloat32Array = PackedFloat32Array()
	for c in cc:
		cel.append(C_STIFF if c >= cc / 2 else 0.0)
		h2o.append(500.0 - 40.0 * float(c))
		o2.append(200.0 + 10.0 * float(c))
		co2.append(50.0 + 3.0 * float(c))
		momz.append(10.0 + 2000.0 * float(c))
		velz.append((10.0 + 2000.0 * float(c)) / RHO_BULK)
		spd.append(sqrt(V_M_S * V_M_S + velz[c] * velz[c]))
	_write(bufs, "vel_x", _filled(cc, V_M_S))
	_write(bufs, "vel_z", velz)
	_write(bufs, "mom_z", momz)
	_write(bufs, "speed", spd)
	_write(bufs, "celerity", cel)
	_write(bufs, "h2o", h2o)
	_write(bufs, "o2", o2)
	_write(bufs, "co2", co2)
	_write(bufs, "h2o_liquid", _filled(cc, 1.0))
	_write(bufs, "rho_bulk", _filled(cc, RHO_BULK))
	_write(bufs, "pressure", _filled(cc, P_IN))
	_write(bufs, "temp", _filled(cc, T_C))

	p.setup(_rd, bufs, cc)
	var checked: PackedStringArray = PackedStringArray(["h2o", "o2", "co2"])
	var before: Dictionary = {}
	for ch in checked:
		before[String(ch)] = _total(bufs, String(ch), cc)
	var start: PackedFloat32Array = _rd.buffer_get_data(bufs["h2o"]).to_float32_array()

	var ctx: Dictionary = {"cell_size": CELL, "sun_dir": Vector3.ZERO, "dt_s": DT}
	var groups: int = int(ceil(float(cc) / 64.0))
	p.pre_step(_rd, ctx, cc, groups)
	var peak: int = 0
	var top: int = 0
	for g in p._peaks.size():
		if int(p._peaks[g]) > peak:
			peak = int(p._peaks[g])
			top = g
	_expect(peak >= 1, "no row group asked for a finer clock than the field step, so the box never "
		+ "reached two levels and this gate examined nothing.")
	# POSITIVE CONTROL: the level field the real code builds has to hold more than one level, or the
	# conservation below is a closed book over a box that never straddled a seam.
	var lcl: int = _rd.compute_list_begin()
	p._build_levels(_rd, lcl, p._row_groups[top], cc, CELL, DT, Vector3.ZERO, peak, top)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	var lv: PackedInt32Array = _rd.buffer_get_data(
		bufs[LATemporalLevels.KEYS.level]).to_int32_array()
	var seen: Dictionary = {}
	for c in cc:
		seen[lv[c]] = true
	_expect(seen.size() >= 2, "every cell landed on ONE level, so no face straddles two clocks and "
		+ "this gate cannot see a seam at all.")
	var cl: int = _rd.compute_list_begin()
	p.dispatch(_rd, cl, ctx, cc, groups)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	for ch in checked:
		var name: String = String(ch)
		var after: float = _total(bufs, name, cc)
		var was: float = float(before[name])
		_expect(absf(after - was) <= TOL * maxf(absf(was), 1.0),
			"%s: a shut box held %s and now holds %s — the seam between two clocks is not conservative."
			% [name, String.num_scientific(was), String.num_scientific(after)])
	var ended: PackedFloat32Array = _rd.buffer_get_data(bufs["h2o"]).to_float32_array()
	var moved: bool = false
	for c in cc:
		if absf(ended[c] - start[c]) > 0.0:
			moved = true
	_expect(moved, "nothing crossed any face, so a closed book proves nothing.")

	p.dispose(_rd)
	for r in owned:
		if r.is_valid():
			_rd.free_rid(r)
	print('LEVEL_REFLUX={"cells":%d,"peak_level":%d,"levels_present":%d,"channels":%d,"failures":%d}'
		% [cc, peak, seen.size(), checked.size(), _fails])
	_rd.free()
	quit(1 if _fails > 0 else 0)
GD

out="$(LA_DONE_RE='^LEVEL_REFLUX=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_level_reflux_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^LEVEL_REFLUX=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no LEVEL_REFLUX line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
printf '%s\n' "$out" | grep '^check_level_reflux:' >&2 || true
if [ "$rc" -eq 2 ]; then
  echo "The gate could not run. See the probe output above." >&2
  exit 2
fi
[ "$rc" -eq 0 ] || exit 1

# --- arm two: the SEEDED world takes its steps and publishes the level it took them on ---------------
# It asks the shared lint arm for a reading of the ordinary global run, so it starts no engine of its
# own; only the rig above needs a configuration that arm cannot give.
if la_cap_dir >/dev/null; then
  out2="$(la_report transport_levels 2>&1)"
  rc2=$?
else
  out2="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --frames "${LA_LEVEL_FRAMES:-2}" \
    --report transport_levels 2>&1)"
  rc2=$?
  # 122/123/126 are physics verdicts from a run that COMPLETED; only a failed run hides the gauge.
  case "$rc2" in 0|122|123|126) ;; *) out2="" ;; esac
fi
line2="$(printf '%s\n' "$out2" | grep -m1 'transport_levels')"
if [ -z "$line2" ] || printf '%s' "$line2" | grep -q 'ABSENT'; then
  echo "check_level_reflux: the seeded world published no transport_levels (exit $rc2) — an absent" >&2
  echo "                    reading examined nothing, so this arm judged the world not at all." >&2
  printf '%s\n' "$out2" | tail -6 >&2
  exit 2
fi
echo "LEVEL_REFLUX_WORLD=$line2"
echo "check_level_reflux: OK"

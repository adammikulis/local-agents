#!/usr/bin/env bash
# THE ESCAPE LAW, judged by the real evaluator: TransportPass dispatching transport.glsl over a rig whose
# box edge faces space. (a) closure — what left the top equals the bnd book; (b) physics — cold top or no
# XUV escapes nothing, a bound gas escapes thermally, an unbound gas escapes only under the epoch's XUV;
# (c) selectivity — the escape parameter keeps every heavy species in. Arm two runs the seeded world and
# holds the hydrogen pair's crossing to reaching the ledger. EXIT 0 clean · 1 a violation · 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/transport.glsl"
[ -f "$KERNEL" ] || { echo "ERROR: transport.glsl missing." >&2; exit 2; }
[ -f "$REPO_ROOT/scripts/sim_run.sh" ] || { echo "ERROR: sim_run.sh missing." >&2; exit 2; }

# --- arm one: the rig — a two-cell box, gravity along -x, the +x face DECLARED space -----------------
PROBE="$REPO_ROOT/addons/local_agents/tests/zz_escape_law_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")

const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/TransportPass.gd"
const CELL: float = 1.0
const DT: float = 1.0e-4
const T_C: float = 26.85
const T_K: float = 300.0
const N_GAS: float = 40.0
const ZERO_TOL: float = 1.0e-12
## M(-phi)/(R T) targets: bound-cold, bound-warm (Jeans runs), unbound (the XUV wind runs).
const LAM_COLD: float = 60.0
const LAM_JEANS: float = 6.0
const LAM_HYDRO: float = 2.9

var _rd: RenderingDevice = null
var _fails: int = 0
var _bufs: Dictionary = {}
var _cc: int = 0


class StubGpu:
	extends RefCounted
	var _rd: RenderingDevice = null
	var _bufs: Dictionary = {}


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		printerr("check_escape_law: " + msg)
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


func _upload(name: String, vals: PackedFloat32Array) -> void:
	var b: PackedByteArray = vals.to_byte_array()
	_rd.buffer_update(_bufs[String(name)], 0, b.size(), b)


func _sum(name: String) -> float:
	var a: PackedFloat32Array = _rd.buffer_get_data(_bufs[String(name)]).to_float32_array()
	var s: float = 0.0
	for c in _cc:
		s += a[c]
	return s


## One dispatch of the full pass against a fresh gas load, a set potential depth and a sun. Returns
## per-gas [stock change, bnd book] sums.
func _arm(p: RefCounted, depth: float, sun: Vector3, xuv_w_m2: float = 0.0) -> Dictionary:
	for gas: String in ["h2", "n2", "o2", "co2"]:
		_upload(gas, _filled(_cc, N_GAS))
	_upload("grav_phi", _filled(_cc, -depth))
	_upload("temp", _filled(_cc, T_C))
	_upload("pressure", _filled(_cc, 101325.0))
	for key in _bufs:
		if String(key).begins_with("bnd_"):
			_rd.buffer_clear(_bufs[key], 0, _cc * 4)
	var cl: int = _rd.compute_list_begin()
	p.dispatch(_rd, cl, {"cell_size": CELL, "sun_dir": sun, "dt_s": DT, "xuv_w_m2": xuv_w_m2},
		_cc, int(ceil(float(_cc) / 64.0)))
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	var out: Dictionary = {}
	for gas: String in ["h2", "n2", "o2", "co2"]:
		out[gas] = [_sum(gas) - N_GAS * float(_cc), _sum("bnd_" + gas)]
	out["bnd_h_h2"] = _sum("bnd_h_h2")
	return out


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		printerr("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		quit(2)
		return
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(2, 1, 1, CELL, Vector3(-1.0, -0.5, -0.5))
	_cc = grid.cell_count
	var owned: Array[RID] = []
	for name in LAChannels.channels():
		_bufs[String(name)] = _f32(_filled(_cc, 0.0), owned)
	for name in LAChannels.derived_buffers():
		_bufs[String(name)] = _f32(_filled(_cc, 0.0), owned)
	for name in ["h_h2o", "h_silicate", "h_sensible", "cap_sensible", "celerity", "speed", "rad_w_m3",
			"bodyf_x", "bodyf_y", "bodyf_z", "grav_phi"]:
		_bufs[String(name)] = _f32(_filled(_cc, 0.0), owned)
	_upload("cap_sensible", _filled(_cc, 1.0))
	var grav: PackedFloat32Array = PackedFloat32Array()
	grav.resize(_cc * 3)
	for i in _cc:
		grav[i * 3] = -5.0
	_bufs["gravity"] = _f32(grav, owned)
	_bufs["nbr"] = _i32(grid.neighbours, owned)
	var ghost_tbl: PackedInt32Array = PackedInt32Array()
	ghost_tbl.resize(_cc * LAVoxelGrid.SLOTS)
	ghost_tbl.fill(-1)
	_bufs["ghost"] = _i32(ghost_tbl, owned)
	# The +x face is SPACE by the provider's own record; every other face is a wall.
	var bnd: LAFieldBoundary3D = LAFieldBoundary3D.new()
	var modes: PackedInt32Array = PackedInt32Array([LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SPACE,
		LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT])
	if not bnd.configure(grid, modes, [null, null, null, null, null, null]):
		printerr("boundary configure failed: " + bnd.error)
		quit(2)
		return
	var p: RefCounted = (load(PASS_PATH) as GDScript).new()
	var want: Dictionary = p._buffers(_cc)
	for key in want:
		var spec: Variant = want[key]
		var n: int = int(spec["n"]) if spec is Dictionary else int(spec)
		var indirect: bool = spec is Dictionary and bool(spec.get("indirect", false))
		var zeros: PackedByteArray = _filled(n, 0.0).to_byte_array()
		var r: RID = _rd.storage_buffer_create(zeros.size(), zeros,
			RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT if indirect else 0)
		owned.append(r)
		_bufs[String(key)] = r
	p.setup(_rd, _bufs, _cc)
	var stub: StubGpu = StubGpu.new()
	stub._rd = _rd
	stub._bufs = _bufs
	bnd.attach(stub)
	if bnd.error != "":
		printerr("boundary attach failed: " + bnd.error)
		quit(2)
		return

	# The arm's potential depth, J/kg, off the h2 escape parameter it targets.
	var per_lam: float = LAPhysical.GAS_CONSTANT_J_MOL_K * T_K / LAPhysical.MOLAR_MASS_H2_KG_MOL
	var up: Vector3 = Vector3(1.0, 0.0, 0.0)
	# The epoch star's XUV at this planet's own separation; the sun vector carries direction only.
	var XUV: float = LABodySeeds.irradiance_w_m2(
		LABodySeeds.xuv_luminosity_at_epoch_w(), LABodySeeds.ASTRONOMICAL_UNIT_M)
	var stock: float = N_GAS * float(_cc)

	# (b) COLD: bound hard, the epoch's XUV shining — nothing may leave.
	var cold: Dictionary = _arm(p, LAM_COLD * per_lam, up, XUV)
	_expect(absf(float(cold["h2"][1])) <= ZERO_TOL * stock,
		"a cold bound cell lost h2 under XUV: bnd_h2 = %s" % String.num_scientific(float(cold["h2"][1])))

	# (b) JEANS: bound but warm enough that the tail escapes, no sun at all.
	var jeans: Dictionary = _arm(p, LAM_JEANS * per_lam, Vector3.ZERO)
	_expect(float(jeans["h2"][1]) < -1.0e-6,
		"Jeans escape moved no h2: bnd_h2 = %s" % String.num_scientific(float(jeans["h2"][1])))
	_expect(float(jeans["bnd_h_h2"]) < 0.0,
		"the escaping tail carried no heat leg: bnd_h_h2 = %s"
		% String.num_scientific(float(jeans["bnd_h_h2"])))
	# (a) closure, and (c) selectivity: the heavy books read zero while h2 drains.
	for gas: String in ["h2", "n2", "o2", "co2"]:
		_expect(absf(float(jeans[gas][0]) - float(jeans[gas][1])) <= 1.0e-5 * stock,
			"%s: the stock changed by %s and its book reads %s — the crossing is not booked."
			% [gas, String.num_scientific(float(jeans[gas][0])),
				String.num_scientific(float(jeans[gas][1]))])
		if gas != "h2":
			_expect(absf(float(jeans[gas][1])) <= ZERO_TOL * stock,
				"%s escaped alongside h2: bnd = %s" % [gas,
					String.num_scientific(float(jeans[gas][1]))])

	# (b) HYDRO: unbound, so the flux is the XUV wind — zero without the sun, real with it.
	var dark: Dictionary = _arm(p, LAM_HYDRO * per_lam, Vector3.ZERO)
	_expect(absf(float(dark["h2"][1])) <= ZERO_TOL * stock,
		"an unbound cell escaped with the XUV driver at zero: bnd_h2 = %s"
		% String.num_scientific(float(dark["h2"][1])))
	var lit: Dictionary = _arm(p, LAM_HYDRO * per_lam, up, XUV)
	_expect(float(lit["h2"][1]) < -1.0e-13,
		"the epoch's XUV drove no wind: bnd_h2 = %s" % String.num_scientific(float(lit["h2"][1])))
	for gas: String in ["n2", "o2", "co2"]:
		_expect(absf(float(lit[gas][1])) <= ZERO_TOL * stock,
			"%s rode the wind its own parameter binds: bnd = %s"
			% [gas, String.num_scientific(float(lit[gas][1]))])

	# SHUT MEANS SHUT: the same warm bound cell behind a wall loses nothing.
	modes[1] = LAFieldBoundary3D.SHUT
	var sealed: LAFieldBoundary3D = LAFieldBoundary3D.new()
	if sealed.configure(grid, modes, [null, null, null, null, null, null]):
		sealed.attach(stub)
	var walled: Dictionary = _arm(p, LAM_JEANS * per_lam, Vector3.ZERO)
	_expect(absf(float(walled["h2"][1])) <= ZERO_TOL * stock,
		"a SHUT face leaked h2: bnd_h2 = %s" % String.num_scientific(float(walled["h2"][1])))

	p.dispose(_rd)
	for r in owned:
		if r.is_valid():
			_rd.free_rid(r)
	print('ESCAPE_LAW={"failures":%d}' % _fails)
	_rd.free()
	quit(1 if _fails > 0 else 0)
GD

out="$(LA_DONE_RE='^ESCAPE_LAW=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_escape_law_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^ESCAPE_LAW=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no ESCAPE_LAW line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
printf '%s\n' "$out" | grep '^check_escape_law:' >&2 || true
[ "$rc" -eq 2 ] && { echo "The gate could not run. See the probe output above." >&2; exit 2; }
[ "$rc" -ne 0 ] && exit 1

# --- arm two: the seeded world loses hydrogen through the top and the ledger's pair closes ------------
ERRLOG="$(mktemp "${TMPDIR:-/tmp}/la_escape.XXXXXX")"
world_out="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" \
  --frames "${LA_ESCAPE_FRAMES:-20}" --report hydrogen_bnd_crossed,hydrogen_bnd_in,hydrogen_rel_drift \
  2>"$ERRLOG")"
world_rc=$?
case "$world_rc" in
  0|122|123|126) ;;
  *) echo "ERROR: the seeded run failed (exit $world_rc) — refusing to report a pass." >&2
     tail -12 "$ERRLOG" >&2; rm -f "$ERRLOG"; exit 2 ;;
esac
rm -f "$ERRLOG"
crossed="$(printf '%s\n' "$world_out" | sed -n 's/^hydrogen_bnd_crossed *= *//p' | head -1)"
if [ -z "$crossed" ] || [ "$crossed" = "None" ]; then
  echo "ERROR: the ledger publishes no hydrogen pair — the H drift gauge is gone." >&2
  printf '%s\n' "$world_out" | tail -8 >&2
  exit 2
fi
if [ "$(printf '%s\n' "$crossed" | awk '{print ($1 == 0.0) ? 1 : 0}')" = "1" ]; then
  echo "FAIL: the seeded planet's hydrogen crossed nothing — escape never reached the ledger." >&2
  exit 1
fi
echo "ESCAPE_LAW_WORLD={\"hydrogen_bnd_crossed\":$crossed}"
echo "check_escape_law: OK"
exit 0

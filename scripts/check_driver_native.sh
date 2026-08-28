#!/usr/bin/env bash
# THE PER-STEP DRIVER IS NATIVE, AND IT MOVES THE SAME MATTER THE GDSCRIPT ONE DID.
# Arm 1  no compute list is recorded from GDScript under sim/material.
# Arm 2  the two-level seam box against a recorded expected state, keyed to its kernels (--record).
# Arm 3  the seeded world publishes a step, so arms 1-2 are not judging a rig nobody boots.
# EXIT 0 clean · 1 a GDScript dispatch remains or the state differs · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
require_tool rg
require_tool md5
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }

RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1

KERNELS="$ROOT/addons/local_agents/sim/material/kernels3d"
FIXTURE="$ROOT/scripts/fixtures/driver_seam_state.txt"

# --- arm one: the dispatch loop is not in GDScript ---------------------------------------------------
SCAN="$ROOT/addons/local_agents/sim/material/sphere_passes $ROOT/addons/local_agents/sim/material/MaterialSphereGPU3D.gd"
scanned=$(rg --count-matches -g '*.gd' '' $SCAN 2>/dev/null | wc -l | tr -d ' ')
require_scanned "${scanned:-0}" 7 "driver files"
if [ "$RECORD" = "0" ]; then
  hits="$(rg -n 'compute_list_dispatch' $SCAN 2>/dev/null)"
  if [ -n "$hits" ]; then
    echo "check_driver_native: the per-step driver still records a compute list from GDScript." >&2
    printf '%s\n' "$hits" >&2
    exit 1
  fi
fi

# --- arm two: the seam box, byte for byte ------------------------------------------------------------
PROBE="$ROOT/addons/local_agents/tests/zz_driver_native_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

# An automated run's window is minimized; macOS clamps an off-view position back on screen.
const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")

const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/TransportPass.gd"
const NX: int = 8
const CELL: float = 2000.0
const DT: float = 1.0
const P: float = 101325.0
const T: float = 15.0
const V: float = 20.0
const C_STIFF: float = 4000.0
const RHO: float = 10.0
const STEPS: int = 3

var _rd: RenderingDevice = null
var _owned: Array[RID] = []


func _filled(n: int, v: float) -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	a.fill(v)
	return a


func _f32(vals: PackedFloat32Array) -> RID:
	var b: PackedByteArray = vals.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	_owned.append(r)
	return r


func _i32(vals: PackedInt32Array) -> RID:
	var b: PackedByteArray = vals.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	_owned.append(r)
	return r


func _write(bufs: Dictionary, key: String, vals: PackedFloat32Array) -> void:
	var b: PackedByteArray = vals.to_byte_array()
	_rd.buffer_update(bufs[key], 0, b.size(), b)


## The seam box of check_active_rows: a stiff right half whose own sound speed earns it a finer clock
## than the left's, and matter crossing every face.
func _build() -> Dictionary:
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(NX, 1, 1, CELL, Vector3(-0.5 * float(NX) * CELL, -0.5 * CELL, -0.5 * CELL))
	var cc: int = grid.cell_count
	var bufs: Dictionary = {"__cc": cc, "__faces": grid.neighbours.size(), "__origin": grid.origin}
	for name in LAChannels.channels():
		bufs[String(name)] = _f32(_filled(cc, 0.0))
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(_filled(cc, 0.0))
	for name in ["h_h2o", "h_silicate", "h_sensible", "cap_sensible", "celerity", "speed", "rad_w_m3",
			"bodyf_x", "bodyf_y", "bodyf_z", "grav_phi", "grav_ref", "k_cond", "mom_orphan"]:
		bufs[name] = _f32(_filled(cc, 0.0))
	bufs["gravity"] = _f32(_filled(cc * 3, 0.0))
	bufs["slot_off"] = _i32(grid.slot_off)
	bufs["face_partner"] = _i32(grid.partners)
	bufs["cell_edge"] = _f32(grid.cell_edges())
	# Everything the derive owns, temporal levels and active lists included, from its own declaration.
	var sd: RefCounted = (load("res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd") as GDScript).new()
	sd.ghost_count = 0
	var derived: Dictionary = sd._buffers(cc)
	for key in derived:
		var spec: Variant = derived[key]
		var n: int = int(spec["n"]) if spec is Dictionary else int(spec)
		var indirect: bool = spec is Dictionary and bool(spec.get("indirect", false))
		var zeros: PackedByteArray = _filled(n, 0.0).to_byte_array()
		var r: RID = _rd.storage_buffer_create(zeros.size(), zeros,
			RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT if indirect else 0)
		_owned.append(r)
		bufs[String(key)] = r
	bufs["nbr"] = _i32(grid.neighbours)
	var ghost_tbl: PackedInt32Array = PackedInt32Array()
	ghost_tbl.resize(cc * LAVoxelGrid.SLOTS)
	ghost_tbl.fill(-1)
	bufs["ghost"] = _i32(ghost_tbl)

	var cel: PackedFloat32Array = PackedFloat32Array()
	var h2o: PackedFloat32Array = PackedFloat32Array()
	var o2: PackedFloat32Array = PackedFloat32Array()
	var co2: PackedFloat32Array = PackedFloat32Array()
	var momz: PackedFloat32Array = PackedFloat32Array()
	var velz: PackedFloat32Array = PackedFloat32Array()
	var spd: PackedFloat32Array = PackedFloat32Array()
	for c in cc:
		cel.append(C_STIFF if c >= cc / 2 else 0.0)
		h2o.append(500.0 - 40.0 * float(c))
		o2.append(200.0 + 10.0 * float(c))
		co2.append(50.0 + 3.0 * float(c))
		momz.append(10.0 + 2000.0 * float(c))
		velz.append((10.0 + 2000.0 * float(c)) / RHO)
		spd.append(sqrt(V * V + velz[c] * velz[c]))
	_write(bufs, "vel_x", _filled(cc, V))
	_write(bufs, "vel_z", velz)
	_write(bufs, "mom_z", momz)
	_write(bufs, "speed", spd)
	_write(bufs, "celerity", cel)
	_write(bufs, "h2o", h2o)
	_write(bufs, "o2", o2)
	_write(bufs, "co2", co2)
	_write(bufs, "h2o_liquid", _filled(cc, 1.0))
	_write(bufs, "rho_bulk", _filled(cc, RHO))
	_write(bufs, "pressure", _filled(cc, P))
	_write(bufs, "temp", _filled(cc, T))
	return bufs


func _attach(bufs: Dictionary) -> RefCounted:
	var cc: int = int(bufs["__cc"])
	var p: RefCounted = (load(PASS_PATH) as GDScript).new()
	p.ghost_count = 0
	p.face_count = int(bufs["__faces"])
	p.grid_cell_size = CELL
	p.grid_origin = bufs["__origin"]
	var want: Dictionary = p._buffers(cc)
	for key in want:
		var spec: Variant = want[key]
		var n: int = int(spec["n"]) if spec is Dictionary else int(spec)
		var indirect: bool = spec is Dictionary and bool(spec.get("indirect", false))
		var zeros: PackedByteArray = _filled(n, 0.0).to_byte_array()
		var r: RID = _rd.storage_buffer_create(zeros.size(), zeros,
			RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT if indirect else 0)
		_owned.append(r)
		bufs[String(key)] = r
	p.setup(_rd, bufs, cc)
	return p


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		printerr("no RenderingDevice — this gate cannot run.")
		quit(2)
		return
	LAProcessSet.declare(LAProcessSet.ADVECT)
	var bufs: Dictionary = _build()
	var cc: int = int(bufs["__cc"])
	var p: RefCounted = _attach(bufs)
	var ctx: Dictionary = {"cell_size": CELL, "cell_size_min": CELL, "sun_dir": Vector3.ZERO, "dt_s": DT}
	var groups: int = int(ceil(float(cc) / 64.0))
	# POSITIVE CONTROL: without two levels the box never straddles a seam and the hash below is a hash
	# of a world one clock stepped, which is not what this gate is for.
	p.pre_step(_rd, ctx, cc, groups)
	var peak: int = 0
	for g in p._peaks.size():
		peak = maxi(peak, int(p._peaks[g]))
	if peak < 1:
		printerr("no row group asked for a finer clock, so the seam this gate holds does not exist.")
		quit(2)
		return
	for _s in STEPS:
		p.pre_step(_rd, ctx, cc, groups)
		var cl: int = _rd.compute_list_begin()
		p.dispatch(_rd, cl, ctx, cc, groups)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
	var names: PackedStringArray = LAChannels.channels()
	names.append_array(LAChannels.derived_buffers())
	names.sort()
	var hc: HashingContext = HashingContext.new()
	hc.start(HashingContext.HASH_MD5)
	var moved: bool = false
	for name in names:
		if not bufs.has(String(name)):
			continue
		var raw: PackedByteArray = _rd.buffer_get_data(bufs[String(name)], 0, cc * 4)
		hc.update(String(name).to_utf8_buffer())
		hc.update(raw)
		var vals: PackedFloat32Array = raw.to_float32_array()
		for c in cc:
			if not is_finite(vals[c]):
				printerr("the seam box reached a non-finite %s, so this state is not a state." % name)
				quit(2)
				return
	var h2o_end: PackedFloat32Array = _rd.buffer_get_data(bufs["h2o"], 0, cc * 4).to_float32_array()
	for c in cc:
		if h2o_end[c] != 500.0 - 40.0 * float(c):
			moved = true
	if not moved:
		printerr("nothing crossed any face, so an identical state proves nothing.")
		quit(2)
		return
	print("DRIVER_SEAM=%s cells=%d peak=%d steps=%d"
		% [hc.finish().hex_encode(), cc, peak, STEPS])
	p.dispose(_rd)
	for r in _owned:
		if r.is_valid():
			_rd.free_rid(r)
	_rd.free()
	quit(0)
GD

out="$(LA_DONE_RE='^DRIVER_SEAM=' "$ROOT/scripts/run_sim_offscreen.sh" \
  --path "$ROOT" -s "res://addons/local_agents/tests/zz_driver_native_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^DRIVER_SEAM=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no DRIVER_SEAM line — it examined nothing, so this refuses to pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
[ "$rc" -eq 2 ] && { echo "The probe could not run. See above." >&2; exit 2; }

kern="$(cat "$KERNELS"/transport.glsl "$KERNELS"/stack.glsli 2>/dev/null | md5 -q)"
state="${line#DRIVER_SEAM=}"
state="${state%% *}"

if [ "$RECORD" = "1" ]; then
  mkdir -p "$(dirname "$FIXTURE")"
  printf 'kernels %s\nstate %s\n' "$kern" "$state" > "$FIXTURE"
  echo "check_driver_native: recorded $FIXTURE"
  echo "$line"
  exit 0
fi

[ -f "$FIXTURE" ] || { echo "ERROR: no $FIXTURE. Record one with --record." >&2; exit 2; }
want_kern="$(awk '$1=="kernels"{print $2}' "$FIXTURE")"
want_state="$(awk '$1=="state"{print $2}' "$FIXTURE")"
if [ "$kern" != "$want_kern" ]; then
  echo "ERROR: transport.glsl/stack.glsli changed since the expected state was recorded." >&2
  echo "       Re-record deliberately: scripts/check_driver_native.sh --record" >&2
  exit 2
fi
if [ "$state" != "$want_state" ]; then
  echo "check_driver_native: the seam box ended in a different state than the recorded one." >&2
  echo "  expected $want_state" >&2
  echo "  got      $state" >&2
  exit 1
fi
echo "$line"

# --- arm three: the seeded world runs this driver ----------------------------------------------------
# A declared second arm: the shared capture is the full world, this arm boots the playable rung.
out2="$("$ROOT/scripts/sim_run.sh" --path "$ROOT" --from-seal --rung 2 --frames 20 --report field_step 2>&1)"
rc2=$?
line2="$(printf '%s\n' "$out2" | grep -m1 'field_step')"
if [ -z "$line2" ] || printf '%s' "$line2" | grep -q 'ABSENT'; then
  echo "check_driver_native: the seeded world published no field_step (exit $rc2), so the arms above" >&2
  echo "                     judged a rig nobody boots." >&2
  printf '%s\n' "$out2" | tail -6 >&2
  exit 2
fi
echo "DRIVER_WORLD=$line2"
echo "check_driver_native: OK"

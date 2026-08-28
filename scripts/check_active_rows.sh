#!/usr/bin/env bash
# THE CELL LIST A ROW WALKS, in space and in time — ONE machine, one rig, one engine. It drives
# TransportPass on sealed lines: across a seam between two clocks, where every matter channel holds
# its total; settled, where the active count falls to nothing while the books still close; and with
# one blob, which may not outrun one cell per substep nor lose a mole at the edge of its own bubble.
# EXIT 0 clean · 1 a leak or it never emptied · 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/lib_capture.sh"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
command -v rg >/dev/null 2>&1 || { echo "ERROR: rg absent — a gate that cannot run FAILS." >&2; exit 2; }
PASS="$REPO_ROOT/addons/local_agents/sim/material/sphere_passes/TransportPass.gd"
[ -f "$PASS" ] || { echo "ERROR: TransportPass.gd missing." >&2; exit 2; }
[ -f "$REPO_ROOT/scripts/run_sim_offscreen.sh" ] || { echo "ERROR: run_sim_offscreen.sh missing." >&2; exit 2; }

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_active_rows_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

# An automated run's window is minimized; macOS clamps an off-view position back on screen.
const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")

const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/TransportPass.gd"
const CELL: float = 4000.0
const DT: float = 1.0
const NX: int = 16
const SEED_CELL: int = 5
const STEPS: int = 3
const BLOB_MOL_M3: float = 500.0
# Air at rest carrying its own sound speed, so the acoustic pair has real state to advance.
const RHO_BULK: float = 1.225
# The seam box: a stiff right half, whose own sound speed earns it a finer clock than the left's, and
# matter crossing every face at a speed the clock is not the business of.
const SEAM_CELL: float = 2000.0
const SEAM_P: float = 101325.0
const SEAM_T: float = 15.0
const SEAM_V: float = 20.0
## The right half is shock-heated, and a gas's own sqrt(gamma R T) is then the seam.
const SEAM_T_STIFF: float = 10000.0
const SEAM_RHO: float = 10.0
const TOL: float = 1.0e-5

var _rd: RenderingDevice = null
var _fails: int = 0


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		printerr("check_active_rows: " + msg)
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


func _read(bufs: Dictionary, key: String) -> PackedFloat32Array:
	return _rd.buffer_get_data(bufs[key]).to_float32_array()


func _total(bufs: Dictionary, key: String, cc: int) -> float:
	var a: PackedFloat32Array = _read(bufs, key)
	var s: float = 0.0
	for c in cc:
		s += a[c]
	return s


## One field step of the transport pass alone: the peaks it reads, then every group's substeps.
func _step(p: RefCounted, ctx: Dictionary, cc: int) -> void:
	var groups: int = int(ceil(float(cc) / 64.0))
	p.pre_step(_rd, ctx, cc, groups)
	var cl: int = _rd.compute_list_begin()
	p.dispatch(_rd, cl, ctx, cc, groups)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()


## A world of nothing but the box: every channel empty, no wind, no gradient, no clock but the field's.
func _build(owned: Array[RID]) -> Dictionary:
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(NX, 1, 1, CELL, Vector3(-0.5 * float(NX) * CELL, -0.5 * CELL, -0.5 * CELL))
	var cc: int = grid.cell_count
	var bufs: Dictionary = {"__cc": cc}
	for name in LAChannels.channels():
		bufs[String(name)] = _f32(_filled(cc, 0.0), owned)
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(_filled(cc, 0.0), owned)
	for name in ["h_h2o", "h_silicate", "h_sensible", "cap_sensible", "celerity", "k_cond", "speed", "rad_w_m3",
			"bodyf_x", "bodyf_y", "bodyf_z", "grav_phi"]:
		bufs[name] = _f32(_filled(cc, 0.0), owned)
	bufs["gravity"] = _f32(_filled(cc * 3, 0.0), owned)
	bufs["g_rest"] = _f32(_filled(cc * 3, 0.0), owned)
	bufs["nbr"] = _i32(grid.neighbours, owned)
	var ghost_tbl: PackedInt32Array = PackedInt32Array()
	ghost_tbl.resize(grid.neighbours.size())
	ghost_tbl.fill(-1)
	bufs["ghost"] = _i32(ghost_tbl, owned)
	_write(bufs, "rho_bulk", _filled(cc, RHO_BULK))
	_write(bufs, "h2o_liquid", _filled(cc, 1.0))
	return bufs


func _attach(bufs: Dictionary, owned: Array[RID]) -> RefCounted:
	var cc: int = int(bufs["__cc"])
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
	p.setup(_rd, bufs, cc)
	return p


## THE SEAM BETWEEN TWO CLOCKS. A fast cell subdivides its own timestep while its quiet neighbour steps
## once; the face between them runs on the coarser of the two, so both sides write the same flux on the
## same substep. The sorted list they walk is the one the arms below hold to the moving cells.
func _seam() -> void:
	var nx: int = 8
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(nx, 1, 1, SEAM_CELL, Vector3(-0.5 * float(nx) * SEAM_CELL, -0.5 * SEAM_CELL, -0.5 * SEAM_CELL))
	var cc: int = grid.cell_count
	var owned: Array[RID] = []
	var bufs: Dictionary = {}
	for name in LAChannels.channels():
		bufs[String(name)] = _f32(_filled(cc, 0.0), owned)
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(_filled(cc, 0.0), owned)
	for name in ["h_h2o", "h_silicate", "h_sensible", "cap_sensible", "celerity", "k_cond", "speed", "rad_w_m3",
			"bodyf_x", "bodyf_y", "bodyf_z", "grav_phi"]:
		bufs[name] = _f32(_filled(cc, 0.0), owned)
	bufs["gravity"] = _f32(_filled(cc * 3, 0.0), owned)
	bufs["g_rest"] = _f32(_filled(cc * 3, 0.0), owned)
	bufs["nbr"] = _i32(grid.neighbours, owned)
	var ghost_tbl: PackedInt32Array = PackedInt32Array()
	ghost_tbl.resize(grid.neighbours.size())
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
	var h2o: PackedFloat32Array = PackedFloat32Array()
	var o2: PackedFloat32Array = PackedFloat32Array()
	var co2: PackedFloat32Array = PackedFloat32Array()
	# A sheared momentum column beside the flow, so every row of the group leaves a NONZERO face flux:
	# a stale one a coarse neighbour never wrote this substep is then visible as matter appearing.
	var temps: PackedFloat32Array = PackedFloat32Array()
	var momz: PackedFloat32Array = PackedFloat32Array()
	var velz: PackedFloat32Array = PackedFloat32Array()
	var spd: PackedFloat32Array = PackedFloat32Array()
	for c in cc:
		h2o.append(500.0 - 40.0 * float(c))
		o2.append(200.0 + 10.0 * float(c))
		co2.append(50.0 + 3.0 * float(c))
		temps.append(SEAM_T_STIFF if c >= cc / 2 else SEAM_T)
		momz.append(10.0 + 2000.0 * float(c))
		velz.append((10.0 + 2000.0 * float(c)) / SEAM_RHO)
		spd.append(sqrt(SEAM_V * SEAM_V + velz[c] * velz[c]))
	_write(bufs, "vel_x", _filled(cc, SEAM_V))
	_write(bufs, "vel_z", velz)
	_write(bufs, "mom_z", momz)
	_write(bufs, "speed", spd)
	_write(bufs, "h2o", h2o)
	_write(bufs, "o2", o2)
	_write(bufs, "co2", co2)
	_write(bufs, "h2o_liquid", _filled(cc, 1.0))
	_write(bufs, "rho_bulk", _filled(cc, SEAM_RHO))
	_write(bufs, "pressure", _filled(cc, SEAM_P))
	_write(bufs, "temp", temps)

	p.setup(_rd, bufs, cc)
	var checked: PackedStringArray = PackedStringArray(["h2o", "o2", "co2"])
	var before: Dictionary = {}
	for ch in checked:
		before[String(ch)] = _total(bufs, String(ch), cc)
	var start: PackedFloat32Array = _rd.buffer_get_data(bufs["h2o"]).to_float32_array()

	var ctx: Dictionary = {"cell_size": SEAM_CELL, "sun_dir": Vector3.ZERO, "dt_s": DT}
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
	p.build_levels(lcl, top, cc, SEAM_CELL, DT, Vector3.ZERO, peak)
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


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		printerr("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		quit(2)
		return
	# UP TO ADVECT: everything that carries matter across a face, and nothing that radiates. A box that
	# emits its own heat to space is never settled, so a rung holding RADIATION could not answer arm one.
	_seam()
	LAProcessSet.declare(LAProcessSet.ADVECT)
	var ctx: Dictionary = {"cell_size": CELL, "sun_dir": Vector3.ZERO, "dt_s": DT}

	# --- ARM ONE: A SETTLED BOX SLEEPS, AND ITS BOOKS STILL CLOSE ---------------------------------
	var owned_a: Array[RID] = []
	var still: Dictionary = _build(owned_a)
	var cc: int = int(still["__cc"])
	# MATTER AT REST IS STILL MATTER: uniform, so no face carries a gradient and nothing has anywhere
	# to go. An empty box would sleep for the wrong reason.
	_write(still, "h2o", _filled(cc, BLOB_MOL_M3))
	_write(still, "co2", _filled(cc, BLOB_MOL_M3))
	var pa: RefCounted = _attach(still, owned_a)
	var rows: int = int(pa._rows.size())
	_expect(rows > 0, "the process rung this ran at holds no transport rows, so nothing was examined.")
	var still_h2o: float = _total(still, "h2o", cc)
	_expect(still_h2o > 0.0, "the settled box holds nothing, so its sleeping proves nothing.")
	for _i in STEPS:
		_step(pa, ctx, cc)
	var idle: int = int(pa._active_cells(_rd))
	_expect(idle == 0, "a box where nothing moves still dispatches %d cells, so no cell ever sleeps."
		% idle)
	_expect(absf(_total(still, "h2o", cc) - still_h2o) <= TOL,
		"the settled box's own water total moved while nothing was stepping it.")
	pa.dispose(_rd)
	for r in owned_a:
		if r.is_valid():
			_rd.free_rid(r)

	# --- ARM TWO: ONE BLOB, ITS OWN BUBBLE, AND NOT A MOLE LOST AT THE EDGE ------------------------
	var owned_b: Array[RID] = []
	var box: Dictionary = _build(owned_b)
	# A PRESSURE FRONT IN ONE CELL and a box at rest around it: nothing else in this world has a
	# gradient, so whatever wakes is what the front reached.
	var blob: PackedFloat32Array = _filled(cc, 0.0)
	blob[SEED_CELL] = BLOB_MOL_M3
	_write(box, "shock", blob)
	var pb: RefCounted = _attach(box, owned_b)
	var before: float = _total(box, "shock", cc)
	_expect(before > 0.0, "the blob seeded nothing, so this arm examined nothing.")
	for _k in STEPS:
		_step(pb, ctx, cc)
	var after: PackedFloat32Array = _read(box, "shock")
	var sum: float = 0.0
	var reach: int = 0
	for c in cc:
		sum += after[c]
		if after[c] != 0.0:
			reach = maxi(reach, absi(c - SEED_CELL))
	# THE ONE CONSERVATION THIS ANSWERS: matter crossing into a cell the mask had asleep is matter gone.
	_expect(absf(sum - before) <= TOL * maxf(absf(before), 1.0),
		"the blob started at %s and the box now holds %s: what it pushed past the edge of its own "
		% [String.num_scientific(before), String.num_scientific(sum)]
		+ "bubble was never gathered, because nothing there was awake to gather it.")
	_expect(reach > 0, "the blob never moved, so a bounded bubble proves nothing.")
	# ONE CELL PER SUBSTEP is the fastest anything travels, and this box takes one substep per step.
	_expect(reach <= STEPS, "the blob reached %d cells from where it was seeded in %d steps: matter "
		% [reach, STEPS] + "outran its own signal speed.")
	var bubble: int = int(pb._active_cells(_rd))
	_expect(bubble > 0 and bubble < int(pb._group_count()) * cc,
		"the blob's bubble holds %d of %d dispatchable cells, so it is not a bubble."
		% [bubble, int(pb._group_count()) * cc])
	pb.dispose(_rd)
	for r in owned_b:
		if r.is_valid():
			_rd.free_rid(r)

	print('ACTIVE_ROWS={"cells":%d,"rows":%d,"settled_active":%d,"blob_reach":%d,"blob_active":%d,"failures":%d}'
		% [cc, rows, idle, reach, bubble, _fails])
	_rd.free()
	quit(1 if _fails > 0 else 0)
GD

out="$(LA_DONE_RE='^ACTIVE_ROWS=' LA_RUNG="${LA_RUNG:-5}" "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_active_rows_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^ACTIVE_ROWS=')"
seam="$(printf '%s\n' "$out" | grep -m1 '^LEVEL_REFLUX=')"
if [ -z "$line" ] || [ -z "$seam" ]; then
  echo "ERROR: the probe produced no ACTIVE_ROWS or no LEVEL_REFLUX line — an arm that did not run" >&2
  echo "       examined nothing, so this refuses to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$seam"
echo "$line"
printf '%s\n' "$out" | grep '^check_active_rows:' >&2 || true
if [ "$rc" -eq 2 ]; then
  echo "The gate could not run. See the probe output above." >&2
  exit 2
fi
[ "$rc" -eq 0 ] || exit 1

# --- arm four: THE SEEDED WORLD, which is the only box this rig cannot build ------------------------
# It asks the shared lint arm for its own reading, so it starts no engine of its own.
if la_cap_dir >/dev/null; then
  out2="$(la_report active_cells,transport_levels 2>&1)"
  rc2=$?
else
  out2="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --from-seal --frames "${LA_ACTIVE_FRAMES:-2}" \
    --rung "${LA_ACTIVE_RUNG:-5}" --report active_cells,transport_levels 2>&1)"
  rc2=$?
  case "$rc2" in 0|122|123|126) ;; *) out2="" ;; esac
fi
line2="$(printf '%s\n' "$out2" | grep -m1 'active_cells')"
if [ -z "$line2" ] || printf '%s' "$line2" | grep -q 'ABSENT'; then
  echo "check_active_rows: the seeded world published no active_cells (exit $rc2) — an absent reading" >&2
  echo "                   examined nothing, so this arm judged that world not at all." >&2
  printf '%s\n' "$out2" | tail -6 >&2
  exit 2
fi
cur="$(printf '%s' "$line2" | grep -oE "'cur': *[0-9.]+" | grep -oE '[0-9.]+' | head -1)"
[ -n "$cur" ] || cur="$(printf '%s' "$line2" | grep -oE '[0-9.]+' | head -1)"
awk -v v="${cur:-0}" 'BEGIN { exit (v > 0) ? 0 : 1 }' || {
  echo "check_active_rows: the seeded world dispatched no cell at all — the rows are not running." >&2
  exit 1
}
echo "ACTIVE_ROWS_WORLD=$line2"
echo "check_active_rows: OK"

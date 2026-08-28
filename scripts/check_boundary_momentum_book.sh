#!/usr/bin/env bash
# MOMENTUM CROSSING AN OPEN BOUNDARY IS BOOKED, judged by the REAL evaluator: TransportPass dispatching
# transport.glsl over a two-cell rig with CONSTANT and REPLAY faces from the real LAFieldBoundary3D.
# bnd_mom_* books the whole exchange with everything outside the fluid, walls and the REPLAY rim's
# nudge included — applied and booked once, no heat leg, held by differencing against the relax-off arm.
# LABoundaryBooks promises no heat leg for a signed channel and still names a matter channel's absent one.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/transport.glsl"
PASS="$REPO_ROOT/addons/local_agents/sim/material/sphere_passes/TransportPass.gd"
[ -f "$KERNEL" ] || { echo "ERROR: transport.glsl missing." >&2; exit 2; }
[ -f "$PASS" ] || { echo "ERROR: TransportPass.gd missing." >&2; exit 2; }

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_boundary_momentum_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

# An automated run's window is minimized; macOS clamps an off-view position back on screen.
const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")

const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/TransportPass.gd"
const CELL: float = 0.5
const P_IN: float = 101325.0
const T_C: float = 15.0

var _rd: RenderingDevice = null
var _fails: int = 0


class StubGpu:
	extends RefCounted
	var _rd: RenderingDevice = null
	var _bufs: Dictionary = {}


func _expect(ok: bool, msg: String) -> void:
	if not ok:
		printerr("check_boundary_momentum_book: " + msg)
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


## One dispatch of the real TransportPass over a 2x1x1 rig at rest at `P_IN`. Face 0 holds `mode` at
## `p_ghost` Pa of real air (n = p/RT) moving at `vel`; NAN shuts every wall. `relax_on` false strips
## the momentum rows' rim flag — the disabled arm the rim assertions difference against.
func _run(p_ghost: float, mode: int = LAFieldBoundary3D.CONSTANT, vel: Vector3 = Vector3.ZERO,
		relax_on: bool = true) -> Dictionary:
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(2, 1, 1, CELL, Vector3(-CELL, -0.5 * CELL, -0.5 * CELL))
	var cc: int = grid.cell_count
	var bnd: LAFieldBoundary3D = null
	var ng: int = 0
	if is_finite(p_ghost):
		bnd = LAFieldBoundary3D.new()
		var modes: PackedInt32Array = PackedInt32Array([mode,
			LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT,
			LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT])
		var n_air: float = p_ghost / (LAPhysical.GAS_CONSTANT_J_MOL_K * (T_C + LAPhysical.KELVIN_OFFSET))
		var st: Dictionary = {"temp_c": T_C, "pressure_pa": p_ghost, "gravity": Vector3.ZERO,
			"velocity": vel, "amounts": {"n2": 0.78 * n_air, "o2": 0.21 * n_air}}
		if not bnd.configure(grid, modes, [st, null, null, null, null, null]):
			_expect(false, "boundary configure failed: " + bnd.error)
			return {}
		ng = bnd.ghost_count()
		_expect(ng == 1, "a 2x1x1 x-low face should hold one ghost cell, got %d." % ng)
	var tc: int = cc + ng
	var owned: Array[RID] = []
	var bufs: Dictionary = {}
	for name in LAChannels.channels():
		bufs[String(name)] = _f32(_filled(tc, 0.0), owned)
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(_filled(tc, 0.0), owned)
	for name in ["h_h2o", "h_silicate", "h_sensible", "cap_sensible", "celerity", "k_cond", "speed", "rad_w_m3",
			"bodyf_x", "bodyf_y", "bodyf_z", "grav_phi"]:
		bufs[name] = _f32(_filled(tc, 0.0), owned)
	bufs["gravity"] = _f32(_filled(tc * 3, 0.0), owned)
	bufs["nbr"] = _i32(grid.neighbours, owned)
	var ghost_tbl: PackedInt32Array = PackedInt32Array()
	ghost_tbl.resize(tc * LAVoxelGrid.SLOTS)
	ghost_tbl.fill(-1)
	bufs["ghost"] = _i32(ghost_tbl, owned)

	var p: RefCounted = (load(PASS_PATH) as GDScript).new()
	p.ghost_count = ng
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

	# Air of that pressure holds this mass: a cell at P with zero density is not a state matter has, and
	# the gas layer's sound speed follows from the pressure and the mass rather than being typed beside it.
	var rho_air: float = P_IN / (LAPhysical.DRY_AIR_GAS_CONSTANT_J_KGK * (T_C + LAPhysical.KELVIN_OFFSET))
	for pair: Array in [["pressure", P_IN], ["temp", T_C], ["rho_bulk", rho_air]]:
		var vals: PackedByteArray = _filled(tc, float(pair[1])).to_byte_array()
		_rd.buffer_update(bufs[String(pair[0])], 0, vals.size(), vals)

	p.setup(_rd, bufs, cc)
	if not relax_on:
		for row: Dictionary in p._rows:
			if String(row["channel"]).begins_with("mom_"):
				row.erase("relax")
	if bnd != null:
		var stub: StubGpu = StubGpu.new()
		stub._rd = _rd
		stub._bufs = bufs
		bnd.attach(stub)
		if bnd.error != "":
			_expect(false, "boundary attach failed: " + bnd.error)
	var cl: int = _rd.compute_list_begin()
	# The step is a small fraction of CELL over the sound speed: inside the explicit acoustic regime.
	p.dispatch(_rd, cl, {"cell_size": CELL, "sun_dir": Vector3.ZERO, "dt_s": 1.0e-4},
		cc, int(ceil(float(cc) / 64.0)))
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	var out: Dictionary = {}
	for key in ["bnd_mom_x", "bnd_mom_y", "bnd_mom_z", "bnd_n2",
			"mom_x", "mom_y", "mom_z", "h_j_m3"]:
		out[key] = _rd.buffer_get_data(bufs[String(key)]).to_float32_array()
	p.dispose(_rd)
	for r in owned:
		if r.is_valid():
			_rd.free_rid(r)
	return out


func _sum(vals: PackedFloat32Array) -> float:
	var s: float = 0.0
	for v in vals:
		s += float(v)
	return s


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		printerr("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		quit(2)
		return

	var gap: Dictionary = _run(2.0 * P_IN)
	var balanced: Dictionary = _run(P_IN)
	var shut: Dictionary = _run(NAN)
	if gap.is_empty() or balanced.is_empty() or shut.is_empty():
		quit(2)
		return

	var gap_x: float = float(gap["bnd_mom_x"][0])
	_expect(gap_x > 0.0, "a higher exterior pressure pushed momentum in through the open face and the "
		+ "edge cell booked none (bnd_mom_x %s)." % String.num_scientific(gap_x))
	_expect(float(gap["mom_x"][0]) > 0.0, "a higher exterior pressure did not accelerate the edge "
		+ "cell inward (mom_x %s)." % String.num_scientific(float(gap["mom_x"][0])))
	_expect(float(gap["bnd_mom_x"][1]) < 0.0, "the far cell's wall took the fluid's push and booked "
		+ "none of it.")
	_expect(_sum(gap["bnd_n2"]) > 0.0, "exterior air diffused in through the open face and bnd_n2 "
		+ "booked none.")
	# The open face's static flux and the far wall's push cancel exactly: no net momentum enters.
	_expect(_sum(balanced["bnd_mom_x"]) == 0.0, "a balanced box exchanged net momentum: bnd_mom_x "
		+ "reads %s." % String.num_scientific(_sum(balanced["bnd_mom_x"])))
	for c in 2:
		_expect(float(balanced["mom_x"][c]) == 0.0, "uniform pressure accelerated cell %d "
			% c + "(mom_x %s)." % String.num_scientific(float(balanced["mom_x"][c])))
	for key in ["bnd_mom_y", "bnd_mom_z"]:
		_expect(_sum(balanced[key]) == 0.0, "no y/z face is open yet %s reads %s."
			% [key, String.num_scientific(_sum(balanced[key]))])
	for key in ["bnd_mom_x", "bnd_mom_y", "bnd_mom_z"]:
		_expect(_sum(shut[key]) == 0.0, "every wall is shut yet %s reads %s."
			% [key, String.num_scientific(_sum(shut[key]))])

	# THE REPLAY RIM. Face 0 REPLAY at the same pressure, exterior air moving on all three axes; the
	# relax-off run is the disabled arm, so the difference IS the rim's momentum nudge.
	var drive: Vector3 = Vector3(10.0, 6.0, -4.0)
	var rim_on: Dictionary = _run(P_IN, LAFieldBoundary3D.REPLAY, drive)
	var rim_off: Dictionary = _run(P_IN, LAFieldBoundary3D.REPLAY, drive, false)
	if rim_on.is_empty() or rim_off.is_empty():
		quit(2)
		return
	var rim_dx: float = 0.0
	for i in 3:
		var a: String = ["x", "y", "z"][i]
		var db: float = _sum(rim_on["bnd_mom_" + a]) - _sum(rim_off["bnd_mom_" + a])
		var dm: float = _sum(rim_on["mom_" + a]) - _sum(rim_off["mom_" + a])
		if i == 0:
			rim_dx = db
		_expect(db * drive[i] > 0.0, "the rim nudged the field toward the driving state and bnd_mom_%s "
			% a + "booked none of it (booked %s against exterior drive %s)."
			% [String.num_scientific(db), String.num_scientific(drive[i])])
		_expect(absf(db - dm) <= 1.0e-3 * maxf(maxf(absf(db), absf(dm)), 1.0e-6),
			"the rim's %s nudge and its booking disagree: applied %s, booked %s — double-counted "
			% [a, String.num_scientific(dm), String.num_scientific(db)] + "or part-unbooked.")
	_expect(float(rim_on["bnd_mom_x"][1]) - float(rim_off["bnd_mom_x"][1]) > 0.0,
		"the rim reaches inward of the face, yet the second rim cell's nudge never reached bnd_mom_x.")
	_expect(_sum(rim_on["h_j_m3"]) == _sum(rim_off["h_j_m3"]),
		"the momentum rim moved enthalpy — momentum is not matter and carries no heat leg.")

	# The matter/energy books never promise a heat leg for a signed channel, and still name a matter
	# channel's absent heat leg.
	var declared: PackedStringArray = LABoundaryBooks.declared()
	_expect(not declared.has("mom_x"), "LABoundaryBooks declares mom_x and will demand a heat leg "
		+ "momentum does not have.")
	_expect(declared.has("h2o"), "LABoundaryBooks no longer declares h2o.")
	var drain: Dictionary = {}
	for ch in declared:
		drain["bnd_" + String(ch)] = 0.0
		drain["bnd_h_" + String(ch)] = 0.0
	drain.erase("bnd_h_h2o")
	var books: LABoundaryBooks = LABoundaryBooks.new()
	books.sample(drain)
	_expect(books.missing.has("bnd_h_h2o"), "h2o's heat leg vanished from the drain and nothing "
		+ "named it — the missing-leg detection is dead.")
	_expect(not books.missing.has("bnd_h2o"), "a leg that was present got named missing.")

	print('BOUNDARY_MOMENTUM_BOOK={"gap_x":%s,"balanced":%s,"shut":%s,"rim_x":%s,"failures":%d}'
		% [String.num_scientific(gap_x), String.num_scientific(_sum(balanced["bnd_mom_x"])),
			String.num_scientific(_sum(shut["bnd_mom_x"])), String.num_scientific(rim_dx), _fails])
	_rd.free()
	quit(1 if _fails > 0 else 0)
GD

out="$(LA_DONE_RE='^BOUNDARY_MOMENTUM_BOOK=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_boundary_momentum_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^BOUNDARY_MOMENTUM_BOOK=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no BOUNDARY_MOMENTUM_BOOK line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
printf '%s\n' "$out" | grep '^check_boundary_momentum_book:' >&2 || true
if [ "$rc" -eq 2 ]; then
  echo "The gate could not run. See the probe output above." >&2
  exit 2
fi
if [ "$rc" -ne 0 ]; then
  exit 1
fi

# ---------------------------------------------------------------------------------------------------
# ARM TWO — the world the SIM seeds. bnd_mom_* books the whole exchange with everything outside the
# fluid, WALLS INCLUDED (the ground's normal force holds the ocean up), so the book is not zero there;
# the rig's shut sub-arm above owns the exact-zero case. Here the fold must be PRESENT and FINITE —
# an absent reading is the fold unwired, a non-finite one is the ledger poisoned.
# The same run records the face-state capture ARM THREE replays.
# ---------------------------------------------------------------------------------------------------
SIM_FRAMES="${LA_BND_MOM_FRAMES:-20}"
OWN_CAP=0
if la_cap_dir >/dev/null; then
  CAP="$(la_cap_state)" || exit 2
  sim_out="$(la_report momentum_book_bnd 2>&1)"
  sim_rc=$?
else
  CAP="${LA_BND_MOM_CAP:-$(mktemp "${TMPDIR:-/tmp}/bnd_mom_cap.XXXXXX")}"
  OWN_CAP=1
  sim_out="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --rung 3 --frames "$SIM_FRAMES" \
    --slice-capture "$CAP" --report momentum_book_bnd 2>&1)"
  sim_rc=$?
fi
drop_cap() { [ "$OWN_CAP" -eq 1 ] && rm -f "$CAP"; return 0; }
reading="$(printf '%s\n' "$sim_out" | sed -n 's/^momentum_book_bnd  *= *//p' | head -1)"
printf 'momentum_book_bnd = %s\n' "${reading:-<none>}"
if [ -z "$reading" ] || printf '%s' "$reading" | grep -q '<ABSENT>'; then
  echo "ERROR: the run published no momentum_book_bnd (sim_run exit $sim_rc) — the boundary fold is" >&2
  echo "       unwired or the report is dead. Refusing to report a pass." >&2
  printf '%s\n' "$sim_out" | tail -20 >&2
  drop_cap
  exit 2
fi
if printf '%s' "$reading" | grep -qiE 'nan|inf|null|None'; then
  echo
  echo "The seeded world's momentum boundary book reads $reading — the fold is poisoned."
  drop_cap
  exit 1
fi

# ---------------------------------------------------------------------------------------------------
# ARM THREE — the REPLAY slice. The capture ARM TWO recorded drives a slice's vertical faces in REPLAY
# mode, standing the relaxation rim up on the real seeded path; the fold must engage REPLAY (not fall
# back to CONSTANT) and publish a present, finite momentum_book_bnd.
# ---------------------------------------------------------------------------------------------------
if [ ! -s "$CAP" ] || ! grep -q '"samples"' "$CAP"; then
  echo "ERROR: the global run recorded no face-state capture at $CAP — the REPLAY arm cannot run." >&2
  drop_cap
  exit 2
fi
REPLAY_FRAMES="${LA_BND_MOM_REPLAY_FRAMES:-15}"
replay_out="$(LA_SLICE_REPLAY=1 "$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --slice --keep \
  --rung 3 --slice-state "$CAP" --frames "$REPLAY_FRAMES" --report momentum_book_bnd 2>&1)"
replay_rc=$?
drop_cap
# SLICE_BOUNDARY prints inside the engine log, which sim_run does not forward; --keep names it.
replay_log="$(printf '%s\n' "$replay_out" | sed -n 's/^sim_run: log kept at //p' | head -1)"
faces="$(grep -m1 '^SLICE_BOUNDARY=' "$replay_log" 2>/dev/null)"
rm -f "$replay_log"
if [ -z "$faces" ]; then
  echo "ERROR: the slice run printed no SLICE_BOUNDARY (sim_run exit $replay_rc) — no boundary stood up." >&2
  printf '%s\n' "$replay_out" | tail -20 >&2
  exit 2
fi
if ! printf '%s' "$faces" | grep -q 'replay'; then
  echo
  echo "LA_SLICE_REPLAY was set and the slice still stood up: $faces"
  echo "The REPLAY rim path is dead."
  exit 1
fi
rreading="$(printf '%s\n' "$replay_out" | sed -n 's/^momentum_book_bnd  *= *//p' | head -1)"
printf 'replay momentum_book_bnd = %s\n' "${rreading:-<none>}"
if [ -z "$rreading" ] || printf '%s' "$rreading" | grep -q '<ABSENT>'; then
  echo "ERROR: the REPLAY slice published no momentum_book_bnd (sim_run exit $replay_rc) — an absent" >&2
  echo "       book examined nothing. A violation is a book that EXISTS and does not close." >&2
  printf '%s\n' "$replay_out" | tail -20 >&2
  exit 2
fi
if printf '%s' "$rreading" | grep -qiE 'nan|inf|null|None'; then
  echo
  echo "The REPLAY slice's momentum boundary book reads $rreading — the fold is poisoned."
  exit 1
fi
echo "check_boundary_momentum_book: OK"

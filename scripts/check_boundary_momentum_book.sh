#!/usr/bin/env bash
# MOMENTUM CROSSING AN OPEN BOUNDARY IS BOOKED, judged by the REAL evaluator: TransportPass dispatching
# transport.glsl over a two-cell rig with one CONSTANT face from the real LAFieldBoundary3D. The PGF is a
# face FLUX (p n dt/L crosses every face, cancelling pairwise inside), so a balanced face books exactly
# the static flux while the cells' momentum stays exactly zero; a gap books more and accelerates the edge
# cell inward; shut walls book zero. LABoundaryBooks promises no heat leg for a signed channel and still
# names a matter channel's absent one.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
const CELL: float = 1.0
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


## One dispatch of the real TransportPass over a 2x1x1 rig at rest at `P_IN`. Face 0 is CONSTANT at
## `p_ghost` Pa with still air outside; NAN shuts every wall. Returns the boundary books off the device.
func _run(p_ghost: float) -> Dictionary:
	var grid: LAVoxelGrid = LAVoxelGrid.new()
	grid.build(2, 1, 1, CELL, Vector3(-1.0, -0.5, -0.5))
	var cc: int = grid.cell_count
	var bnd: LAFieldBoundary3D = null
	var ng: int = 0
	if is_finite(p_ghost):
		bnd = LAFieldBoundary3D.new()
		var modes: PackedInt32Array = PackedInt32Array([LAFieldBoundary3D.CONSTANT,
			LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT,
			LAFieldBoundary3D.SHUT, LAFieldBoundary3D.SHUT])
		var st: Dictionary = {"temp_c": T_C, "pressure_pa": p_ghost, "gravity": Vector3.ZERO,
			"velocity": Vector3.ZERO, "amounts": {"n2": 0.78, "o2": 0.21}}
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
	for name in ["h_h2o", "h_silicate", "h_sensible", "cap_sensible"]:
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

	for pair: Array in [["pressure", P_IN], ["temp", T_C]]:
		var vals: PackedByteArray = _filled(tc, float(pair[1])).to_byte_array()
		_rd.buffer_update(bufs[String(pair[0])], 0, vals.size(), vals)

	p.setup(_rd, bufs, cc)
	if bnd != null:
		var stub: StubGpu = StubGpu.new()
		stub._rd = _rd
		stub._bufs = bufs
		bnd.attach(stub)
		if bnd.error != "":
			_expect(false, "boundary attach failed: " + bnd.error)
	var cl: int = _rd.compute_list_begin()
	p.dispatch(_rd, cl, {"cell_size": CELL, "sun_dir": Vector3.ZERO}, cc, int(ceil(float(cc) / 64.0)))
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	var out: Dictionary = {}
	for key in ["bnd_mom_x", "bnd_mom_y", "bnd_mom_z", "bnd_n2"]:
		out[key] = _rd.buffer_get_data(bufs[String(key)]).to_float32_array()
	out["mom_x"] = _rd.buffer_get_data(bufs["mom_x"]).to_float32_array()
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
	_expect(float(gap["bnd_mom_x"][1]) == 0.0, "the interior cell touches no open face and booked "
		+ "momentum anyway.")
	_expect(_sum(gap["bnd_n2"]) > 0.0, "exterior air diffused in through the open face and bnd_n2 "
		+ "booked none.")
	# The static momentum flux p dt / L crosses the balanced face; the cells it enters do not move.
	var flux: float = P_IN * LAMaterialFieldSphereStep3D.real_seconds_per_step() / CELL
	var bal_x: float = _sum(balanced["bnd_mom_x"])
	_expect(absf(bal_x - flux) <= 1.0e-4 * flux, ("a balanced face carries the static flux %s yet "
		+ "bnd_mom_x reads %s.") % [String.num_scientific(flux), String.num_scientific(bal_x)])
	for c in 2:
		_expect(float(balanced["mom_x"][c]) == 0.0, "uniform pressure accelerated cell %d "
			% c + "(mom_x %s)." % String.num_scientific(float(balanced["mom_x"][c])))
	for key in ["bnd_mom_y", "bnd_mom_z"]:
		_expect(_sum(balanced[key]) == 0.0, "no y/z face is open yet %s reads %s."
			% [key, String.num_scientific(_sum(balanced[key]))])
	for key in ["bnd_mom_x", "bnd_mom_y", "bnd_mom_z"]:
		_expect(_sum(shut[key]) == 0.0, "every wall is shut yet %s reads %s."
			% [key, String.num_scientific(_sum(shut[key]))])

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
	books.sample(drain, 1.0)
	_expect(books.missing.has("bnd_h_h2o"), "h2o's heat leg vanished from the drain and nothing "
		+ "named it — the missing-leg detection is dead.")
	_expect(not books.missing.has("bnd_h2o"), "a leg that was present got named missing.")

	print('BOUNDARY_MOMENTUM_BOOK={"gap_x":%s,"balanced":%s,"shut":%s,"failures":%d}'
		% [String.num_scientific(gap_x), String.num_scientific(_sum(balanced["bnd_mom_x"])),
			String.num_scientific(_sum(shut["bnd_mom_x"])), _fails])
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
# ARM TWO — the world the SIM seeds. Every wall is shut there, so the momentum ledger's boundary book
# must read exactly zero on every axis; an absent reading is the fold unwired, not a zero.
# ---------------------------------------------------------------------------------------------------
SIM_FRAMES="${LA_BND_MOM_FRAMES:-20}"
sim_out="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --frames "$SIM_FRAMES" \
  --report momentum_book_bnd 2>&1)"
sim_rc=$?
reading="$(printf '%s\n' "$sim_out" | sed -n 's/^momentum_book_bnd  *= *//p' | head -1)"
printf 'momentum_book_bnd = %s\n' "${reading:-<none>}"
if [ -z "$reading" ] || printf '%s' "$reading" | grep -q '<ABSENT>'; then
  echo "ERROR: the run published no momentum_book_bnd (sim_run exit $sim_rc) — the boundary fold is" >&2
  echo "       unwired or the report is dead. Refusing to report a pass." >&2
  printf '%s\n' "$sim_out" | tail -20 >&2
  exit 2
fi
nonzero="$(printf '%s' "$reading" | tr -d '[] ' | tr ',' '\n' \
  | grep -Evc '^(-?0(\.0+)?|0)$' || true)"
if [ "${nonzero:-0}" -ne 0 ]; then
  echo
  echo "Every wall of the seeded world is shut, yet its momentum boundary book reads $reading —"
  echo "momentum is being booked across a boundary that does not exist."
  exit 1
fi
echo "check_boundary_momentum_book: OK"

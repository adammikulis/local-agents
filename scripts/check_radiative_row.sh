#!/usr/bin/env bash
# =====================================================================================================
# THE RADIATE ROW — checked against the radiation laws, on the device that runs it.
#
# transport.glsl's RADIATE row is the planet's only radiative model. It emits from every face of every
# cell and gathers what the neighbours sent, and it now writes its own per-cell books into rad_emitted
# and rad_absorbed, which the ledger reduces into the energy accounts. Three closed forms check it:
#
#   STEFAN-BOLTZMANN. A cube of side L at temperature T with emissivity e radiates e*sigma*T^4 out of
#   each of its six faces. The kernel carries that as J/m^3 per step, so rad_emitted must read
#   6 * e * sigma * T^4 * dt / L, and it must scale as T^4 between two temperatures. A units error in
#   the J/m^3 -> joules -> watts chain the ledger walks cannot survive both halves.
#
#   AN ISOTHERMAL BLOCK IS IN RADIATIVE EQUILIBRIUM. Radiation crosses more than one cell, so a cell
#   gathers the emission of the whole grid line behind each face, every term attenuated by the cells in
#   between. In an isothermal medium those terms telescope and rad_absorbed / rad_emitted is
#   (1/6) sum_d (1 - (1-e)^n_d), n_d the cells along d before the box edge — which goes to 1 as the
#   column deepens, because a body in an isothermal enclosure absorbs exactly what it emits. It reads e
#   instead when the mean free path is one cell, and it reads the wrong number the moment absorptivity
#   stops equalling emissivity, so one closed form gates Kirchhoff AND the column.
#
#   TRANSMISSION. A transparent cell between a hot emitter and a cold absorber must PASS the emission
#   on: what a cell does not absorb is not destroyed. The absorber two cells along receives
#   e * (e sigma T_hot^4 dt / L) and the clear cell in the middle absorbs exactly nothing.
#
#   A VACUUM DOES NOT RADIATE. A cell holding no matter at all must emit exactly zero, whatever its
#   temperature. This is the negative control: without it, a floor or a default in the emissivity would
#   pass the two arms above unnoticed.
#
# ARM TWO IS THE SIM'S OWN FIELD. Everything above builds its own grid, its own buffers and its own
# temperatures, so it cannot see whether the row ran in the world at all: a uniform set the driver cannot
# build makes the whole transport dispatch a no-op that arm one still reads as clean. The second arm boots
# the real world and reads the row's own books off it. Matter above absolute zero radiates, and a cell
# inside an opaque planet is surrounded by emitters, so both books are positive in a box holding condensed
# matter — with solid_cells as the positive control, since an empty box emits nothing by construction.
#
# WHAT ARM TWO STILL CANNOT ASSERT. Stefan-Boltzmann in the seeded world needs the per-cell residual
# computed beside the field it measures, in transport.glsl's RADIATE path, published as a gauge the way
# gravity publishes Gauss's law. Off the reduced books alone the law is only checkable as a sign.
#
# The row is a compute kernel, so this needs a real device: headless has none. It runs through
# run_sim_offscreen.sh, which takes the machine-wide GPU lock.
#
# EXIT CODES. 0 within tolerance · 1 the row is wrong · 2 could not run.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/transport.glsl"
PASS="$REPO_ROOT/addons/local_agents/sim/material/sphere_passes/TransportPass.gd"
[ -f "$KERNEL" ] || { echo "ERROR: transport.glsl missing." >&2; exit 2; }
[ -f "$PASS" ] || { echo "ERROR: TransportPass.gd missing." >&2; exit 2; }
grep -q "rad_emitted" "$KERNEL" || { echo "ERROR: transport.glsl writes no rad_emitted — nothing to check." >&2; exit 2; }

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_radiative_gate.gd"
cat > "$PROBE" <<'GD'
extends SceneTree

const N: int = 6
const CELL: float = 1.0
const ORIGIN: Vector3 = Vector3(-0.5 * N * CELL, -0.5 * N * CELL, -0.5 * N * CELL)
const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/TransportPass.gd"
const LIST_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/CellListPass.gd"

## Two temperatures far enough apart that T^4 separates them by more than any tolerance.
const COOL_C: float = 20.0
const HOT_C: float = 520.0
const REL_TOLERANCE: float = 0.01

var _rd: RenderingDevice = null
var _owned: Array[RID] = []


func _f32(n: int) -> RID:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(maxi(n, 1))
	var b: PackedByteArray = a.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	_owned.append(r)
	return r


func _u32(n: int) -> RID:
	var a: PackedInt32Array = PackedInt32Array()
	a.resize(maxi(n, 1))
	var b: PackedByteArray = a.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	_owned.append(r)
	return r


func _upload(rid: RID, v: PackedFloat32Array) -> void:
	var b: PackedByteArray = v.to_byte_array()
	_rd.buffer_update(rid, 0, b.size(), b)


func _filled(cc: int, v: float) -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(cc)
	a.fill(v)
	return a


## One dispatch of the whole transport pass over a grid holding `solid` at `temp_c` per cell, with no sun.
## Hands back [rad_absorbed, rad_emitted].
func _run(grid, solid_v: PackedFloat32Array, temp_c: PackedFloat32Array) -> Array:
	var cc: int = grid.cell_count
	var scr: GDScript = load(PASS_PATH)
	var lst: GDScript = load(LIST_PATH)
	var p: RefCounted = scr.new()
	var bufs: Dictionary = {}
	for name in LAChannels.pair_channels():
		bufs[String(name)] = [_f32(cc), _f32(cc)]
	for name in LAChannels.single_channels():
		bufs[String(name)] = _f32(cc)
	for name in LAChannels.derived_buffers():
		bufs[String(name)] = _f32(cc)
	# The one listed row's compacted-cell buffers, so it builds a uniform set like every other row.
	for row: Dictionary in lst.rows():
		bufs[String(row["idx"])] = _u32(cc)
		bufs[String(row["flag"])] = _u32(cc)
		bufs[String(row["args"])] = _u32(int(lst.Arg.SLOTS))
	# ASK THE PASS what it declares, exactly as the driver's _allocate_declared does. A harness that
	# builds its own inputs tests the kernel against a table the sim never sends it.
	var declared: Dictionary = p._buffers(cc)
	for name in declared:
		var spec: Variant = declared[name]
		bufs[String(name)] = _f32(int(spec["n"]) if spec is Dictionary else int(spec))
	var nbr_bytes: PackedByteArray = grid.neighbours.to_byte_array()
	var nbr: RID = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	_owned.append(nbr)
	bufs["nbr"] = nbr
	bufs["gravity"] = _f32(cc * 3)
	bufs["pos"] = _f32(cc * 3)

	_upload(bufs["solid"], solid_v)
	_upload(bufs["temp"], temp_c)

	p.setup(_rd, bufs, cc)
	var groups: int = int(ceil(float(cc) / 64.0))
	# No sun: solar_incident returns zero, so what comes back is the longwave half alone.
	var ctx: Dictionary = {"cell_size": CELL, "g_m_s2": 9.81, "sun_dir": Vector3.ZERO,
		"step_index": 0.0}
	var cl: int = _rd.compute_list_begin()
	p.dispatch(_rd, cl, 0, ctx, cc, groups)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	var absorbed: PackedFloat32Array = _rd.buffer_get_data(bufs["rad_absorbed"]).to_float32_array()
	var emitted: PackedFloat32Array = _rd.buffer_get_data(bufs["rad_emitted"]).to_float32_array()
	p.dispose(_rd)
	return [absorbed, emitted]


## Cells with all six neighbours inside the grid: the ones an isothermal-block argument holds for.
func _interior(grid) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for c in grid.cell_count:
		var all_in: bool = true
		for d in 6:
			if grid.neighbours[c * 6 + d] < 0:
				all_in = false
				break
		if all_in:
			out.append(c)
	return out


## Cells along direction `d` from `c` before the march runs out of grid. Bounded by the cell count, which
## is a loop guard on a finite graph and not a physical number.
func _depth(grid, c: int, d: int) -> int:
	var n: int = 0
	var at: int = grid.neighbours[c * 6 + d]
	while at >= 0 and n < grid.cell_count:
		n += 1
		at = grid.neighbours[at * 6 + d]
	return n


## THE TRANSMISSION ARM, kept whole and separate. A hot emitter, a transparent cell, a cold absorber, on
## one grid line. Returns [relative error at the absorber, what the transparent cell absorbed], or [] when
## the grid holds no such line.
func _transmission(grid) -> Array:
	var cc: int = grid.cell_count
	var solid: PackedFloat32Array = _filled(cc, 0.0)
	var temp: PackedFloat32Array = _filled(cc, COOL_C)
	# Walk the neighbour table rather than any index layout: absorber -> clear -> emitter along one slot.
	var absorber: int = -1
	var clear: int = -1
	var emitter: int = -1
	for c in cc:
		var mid: int = grid.neighbours[c * 6]
		if mid < 0:
			continue
		var far: int = grid.neighbours[mid * 6]
		if far < 0:
			continue
		absorber = c
		clear = mid
		emitter = far
		break
	if emitter < 0:
		return []
	solid[emitter] = 1.0
	solid[absorber] = 1.0
	temp[emitter] = HOT_C
	var out: Array = _run(grid, solid, temp)
	var emis: float = LAPhysical.BASALT_EMISSIVITY
	var t_hot: float = HOT_C + LAPhysical.KELVIN_OFFSET
	var dt: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	# One face of the emitter, crossing the clear cell untouched, and the absorber keeps its own share.
	var want: float = emis * emis * LAPhysical.STEFAN_BOLTZMANN * pow(t_hot, 4.0) * dt / CELL
	var got: float = float(out[0][absorber])
	return [absf(got - want) / want, absf(float(out[0][clear]))]


func _fail(msg: String) -> void:
	printerr(msg)
	quit(2)


func _worst_rel(v: PackedFloat32Array, want: float, cells: PackedInt32Array) -> float:
	var worst: float = 0.0
	for c in cells:
		worst = maxf(worst, absf(float(v[c]) - want) / maxf(absf(want), 1.0e-30))
	return worst


func _init() -> void:
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		_fail("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		return
	var grid = LAVoxelGrid.new()
	grid.build(N, N, N, CELL, ORIGIN)
	var inside: PackedInt32Array = _interior(grid)
	if inside.is_empty():
		_fail("the grid has no interior cell, so no closed form applies.")
		return

	var dt: float = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	var sigma: float = LAPhysical.STEFAN_BOLTZMANN
	var emis: float = LAPhysical.BASALT_EMISSIVITY

	# ROCK, isothermal. A solid cell holding nothing else is condensed matter through and through, so its
	# longwave emissivity is the cited emissivity of rock and the closed form has no free parameter.
	var cc: int = grid.cell_count
	var cool: Array = _run(grid, _filled(cc, 1.0), _filled(cc, COOL_C))
	var hot: Array = _run(grid, _filled(cc, 1.0), _filled(cc, HOT_C))
	var t_cool: float = COOL_C + LAPhysical.KELVIN_OFFSET
	var t_hot: float = HOT_C + LAPhysical.KELVIN_OFFSET
	# Six faces of a cube of side CELL, carried as J/m^3 over one step.
	var want_cool: float = 6.0 * emis * sigma * pow(t_cool, 4.0) * dt / CELL
	var want_hot: float = 6.0 * emis * sigma * pow(t_hot, 4.0) * dt / CELL
	var sb_cool: float = _worst_rel(cool[1], want_cool, inside)
	var sb_hot: float = _worst_rel(hot[1], want_hot, inside)

	# T^4, measured rather than assumed: the ratio the kernel produces against the ratio the law demands.
	var got_ratio: float = float(hot[1][inside[0]]) / maxf(float(cool[1][inside[0]]), 1.0e-30)
	var want_ratio: float = pow(t_hot / t_cool, 4.0)
	var t4_rel: float = absf(got_ratio - want_ratio) / want_ratio

	# THE ISOTHERMAL BLOCK. Along each direction the gathered emission telescopes to 1 - (1-e)^n, n cells
	# to the box edge, so the ratio approaches 1: an isothermal medium is in radiative equilibrium.
	var isothermal: float = 0.0
	for c in inside:
		var want: float = 0.0
		for d in 6:
			want += 1.0 - pow(1.0 - emis, float(_depth(grid, c, d)))
		want /= 6.0
		var ratio: float = float(cool[0][c]) / maxf(float(cool[1][c]), 1.0e-30)
		isothermal = maxf(isothermal, absf(ratio - want) / want)

	# TRANSMISSION, the arm a mean free path of one cell cannot pass.
	var trans: Array = _transmission(grid)
	if trans.is_empty():
		_fail("no three cells lie on one grid line, so nothing can be transmitted across one.")
		return

	# THE NEGATIVE CONTROL. Nothing in the cell, so nothing to radiate, at a temperature that would blaze
	# if the emissivity had a floor under it.
	var empty: Array = _run(grid, _filled(cc, 0.0), _filled(cc, HOT_C))
	var vacuum_max: float = 0.0
	for c in grid.cell_count:
		vacuum_max = maxf(vacuum_max, absf(float(empty[1][c])))

	var fail: int = 0
	if sb_cool > REL_TOLERANCE: fail += 1
	if sb_hot > REL_TOLERANCE: fail += 1
	if t4_rel > REL_TOLERANCE: fail += 1
	if isothermal > REL_TOLERANCE: fail += 1
	if float(trans[0]) > REL_TOLERANCE: fail += 1
	if float(trans[1]) > 0.0: fail += 1
	if vacuum_max > 0.0: fail += 1
	print('RADIATIVE_ROW={"stefan_cool_rel":%.5f,"stefan_hot_rel":%.5f,"t4_ratio_rel":%.5f,"isothermal_rel":%.5f,"transmitted_rel":%.5f,"clear_cell_absorbed":%s,"vacuum_emission":%s,"interior_cells":%d,"failures":%d}'
		% [sb_cool, sb_hot, t4_rel, isothermal, float(trans[0]), float(trans[1]), vacuum_max,
			inside.size(), fail])
	for r in _owned:
		if r.is_valid():
			_rd.free_rid(r)
	_rd.free()
	quit(1 if fail > 0 else 0)
GD

out="$(LA_DONE_RE='^RADIATIVE_ROW=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_radiative_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^RADIATIVE_ROW=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no RADIATIVE_ROW line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
echo "$line"
if [ "$rc" -eq 2 ]; then
  echo "The gate could not run. See the probe output above." >&2
  exit 2
fi
if [ "$rc" -ne 0 ]; then
  echo
  echo "The RADIATE row does not obey the radiation laws. stefan_*_rel is what one cell of rock emits"
  echo "against e*sigma*T^4 out of six faces; t4_ratio_rel is the T^4 scaling between two temperatures,"
  echo "which a units error cannot fake alongside the absolute arm; isothermal_rel is the equilibrium a"
  echo "block at one temperature must settle into once radiation crosses more than one cell, and it also"
  echo "fails if absorptivity stops equalling emissivity; transmitted_rel is a hot cell warming a cold one"
  echo "THROUGH a transparent cell, which reads 1.0 when the mean free path is one cell, and"
  echo "clear_cell_absorbed must be zero because a transparent cell takes nothing on the way past;"
  echo "vacuum_emission must be exactly zero, because a cell holding no matter has nothing to radiate."
  exit 1
fi

# ---------------------------------------------------------------------------------------------------
# ARM TWO — the field the SIM seeds, not one this script built.
# ---------------------------------------------------------------------------------------------------
SIM_FRAMES="${LA_RADIATIVE_FRAMES:-20}"
sim_out="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --frames "$SIM_FRAMES" \
  --report rad_emitted,rad_absorbed,solid_cells 2>&1)"
sim_rc=$?
printf '%s\n' "$sim_out" | grep -E '^(rad_emitted|rad_absorbed|solid_cells)' || true
# A reduce row arrives as a gauge, so the value is behind a 'cur' key; a plain scalar has none.
reading() { printf '%s\n' "$sim_out" | sed -n "s/^$1  *= *//p" | head -1 \
  | sed -e "s/.*'cur': *//" -e 's/[,}].*//' -e "s/[^0-9eE.+-]//g"; }
numeric() { printf '%s' "$1" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$'; }
emitted="$(reading rad_emitted)"
absorbed="$(reading rad_absorbed)"
solid="$(reading solid_cells)"
for pair in "rad_emitted $emitted" "rad_absorbed $absorbed" "solid_cells $solid"; do
  if ! numeric "${pair#* }"; then
    echo "ERROR: the run published no numeric ${pair%% *} (sim_run exit $sim_rc), so the row went" >&2
    echo "       unmeasured in the world the sim seeds. Refusing to report a pass." >&2
    printf '%s\n' "$sim_out" | tail -20 >&2
    exit 2
  fi
done
# THE POSITIVE CONTROL. An empty box emits nothing by construction, which is not a verdict.
if ! awk -v s="$solid" 'BEGIN{exit !(s > 0)}'; then
  echo "ERROR: the box holds no condensed matter, so nothing in it is obliged to radiate." >&2
  exit 2
fi
if ! awk -v e="$emitted" 'BEGIN{exit !(e > 0)}'; then
  echo
  echo "In the world the sim seeds the RADIATE row emitted NOTHING, while the box holds condensed matter"
  echo "above absolute zero. Every such cell radiates through its six faces, so the row did not run there:"
  echo "look for a uniform set the driver could not build, or a dispatch that never reached this pass."
  exit 1
fi
if ! awk -v a="$absorbed" 'BEGIN{exit !(a > 0)}'; then
  echo
  echo "In the world the sim seeds the RADIATE row absorbed NOTHING. A cell inside an opaque planet is"
  echo "surrounded by six emitters and the lit surface also takes sunlight, so the gather half of the row"
  echo "is not running even though the emit half is."
  exit 1
fi
echo "check_radiative_row: OK"

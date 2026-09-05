#!/usr/bin/env bash
# A SPARSE FIELD EDIT TOUCHES ONLY THE CELLS IT NAMES, AND MOVES EXACTLY WHAT IT SAYS. Every amount
# below is a power of two, so float32 carries it and every comparison is exact. Several sources into
# ONE sink is the arm that catches a lost update; the flush must read nothing back.
# EXIT 0 clean · 1 the scatter is wrong · 2 the gate could not run.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
KERNEL="$REPO_ROOT/addons/local_agents/sim/material/kernels3d/sparse_edit.glsl"
PASS="$REPO_ROOT/addons/local_agents/sim/material/sphere_passes/InjectPass.gd"
QUEUE="$REPO_ROOT/addons/local_agents/sim/material/MaterialFieldInjectQueue3D.gd"
for f in "$KERNEL" "$PASS" "$QUEUE"; do
  [ -f "$f" ] || { echo "ERROR: $(basename "$f") missing." >&2; exit 2; }
done

# --- THE FLUSH READS NOTHING BACK ---------------------------------------------------------------------
if grep -nE 'buffer_get_data|read_raw' "$QUEUE"; then
  echo "check_sparse_edit: FAILED — the inject queue reads the device back. A flush uploads; it never" >&2
  echo "  pulls a channel to the CPU." >&2
  exit 1
fi
# In the pass, only the drain may read: the device is synced there and the read is the batch, not the grid.
OFFENDER="$(awk '/^func /{fn=$2} /buffer_get_data/{print fn}' "$PASS" | grep -v '^_drain' || true)"
if [ -n "$OFFENDER" ]; then
  echo "check_sparse_edit: FAILED — InjectPass reads the device outside the drain: $OFFENDER" >&2
  exit 1
fi

# A .glsl edited since its last import leaves the compiled .res stale, and the probe would then check
# the PREVIOUS kernel and report a pass on it.
la_cap_dir >/dev/null || la_godot --headless --path "$REPO_ROOT" --import >/dev/null 2>&1

PROBE="$REPO_ROOT/addons/local_agents/tests/zz_sparse_edit_gate.gd"
trap 'rm -f "$PROBE" "$PROBE.uid"' EXIT INT TERM
cat > "$PROBE" <<'GD'
extends SceneTree

const QuietWindow: GDScript = preload("res://addons/local_agents/runtime/QuietWindow.gd")
const PASS_PATH: String = "res://addons/local_agents/sim/material/sphere_passes/InjectPass.gd"
const QueueScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialFieldInjectQueue3D.gd")

const N: int = 8
const CELL: float = 1.0
const CH: String = "h2o"
const CH2: String = "h2o_pore"

var _rd: RenderingDevice = null
var _owned: Array[RID] = []
var _pass: RefCounted = null
var _bufs: Dictionary = {}
var _grid = null
var _cc: int = 0
var _checks: int = 0
var _violations: int = 0


func _f32(n: int) -> RID:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	var b: PackedByteArray = a.to_byte_array()
	var r: RID = _rd.storage_buffer_create(b.size(), b)
	_owned.append(r)
	return r


func _read(name: String) -> PackedFloat32Array:
	return _rd.buffer_get_data(_bufs[name]).to_float32_array()


func _write(name: String, arr: PackedFloat32Array) -> void:
	var b: PackedByteArray = arr.to_byte_array()
	_rd.buffer_update(_bufs[name], 0, b.size(), b)


## The pattern every arm starts from: cell c holds c, which float32 carries exactly here.
func _pattern() -> PackedFloat32Array:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(_cc)
	for c in _cc:
		a[c] = float(c)
	return a


func _total(a: PackedFloat32Array) -> float:
	var s: float = 0.0
	for v in a:
		s += float(v)
	return s


## The rig stands in for the driver: the queue hands its batch here and the pass plans it.
func queue_sparse(ops: Array) -> void:
	_pass.plan(ops)


func _dispatch() -> void:
	var cl: int = _rd.compute_list_begin()
	_pass.dispatch(_rd, cl, {}, _cc, int(ceil(float(_cc) / 64.0)))
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	_pass._drain(_rd)


func _queue() -> RefCounted:
	var q: RefCounted = QueueScript.new()
	q.setup(_grid)
	return q


func _claim(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_violations += 1
		printerr("SPARSE_EDIT_VIOLATION: " + msg)


## Every cell outside `named` holds exactly what it held.
func _untouched(before: PackedFloat32Array, after: PackedFloat32Array, named: PackedInt32Array) -> void:
	var skip: Dictionary = {}
	for c in named:
		skip[c] = true
	var moved_cells: int = 0
	for c in _cc:
		if skip.has(c):
			continue
		if after[c] != before[c]:
			moved_cells += 1
	_claim(moved_cells == 0, "%d cells nobody named changed" % moved_cells)


func _arm_add() -> void:
	_write(CH, _pattern())
	var before: PackedFloat32Array = _read(CH)
	var cells: PackedInt32Array = PackedInt32Array([3, 17, 40, 41, 200])
	var deltas: PackedFloat32Array = PackedFloat32Array([2.0, 2.0, 2.0, 2.0, 2.0])
	var q: RefCounted = _queue()
	q.add(CH, cells, deltas)
	q.flush(self)
	_dispatch()
	var after: PackedFloat32Array = _read(CH)
	for i in cells.size():
		_claim(after[cells[i]] == before[cells[i]] + 2.0,
			"add: cell %d holds %f, wanted %f" % [cells[i], after[cells[i]], before[cells[i]] + 2.0])
	_claim(_total(after) - _total(before) == 10.0,
		"add: the total moved by %f, wanted 10" % (_total(after) - _total(before)))
	_untouched(before, after, cells)


func _arm_ceiling() -> void:
	_write(CH, _pattern())
	var q: RefCounted = _queue()
	q.add(CH, PackedInt32Array([5]), PackedFloat32Array([10.0]), 8.0)
	q.flush(self)
	_dispatch()
	var after: PackedFloat32Array = _read(CH)
	_claim(after[5] == 8.0, "ceiling: cell 5 holds %f past a ceiling of 8" % after[5])


func _arm_move() -> void:
	_write(CH, _pattern())
	var before: PackedFloat32Array = _read(CH)
	var src: PackedInt32Array = PackedInt32Array([10, 11, 12])
	var dst: PackedInt32Array = PackedInt32Array([100, 101, 102])
	var q: RefCounted = _queue()
	q.transfer(CH, src, PackedFloat32Array([4.0, 4.0, 4.0]), CH, dst)
	q.flush(self)
	_dispatch()
	var after: PackedFloat32Array = _read(CH)
	_claim(_total(after) == _total(before),
		"move: the total went from %f to %f" % [_total(before), _total(after)])
	for i in src.size():
		_claim(after[src[i]] == before[src[i]] - 4.0, "move: source %d holds %f" % [src[i], after[src[i]]])
		_claim(after[dst[i]] == before[dst[i]] + 4.0, "move: sink %d holds %f" % [dst[i], after[dst[i]]])
	var named: PackedInt32Array = src.duplicate()
	named.append_array(dst)
	_untouched(before, after, named)


## FOUR SOURCES, ONE SINK. Every source is debited and the sink takes the sum: a scatter that let two
## threads read-modify-write one cell would lose all but one of the credits.
func _arm_converge() -> void:
	_write(CH, _pattern())
	var before: PackedFloat32Array = _read(CH)
	var src: PackedInt32Array = PackedInt32Array([20, 21, 22, 23])
	var q: RefCounted = _queue()
	q.transfer(CH, src, PackedFloat32Array([1.0, 1.0, 1.0, 1.0]), CH, PackedInt32Array([300, 300, 300, 300]))
	q.flush(self)
	_dispatch()
	var after: PackedFloat32Array = _read(CH)
	_claim(after[300] == before[300] + 4.0,
		"converge: the sink holds %f, wanted %f" % [after[300], before[300] + 4.0])
	_claim(_total(after) == _total(before),
		"converge: the total went from %f to %f" % [_total(before), _total(after)])


func _arm_cross_channel() -> void:
	_write(CH, _pattern())
	var zero: PackedFloat32Array = PackedFloat32Array()
	zero.resize(_cc)
	_write(CH2, zero)
	var before: PackedFloat32Array = _read(CH)
	var q: RefCounted = _queue()
	q.transfer(CH, PackedInt32Array([60, 61]), PackedFloat32Array([3.0, 3.0]), CH2, PackedInt32Array([60, 61]))
	q.flush(self)
	_dispatch()
	var after: PackedFloat32Array = _read(CH)
	var pore: PackedFloat32Array = _read(CH2)
	_claim(_total(after) + _total(pore) == _total(before),
		"cross-channel: %f + %f against %f" % [_total(after), _total(pore), _total(before)])
	_claim(pore[60] == 3.0 and pore[61] == 3.0,
		"cross-channel: the sink holds %f / %f, wanted 3 each" % [pore[60], pore[61]])


func _arm_discard() -> void:
	_write(CH, _pattern())
	var before: PackedFloat32Array = _read(CH)
	var q: RefCounted = _queue()
	q.discard(CH, PackedInt32Array([55]))
	q.flush(self)
	_dispatch()
	var after: PackedFloat32Array = _read(CH)
	_claim(after[55] == 0.0, "discard: cell 55 still holds %f" % after[55])
	_claim(_total(before) - _total(after) == 55.0,
		"discard: the total dropped by %f, wanted 55" % (_total(before) - _total(after)))


## The device's own book of what it applied, cumulative over every arm above.
func _arm_books() -> void:
	var book: Dictionary = _pass._drain(_rd)
	var created: float = float(book.get("inject_created_" + CH, 0.0))
	var moved: float = float(book.get("inject_moved_" + CH, 0.0))
	var removed: float = float(book.get("inject_removed_" + CH, 0.0))
	_claim(created == 13.0, "book: created %f, wanted 13 (10 added plus 3 of headroom)" % created)
	_claim(moved == 22.0, "book: moved %f, wanted 22 (12 plus 4 plus 6)" % moved)
	_claim(removed == 55.0, "book: removed %f, wanted 55" % removed)


func _fail(msg: String) -> void:
	printerr(msg)
	quit(2)


func _init() -> void:
	QuietWindow.apply_if_automated()
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		_fail("no RenderingDevice — headless has no compute device, so this gate cannot run.")
		return
	_grid = LAVoxelGrid.new()
	_grid.build(N, N, N, CELL, Vector3.ZERO)
	_cc = _grid.cell_count
	for name in LAChannels.channels():
		_bufs[String(name)] = _f32(_cc)
	var edge_b: PackedByteArray = _grid.cell_edges().to_byte_array()
	_bufs["cell_edge"] = _rd.storage_buffer_create(edge_b.size(), edge_b)
	_owned.append(_bufs["cell_edge"])
	_pass = (load(PASS_PATH) as GDScript).new()
	_pass.ghost_count = 0
	_pass.grid_dims = Vector3i(N, N, N)
	_pass.grid_cell_size = CELL
	_pass.setup(_rd, _bufs, _cc)

	_arm_add()
	_arm_ceiling()
	_arm_move()
	_arm_converge()
	_arm_cross_channel()
	_arm_discard()
	_arm_books()

	print("SPARSE_EDIT={\"checks\":%d,\"violations\":%d}" % [_checks, _violations])
	_pass.dispose(_rd)
	for r in _owned:
		if r.is_valid():
			_rd.free_rid(r)
	_rd.free()
	_rd = null
	quit(1 if _violations > 0 else 0)
GD

out="$(LA_DONE_RE='^SPARSE_EDIT=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://addons/local_agents/tests/zz_sparse_edit_gate.gd" 2>&1)"
rc=$?
rm -f "$PROBE" "$PROBE.uid"
line="$(printf '%s\n' "$out" | grep -m1 '^SPARSE_EDIT=')"
if [ -z "$line" ]; then
  echo "ERROR: the probe produced no SPARSE_EDIT line — refusing to report a pass." >&2
  printf '%s\n' "$out" | tail -30 >&2
  exit 2
fi
echo "$line"
CHECKS="$(printf '%s' "$line" | grep -oE '"checks":[0-9]+' | grep -oE '[0-9]+$')"
VIOL="$(printf '%s' "$line" | grep -oE '"violations":[0-9]+' | grep -oE '[0-9]+$')"
if [ -z "${CHECKS:-}" ] || [ "$CHECKS" -lt 20 ]; then
  echo "ERROR: the probe made $CHECKS claims; it examined nothing." >&2
  exit 2
fi
if [ "$rc" -eq 2 ]; then
  echo "The gate could not run. See the probe output above." >&2
  exit 2
fi
if [ "${VIOL:-1}" -ne 0 ] || [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" | grep '^SPARSE_EDIT_VIOLATION' >&2 || true
  echo "The scatter did not do what the batch named. A cell nobody named changed means the kernel's" >&2
  echo "index is wrong; a total that moved means a debit and its credit disagree." >&2
  exit 1
fi

# ---------------------------------------------------------------------------------------------------
# ARM TWO — the world the SIM seeds, not one this script built. --stamp-test deposits rock into one void
# cell through the ordinary injection queue, so the batch the device gets is the sim's own: a graded
# grid, the seeded channels, the real driver. `cement` is the exact claim — an empty cell, a credit of 1
# and a ceiling of 1, so the device must book exactly 1 whatever the terrain under it.
# ---------------------------------------------------------------------------------------------------
SIM_FRAMES="${LA_SPARSE_FRAMES:-200}"
sim_out="$("$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --frames "$SIM_FRAMES" \
  --report inject_cells,inject_created_silicate,inject_created_cement,conservation_failed \
  -- --stamp-test 2>&1)"
sim_rc=$?
printf '%s\n' "$sim_out" | grep -E '^(inject_|conservation_failed)' || true
if [ "$sim_rc" -eq 2 ] || [ "$sim_rc" -eq 3 ] || [ "$sim_rc" -eq 4 ] || [ "$sim_rc" -eq 124 ]; then
  printf '%s\n' "$sim_out" | tail -20 >&2
  echo "ERROR: the seeded-world arm did not run, so nothing was read off the sim." >&2
  exit 2
fi
reading() { printf '%s\n' "$sim_out" | sed -n "s/^$1  *= *//p" | head -1 \
  | sed -e "s/.*'cur': *//" -e 's/[,}].*//' -e 's/[[:space:]]*$//'; }
CELLS="$(reading inject_cells)"
if ! printf '%s' "$CELLS" | grep -Eq '^[0-9]+$'; then
  echo "ERROR: the seeded run published no inject_cells, so the queue is not wired into its report." >&2
  exit 2
fi
sim_fail=0
if [ "$CELLS" -lt 2 ]; then
  echo "FAIL  the stamp deposited into two channels and the queue flushed $CELLS cell(s)." >&2
  sim_fail=1
fi
CEMENT="$(reading inject_created_cement)"
if [ "$CEMENT" != "1.0" ] && [ "$CEMENT" != "1" ]; then
  echo "FAIL  the device booked ${CEMENT:-<ABSENT>} of cement against a credit of 1 into an empty cell" >&2
  echo "  under a ceiling of 1: the seeded world's batch did not reach the kernel intact." >&2
  sim_fail=1
fi
ROCK="$(reading inject_created_silicate)"
if ! printf '%s' "$ROCK" | grep -Eq '^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$' \
    || [ "$(printf '%s\n' "$ROCK" | awk '{print ($1 > 0.0) ? 1 : 0}')" != "1" ]; then
  echo "FAIL  the stamp deposited rock and the device booked ${ROCK:-<ABSENT>}." >&2
  sim_fail=1
fi
CONS="$(reading conservation_failed)"
if [ "$CONS" != "0" ] && [ "$CONS" != "False" ] && [ "$CONS" != "<ABSENT>" ]; then
  echo "FAIL  the seeded run reports conservation_failed=$CONS with the scatter pass in the world." >&2
  sim_fail=1
fi
[ "$sim_fail" -eq 0 ] || exit 1

echo "check_sparse_edit: OK ($CHECKS exact claims, and the seeded world booked the cells it flushed)"
exit 0

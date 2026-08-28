#!/usr/bin/env bash
# A CELL AT REST STAYS AT REST. The pressure a cell's own reconstruction presents on its six faces must
# integrate to exactly the weight of what it holds — at any scale height, and whatever direction gravity
# points in the box. Sampling the pressure at each face's CENTRE does not: the cell then keeps only part
# of its own weight and falls out of a balance nothing disturbed.
# EXIT 0 every case balances · 1 one does not · 2 the gate could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
. "$SCRIPT_DIR/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?

# AND THE DEPTH IS THE CELL'S OWN. A face's depth in this cell's stack is its own gravity against its
# own face normal, which makes the two faces of an axis exact opposites and the six sum to the weight.
# Reading it off the geopotential between two CENTRES brings the neighbour's gravity in, the opposites
# stop cancelling, and the cell keeps a share of its own weight that no body force answers.
T="$ROOT/addons/local_agents/sim/material/kernels3d/closures.glsli"
[ -f "$T" ] || { echo "check_stack_balance: MISSING ${T#"$ROOT"/}" >&2; exit 2; }
if ! rg -q -e 'return gm > 0\.0 \? dot\(face_normal\(d\), gv\) / gm : 0\.0;' "$T"; then
	echo "check_stack_balance: closures.glsli no longer measures a face's depth by the cell's OWN" >&2
	echo "                     gravity direction against that face's normal." >&2
	exit 1
fi
if rg -q -e 'grav_phi\[c\] - grav_phi\[uint\(inb\)\]' "$T"; then
	echo "check_stack_balance: the face depth is back on the geopotential between two cell centres," >&2
	echo "                     which is a different quantity and does not self-balance." >&2
	exit 1
fi

out="$("$SCRIPT_DIR/run_sim_offscreen.sh" --path "$ROOT" -s scripts/check_stack_balance.gd 2>&1)"
rc=$?
printf '%s\n' "$out" | rg -N -e '^STACK_BALANCE=' || true

if ! printf '%s\n' "$out" | rg -N -q -e '^STACK_BALANCE='; then
	echo "check_stack_balance: the rig dispatched no case, so it asserts nothing (exit $rc)." >&2
	printf '%s\n' "$out" | tail -20 >&2
	exit 2
fi
case "$rc" in
	0) ;;
	1) printf '%s\n' "$out" | rg -N -e 'check_stack_balance:' >&2; exit 1 ;;
	*) echo "check_stack_balance: the rig could not run (exit $rc)." >&2; exit 2 ;;
esac

# SECOND ARM, ON THE WORLD THE SEED BUILDS. The rig feeds the reconstruction a table of its own, and a
# face pressure that overflows or divides by nothing on a state the rig never holds passes it. Only the
# seeded world sends those states, and what they leave behind is non-finite derived state. Read off the
# lint's SHARED arm: a per-rung run of its own is the ladder's job, not a gate's.
world="$(la_report nonfinite_cells,celerity_max --path "$ROOT" --rung 3 --frames 4 2>&1)" || true
read -r NF CEL <<EOF
$(printf '%s\n' "$world" | python3 -c "
import re, sys
out = {}
for ln in sys.stdin:
    for key in ('nonfinite_cells', 'celerity_max'):
        if ln.startswith(key):
            m = re.search(r\"'max': *([-+0-9.eE]+)\", ln)
            if m:
                out[key] = m.group(1)
print(out.get('nonfinite_cells', ''), out.get('celerity_max', ''))
")
EOF
if [ -z "${NF:-}" ] || [ -z "${CEL:-}" ]; then
	echo "check_stack_balance: the seeded world published no nonfinite_cells/celerity_max, so the" >&2
	echo "                     reconstruction was never asked for a face on the sim's own state." >&2
	printf '%s\n' "$world" | tail -20 >&2
	exit 2
fi
echo "STACK_WORLD={\"nonfinite_cells\":$NF,\"celerity_max\":$CEL}"
if ! awk -v n="$NF" -v c="$CEL" 'BEGIN{exit !(n == 0 && c > 0)}'; then
	echo "check_stack_balance: the seeded world left non-finite derived state behind, or states no" >&2
	echo "                     signal speed at all. A face returned something that is not a pressure." >&2
	exit 1
fi
echo "check_stack_balance: OK"

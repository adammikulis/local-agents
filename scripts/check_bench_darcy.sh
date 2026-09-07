#!/usr/bin/env bash
# DARCY'S LAW: saturated rock drains at K = rho g k / mu (Darcy 1856; Bear 1972) with the packed-bed
# permeability k = d^2 phi^3 / (180 (1-phi)^2) (Kozeny 1927; Carman 1937), water at 20 C from Kestin,
# Sokolov & Wakeham 1978. Six columns span porosity and grain size; the bound is one explicit
# donor-cell step in float32. EXIT 0 within the bound * 1 outside it * 2 the rig could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH." >&2; exit 2; }
PROBE="addons/local_agents/tests/bench_darcy.gd"
[ -f "$REPO_ROOT/$PROBE" ] || { echo "ERROR: $PROBE missing." >&2; exit 2; }

JUDGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench_darcy.XXXXXX")"; JUDGE="$JUDGE_DIR/judge.py"
trap 'rm -rf "$JUDGE_DIR"' EXIT INT TERM
cat > "$JUDGE" <<'PY'
import json, os, sys

RHO_W, MU_W, KC = 998.2, 1.002e-3, 180.0
MODE = os.environ.get("LA_BENCH_SELFTEST", "")
if MODE:
    # THE GATE'S OWN CONTROL: columns that pass exactly what Darcy and Kozeny-Carman say, then the same
    # columns passing a tenth less.
    G0, DT0, DZ0, FULL = 9.80665, 1.0, 1.0, 55342.77
    cols = []
    for phi, dia in ((0.10, 4e-3), (0.20, 4e-3), (0.30, 4e-3), (0.40, 4e-3), (0.40, 6e-5), (0.40, 2e-4)):
        k = dia * dia * phi ** 3 / (KC * (1.0 - phi) ** 2)
        q = FULL * phi * (RHO_W * G0 * k / MU_W) * DT0 / DZ0 * (0.9 if MODE == "broken" else 1.0)
        n = 12
        before = [FULL * phi] * n
        after = list(before)
        after[0] += q
        after[-1] -= q
        cols.append({"porosity": phi, "grain_m": dia, "solid": 1.0,
                     "pore_before": before, "pore_after": after, "claim": 2, "tlevel": 0})
    d = {"cell_m": DZ0, "g": G0, "dt_s": DT0, "full_h2o_mol_m3": FULL, "kozeny_carman_c": KC,
         "water_rho_kg_m3": RHO_W, "columns": cols}
else:
    d = json.loads(sys.stdin.read().split("=", 1)[1])
g, dt, dz = d["g"], d["dt_s"], d["cell_m"]
BOUND = 1e-4     # one explicit donor-cell step in float32

cols, fails = [], []
for c in d["columns"]:
    phi, dia = c["porosity"], c["grain_m"]
    perm = dia * dia * phi ** 3 / (KC * (1.0 - phi) ** 2)
    cond = RHO_W * g * perm / MU_W
    pore = c["pore_before"]
    # Gravity drainage carries the pore water down at K: the bottom cell gains what crosses into it and
    # loses nothing through the wall under it, the top cell loses and gains nothing.
    expect = pore[0] * cond * dt / dz
    gained = c["pore_after"][0] - pore[0]
    lost = pore[-1] - c["pore_after"][-1]
    rel = max(abs(gained - expect), abs(lost - expect)) / max(expect, 1e-30)
    cols.append({"porosity": phi, "grain_m": dia, "permeability_m2": perm,
                 "hydraulic_conductivity_m_s": cond, "expected_mol_m3": expect,
                 "bottom_gained_mol_m3": gained, "top_lost_mol_m3": lost, "rel": rel})
    # The rig's own configuration, read back off the device: the closed form above is computed from
    # these numbers, so a column that does not hold them is a harness fault and not a solver's.
    if c["solid"] == 0.0:
        fails.append("phi %.2f: the column is not rock, so Darcy's law has no medium to run in." % phi)
    if MODE == "":
        if abs(c["porosity_read"] - phi) > 1e-6 or abs(c["grain_read"] - dia) > 1e-9 \
                or c["cement_read"] < 1.0 or abs(abs(c["g_rest_y"]) - g) > 1e-4 \
                or abs(c["edge"] - dz) > 1e-9:
            fails.append("phi %.2f: the cells hold porosity %.6g, grain %.6g, cement %.4g, gravity "
                         "%.6g and edge %.6g, not what the closed form was computed from."
                         % (phi, c["porosity_read"], c["grain_read"], c["cement_read"],
                            c["g_rest_y"], c["edge"]))
        if c["claim"] != 2 or c["tlevel"] != 0:
            fails.append("phi %.2f: the column's cells are not in the record's own dispatch list "
                         "(claim %d, level %d), so the row was never asked to move anything."
                         % (phi, c["claim"], c["tlevel"]))
    if rel > BOUND:
        fails.append("phi %.2f d %.0e: the saturated column should pass %.6g mol/m^3 in one step at "
                     "K = %.4g m/s; the bottom cell gained %.6g and the top lost %.6g."
                     % (phi, dia, expect, cond, gained, lost))

print("BENCH_DARCY=" + json.dumps({"error": round(max(x["rel"] for x in cols), 8),
                                   "bound": BOUND, "order": 1, "columns": cols}, sort_keys=True))
for m in fails:
    print("check_bench_darcy: " + m, file=sys.stderr)
sys.exit(1 if fails else 0)
PY

if ! LA_BENCH_SELFTEST=exact python3 "$JUDGE" >/dev/null; then
  echo "ERROR: this gate rejects columns passing exactly the Darcy flux, so its bound is not one any" >&2
  echo "       solver could meet. Refusing to report a verdict." >&2
  exit 2
fi
if LA_BENCH_SELFTEST=broken python3 "$JUDGE" >/dev/null 2>&1; then
  echo "ERROR: this gate accepts a tenth less than Darcy's law, so it cannot fail." >&2
  exit 2
fi

out="$(LA_DONE_RE='^BENCH_RAW_DARCY=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://$PROBE" 2>&1)"
raw="$(printf '%s\n' "$out" | grep -m1 '^BENCH_RAW_DARCY=')"
if [ -z "$raw" ]; then
  echo "ERROR: the rig published no BENCH_RAW_DARCY line." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
printf '%s' "$raw" | python3 "$JUDGE"
rc=$?
[ "$rc" -eq 1 ] && exit 1
[ "$rc" -eq 0 ] || exit 2

# ARM TWO -- the world the sim seeds, at the rung the groundwater row arrives on. Its pore stock must be
# present and finite, or the row the rig judged is not in the planet.
FRAMES="${LA_BENCH_DC_FRAMES:-8}"
. "$REPO_ROOT/scripts/lib_rung.sh"
world="$(la_rung_report 5 "$FRAMES" "all_h2o_pore,wet_cells")"
la_rung_require "$world" all_h2o_pore || exit 2
printf 'BENCH_DARCY_WORLD={"all_h2o_pore":%s}\n' "$(la_rung_value "$world" all_h2o_pore)"
echo "check_bench_darcy: OK"

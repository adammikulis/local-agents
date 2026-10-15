#!/usr/bin/env bash
# THE BAROMETRIC LAW p(z) = p0 exp(-z/H), H = RT/(Mg): the hydrostatic equation integrated at constant
# temperature, read against the seeded pressure and again after the acoustic group has stepped it.
# The bound is (dz/H)^2/24, a cell average of an exponential read at its centre. A flat column is the
# control that must break it. EXIT 0 within * 1 broken, or the control held * 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH." >&2; exit 2; }
PROBE="addons/local_agents/tests/bench_hydrostatic_column.gd"
[ -f "$REPO_ROOT/$PROBE" ] || { echo "ERROR: $PROBE missing." >&2; exit 2; }

JUDGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench_hydro.XXXXXX")"; JUDGE="$JUDGE_DIR/judge.py"
trap 'rm -rf "$JUDGE_DIR"' EXIT INT TERM
cat > "$JUDGE" <<'PY'
import json, math, os, sys

MODE = os.environ.get("LA_BENCH_SELFTEST", "")
if MODE:
    # THE GATE'S OWN CONTROL: a column standing exactly on the barometric law and not moving, beside a
    # flat one that falls; then the same balanced column drifting off the law.
    N, DZ, G, P0 = 48, 200.0, 9.80665, 101325.0
    H = 8.314462618 * 288.15 / (0.0280134 * G)
    z = [(c + 0.5) * DZ for c in range(N)]
    baro = [P0 * math.exp(-(zz - z[0]) / H) for zz in z]
    drift = 1.01 if MODE == "broken" else 1.0
    d = {"balanced": {"cells": N, "cell_m": DZ, "g": G, "t_c": 15.0, "p_base": P0, "scale_h_m": H,
                      "steps": 40, "dt_s": 0.05, "t_s": 2.0, "z": z, "p_seeded": baro,
                      "p_stepped": [p * drift for p in baro], "vel_y": [0.0] * N,
                      "temp": [15.0] * N, "rho": [1.2] * N},
         "flat": {"cells": N, "cell_m": DZ, "g": G, "t_c": 15.0, "p_base": P0, "scale_h_m": H,
                  "steps": 40, "dt_s": 0.05, "t_s": 2.0, "z": z, "p_seeded": [P0] * N,
                  "p_stepped": [P0] * N, "vel_y": [20.0] * N, "temp": [15.0] * N, "rho": [1.2] * N}}
else:
    d = json.loads(sys.stdin.read().split("=", 1)[1])
report, fails = {}, []
for key in ("balanced", "flat"):
    a = d[key]
    h, z0, p0, dz = a["scale_h_m"], a["z"][0], a["p_base"], a["cell_m"]
    seeded = stepped = 0.0
    for c in range(a["cells"]):
        ref = p0 * math.exp(-(a["z"][c] - z0) / h)
        seeded = max(seeded, abs(a["p_seeded"][c] - ref) / ref)
        stepped = max(stepped, abs(a["p_stepped"][c] - ref) / ref)
    # A cell holds the mean of exp(-z/H) over its own edge; the law is read at the centre.
    bound = (dz / h) ** 2 / 24.0
    vmax = max(abs(v) for v in a["vel_y"])
    # An imbalance of `bound` in the reconstructed pressure accelerates the column by at most g times it.
    v_bound = a["g"] * a["t_s"] * bound
    report[key] = {"seeded_rel": seeded, "stepped_rel": stepped, "bound": bound,
                   "vel_max_m_s": vmax, "vel_bound_m_s": v_bound, "scale_h_m": h,
                   "dz_over_h": dz / h}
    if key == "balanced":
        if seeded > bound:
            fails.append("the seeded column is %.4g off the barometric law, past the %.4g a cell "
                         "average of an exponential read at its centre costs." % (seeded, bound))
        if stepped > bound:
            fails.append("after %g s of stepping the column stands %.4g off the barometric law "
                         "against the same %.4g bound: it is moving itself."
                         % (a["t_s"], stepped, bound))
        if vmax > v_bound:
            fails.append("the balanced column reached %.4g m/s; a reconstruction accurate to %.4g "
                         "can accelerate it to at most %.4g m/s in %g s."
                         % (vmax, bound, v_bound, a["t_s"]))

# THE CONTROL. A column seeded uniform is not in hydrostatic balance and must move; if it holds, the
# arm above is measuring an integrator that does nothing rather than one that does the right thing.
f = report["flat"]
if f["stepped_rel"] <= report["balanced"]["bound"] or f["vel_max_m_s"] <= f["vel_bound_m_s"]:
    fails.append("the CONTROL held: a column seeded at one pressure everywhere is not in balance and "
                 "must fall, yet it reads %.4g off the law at %.4g m/s. Nothing in this gate is "
                 "measuring an integrator." % (f["stepped_rel"], f["vel_max_m_s"]))

print("BENCH_HYDROSTATIC_COLUMN=" + json.dumps(
    {"error": round(report["balanced"]["stepped_rel"], 10),
     "bound": round(report["balanced"]["bound"], 10),
     "order": 2, "detail": report}, sort_keys=True))
for m in fails:
    print("check_bench_hydrostatic_column: " + m, file=sys.stderr)
sys.exit(1 if fails else 0)
PY

if ! LA_BENCH_SELFTEST=exact python3 "$JUDGE" >/dev/null; then
  echo "ERROR: this gate rejects a column standing exactly on the barometric law, so its bound is not" >&2
  echo "       one any solver could meet. Refusing to report a verdict." >&2
  exit 2
fi
if LA_BENCH_SELFTEST=broken python3 "$JUDGE" >/dev/null 2>&1; then
  echo "ERROR: this gate accepts a column one percent off the law, so it cannot fail." >&2
  exit 2
fi

out="$(LA_DONE_RE='^BENCH_RAW_HYDROSTATIC_COLUMN=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://$PROBE" 2>&1)"
raw="$(printf '%s\n' "$out" | grep -m1 '^BENCH_RAW_HYDROSTATIC_COLUMN=')"
if [ -z "$raw" ]; then
  echo "ERROR: the rig published no BENCH_RAW_HYDROSTATIC_COLUMN line." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
printf '%s' "$raw" | python3 "$JUDGE"
rc=$?
[ "$rc" -eq 1 ] && exit 1
[ "$rc" -eq 0 ] || exit 2

# ARM TWO -- the world the sim seeds, at the hydrostatic rung. Its own rest gauge must be present and
# finite, or the pressure the rig compared with the barometric law is not the planet's.
FRAMES="${LA_BENCH_HC_FRAMES:-6}"
. "$REPO_ROOT/scripts/lib_rung.sh"
world="$(la_rung_report 2 "$FRAMES" "pressure_rest_rel,pressure_audited")"
la_rung_require "$world" pressure_rest_rel pressure_audited || exit $?
printf 'BENCH_HYDROSTATIC_COLUMN_WORLD={"pressure_rest_rel":%s,"pressure_audited":%s}\n' \
  "$(la_rung_value "$world" pressure_rest_rel)" "$(la_rung_value "$world" pressure_audited)"
echo "check_bench_hydrostatic_column: OK"

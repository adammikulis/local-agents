#!/usr/bin/env bash
# JEANS ESCAPE against kinetic theory: Phi = n u (1 + lambda) e^-lambda / (2 sqrt(pi)) at
# u = sqrt(2 R T / M), lambda = G M m / (k T r) (Jeans 1925; Chamberlain & Hunten, Theory of Planetary
# Atmospheres, 1987, eq. 7.2.3), computed from the rig's own temperature, molar mass and potential
# depth. The bound is float32 through one exponential, so it grows with lambda. Nine of them.
# EXIT 0 within the bound * 1 outside it * 2 the rig could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH." >&2; exit 2; }
PROBE="addons/local_agents/tests/bench_jeans_escape.gd"
[ -f "$REPO_ROOT/$PROBE" ] || { echo "ERROR: $PROBE missing." >&2; exit 2; }

JUDGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench_jeans.XXXXXX")"; JUDGE="$JUDGE_DIR/judge.py"
trap 'rm -rf "$JUDGE_DIR"' EXIT INT TERM
cat > "$JUDGE" <<'PY'
import json, math, os, sys

MODE = os.environ.get("LA_BENCH_SELFTEST", "")
if MODE:
    # THE GATE'S OWN CONTROL: the closed form fed back as if a solver had produced it, exactly and
    # then deliberately wrong.
    R0, M0, T0, N0, DT0, L0 = 8.314462618, 0.00201588, 1000.0, 40.0, 1.0, 500.0
    u0 = math.sqrt(2.0 * R0 * T0 / M0)
    rr = []
    for lam in (3.5, 4.0, 5.0, 6.0, 7.0, 8.0, 10.0, 12.0, 15.0):
        left = N0 * u0 / (2.0 * math.sqrt(math.pi)) * (1.0 + lam) * math.exp(-lam) * DT0 / L0
        if MODE == "broken":
            left *= 1.01
        rr.append({"lambda": lam, "left": left, "stock": N0 - left})
    d = {"gas_constant": R0, "molar_mass_kg_mol": M0, "t_k": T0, "n_mol_m3": N0, "dt_s": DT0,
         "cell_m": L0, "phi_per_lambda_j_kg": R0 * T0 / M0, "rows": rr}
else:
    d = json.loads(sys.stdin.read().split("=", 1)[1])
R, M, T = d["gas_constant"], d["molar_mass_kg_mol"], d["t_k"]
n, dt, L = d["n_mol_m3"], d["dt_s"], d["cell_m"]
u = math.sqrt(2.0 * R * T / M)
# float32 carries seven digits; the escape parameter enters through one exponential, so the relative
# error the arithmetic is entitled to grows with lambda.
FLOAT32_EPS = 1.1920929e-7

rows, fails, worst = [], [], 0.0
for r in d["rows"]:
    lam = r["lambda"]
    phi = n * u / (2.0 * math.sqrt(math.pi)) * (1.0 + lam) * math.exp(-lam)
    expect = phi * dt / L
    got = r["left"]
    rel = abs(got - expect) / expect
    bound = max(FLOAT32_EPS * (2.0 + lam) * 8.0, 1e-6)
    worst = max(worst, rel / bound)
    rows.append({"lambda": lam, "measured_mol_m3": got, "jeans_mol_m3": expect,
                 "rel": rel, "bound": bound})
    if rel > bound:
        fails.append("lambda %.1f: the row booked %.6g mol/m^3 through the space face; the Jeans flux "
                     "is %.6g, a relative %.4g against a bound of %.4g."
                     % (lam, got, expect, rel, bound))
    if abs(r["stock"] + got - n) > 1e-4 * n:
        fails.append("lambda %.1f: the cell lost %.6g and the boundary book reads %.6g. What leaves "
                     "the world is booked or it is destroyed."
                     % (lam, n - r["stock"], got))

print("BENCH_JEANS_ESCAPE=" + json.dumps(
    {"error": round(max(x["rel"] for x in rows), 9),
     "bound": round(max(x["bound"] for x in rows), 9),
     "order": 0, "most_probable_speed_m_s": round(u, 4), "rows": rows}, sort_keys=True))
for m in fails:
    print("check_bench_jeans_escape: " + m, file=sys.stderr)
sys.exit(1 if fails else 0)
PY

if ! LA_BENCH_SELFTEST=exact python3 "$JUDGE" >/dev/null; then
  echo "ERROR: this gate rejects the exact Jeans flux, so its bound is not one any solver could" >&2
  echo "       meet. Refusing to report a verdict." >&2
  exit 2
fi
if LA_BENCH_SELFTEST=broken python3 "$JUDGE" >/dev/null 2>&1; then
  echo "ERROR: this gate accepts a flux one percent off the Jeans law, so it cannot fail." >&2
  exit 2
fi

out="$(LA_DONE_RE='^BENCH_RAW_JEANS_ESCAPE=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://$PROBE" 2>&1)"
raw="$(printf '%s\n' "$out" | grep -m1 '^BENCH_RAW_JEANS_ESCAPE=')"
if [ -z "$raw" ]; then
  echo "ERROR: the rig published no BENCH_RAW_JEANS_ESCAPE line." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
printf '%s' "$raw" | python3 "$JUDGE"
rc=$?
[ "$rc" -eq 1 ] && exit 1
[ "$rc" -eq 0 ] || exit 2

# ARM TWO -- the world the sim seeds, at the rung the escape rows arrive on. Its hydrogen stock must be
# present and finite, or the row the rig judged is not in the planet.
FRAMES="${LA_BENCH_JE_FRAMES:-8}"
. "$REPO_ROOT/scripts/lib_rung.sh"
world="$(la_rung_report 8 "$FRAMES" "all_h2,open_h2")"
la_rung_require "$world" all_h2 || exit 2
printf 'BENCH_JEANS_ESCAPE_WORLD={"all_h2":%s}\n' "$(la_rung_value "$world" all_h2)"
echo "check_bench_jeans_escape: OK"

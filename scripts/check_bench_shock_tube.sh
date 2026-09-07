#!/usr/bin/env bash
# SOD'S SHOCK TUBE against the EXACT Riemann solution (Sod 1978; Toro, Riemann Solvers, ch. 4), solved
# here by Newton on the star pressure. Bounds: the wave positions within the first-order scheme's own
# diffusion width (Hirt 1968), positivity, no growing overshoot, and Kuznetsov's half order (1976).
# docs/BENCHMARKS.md carries the table. EXIT 0 within the bounds * 1 broken * 2 the rig could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH." >&2; exit 2; }
PROBE="addons/local_agents/tests/bench_shock_tube.gd"
[ -f "$REPO_ROOT/$PROBE" ] || { echo "ERROR: $PROBE missing." >&2; exit 2; }

JUDGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench_shock.XXXXXX")"; JUDGE="$JUDGE_DIR/judge.py"
trap 'rm -rf "$JUDGE_DIR"' EXIT INT TERM
cat > "$JUDGE" <<'PY'
import json, math, os, sys


def f(p, pk, rk, ck, g):
    if p > pk:
        a = 2.0 / ((g + 1.0) * rk)
        b = (g - 1.0) / (g + 1.0) * pk
        return (p - pk) * math.sqrt(a / (p + b))
    return 2.0 * ck / (g - 1.0) * ((p / pk) ** ((g - 1.0) / (2.0 * g)) - 1.0)


def fp(p, pk, rk, ck, g):
    if p > pk:
        a = 2.0 / ((g + 1.0) * rk)
        b = (g - 1.0) / (g + 1.0) * pk
        return math.sqrt(a / (b + p)) * (1.0 - 0.5 * (p - pk) / (b + p))
    return 1.0 / (rk * ck) * (p / pk) ** (-(g + 1.0) / (2.0 * g))


def star(rl, ul, pl, rr, ur, pr, g):
    cl, cr = math.sqrt(g * pl / rl), math.sqrt(g * pr / rr)
    p = max(1e-12, 0.5 * (pl + pr) - 0.125 * (ur - ul) * (rl + rr) * (cl + cr))
    for _ in range(200):
        pn = p - (f(p, pl, rl, cl, g) + f(p, pr, rr, cr, g) + (ur - ul)) / (
            fp(p, pl, rl, cl, g) + fp(p, pr, rr, cr, g))
        pn = max(pn, 1e-12)
        if abs(pn - p) <= 1e-12 * abs(pn + p) + 1e-14:
            return pn, 0.5 * (ul + ur) + 0.5 * (f(pn, pr, rr, cr, g) - f(pn, pl, rl, cl, g))
        p = pn
    return p, 0.5 * (ul + ur) + 0.5 * (f(p, pr, rr, cr, g) - f(p, pl, rl, cl, g))


def sample(xi, rl, ul, pl, rr, ur, pr, g):
    ps, us = star(rl, ul, pl, rr, ur, pr, g)
    cl, cr = math.sqrt(g * pl / rl), math.sqrt(g * pr / rr)
    if xi <= us:
        if ps > pl:
            sl = ul - cl * math.sqrt((g + 1.0) / (2.0 * g) * ps / pl + (g - 1.0) / (2.0 * g))
            if xi <= sl:
                return rl, ul, pl
            return (rl * (ps / pl + (g - 1.0) / (g + 1.0))
                    / ((g - 1.0) / (g + 1.0) * ps / pl + 1.0), us, ps)
        csl = cl * (ps / pl) ** ((g - 1.0) / (2.0 * g))
        if xi <= ul - cl:
            return rl, ul, pl
        if xi >= us - csl:
            return rl * (ps / pl) ** (1.0 / g), us, ps
        u = 2.0 / (g + 1.0) * (cl + (g - 1.0) / 2.0 * ul + xi)
        c = 2.0 / (g + 1.0) * (cl + (g - 1.0) / 2.0 * (ul - xi))
        return (rl * (c / cl) ** (2.0 / (g - 1.0)), u,
                pl * (c / cl) ** (2.0 * g / (g - 1.0)))
    if ps > pr:
        sr = ur + cr * math.sqrt((g + 1.0) / (2.0 * g) * ps / pr + (g - 1.0) / (2.0 * g))
        if xi >= sr:
            return rr, ur, pr
        return (rr * (ps / pr + (g - 1.0) / (g + 1.0))
                / ((g - 1.0) / (g + 1.0) * ps / pr + 1.0), us, ps)
    csr = cr * (ps / pr) ** ((g - 1.0) / (2.0 * g))
    if xi >= ur + cr:
        return rr, ur, pr
    if xi <= us + csr:
        return rr * (ps / pr) ** (1.0 / g), us, ps
    u = 2.0 / (g + 1.0) * (-cr + (g - 1.0) / 2.0 * ur + xi)
    c = 2.0 / (g + 1.0) * (cr - (g - 1.0) / 2.0 * (ur - xi))
    return rr * (c / cr) ** (2.0 / (g - 1.0)), u, pr * (c / cr) ** (2.0 * g / (g - 1.0))


MODE = os.environ.get("LA_BENCH_SELFTEST", "")
if MODE:
    # THE GATE'S OWN CONTROL: the exact Riemann solution smeared exactly as a first-order upwind scheme
    # smears it -- a Gaussian of the modified equation's own width -- so the arms converge at the half
    # order the theorem gives; then the same with the waves displaced.
    GAM, RL, PL, T = 1.4, 1.0, 1.0e5, 0.2 / math.sqrt(1.4 * 1.0e5 / 1.0)
    arms = {}
    for fam, rr0, pr0 in (("sod", 0.125, 1.0e4),
                          ("weak", 1.0 * 0.99 ** (1.0 / GAM), 0.99e5)):
        for tag, n in (("coarse", 200), ("fine", 400)):
            L = 1.0 / n
            sd = math.sqrt(0.5 * math.sqrt(GAM * PL / RL) * L * T)
            shift = 3.0 * sd if MODE == "broken" else 0.0
            rho, vel, pre = [], [], []
            for c in range(n):
                x = (c + 0.5) * L
                acc, w = [0.0, 0.0, 0.0], 0.0
                for k in range(-24, 25):
                    xx = x + k * L - shift
                    g = math.exp(-0.5 * (k * L / sd) ** 2)
                    s = sample((xx - 0.5) / T, RL, 0.0, PL, rr0, 0.0, pr0, GAM)
                    for i in range(3):
                        acc[i] += g * s[i]
                    w += g
                rho.append(acc[0] / w)
                vel.append(acc[1] / w)
                pre.append(acc[2] / w)
            arms[fam + "_" + tag] = {"cells": n, "cell_m": L, "t_s": T, "dt_s": T / 120.0,
                                     "rho_r": rr0, "p_r": pr0, "rho": rho, "pressure": pre,
                                     "vel_x": vel, "temp": [0.0] * n, "gamma": [GAM] * n,
                                     "gas_r": [287.0] * n}
    d = {"tube_m": 1.0, "rho_l": RL, "p_l": PL, "arms": arms}
else:
    d = json.loads(sys.stdin.read().split("=", 1)[1])

rl, pl, x0 = d["rho_l"], d["p_l"], 0.5 * d["tube_m"]
THRESH = 0.05     # share of the density jump that counts as the wave having arrived


def edge(xs, rho, ref, jump, from_left):
    idx = range(len(xs)) if from_left else range(len(xs) - 1, -1, -1)
    for i in idx:
        if abs(rho[i] - ref) > THRESH * jump:
            return xs[i]
    return x0


report, fails, errs, over = {}, [], {}, {}
for key, a in sorted(d["arms"].items()):
    n, L, t, g = a["cells"], a["cell_m"], a["t_s"], a["gamma"][0]
    rr, pr = a["rho_r"], a["p_r"]
    cl = math.sqrt(g * pl / rl)
    # The width a first-order upwind scheme diffuses a front to over t: its modified equation carries
    # D = a dx / 2 (Hirt 1968), and a step under diffusion spreads as 2 sqrt(D t).
    width = 2.0 * math.sqrt(0.5 * cl * L * t)
    ps, us = star(rl, 0.0, pl, rr, 0.0, pr, g)
    lo = [min(rl, rr), min(0.0, us), min(pl, pr)]
    hi = [max(rl, rr), max(0.0, us), max(pl, pr)]
    xs = [(c + 0.5) * L for c in range(n)]
    exact = [sample((x - x0) / t, rl, 0.0, pl, rr, 0.0, pr, g) for x in xs]
    e1, tv = [0.0] * 3, [0.0] * 3
    for c in range(n):
        for i in range(3):
            e1[i] += abs((a["rho"][c], a["vel_x"][c], a["pressure"][c])[i] - exact[c][i])
        if c:
            for i in range(3):
                tv[i] += abs(exact[c][i] - exact[c - 1][i])
    errs[key] = [e1[i] / max(tv[i] * n, 1e-30) for i in range(3)]
    # (a) THE WAVE POSITIONS, both profiles read by the SAME threshold so only the scheme's smearing
    # separates them. The head runs at the left sound speed, the shock at its own exact speed.
    jump = abs(rl - rr)
    ex_rho = [e[0] for e in exact]
    head_ex = edge(xs, ex_rho, rl, jump, True)
    head_sim = edge(xs, a["rho"], rl, jump, True)
    shock_ex = edge(xs, ex_rho, rr, jump, False)
    shock_sim = edge(xs, a["rho"], rr, jump, False)
    # (b) POSITIVITY, an exact requirement of the Euler equations, and the overshoot past the range the
    # exact solution spans, which must FALL under refinement.
    worst = 0.0
    for i, nm in enumerate(("rho", "vel_x", "pressure")):
        for v in a[nm]:
            worst = max(worst, (lo[i] - v) / max(hi[i] - lo[i], 1e-30),
                        (v - hi[i]) / max(hi[i] - lo[i], 1e-30))
    over[key] = worst
    if min(a["rho"]) <= 0.0 or min(a["pressure"]) <= 0.0:
        fails.append("%s: a cell holds a non-positive density or pressure, which the Euler equations "
                     "do not have a solution for." % key)
    report[key] = {"L1_rho": errs[key][0], "L1_u": errs[key][1], "L1_p": errs[key][2],
                   "head_err_m": abs(head_sim - head_ex), "shock_err_m": abs(shock_sim - shock_ex),
                   "front_width_m": width, "overshoot": worst}
    if abs(head_sim - head_ex) > width:
        fails.append("%s: the rarefaction head stands at %.4f m; the exact one read the same way is at "
                     "%.4f m, and the scheme's own diffusion allows %.4f m."
                     % (key, head_sim, head_ex, width))
    if abs(shock_sim - shock_ex) > width:
        fails.append("%s: the shock stands at %.4f m against an exact %.4f m, past the %.4f m the "
                     "scheme's own diffusion allows." % (key, shock_sim, shock_ex, width))

order = {}
for fam in ("sod", "weak"):
    o = [math.log(errs[fam + "_coarse"][i] / max(errs[fam + "_fine"][i], 1e-30)) / math.log(2.0)
         for i in range(3)]
    order[fam] = o
    if min(o) < 0.4:
        fails.append("%s: the L1 error converges at order %.3f in the coarsest of rho, u, p. A "
                     "monotone first-order scheme converges at 1/2 on Riemann data (Kuznetsov 1976); "
                     "below that it is not converging to the exact solution at all."
                     % (fam, min(o)))
    # Below float32's own noise on the state there is no overshoot to speak of, only round-off.
    if over[fam + "_fine"] > max(over[fam + "_coarse"], 1e-5):
        fails.append("%s: the overshoot past the exact solution's own range GREW from %.4g to %.4g as "
                     "the grid halved. Refinement is making the scheme more oscillatory, so it is not "
                     "converging." % (fam, over[fam + "_coarse"], over[fam + "_fine"]))

print("BENCH_SHOCK_TUBE=" + json.dumps(
    {"error": {k: round(v["L1_rho"], 6) for k, v in report.items()},
     "bound": {k: round(v["front_width_m"], 6) for k, v in report.items()},
     "order": {k: [round(x, 3) for x in v] for k, v in order.items()},
     "detail": report}, sort_keys=True))
for m in fails:
    print("check_bench_shock_tube: " + m, file=sys.stderr)
sys.exit(1 if fails else 0)
PY

if ! LA_BENCH_SELFTEST=exact python3 "$JUDGE" >/dev/null; then
  echo "ERROR: this gate rejects the exact Riemann solution smeared as a first-order scheme smears" >&2
  echo "       it, so its bounds are not ones any solver could meet." >&2
  exit 2
fi
if LA_BENCH_SELFTEST=broken python3 "$JUDGE" >/dev/null 2>&1; then
  echo "ERROR: this gate accepts waves standing three smearing widths from where the characteristics" >&2
  echo "       put them, so it cannot fail." >&2
  exit 2
fi

out="$(LA_DONE_RE='^BENCH_RAW_SHOCK_TUBE=' "$REPO_ROOT/scripts/run_sim_offscreen.sh" \
  --path "$REPO_ROOT" -s "res://$PROBE" 2>&1)"
raw="$(printf '%s\n' "$out" | grep -m1 '^BENCH_RAW_SHOCK_TUBE=')"
if [ -z "$raw" ]; then
  echo "ERROR: the rig published no BENCH_RAW_SHOCK_TUBE line." >&2
  printf '%s\n' "$out" | tail -20 >&2
  exit 2
fi
printf '%s' "$raw" | python3 "$JUDGE"
rc=$?
[ "$rc" -eq 1 ] && exit 1
[ "$rc" -eq 0 ] || exit 2

# ARM TWO -- the world the sim seeds. The acoustic rung's own gauges must be present and finite, or the
# face solve the rig exercised is not the one the planet runs.
FRAMES="${LA_BENCH_ST_FRAMES:-8}"
. "$REPO_ROOT/scripts/lib_rung.sh"
world="$(la_rung_report 3 "$FRAMES" "mach_max,wind_speed_max,field_dt_s")"
la_rung_require "$world" mach_max wind_speed_max || exit 2
printf 'BENCH_SHOCK_TUBE_WORLD={"mach_max":%s,"wind_speed_max":%s}\n' \
  "$(la_rung_value "$world" mach_max)" "$(la_rung_value "$world" wind_speed_max)"
echo "check_bench_shock_tube: OK"

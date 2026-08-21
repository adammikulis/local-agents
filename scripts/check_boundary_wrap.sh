#!/usr/bin/env bash
# A TORUS HAS NO EDGE. A fully sealed slice — sides WRAP, vertical SHUT, requested explicitly, since the
# capture-less default now opens its top to SPACE — must book exactly zero on every boundary row and hold
# every gated stock to round-off. energy_stock may read
# unmeasured only while HANDOFF item 0's momentum runaway poisons the enthalpy sum; any other unmeasured
# stock is red.
# EXIT 0 clean · 1 a violation · 2 could not run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -f "$REPO_ROOT/scripts/sim_run.sh" ] || { echo "ERROR: sim_run.sh missing." >&2; exit 2; }

# The torus claim — no edge, so no book — holds from the first step, and the books and conservation rows
# publish every step. The 600-step audited verdict belongs to check_conservation.sh, a declared soak.
FRAMES="${LA_BND_WRAP_FRAMES:-40}"
ERRLOG="$(mktemp "${TMPDIR:-/tmp}/la_bnd_wrap.XXXXXX")"
out="$(LA_BOUNDARY_FACES="wrap,wrap,shut,shut,wrap,wrap" \
  "$REPO_ROOT/scripts/sim_run.sh" --path "$REPO_ROOT" --slice --frames "$FRAMES" --raw 2>"$ERRLOG")"
rc=$?
case "$rc" in
  0|122|123) ;;
  126) echo "FAIL: the torus run fired CONSERVATION_VIOLATION." >&2; tail -6 "$ERRLOG" >&2; rm -f "$ERRLOG"; exit 1 ;;
  *) echo "ERROR: the torus run failed (exit $rc) — refusing to report a pass." >&2; tail -12 "$ERRLOG" >&2; rm -f "$ERRLOG"; exit 2 ;;
esac
rm -f "$ERRLOG"

RAWFILE="$(mktemp "${TMPDIR:-/tmp}/la_bnd_wrap_raw.XXXXXX")"
printf '%s\n' "$out" > "$RAWFILE"
python3 - "$RAWFILE" <<'PY'
import json, sys

raw = open(sys.argv[1]).read().strip()
if not raw.startswith("{"):
    print("ERROR: the run printed no report JSON — refusing to report a pass.", file=sys.stderr)
    raise SystemExit(2)
d = json.loads(raw)

def find(key):
    if key in d:
        return d[key]
    for sub in d.values():
        if isinstance(sub, dict) and key in sub:
            return sub[key]
    return None

books = {}
for blk in [d] + [v for v in d.values() if isinstance(v, dict)]:
    for k, v in blk.items():
        if (k.endswith("_bnd_in") or k.endswith("_bnd_crossed")) and isinstance(v, (int, float)):
            books[k] = float(v)
if len(books) < 10:
    print("ERROR: only %d boundary books published — the ledger shape changed under this gate." % len(books),
          file=sys.stderr)
    raise SystemExit(2)

fails = 0
for k, v in sorted(books.items()):
    if v != 0.0:
        print("FAIL: %s reads %r on a domain with no edge." % (k, v), file=sys.stderr)
        fails += 1

rows = find("conservation")
allowed = find("conservation_allowed_rel")
if not isinstance(rows, dict) or not isinstance(allowed, dict):
    print("ERROR: the run published no conservation rows.", file=sys.stderr)
    raise SystemExit(2)
for key, v in sorted(rows.items()):
    if key == "energy_stock" and v == "unmeasured":
        continue
    if not isinstance(v, (int, float)):
        print("FAIL: conservation row %s reads %r — a stock this gate holds went unmeasured." % (key, v),
              file=sys.stderr)
        fails += 1
        continue
    lim = allowed.get(key)
    if not isinstance(lim, (int, float)):
        print("FAIL: conservation row %s has no floor to be judged against." % key, file=sys.stderr)
        fails += 1
        continue
    if abs(float(v)) > float(lim):
        print("FAIL: %s drifted %r on a closed torus (round-off floor %r)." % (key, v, lim), file=sys.stderr)
        fails += 1

viol = find("conservation_violations") or []
if viol:
    print("FAIL: the run's own gate fired on %s." % viol, file=sys.stderr)
    fails += 1
if len(rows) < 5:
    print("ERROR: only %d conservation rows published — this arm judged almost nothing." % len(rows),
          file=sys.stderr)
    raise SystemExit(2)

print("BOUNDARY_WRAP={\"books\":%d,\"rows\":%d,\"failures\":%d}" % (len(books), len(rows), fails))
raise SystemExit(1 if fails else 0)
PY
rc=$?
rm -f "$RAWFILE"
[ "$rc" -eq 0 ] && echo "check_boundary_wrap: OK"
exit "$rc"

#!/usr/bin/env bash
# CONSERVATION GATE — matter and energy do not appear or vanish.
#
# EVERY ROW IS A FRACTION: the ledger's `*_rel` gauges, a residual over what it is a residual OF, never bare
# SI. The tolerance is a fraction too, from the float32 format and the cell count; changing it needs the
# maintainer.
#
# A CLEAN LOG IS NOT A PASS. The audit runs once, REFERENCE_STEPS past the seal, and only when every gated
# quantity produced a number. A run that never reached the horizon, or whose ledger could not answer, prints
# no violation line at all — so this gate reads `conservation_audited` and refuses to call that conserved.
#
# EXIT CODES. 0 conserved · 1 a substance drifted · 2 could not run or could not measure, never a silent pass.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# DECISION, not a law: long enough that LAMaterialFieldConservation3D.REFERENCE_STEPS past the seal is
# reached even if the field steps only once per rendered frame. `conservation_audited` below is what proves
# it, so a default that turns out short goes RED and names itself rather than passing.
FRAMES="${LA_CONS_FRAMES:-900}"
SEED="${LA_CONS_SEED:-4242}"

# shellcheck source=lib_require.sh
source "$REPO_ROOT/scripts/lib_require.sh" || {
  echo "ERROR: scripts/lib_require.sh is missing — the tool preflight cannot run, so neither can this." >&2
  exit 2
}
require_tool godot
require_tool python3

OUT="$(mktemp "${TMPDIR:-/tmp}/la_cons.XXXXXX")"
trap 'rm -f "$OUT"' EXIT

# SOAK: 600+ frames to audit the books at all; run by hand, no lane blocks on it

# SOAK: the books cannot be audited under 600 frames; run by hand, no lane blocks on it
LA_RUN_TIMEOUT="${LA_RUN_TIMEOUT:-1800}" LA_NO_STREAMER=1 \
  "$REPO_ROOT/scripts/run_sim_offscreen.sh" --path "$REPO_ROOT" \
  addons/local_agents/game/VoxelWorld.tscn --fixed-fps 60 \
  -- --sandbox --planet-only --no-fauna --bare "--run-frames=${FRAMES}" "--seed=${SEED}" \
  > "$OUT" 2>&1
rc=$?

if ! grep -q '^SIM_REPORT=' "$OUT"; then
  echo "ERROR: the run produced no SIM_REPORT (exit $rc) — refusing to report a pass on no data." >&2
  tail -20 "$OUT" >&2
  exit 2
fi

# A BREACH OUTRANKS A STARVED AUDIT. Some rows can answer while others cannot, and what they found stands.
n="$(grep -c '^CONSERVATION_VIOLATION=' "$OUT" || true)"
if [ "$n" -gt 0 ]; then
  grep '^CONSERVATION_VIOLATION=' "$OUT"
  echo
  echo "$n quantity(s) drifted beyond arithmetic noise. Matter and energy do not appear or vanish; the"
  echo "allowance is zero and raising it needs the maintainer AND a measurement taken after the floor holds"
  echo "(determinism, observer independence, a physics-clock horizon)."
  exit 1
fi

# The audit is what makes a clean log mean anything. Four ways it does not happen, each needing a different
# fix, so the gate names which one it saw instead of guessing.
verdict="$(python3 - "$OUT" <<'PY'
import json, sys
rep = None
for line in open(sys.argv[1], errors="replace"):
    if line.startswith("SIM_REPORT="):
        rep = line[len("SIM_REPORT="):]
try:
    d = json.loads(rep)
except Exception as exc:
    print("unreadable %s" % exc)
    raise SystemExit(0)
if d.get("conservation_audited") is True:
    print("audited")
elif "conservation" not in d:
    print("absent")
elif d.get("conservation") == "seeding":
    print("seeding")
elif d.get("conservation_unmeasured"):
    print("starved %s" % ",".join(str(s) for s in d["conservation_unmeasured"]))
else:
    print("short")
PY
)"

case "$verdict" in
  audited)
    echo "check_conservation: OK — every gated quantity was measured and held to arithmetic noise."
    exit 0 ;;
  absent)
    echo "ERROR: the report carries no conservation block at all — the material field never reported." >&2
    echo "       Look for a script that failed to compile; a dead field still prints a full SIM_REPORT." >&2
    exit 2 ;;
  seeding)
    echo "ERROR: the world never sealed, so matter was still allowed to be created for the whole run." >&2
    echo "       LAMaterialFieldSeal3D latches only once every required channel is live." >&2
    exit 2 ;;
  starved*)
    echo "ERROR: the audit ran and could not answer. No number for: ${verdict#starved }" >&2
    echo "       A quantity with no total is UNMEASURED, not conserved. Fix the ledger leg that is absent." >&2
    echo "       A row also reads UNMEASURED when its tolerance reached 1.0: past that the instrument" >&2
    echo "       cannot separate a wholly unaccounted window from round-off, so it may not report a pass." >&2
    grep '^CONSERVATION_UNMEASURED=' "$OUT" >&2
    exit 2 ;;
  short)
    echo "ERROR: the run never reached the audit horizon, so nothing was checked." >&2
    echo "       Raise LA_CONS_FRAMES until conservation_audited reads true — the horizon is" >&2
    echo "       LAMaterialFieldConservation3D.REFERENCE_STEPS field steps past the seal step." >&2
    exit 2 ;;
  *)
    echo "ERROR: could not read conservation_audited from SIM_REPORT — $verdict" >&2
    exit 2 ;;
esac

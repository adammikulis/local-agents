#!/usr/bin/env bash
# =====================================================================================================
# NEIGHBOUR RECIPROCITY — the send/gather pairing may be written in exactly one place.
#
# A two-pass transport debits `send[me*6 + d]` and the receiver credits `send[donor*6 + opposite(d)]`.
# Get `opposite` wrong and mass is debited from one cell and credited to another, or to none at all.
#
# gravity_flow_sphere3d.glsl had `uint rev = (d == 0u) ? 5u : ((d == 5u) ? 0u : (d ^ 1u));` directly
# under a comment correctly stating the pairing is 0<->5, 1<->2, 3<->4. `d ^ 1` is the opposite in
# LASphereGrid's INTERNAL order [IN,OUT,A0,A1,B0,B1]; neighbours_kernel_order() permutes that into
# [IN,A0,A1,B0,B1,OUT] before the buffer reaches any kernel. So all four lateral slots resolved wrong:
# slots 1 and 4 were read by nobody while 0 and 5 were each read twice, on every transfer of water,
# sediment and lava, with inflow_heat riding the fictitious mass.
#
# The comment was right and the code was wrong, which is why this is a gate and not a comment.
#
# BANNED in kernels3d/*.glsl: a `^ 1` on a slot index, and a `send[... * 6u + <literal>]` gather. Both
# mean the pairing has been rewritten locally. Call opposite_slot() / opposite_link() from
# nbr_shared.glsli instead — one place to be wrong, one place to fix.
#
# EXIT CODES. 0 clean · 1 a local pairing · 2 could not run.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K="$REPO_ROOT/addons/local_agents/sim/material/kernels3d"
SHARED="nbr_shared.glsli"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -d "$K" ] || { echo "ERROR: kernel dir missing." >&2; exit 2; }
[ -f "$K/$SHARED" ] || { echo "ERROR: $SHARED missing — the one place the pairing lives." >&2; exit 2; }

python3 - "$K" "$SHARED" <<'PY'
import os, re, sys

kdir, shared = sys.argv[1], sys.argv[2]
# A gather that hardcodes the reciprocal slot, or any local xor-pairing of a slot index.
LITERAL_GATHER = re.compile(r"send\s*\[[^\]]*\*\s*6u?\s*\+\s*\d+u?\s*\]")
XOR_PAIR = re.compile(r"\^\s*1u?\b")

hits = []
for fn in sorted(os.listdir(kdir)):
    if not fn.endswith((".glsl", ".glsli")) or fn == shared:
        continue
    path = os.path.join(kdir, fn)
    for n, line in enumerate(open(path, errors="replace").read().splitlines(), 1):
        code = line.split("//", 1)[0]
        if not code.strip():
            continue
        if LITERAL_GATHER.search(code):
            hits.append((fn, n, "hardcoded reciprocal slot", code.strip()[:88]))
        elif XOR_PAIR.search(code):
            # Unconditional. The first draft of this gate additionally required "send[" on the same line
            # and so did NOT catch `uint rev = ... (d ^ 1u);`, which is the exact line that caused the
            # defect — a gate that could only pass. There is no legitimate `^ 1` left in these kernels.
            hits.append((fn, n, "local xor pairing", code.strip()[:88]))

print('NEIGHBOUR_RECIPROCITY={"local_pairings":%d}' % len(hits))
for fn, n, why, code in hits:
    print("  %s:%d  %s\n      %s" % (fn, n, why, code))

if hits:
    print("\nThe send/gather pairing is written outside %s. Kernel slot order is [IN,A0,A1,B0,B1,OUT], so" % shared)
    print("the opposites are 0<->5, 1<->2, 3<->4 — `d ^ 1` is the INTERNAL order's answer and is wrong here.")
    print("Call opposite_slot(d) or opposite_link(l) so there is one place to be wrong.")
    sys.exit(1)
print("check_neighbour_reciprocity: OK")
PY

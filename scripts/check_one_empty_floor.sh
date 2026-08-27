#!/usr/bin/env bash
# ONE EMPTINESS FLOOR. "Is this cell empty" guards a division by mass, so the floor is a DENSITY, and
# there is one of it: transport.glsl's donor test and state_derive.glsl's v = p/rho read the same
# push-constant, fed from one GDScript declaration. A second floor — a volume fraction, a per-row
# amount — makes a cell of hydrogen and a cell of rock empty at densities orders of magnitude apart.
# EXIT 0 clean · 1 a second floor or a kernel that stopped reading the one · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "check_one_empty_floor: python3 absent." >&2; exit 2; }

python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
KERNELS = os.path.join(root, "addons/local_agents/sim/material/kernels3d")
OWNER = os.path.join(root, "addons/local_agents/sim/material/sphere_passes/TransportPass.gd")
READERS = ["transport.glsl", "state_derive.glsl"]
FLOOR = "rho_floor"
OWNER_NAME = "EMPTY_RHO_KG_M3"
RETIRED = ["min_fill", "min_amount", "MIN_FILL_FRAC", "MIN_AMOUNT"]

if not os.path.isdir(KERNELS):
    print("check_one_empty_floor: MISSING %s" % KERNELS, file=sys.stderr); sys.exit(2)
if not os.path.isfile(OWNER):
    print("check_one_empty_floor: MISSING %s" % OWNER, file=sys.stderr); sys.exit(2)


def read(p):
    return open(p, encoding="utf-8").read()


kernels = sorted(f for f in os.listdir(KERNELS) if f.endswith(".glsl"))
if len(kernels) < 5:
    print("check_one_empty_floor: %d kernels found — the gate's scope collapsed." % len(kernels),
          file=sys.stderr)
    sys.exit(2)
for r in READERS:
    if r not in kernels:
        print("check_one_empty_floor: MISSING kernel %s" % r, file=sys.stderr); sys.exit(2)

bad = []
for f in kernels:
    src = read(os.path.join(KERNELS, f))
    for name in RETIRED:
        if re.search(r"\b%s\b" % re.escape(name), src):
            bad.append("%s still names the retired floor `%s`" % (f, name))

# A reader must USE the floor, not merely declare the slot: params.rho_floor has to appear.
for r in READERS:
    src = read(os.path.join(KERNELS, r))
    if not re.search(r"\bparams\.%s\b" % FLOOR, src):
        bad.append("%s never reads params.%s, so its emptiness test is not the one floor" % (r, FLOOR))

owner_src = read(OWNER)
decls = re.findall(r"^const\s+%s\b" % OWNER_NAME, owner_src, re.M)
if len(decls) != 1:
    bad.append("TransportPass.gd declares %s %d times; the floor has one owner" % (OWNER_NAME, len(decls)))

# Every reader's push constant is fed from that one owner, and nowhere else declares it.
SIM = os.path.join(root, "addons/local_agents/sim")
elsewhere = []
for dirpath, _dirs, files in os.walk(SIM):
    for f in files:
        if not f.endswith(".gd"):
            continue
        p = os.path.join(dirpath, f)
        if os.path.samefile(p, OWNER) if os.path.exists(p) else False:
            continue
        if re.search(r"^const\s+%s\b" % OWNER_NAME, read(p), re.M):
            elsewhere.append(os.path.relpath(p, root))
for p in elsewhere:
    bad.append("%s declares a second %s" % (p, OWNER_NAME))

if bad:
    print("check_one_empty_floor: FAILED", file=sys.stderr)
    for x in sorted(set(bad)):
        print("  " + x, file=sys.stderr)
    print("\nOne floor, a density in kg/m^3, owned by TransportPass.%s and read by both kernels."
          % OWNER_NAME, file=sys.stderr)
    sys.exit(1)

print("check_one_empty_floor: OK (%d kernels scanned, one owner, %d readers)"
      % (len(kernels), len(READERS)))
PY

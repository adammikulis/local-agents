#!/usr/bin/env bash
# `restrict` on a transport binding that aliases the row's own channel is a lie the compiler believes.
# flux.glsl binds the row's channel at binding 0 and named field buffers elsewhere; when a row's
# channel IS one of those, two bindings reach one buffer and `restrict` lets a read hoist over a write.
# EXIT 0 clean · 1 a restrict-qualified alias · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "check_transport_alias: python3 absent." >&2; exit 2; }

python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
KERNEL = os.path.join(root, "addons/local_agents/sim/material/kernels3d/flux.glsl")
PASS = os.path.join(root, "addons/local_agents/sim/material/sphere_passes/FluxPass.gd")
RECORDS = os.path.join(root, "addons/local_agents/sim/material/TransportRecords.gd")
for p in (KERNEL, PASS, RECORDS):
    if not os.path.isfile(p):
        print("check_transport_alias: MISSING %s" % p, file=sys.stderr); sys.exit(2)


def read(p):
    return open(p, encoding="utf-8").read()


channels = set(re.findall(r'"channel"\s*:\s*"(\w+)"', read(RECORDS)))
# escape_rows() builds a row per gas from LAMatterChannels.GASES, so the literal scan misses those.
gases = os.path.join(root, "addons/local_agents/sim/material/MatterChannels.gd")
if os.path.isfile(gases):
    m = re.search(r"^const GASES\s*(?::[^=]+)?=\s*\[(.*?)\]", read(gases), re.M | re.S)
    if m:
        channels |= set(re.findall(r'"(\w+)"', m.group(1)))
if len(channels) < 10:
    print("check_transport_alias: found %d transport channels — the gate's scope collapsed."
          % len(channels), file=sys.stderr)
    sys.exit(2)

src = read(PASS)
# The pass names its plain bindings once, as `"<buffer>": <binding>`; the rest are inline pairs.
bound = [(b, n) for n, b in re.findall(r'"(\w+)"\s*:\s*(\d+)', src)]
bound += re.findall(r'\[\s*(\d+)\s*,\s*_single\(bufs,\s*"(\w+)"\)', src)
if len(bound) < 20:
    print("check_transport_alias: read %d bindings out of FluxPass — the gate's scope collapsed."
          % len(bound), file=sys.stderr)
    sys.exit(2)

DECL = re.compile(r"layout\(set = 0, binding = (\d+), std430\)\s*((?:\w+\s+)*)buffer\s+(\w+)")
restricted = {}
for m in DECL.finditer(read(KERNEL)):
    restricted[int(m.group(1))] = ("restrict" in m.group(2).split(), m.group(3))
if not restricted:
    print("check_transport_alias: flux.glsl declared no bindings.", file=sys.stderr); sys.exit(2)

bad = []
# Binding 0 takes whichever channel the row moves, so it aliases every named channel buffer beside it.
if restricted.get(0, (False, "?"))[0]:
    bad.append("binding 0 (%s) is restrict, and it takes the row's own channel buffer" % restricted[0][1])
for b, name in bound:
    b = int(b)
    if name not in channels:
        continue
    if b not in restricted:
        print("check_transport_alias: FluxPass binds %d, which flux.glsl never declares."
              % b, file=sys.stderr)
        sys.exit(2)
    if restricted[b][0]:
        bad.append("binding %d (%s) is restrict and binds \"%s\", which is also a transport channel"
                   % (b, restricted[b][1], name))

if bad:
    print("check_transport_alias: FAILED", file=sys.stderr)
    for x in sorted(set(bad)):
        print("  " + x, file=sys.stderr)
    print("\nTwo bindings on one buffer under `restrict` let the compiler reorder a read across a write.\n"
          "The row then transports nothing and nothing goes red. Drop the qualifier.", file=sys.stderr)
    sys.exit(1)

print("check_transport_alias: OK (%d channels, %d named bindings)" % (len(channels), len(bound)))
PY

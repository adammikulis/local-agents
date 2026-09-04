#!/usr/bin/env bash
# `restrict` ON A TRANSPORT SLOT THAT ALIASES ANOTHER IS A LIE THE COMPILER BELIEVES. flux.glsl runs
# one record at a time; six of its slots take whatever buffer the ROW names, so when a row names a
# buffer that is also bound by name, two bindings reach one memory and a read may hoist over a write.
# Two readonly bindings on one buffer are harmless: no write to reorder around. The violation is an
# aliasing pair where at least one side is written through and either side is `restrict`. The slots
# come from material/Bindings.gd. EXIT 0 clean · 1 an alias · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib_require.sh
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
if declare -f require_tool >/dev/null 2>&1; then
  require_tool python3
elif ! command -v python3 >/dev/null 2>&1; then
  echo "check_transport_alias: python3 absent." >&2
  exit 2
fi

python3 - "$ROOT" <<'PY'
import os, re, sys
sys.dont_write_bytecode = True
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "scripts"))
import lib_bindings as LB

KERNEL = "flux.glsl"
PASS = "FluxPass.gd"
RECORDS = os.path.join(LB.MATERIAL, "TransportRecords.gd")
MATTER = os.path.join(LB.MATERIAL, "MatterChannels.gd")

# The record field each row-fed slot takes its buffer from. `flux_drive` falls back to the row's own
# channel, and `flux_energy` carries whichever of the two energy reservoirs the row is not moving.
FED_BY = {"flux_amount": ["channel"], "flux_drive": ["drive", "channel"], "flux_resist": ["resist"],
          "flux_aux": ["aux"], "flux_frac": ["frac"]}
ENERGY = ("flux_energy", ["e_j_m3", "e_lith_j_m3"])

try:
    recs = LB.read(RECORDS)
    declared = LB.in_kernel().get(KERNEL, [])
    sets, unresolved = LB.pass_sets(PASS, LB.sim_classes())
except (LB.Missing, OSError) as err:
    print("check_transport_alias: %s" % err, file=sys.stderr)
    sys.exit(2)
if unresolved or not sets:
    print("check_transport_alias: a uniform set the gate cannot read is one it cannot check.",
          file=sys.stderr)
    for u in sorted(set(unresolved)) or ["%s builds no uniform set" % PASS]:
        print("  " + u, file=sys.stderr)
    sys.exit(2)

# What each slot may receive. A row-fed slot takes the row table's values; a fixed slot takes itself.
may_hold = {name: {name} for name in declared}
for slot, fields in FED_BY.items():
    got = set()
    for f in fields:
        got |= set(re.findall(r'"%s"\s*:\s*"(\w+)"' % f, recs))
    may_hold.setdefault(slot, set()).update(got)
# escape_rows() builds a row per gas from LAMatterChannels.GASES, so the literal scan misses those.
gases = re.search(r"^const GASES\s*(?::[^=]+)?=\s*\[(.*?)\]", LB.read(MATTER), re.M | re.S)
if gases is None:
    print("check_transport_alias: MatterChannels.gd declares no GASES.", file=sys.stderr)
    sys.exit(2)
for slot in ("flux_amount", "flux_drive"):
    may_hold[slot] |= set(re.findall(r'"(\w+)"', gases.group(1)))
may_hold[ENERGY[0]] = set(ENERGY[1])

if len(may_hold.get("flux_amount", set())) < 10:
    print("check_transport_alias: found %d transport channels — the gate's scope collapsed."
          % len(may_hold.get("flux_amount", set())), file=sys.stderr)
    sys.exit(2)

# How flux.glsl declares each slot. `restrict` promises no other binding reaches this memory.
QUAL = re.compile(r"layout\s*\(([^)]*)\)\s*((?:\w+\s+)*)buffer\s+(\w+)")
qual = {}
for fn in [KERNEL] + sorted(LB.includes_of(KERNEL)):
    src = LB.read(os.path.join(LB.KERNELS, fn))
    for m in QUAL.finditer(src):
        got = re.search(r"\bbinding\s*=\s*LA_BIND_(\w+)", m.group(1))
        if got:
            qual[got.group(1).lower()] = (m.group(2).split(), m.group(3))
if not qual:
    print("check_transport_alias: flux.glsl declared no bindings.", file=sys.stderr)
    sys.exit(2)

missing = sorted(s for s in may_hold if s not in qual)
if missing:
    print("check_transport_alias: %s binds %s, which %s never declares."
          % (PASS, ", ".join(missing), KERNEL), file=sys.stderr)
    sys.exit(2)

bad = []
slots = sorted(may_hold)
for i, a in enumerate(slots):
    for b in slots[i + 1:]:
        shared = may_hold[a] & may_hold[b]
        if not shared:
            continue
        qa, qb = qual[a][0], qual[b][0]
        if "readonly" in qa and "readonly" in qb:
            continue                       # two reads on one buffer: no write to reorder around
        for side, q in ((a, qa), (b, qb)):
            if "restrict" in q:
                bad.append("%s (%s) is restrict and can hold %s, which %s also binds"
                           % (side, qual[side][1], sorted(shared)[0], b if side == a else a))

if bad:
    print("check_transport_alias: FAILED", file=sys.stderr)
    for x in sorted(set(bad)):
        print("  " + x, file=sys.stderr)
    print("\nTwo bindings on one buffer under `restrict` let the compiler reorder a read across a write.\n"
          "The row then transports nothing and nothing goes red. Drop the qualifier.", file=sys.stderr)
    sys.exit(1)

print("check_transport_alias: OK (%d slots, %d that a record fills)" % (len(qual), len(FED_BY) + 1))
PY

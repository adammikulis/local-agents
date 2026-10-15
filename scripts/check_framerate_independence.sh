#!/usr/bin/env bash
# NO FRAME CALLBACK MAY DRIVE THE SIMULATION. LASimLoop steps a fixed quantum of simulated seconds; a
# frame integrator turns the machine's speed into a physical rate.
#   R1  No simulation MUTATOR is reachable from `_process`, through the same file's private helpers.
#   R2  Nothing under sim/ or game/world/ defines `_process` with a USED delta, bar PRESENTATION_ALLOW.
#   R3  Nothing under sim/ but SimLoop.gd defines `_physics_process`, bar PHYSICS_TICK_ALLOW, a ratchet.
#   R4  An allowlist entry names a file in its rule's scope that still holds what the rule forbids.

# EXIT 0 pass · 1 violations · 2 the gate could not run (missing tool or missing input).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool python3

SIM_DIR="$REPO_ROOT/addons/local_agents/sim"
GAME_DIR="$REPO_ROOT/addons/local_agents/game"

for d in "$SIM_DIR" "$GAME_DIR"; do
  if [[ ! -d "$d" ]]; then
    echo "ERROR: scan root not found: $d" >&2
    echo "       A gate whose input is missing FAILS. It does not pass." >&2
    exit 2
  fi
done

REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os, re, sys

repo = os.environ["REPO_ROOT"]
SIM = "addons/local_agents/sim"
GAME = "addons/local_agents/game"
# R2 also covers the world controllers: they sit in game/ but advance world state, and VoxelTimeline
# integrated the render delta there for a whole release without any gate seeing it.
GAME_WORLD = "addons/local_agents/game/world"
# R3's one legal holder. The loop is the simulation's entry point and reads no delta.
SIM_LOOP = f"{SIM}/SimLoop.gd"

# R1: writes to the material field, the ecology's world state, or the orbital state. Names come from
# MaterialField3D's public write API, LAEcologyService.set_sun and LASystemOrbits.
MUTATORS = [
    "set_wind(", "set_sun(", "set_star(", "set_sun_flux(", "set_plate_motion(",
    "add_heat_energy(", "add_lava(", "add_charge(",
    "add_water_pooled(", "add_magma_source(", "seed_field(", "apply_impulse(",
    "fire_barrage(", "force_erupt(",
]
# The integrating advance LAVoxelWorld drives. It consumes a delta, so the call site itself is the
# defect and nothing downstream of it needs naming.
ADVANCES = ["_orbits.update("]

# R2 allowlist: presentation + instrument modules under sim/. One line each, saying why the render clock
# is the right clock for it.
PRESENTATION_ALLOW = {
    f"{SIM}/ecology/BandChronicle.gd": "historian: writes dated records to the backstory store, not the field",
}

# R3 allowlist. A RATCHET — entries are removed as each module moves onto LASimLoop.subscribe, never added.
# Each entry ticks its own integrator, or follows its LABallistics bodies, on the engine's physics tick.
PHYSICS_TICK_ALLOW = {
    f"{SIM}/actors/Tree.gd": "advances its own topple swing each engine tick",
    f"{SIM}/actors/Nest.gd": "counts its own neglect clock each engine tick",
    f"{SIM}/actors/Meteor.gd": "copies its LABallistics free body onto the node each engine tick",
    f"{SIM}/actors/ThrownRock.gd": "steers its own flight each engine tick, not an LABallistics free body",
    f"{SIM}/TrackSystem.gd": "footprint decals laid under bodies moving on the physics tick",
}

# What each rule forbids, and where. R4 reads the same two patterns.
R2_RE = re.compile(r"^func _process\(delta")
R3_RE = re.compile(r"^func _physics_process\(")
R2_SCOPE = (f"{SIM}/", f"{GAME_WORLD}/")
R3_SCOPE = (f"{SIM}/",)

def gd_files(root):
    out = []
    for dp, _, fns in os.walk(os.path.join(repo, root)):
        for fn in sorted(fns):
            if fn.endswith(".gd"):
                out.append(os.path.relpath(os.path.join(dp, fn), repo))
    return sorted(out)

def split_funcs(lines):
    """name -> [(lineno, text)] for every top-level func body."""
    out, cur = {}, None
    for i, l in enumerate(lines):
        m = re.match(r"^(?:static )?func ([A-Za-z0-9_]+)\(", l)
        if m:
            cur = m.group(1)
            out.setdefault(cur, [])
            continue
        if l and not l[0].isspace() and not l.startswith("#"):
            cur = None
        if cur is not None:
            out[cur].append((i + 1, l))
    return out

def read_lines(rel):
    return open(os.path.join(repo, rel), encoding="utf-8").read().split("\n")

violations = []

# R4 — an entry whose file is gone, out of scope, or no longer holds the forbidden shape exempts nothing.
for allow, scope, pattern, rule in ((PRESENTATION_ALLOW, R2_SCOPE, R2_RE, "R2"),
                                    (PHYSICS_TICK_ALLOW, R3_SCOPE, R3_RE, "R3")):
    for rel in sorted(allow):
        path = os.path.join(repo, rel)
        if not (rel.startswith(scope) and os.path.isfile(path) and any(pattern.match(l) for l in read_lines(rel))):
            violations.append(
                f"{rel}: R4 stale {rule} allowlist entry exempts nothing\n"
                f"    delete the entry: the file is gone, outside {rule}'s scope, or holds no `{pattern.pattern[1:].replace(chr(92), '')}`")

for rel in gd_files(SIM) + gd_files(GAME):
    lines = read_lines(rel)
    funcs = split_funcs(lines)

    # R3 — the sim owns its loop, so a sim module may not hang off the engine's physics tick.
    if rel.startswith(R3_SCOPE) and rel != SIM_LOOP and rel not in PHYSICS_TICK_ALLOW:
        for i, l in enumerate(lines):
            if R3_RE.match(l):
                violations.append(
                    f"{rel}:{i+1}: R3 sim module runs on the ENGINE's physics tick\n"
                    f"    step through LASimLoop.subscribe() instead; only {SIM_LOOP} may hold _physics_process")

    if "_process" not in funcs:
        continue

    # R1 — mutators reachable from _process through same-file private helpers.
    seen, stack = set(), ["_process"]
    while stack:
        fn = stack.pop()
        if fn in seen:
            continue
        seen.add(fn)
        for ln, l in funcs.get(fn, []):
            s = l.strip()
            if s.startswith("#"):
                continue
            for m in MUTATORS + ADVANCES:
                if m in s:
                    via = "" if fn == "_process" else f" (via {fn})"
                    violations.append(
                        f"{rel}:{ln}: R1 simulation write `{m[:-1]}` reachable from _process{via}\n"
                        f"    {s[:100]}")
            for callee in re.findall(r"\b(_[A-Za-z0-9_]+)\(", s):
                if callee in funcs:
                    stack.append(callee)

    # R2 — a sim/ or game/world/ module may not integrate on the render delta.
    if not rel.startswith(R2_SCOPE) or rel in PRESENTATION_ALLOW:
        continue
    for i, l in enumerate(lines):
        if R2_RE.match(l):
            violations.append(
                f"{rel}:{i+1}: R2 module integrates the RENDER delta in _process\n"
                f"    step through LASimLoop.subscribe(), or add it to PRESENTATION_ALLOW with a reason")

if violations:
    print("FRAMERATE-INDEPENDENCE GATE FAILED")
    print("No frame callback may drive the simulation. Offenders:")
    print("")
    for v in violations:
        print("  " + v)
    print("")
    print(f"{len(violations)} violation(s).")
    sys.exit(1)

print("check_framerate_independence.sh: no simulation state advances on a frame callback.")
sys.exit(0)
PY
rc=$?
exit $rc

#!/usr/bin/env bash
# =====================================================================================================
# FRAMERATE-INDEPENDENCE GATE — no frame callback may drive the simulation.
#
# The simulation owns its loop (LASimLoop). One step is a fixed quantum of SIMULATED seconds; a slow frame
# yields fewer steps per wall second and loses no simulated time. A frame integrator does not: it turns the
# machine's speed into a physical rate, so the sun advances further per unit of chemistry than it should and
# by a machine-dependent amount.
#
# THREE RULES, all static (no run required):
#   R1  No simulation MUTATOR is reachable from a `_process` body. Reachability is resolved through the
#       same-file private helpers `_process` calls, so `_process -> _push_environment -> set_wind` fails.
#   R2  No file under addons/local_agents/sim/ or addons/local_agents/game/world/ defines `_process` with a
#       USED delta parameter, unless it is in PRESENTATION_ALLOW below. A `_delta` (unused) parameter
#       cannot integrate anything.
#   R3  No file under addons/local_agents/sim/ defines `_physics_process` at all, unless it is in
#       PHYSICS_TICK_ALLOW below. The loop is the ONE entry; everything else subscribes to `stepped`.
#
# Both allowlists hold presentation, instrument and engine-physics-body modules only. Every entry carries
# its reason, and PHYSICS_TICK_ALLOW is a RATCHET: entries come out, never in.
#
# EXIT CODES. 0 pass · 1 violations · 2 the gate could not run (missing tool or missing input).
# =====================================================================================================
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
    "set_wind(", "set_sun(", "set_sun_dir(", "set_solid(", "set_plate_motion(",
    "add_heat_energy(", "add_lava(", "add_vapor(", "add_charge(", "add_water_cell(",
    "add_water_pooled(", "add_magma_source(", "seed_field(", "apply_impulse(",
    "fire_barrage(", "force_erupt(",
]
# The two integrating advances LAVoxelWorld drives. They consume a delta, so the call site itself is the
# defect and nothing downstream of them needs naming.
ADVANCES = ["_orbits.update(", "_sky_ctrl.update("]

# R2 allowlist: presentation + instrument modules under sim/. One line each, saying why the render clock
# is the right clock for it.
PRESENTATION_ALLOW = {
    f"{SIM}/streamer/SceneEnergyGraph.gd": "overlay graph: samples gauges and redraws, writes no world state",
    f"{SIM}/streamer/StreamerDirector.gd": "commentary pacing for the LLM/TTS caster, writes no world state",
    f"{SIM}/streamer/StreamerAvatar.gd": "avatar animation",
    f"{SIM}/streamer/StreamerOverlay.gd": "overlay layout and animation",
    f"{SIM}/actors/LightningStrike.gd": "flash fade and node lifetime; it writes no world state",
    f"{SIM}/ecology/BandChronicle.gd": "historian: writes dated records to the backstory store, not the field",
    f"{SIM}/events/LAEventTracker.gd": "instrument: samples the report and emits events, mutates nothing",
    f"{SIM}/material/MaterialFieldRender3D.gd": "renderer: rebuilds the near-cap surface mesh for the camera",
    f"{GAME_WORLD}/VoxelViewControls.gd": "on-screen control bar: button state and layout, writes no world state",
}

# R3 allowlist. A RATCHET — entries are removed as each module moves onto LASimLoop.stepped, never added.
# Everything here is a body in the ENGINE's physics world, integrating against the physics server rather
# than the substrate. They are wrong for the same reason the field was and are not yet converted.
PHYSICS_TICK_ALLOW = {
    f"{SIM}/actors/Plant.gd": "engine physics body",
    f"{SIM}/actors/Tree.gd": "engine physics body",
    f"{SIM}/actors/Nest.gd": "engine physics body",
    f"{SIM}/actors/Meteor.gd": "engine physics body: ballistic arrival integrated by the physics server",
    f"{SIM}/actors/ThrownRock.gd": "engine physics body: ballistic flight integrated by the physics server",
    f"{SIM}/material/MaterialEjecta3D.gd": "ballistic ejecta integrated against the physics server",
    f"{SIM}/material/FieldBox.gd": "demo-scene host for a standalone field box, outside the planet loop",
    f"{SIM}/TrackSystem.gd": "footprint decals laid under bodies moving on the physics tick",
}

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

violations = []
for rel in gd_files(SIM) + gd_files(GAME):
    lines = open(os.path.join(repo, rel), encoding="utf-8").read().split("\n")
    funcs = split_funcs(lines)

    # R3 — the sim owns its loop, so a sim module may not hang off the engine's physics tick.
    if rel.startswith(SIM) and rel != SIM_LOOP and rel not in PHYSICS_TICK_ALLOW:
        for i, l in enumerate(lines):
            if re.match(r"^func _physics_process\(", l):
                violations.append(
                    f"{rel}:{i+1}: R3 sim module runs on the ENGINE's physics tick\n"
                    f"    subscribe to LASimLoop.stepped instead; only {SIM_LOOP} may hold _physics_process")

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
    if not (rel.startswith(SIM) or rel.startswith(GAME_WORLD)):
        continue
    if rel in PRESENTATION_ALLOW:
        continue
    for i, l in enumerate(lines):
        if re.match(r"^func _process\(delta", l):
            violations.append(
                f"{rel}:{i+1}: R2 module integrates the RENDER delta in _process\n"
                f"    subscribe to LASimLoop.stepped, or add it to PRESENTATION_ALLOW with a reason")

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

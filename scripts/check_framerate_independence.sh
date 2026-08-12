#!/usr/bin/env bash
# =====================================================================================================
# FRAMERATE-INDEPENDENCE GATE — the render clock may not drive the simulation.
#
# The material field advances in _physics_process on a fixed accumulator. Physics is capped by
# Engine.max_physics_steps_per_frame, and LAMaterialFieldSphereStep3D drops banked time above its own cap,
# so under load or a high --fast the physics clock falls behind the render clock. A _process integrator
# does not: it keeps accumulating wall time. The sun then advances further per unit of chemistry than it
# should, and by a machine-dependent amount.
#
# TWO RULES, both static (no run required):
#   R1  No simulation MUTATOR is reachable from a `_process` body. Reachability is resolved through the
#       same-file private helpers `_process` calls, so `_process -> _push_environment -> set_wind` fails.
#   R2  No file under addons/local_agents/sim/ defines `_process` with a USED delta parameter, unless it
#       is in PRESENTATION_ALLOW below. A `_delta` (unused) parameter cannot integrate anything.
#
# The allowlist holds presentation and instrument modules only. Every entry carries its reason.
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

# R1: writes to the material field, the ecology's world state, or the orbital state. Names come from
# MaterialField3D's public write API, LAEcologyService.set_sun and LASystemOrbits.
MUTATORS = [
    "set_wind(", "set_sun(", "set_sun_dir(", "set_solid(", "set_plate_motion(",
    "add_heat_energy(", "add_lava(", "add_vapor(", "add_charge(", "add_water_cell(",
    "add_water_pooled(", "add_magma_source(", "seed_field(", "apply_impulse(",
    # LAVoxelDisasters' seeding facade: each of these injects heat/water/pressure into the field.
    "spawn_thunderstorm(", "spawn_tornado(", "spawn_hurricane(", "spawn_default_volcano(",
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
    f"{SIM}/actors/Earthquake.gd": "node lifetime; the seismic and scare broadcasts fire in setup",
    f"{SIM}/ecology/BandChronicle.gd": "historian: writes dated records to the backstory store, not the field",
    f"{SIM}/events/LAEventTracker.gd": "instrument: samples the report and emits events, mutates nothing",
    f"{SIM}/material/MaterialFieldRender3D.gd": "renderer: rebuilds the near-cap surface mesh for the camera",
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

    # R2 — a sim/ module may not integrate on the render delta.
    if not rel.startswith(SIM):
        continue
    if rel in PRESENTATION_ALLOW:
        continue
    for i, l in enumerate(lines):
        if re.match(r"^func _process\(delta", l):
            violations.append(
                f"{rel}:{i+1}: R2 sim module integrates the RENDER delta in _process\n"
                f"    move it to _physics_process, or add it to PRESENTATION_ALLOW with a reason")

if violations:
    print("FRAMERATE-INDEPENDENCE GATE FAILED")
    print("The render clock may not drive the simulation. Offenders:")
    print("")
    for v in violations:
        print("  " + v)
    print("")
    print(f"{len(violations)} violation(s).")
    sys.exit(1)

print("check_framerate_independence.sh: no simulation state advances on the render clock.")
sys.exit(0)
PY
rc=$?
exit $rc

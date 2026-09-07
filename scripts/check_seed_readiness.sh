#!/usr/bin/env bash
# LIFE IS SEEDED WHEN THE WORLD CAN ANSWER, NOT WHEN A COUNTER SAYS SO. A vegetation placement reads the
# ground under the site and the temperature in the cell above it; both are produced by work whose latency
# is the machine's, so a wait counted in frames seeds a different census on a busy machine than on an idle
# one. The seeding gates on the field being sealed with a step drained and the terrain answering a radius.
# EXIT 0 the wait is the world's own · 1 a counter stands in for it · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3

SPAWN="$ROOT/addons/local_agents/game/world/VoxelSpawnController.gd"
FIELD="$ROOT/addons/local_agents/sim/material/MaterialField3D.gd"
CAPTURE="$ROOT/scripts/lint_capture.sh"
for f in "$SPAWN" "$FIELD" "$CAPTURE"; do
	[ -f "$f" ] || { echo "check_seed_readiness: MISSING ${f#"$ROOT"/}" >&2; exit 2; }
done

python3 - "$SPAWN" "$FIELD" "$CAPTURE" <<'PY'
import re, sys

spawn_path, field_path, capture_path = sys.argv[1], sys.argv[2], sys.argv[3]
spawn = open(spawn_path, errors="replace").read()
field = open(field_path, errors="replace").read()
capture = open(capture_path, errors="replace").read()
fails = []


def body_of(text, name):
    m = re.search(r"^func %s\(.*?\n(.*?)(?=^func |\Z)" % re.escape(name), text, re.M | re.S)
    return m.group(1) if m else None


# A COUNTER STANDING IN FOR AN ANSWER: a member incremented by one and compared to a literal.
counted = []
for m in re.finditer(r"^var (_\w+)\s*:\s*int\s*=", spawn, re.M):
    name = m.group(1)
    if re.search(r"%s\s*\+=\s*1" % re.escape(name), spawn) and \
            re.search(r"%s\s*[<>]=?\s*\d" % re.escape(name), spawn):
        counted.append(name)
if counted:
    fails.append("the spawn controller waits on %s, a counter of frames: on a loaded machine the same "
                 "world seeds a different census" % ", ".join(sorted(counted)))

spawn_body = body_of(spawn, "try_spawn")
if spawn_body is None:
    print("check_seed_readiness: VoxelSpawnController declares no try_spawn.", file=sys.stderr)
    sys.exit(2)
if "_world_ready()" not in spawn_body:
    fails.append("try_spawn does not gate on _world_ready(), so nothing holds the seeding to what the "
                 "world can answer")

ready = body_of(spawn, "_world_ready")
if ready is None:
    fails.append("the spawn controller declares no _world_ready")
else:
    for want, why in (("seeding_ready", "the field being sealed with a step drained into its mirrors"),
                      ("surface_radius", "the terrain answering a radius under the site")):
        if want not in ready:
            fails.append("_world_ready does not consult %s: %s goes unwaited-for" % (want, why))

seeding = body_of(field, "seeding_ready")
if seeding is None:
    fails.append("MaterialField3D declares no seeding_ready, so the field cannot say when it can answer")
else:
    for want in ("sealed()", "full_steps()"):
        if want not in seeding:
            fails.append("seeding_ready does not read %s, so it answers before the world does" % want)

# THE DEMO RUN IS THE SHARED ARM'S, taken before any gate starts. A gate that took its own would run it
# beside the worker pool, and the census would read the machine's load as well as the world.
if "life_demo.log" not in capture:
    fails.append("lint_capture.sh records no life run, so every gate that wants one takes it beside the "
                 "worker pool")

# THE FOUNDING CENSUS IS PUBLISHED WHERE IT IS MADE. Read off a periodic sample it is whatever stood on
# the world when the clock ticked, which is the seeding only when the seeding beat the tick.
if spawn_body is not None and "emit_founding" not in spawn_body:
    fails.append("try_spawn publishes no founding census, so what it seeded can only be inferred from a "
                 "sample taken on the step clock")

print("SEED_READINESS={\"counters\":%d,\"checks\":%d}" % (len(counted), 6))
if fails:
    for f in fails:
        print("  " + f, file=sys.stderr)
    print("check_seed_readiness: FAIL (%d)" % len(fails), file=sys.stderr)
    sys.exit(1)
print("check_seed_readiness: OK")
PY
exit $?

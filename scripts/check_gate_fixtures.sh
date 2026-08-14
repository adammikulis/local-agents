#!/usr/bin/env bash
# A GATE THAT BUILDS ITS OWN INPUTS PROVES THE KERNEL CORRECT AND SAYS NOTHING ABOUT THE SYSTEM.
#
# THE RULE. A gate whose GDScript makes its own RenderingDevice and dispatches a pass over buffers it
# allocated is feeding the kernel a table the sim never sends it. Such a gate must ALSO boot the world the
# sim seeds — scripts/sim_run.sh, or agent_harness.sh sim — and read a published gauge back off it.
#
# WHAT COMES OUT CLEAN, AND WHY IT IS THE RULE RATHER THAN A LIST. A pure text check over source constructs
# nothing, so the conjunction never fires on it. check_voxel_grid.sh builds a grid and dispatches nothing at
# it: the grid IS the subject under test, not a stand-in for the world's field.
#
# EXIT 0 clean · 1 a gate has a fixture arm and no seeded-world arm · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3

GATE_FLOOR="${GATE_FLOOR:-40}"
python3 - "$ROOT" "$GATE_FLOOR" <<'PY'
import os, re, sys

root, floor = sys.argv[1], int(sys.argv[2])
sdir = os.path.join(root, "scripts")
if not os.path.isdir(sdir):
    print("check_gate_fixtures: no scripts/ directory.", file=sys.stderr)
    sys.exit(2)

def read(p):
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()

HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")

def is_gdscript(body):
    # GDScript opens with `extends`. Anchoring on the FIRST statement rather than anywhere in the body is
    # what keeps a python heredoc that merely names the marker from reading as a probe.
    for ln in body.splitlines():
        if ln.strip():
            return ln.strip().startswith("extends ")
    return False


def embedded_gdscript(text):
    out, delim, buf = [], None, []
    for ln in text.splitlines():
        if delim is None:
            m = HEREDOC.search(ln)
            if m:
                delim, buf = m.group(1), []
            continue
        if ln.strip() == delim:
            body = "\n".join(buf)
            if is_gdscript(body):
                out.append(body)
            delim = None
            continue
        buf.append(ln)
    return "\n".join(out)

# A probe kept in a sibling .gd file is the same arm with the heredoc unrolled, so it counts too.
SIBLINGS = [g for g in sorted(os.listdir(sdir)) if g.endswith(".gd")]

FIXTURE = re.compile(r"create_local_rendering_device|storage_buffer_create|LAVoxelGrid\.new\(|\bbufs\b")
DISPATCH = re.compile(r"compute_list_begin|\.dispatch\(|_buffers\(")
HARNESS_SIM = re.compile(r"agent_harness\.sh[\"']?\s+sim\b")

def seeded_arm(text):
    boots = "sim_run.sh" in text or HARNESS_SIM.search(text) is not None
    return boots and "--report" in text

gates = sorted(g for g in os.listdir(sdir) if g.startswith("check_") and g.endswith(".sh"))
fixture_gates, seeded_gates, bad = [], [], []
for g in gates:
    text = read(os.path.join(sdir, g))
    gd = embedded_gdscript(text)
    for sib in SIBLINGS:
        if sib in text:
            gd += "\n" + read(os.path.join(sdir, sib))
    if seeded_arm(text):
        seeded_gates.append(g)
    if FIXTURE.search(gd) and DISPATCH.search(gd):
        fixture_gates.append(g)
        if not seeded_arm(text):
            bad.append(g)

if len(gates) < floor:
    print("check_gate_fixtures: examined %d gate scripts, below its floor of %d. Its scope collapsed."
          % (len(gates), floor), file=sys.stderr)
    sys.exit(2)
# The detector's own positive control: with no gate on either side of the rule its silence means nothing.
if not fixture_gates or not seeded_gates:
    print("check_gate_fixtures: matched %d fixture arms and %d seeded-world arms. The markers have rotted "
          "and this gate can no longer fail." % (len(fixture_gates), len(seeded_gates)), file=sys.stderr)
    sys.exit(2)

if bad:
    print("check_gate_fixtures: FAILED", file=sys.stderr)
    for g in bad:
        print("  %s dispatches a pass over buffers it allocated itself, and never boots the seeded world."
              % g, file=sys.stderr)
    print("\nSuch a gate checks the kernel against inputs the sim never sends it. Give it a second arm that\n"
          "runs scripts/sim_run.sh --report <gauge> and asserts on the reading, as check_gravity_solve.sh\n"
          "does with Gauss's law.", file=sys.stderr)
    sys.exit(1)

print("check_gate_fixtures: OK (%d gates, %d with a fixture arm, all of those boot the seeded world)"
      % (len(gates), len(fixture_gates)))
PY

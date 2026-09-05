#!/usr/bin/env bash
# TWO RULES OVER THE GATES THEMSELVES.
# 1  A gate whose GDScript makes its own RenderingDevice and dispatches a pass over buffers it allocated
#    must ALSO boot the world the sim seeds and read a published gauge off it. A pure text check
#    constructs nothing and never fires; check_voxel_grid.sh builds the grid that IS its subject.
# 2  A gate may not compare a run against a recording. Assert the invariant it stood for off a live run.
# EXIT 0 clean · 1 a fixture arm with no seeded-world arm, or a recording · 2 could not run.
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
CAPTURE_ARM = re.compile(r"la_report(_raw)?\b|la_rung_report\b")

def seeded_arm(text):
    # la_report reads the shared arm scripts/lint_capture.sh records, and la_rung_report launches
    # sim_run.sh at a declared rung; both are the world the sim seeds.
    if CAPTURE_ARM.search(text):
        return True
    boots = "sim_run.sh" in text or HARNESS_SIM.search(text) is not None
    return boots and "--report" in text

# A path token carrying a `fixtures` component, and a stored digest. Neither matches this file: the first
# demands a slash, the second a run of 32 hex characters.
RECORDING_PATH = re.compile(r"[\w.${}][\w.${}/-]*")
STORED_DIGEST = re.compile(r"(?<![0-9a-zA-Z])[0-9a-f]{32,}(?![0-9a-zA-Z])")


def recordings(text):
    out = []
    for tok in RECORDING_PATH.findall(text):
        if "/" in tok and "fixtures" in tok.split("/"):
            out.append(tok)
    for d in STORED_DIGEST.findall(text):
        out.append("stored digest " + d[:12])
    return sorted(set(out))


scripts = sorted(s for s in os.listdir(sdir) if s.endswith(".sh"))
recorded = []
for s in scripts:
    for r in recordings(read(os.path.join(sdir, s))):
        recorded.append((s, r))

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

if recorded:
    print("check_gate_fixtures: FAILED", file=sys.stderr)
    for s, r in recorded:
        print("  %s compares against a recording: %s" % (s, r), file=sys.stderr)
    print("\nA recording reads red on every correct change until someone re-records it, and green on a wrong\n"
          "substrate whose output matches its own past. Assert the invariant it stood for off a live run:\n"
          "conservation to a bound, symmetry, a fixed point, monotonicity, an analytic solution,\n"
          "order-independence, or determinism between two runs of one build.", file=sys.stderr)
    sys.exit(1)

if bad:
    print("check_gate_fixtures: FAILED", file=sys.stderr)
    for g in bad:
        print("  %s dispatches a pass over buffers it allocated itself, and never boots the seeded world."
              % g, file=sys.stderr)
    print("\nSuch a gate checks the kernel against inputs the sim never sends it. Give it a second arm that\n"
          "runs scripts/sim_run.sh --report <gauge> and asserts on the reading, as check_gravity_solve.sh\n"
          "does with Gauss's law.", file=sys.stderr)
    sys.exit(1)

print("check_gate_fixtures: OK (%d gates, %d with a fixture arm, all of those boot the seeded world; "
      "%d scripts, none against a recording)" % (len(gates), len(fixture_gates), len(scripts)))
PY

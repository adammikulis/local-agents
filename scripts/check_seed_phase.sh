#!/usr/bin/env bash
# THE WORLD HAS TWO PHASES AND ONLY ONE OF THEM MAY CREATE MATTER OR ENERGY.
#
#   SEEDING  — the world is being built. Creation is legitimate; the planet does not have the matter yet.
#   SEALED   — the world exists. Matter and energy may only be MOVED or TRANSFORMED.
#
# LAMaterialFieldSeal3D.note_creation() is the boundary. This gate fails when a creation-class call site
# writes the field without asking it, so the phase cannot be crossed by forgetting.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/addons/local_agents"
[ -d "$SRC" ] || { echo "check_seed_phase: MISSING $SRC" >&2; exit 2; }

python3 - "$SRC" <<'PY'
import os, re, sys
root = sys.argv[1]

# A creation-class call: it names no source for what it adds. `note_unsourced` is the existing admission
# that a raw degrees injection creates heat; `seed_` names the seeding path explicitly.
CREATES = re.compile(r'\bnote_unsourced\s*\(')
GUARDED = re.compile(r'creation_allowed\s*\(|note_creation\s*\(')
# A whole-mirror upload cannot say what it changed, so it can create matter without any ledger noticing.
WHOLE_MIRROR = re.compile(r'\bset_field\s*\(\s*["\']')
EXEMPT_FILES = {"MaterialFieldSeal3D.gd"}

files, bad, mirror = 0, [], []
for dirpath, _, names in os.walk(root):
    for n in names:
        if not n.endswith(".gd") or n in EXEMPT_FILES:
            continue
        path = os.path.join(dirpath, n)
        files += 1
        lines = open(path, errors="replace").read().splitlines()
        body, start = [], 0

        def flush(body, start):
            if not body:
                return
            text = "\n".join(re.sub(r'#.*$', '', ln) for ln in body)
            if CREATES.search(text) and not GUARDED.search(text):
                bad.append((os.path.relpath(path, root), start + 1))
            for i, ln in enumerate(body):
                code = re.sub(r'#.*$', '', ln)
                if code.lstrip().startswith("func "):
                    continue
                if WHOLE_MIRROR.search(code):
                    mirror.append((os.path.relpath(path, root), start + 1 + i))

        for i, ln in enumerate(lines):
            if re.match(r'^(static\s+)?func\s', ln):
                flush(body, start)
                body, start = [ln], i
            elif body:
                body.append(ln)
        flush(body, start)

if files == 0:
    print("check_seed_phase: scanned 0 files — the tree moved.", file=sys.stderr)
    sys.exit(2)

fail = False
if bad:
    fail = True
    print("check_seed_phase: FAILED — a creation-class write does not ask the seal", file=sys.stderr)
    for path, line in bad:
        print("  %s:%d" % (path, line), file=sys.stderr)
    print("  Call LAMaterialFieldSeal3D.note_creation(what, amount) and honour its answer. Before the seal",
          file=sys.stderr)
    print("  it returns true; after it, creating matter or energy is a violation.", file=sys.stderr)
# THE WHOLE-MIRROR UPLOADS ARE A RATCHET, NOT A PASS. Five remain and they are the ownership migration
# (HANDOFF Stage 2): each needs the cell list a dirty flag does not record, so they cannot be converted in
# one edit. A gate that halts every commit for the length of a multi-session migration is not enforcing, it
# is stopping the world — so the COUNT is fixed here and may only shrink. A sixth fails the build, and each
# one converted must lower this number in the same commit. This is the MAX_DECLARED pattern the parameter
# registry already uses. It is not a carve-out: no upload is exempt, and the backlog cannot grow.
MAX_MIRROR_UPLOADS = 0
if len(mirror) > MAX_MIRROR_UPLOADS:
    fail = True
    print("check_seed_phase: FAILED — %d whole-mirror set_field() uploads, ceiling is %d"
          % (len(mirror), MAX_MIRROR_UPLOADS), file=sys.stderr)
    for path, line in mirror:
        print("  %s:%d" % (path, line), file=sys.stderr)
    print("  A whole-mirror upload cannot say what it changed, so it rewinds every cell the device evolved",
          file=sys.stderr)
    print("  and no ledger sees it. Use the sparse queue, which books what it moved.", file=sys.stderr)
elif len(mirror) < MAX_MIRROR_UPLOADS:
    print("check_seed_phase: %d whole-mirror uploads left (ceiling %d) — LOWER THE CEILING in this commit."
          % (len(mirror), MAX_MIRROR_UPLOADS), file=sys.stderr)
    sys.exit(1)
if fail:
    sys.exit(1)
print("check_seed_phase: OK (%d files; creation is seeding-only, %d whole-mirror uploads left)"
      % (files, len(mirror)))
PY

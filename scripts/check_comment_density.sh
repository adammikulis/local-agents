#!/usr/bin/env bash
# Comment only what is needed to understand THAT line. Enforced, because prose cannot be executed: it rots
# silently and then misleads with authority. Every false layout claim that sent twelve kernels walking
# sideways was a comment.
#
#   MAX_RUN    consecutive comment lines. A block longer than this is an essay, not a line note.
#   MAX_PCT    comment lines as a share of non-blank lines.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX_RUN="${MAX_RUN:-3}"
MAX_PCT="${MAX_PCT:-15}"
SCOPE="${1:-$ROOT/addons/local_agents/sim/material/kernels3d}"

python3 - "$SCOPE" "$MAX_RUN" "$MAX_PCT" <<'PY'
import sys, os, glob
scope, max_run, max_pct = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
files = sorted(glob.glob(os.path.join(scope, '*.glsl')) + glob.glob(os.path.join(scope, '*.glsli')))
if not files:
    print("check_comment_density: no files under %s" % scope, file=sys.stderr); sys.exit(2)
bad = []
for f in files:
    lines = open(f, errors='replace').read().split('\n')
    tot = com = run = worst = 0
    worst_at = 0
    for i, l in enumerate(lines, 1):
        t = l.strip()
        if not t:
            continue
        tot += 1
        if t.startswith('//'):
            com += 1; run += 1
            if run > worst: worst, worst_at = run, i - run + 1
        else:
            run = 0
    pct = 100.0 * com / tot if tot else 0.0
    if worst > max_run or pct > max_pct:
        bad.append((os.path.basename(f), worst, worst_at, pct))
if bad:
    print("check_comment_density: FAILED (max run %d, max %.0f%%)" % (max_run, max_pct), file=sys.stderr)
    for name, worst, at, pct in bad:
        print("  %-40s run=%-3d at line %-5d %.1f%%" % (name, worst, at, pct), file=sys.stderr)
    print("  Comment only what is needed to understand that line. No headers, no rationale, no history,",
          file=sys.stderr)
    print("  no measured numbers — a measurement in a comment is true for one commit.", file=sys.stderr)
    sys.exit(1)
print("Comment-density gate passed (%d files, max run %d, max %.0f%%)." % (len(files), max_run, max_pct))
PY

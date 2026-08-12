#!/usr/bin/env bash
# Comment only what is needed to understand THAT line. Enforced, because prose cannot be executed: it rots
# silently and then misleads with authority.
#
#   MAX_RUN     consecutive comment lines. A block longer than this is an essay, not a line note.
#   MAX_PCT     comment lines as a share of non-blank lines.
#   EXCLUDE_RE  POSIX regex; a path matching it is skipped.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX_RUN="${MAX_RUN:-3}"
MAX_PCT="${MAX_PCT:-15}"
EXCLUDE_RE="${EXCLUDE_RE:-}"
SCOPE="${1:-$ROOT/addons/local_agents/sim/material/kernels3d}"

python3 - "$SCOPE" "$MAX_RUN" "$MAX_PCT" "$EXCLUDE_RE" <<'PY'
import sys, os, re
scope, max_run, max_pct, exclude = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
MARKER = {'.glsl': '//', '.glsli': '//', '.gd': '#'}
skip = re.compile(exclude) if exclude else None
files = []
for dirpath, dirnames, filenames in os.walk(scope):
    dirnames[:] = [d for d in dirnames if d != '.git']
    for name in filenames:
        path = os.path.join(dirpath, name)
        if os.path.splitext(name)[1] not in MARKER:
            continue
        if skip and skip.search(path.replace(os.sep, '/')):
            continue
        files.append(path)
files.sort()
if not files:
    print("check_comment_density: no files under %s" % scope, file=sys.stderr); sys.exit(2)
bad = []
for f in files:
    marker = MARKER[os.path.splitext(f)[1]]
    lines = open(f, errors='replace').read().split('\n')
    tot = com = run = worst = 0
    worst_at = 0
    # A `##` block of at most MAX_RUN lines sitting directly on an @export / signal / const / enum is a
    # Godot INSPECTOR TOOLTIP: user-facing documentation with a real consumer, not prose about internals.
    # It still counts toward MAX_RUN, so it can never become an essay, but it does not count toward the
    # ratio — a schema Resource is one export per line and would otherwise be 50% by construction, and the
    # only way to pass would be deleting documentation to satisfy a number.
    DOCS_TARGET = ('@export', 'signal ', 'const ', 'enum ')
    doc_lines = set()
    if marker == '#':
        block = []
        for i, l in enumerate(lines, 1):
            t = l.strip()
            if t.startswith('##'):
                block.append(i)
                continue
            if block and t.startswith(DOCS_TARGET) and len(block) <= max_run:
                doc_lines.update(block)
            block = []
    for i, l in enumerate(lines, 1):
        t = l.strip()
        if not t:
            continue
        tot += 1
        if t.startswith(marker):
            run += 1
            if i not in doc_lines:
                com += 1
            if run > worst: worst, worst_at = run, i - run + 1
        else:
            run = 0
    pct = 100.0 * com / tot if tot else 0.0
    if worst > max_run or pct > max_pct:
        bad.append((os.path.relpath(f, scope), worst, worst_at, pct))
if bad:
    print("check_comment_density: FAILED (max run %d, max %.0f%%)" % (max_run, max_pct), file=sys.stderr)
    for name, worst, at, pct in bad:
        print("  %-56s run=%-3d at line %-5d %.1f%%" % (name, worst, at, pct), file=sys.stderr)
    print("  Comment only what is needed to understand that line. No headers, no rationale, no history,",
          file=sys.stderr)
    print("  no measured numbers — a measurement in a comment is true for one commit.", file=sys.stderr)
    sys.exit(1)
print("Comment-density gate passed (%d files, max run %d, max %.0f%%)." % (len(files), max_run, max_pct))
PY

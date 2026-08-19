#!/usr/bin/env bash
# A COMMENT LABELS. IT DOES NOT ARGUE. A run of more than MAX consecutive comment lines is a paragraph,
# and a paragraph is a case being made to a reader. Counts the LINES past MAX, so prose added to an
# existing block still raises it.
#
# EXIT 0 clean · 1 the ratchet rose · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
. "$ROOT/scripts/lib_ceiling.sh" 2>/dev/null || true
require_tool git
require_tool python3

MAX="${LA_COMMENT_BLOCK_MAX:-6}"
CEIL_FILE="$ROOT/docs/COMMENT_BLOCK_CEILING"
[ -f "$CEIL_FILE" ] || { echo "check_comment_block: no docs/COMMENT_BLOCK_CEILING." >&2; exit 2; }
CEIL="$(grep -E '^[0-9]+$' "$CEIL_FILE" | head -1)"
case "$CEIL" in "" | *[!0-9]*) echo "check_comment_block: the ceiling carries no number." >&2; exit 2 ;; esac

out="$(cd "$ROOT" && MAX="$MAX" python3 - <<'PY'
import io, os, subprocess, sys, tokenize
files = subprocess.run(['git','ls-files','*.gd','*.sh','*.glsl','*.glsli','*.py'],
                       capture_output=True, text=True).stdout.split()
files = [f for f in files if 'thirdparty' not in f and 'generated' not in f and 'zylann' not in f
         and os.path.exists(f)]
if not files:
    print("NOFILES"); sys.exit(0)
lim = int(os.environ['MAX'])

def comment_lines(path, text):
    # A `#` inside a string literal is not a comment. Python can be tokenized exactly; for the rest a
    # leading marker is the whole grammar that matters.
    if path.endswith('.py'):
        try:
            return {t.start[0] for t in tokenize.generate_tokens(io.StringIO(text).readline)
                    if t.type == tokenize.COMMENT}
        except Exception:
            pass
    out = set()
    for i, l in enumerate(text.split('\n'), 1):
        s = l.strip()
        if s.startswith('#') or s.startswith('//'):
            out.add(i)
    return out

over = []
for f in files:
    text = open(f, errors='ignore').read()
    marks = comment_lines(f, text)
    run = 0; start = 0
    for i in range(1, text.count('\n') + 2):
        if i in marks:
            if run == 0: start = i
            run += 1
        else:
            if run > lim: over.append((run, f, start))
            run = 0
    if run > lim: over.append((run, f, start))
over.sort(reverse=True)
# EXCESS LINES, not violating blocks: counting blocks lets an essay be appended to an existing essay
# for free, which is a gate you can walk past.
print("COUNT %d" % sum(n - lim for n, _, _ in over))
for n, f, s in over[:15]:
    print("  %3d lines  %s:%d" % (n, f, s))
PY
)"
case "$out" in NOFILES*) echo "check_comment_block: git listed no source files." >&2; exit 2 ;; esac
n="$(printf '%s' "$out" | head -1 | awk '{print $2}')"
case "$n" in "" | *[!0-9]*) echo "check_comment_block: the scan produced no count." >&2; exit 2 ;; esac

echo "COMMENT_BLOCK={\"count\":$n,\"max\":$MAX,\"cap\":$CEIL}"
if [ "$n" -gt "$CEIL" ]; then
	echo "check_comment_block: $n comment line(s) past the $MAX-line block limit, ceiling $CEIL." >&2
	printf '%s\n' "$out" | tail -n +2 >&2
	echo "" >&2
	echo "Say what the code does and stop. If the claim matters, make it a GATE." >&2
	exit 1
fi
if [ "$n" -lt "$CEIL" ]; then
	ceiling_slack "COMMENT_BLOCK_CEILING" "$n" "$CEIL" 2>/dev/null \
		|| echo "NOTE  $((CEIL - n)) below the ceiling — the integrator banks it."
fi
echo "check_comment_block: OK ($n against a ceiling of $CEIL)"

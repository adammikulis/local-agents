#!/usr/bin/env bash
# WRITTEN AND NEVER READ: a class-scope `var` the tree stores to, adds to or appends to, and never reads.
# Its own file reads it bare, any file reads it as `.name`, or anything names it in quotes; a store, an
# indexed store, a compound self-update (`x += d`) and a container's own mutator are writes, never reads.
# EXIT 0 at or under the ceiling · 1 over it · 2 could not run.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP_FILE="$ROOT/docs/WRITE_ONLY_STATE_CEILING"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -d "$ROOT/addons/local_agents" ] || { echo "ERROR: source root missing." >&2; exit 2; }
[ -f "$CAP_FILE" ] || { echo "check_write_only_state: MISSING $CAP_FILE" >&2; exit 2; }
CEILING="$(grep -E '^[0-9]+$' "$CAP_FILE" | head -1)"
[ -n "$CEILING" ] || { echo "check_write_only_state: $CAP_FILE holds no bare integer." >&2; exit 2; }

OUT="$(python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
SRC = os.path.join(root, "addons", "local_agents")
NAME = r"[A-Za-z_][A-Za-z0-9_]*"
DECL = re.compile(r"^var\s+(%s)\s*(?::[^=]*)?(=.*)?$" % NAME)
OP = r"\s*(?:[-+*/%|&^]|<<|>>)?=(?!=)"
MUT = "append|append_array|push_back|push_front|resize|fill|clear|erase|insert|remove_at|sort|sort_custom|assign|merge"
WRITE = re.compile(r"(?<![A-Za-z0-9_])(\.?)(%s)(?:%s|\s*\[[^\]]*\]%s|\s*\.(?:%s)\()" % (NAME, OP, OP, MUT))
BARE = re.compile(r"(?<![A-Za-z0-9_.])(%s)(?![A-Za-z0-9_])" % NAME)
DOTTED = re.compile(r"\.(%s)(?![A-Za-z0-9_])" % NAME)
QUOTED = re.compile(r"[\"'&](%s)[\"']" % NAME)


def code_of(line):
    out, quote = [], None
    for ch in line:
        if quote:
            out.append(ch)
            quote = None if ch == quote else quote
        elif ch in "\"'":
            quote = ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out)


corpus, sources = [], {}
for base in (SRC, os.path.join(root, "scripts")):
    for dp, dns, fns in os.walk(base):
        dns[:] = [d for d in dns if d not in (".godot", "thirdparty")]
        for fn in sorted(fns):
            if fn.endswith((".gd", ".tscn", ".tres", ".cpp", ".hpp", ".mm", ".sh", ".py", ".glsl", ".glsli")):
                path = os.path.join(dp, fn)
                text = open(path, errors="replace").read()
                corpus.append((path, text))
                if fn.endswith(".gd") and path.startswith(SRC):
                    sources[path] = text
if not sources:
    print("check_write_only_state: no .gd under %s." % SRC, file=sys.stderr)
    sys.exit(2)

dotted, quoted = set(), set()
for path, text in corpus:
    for line in text.splitlines():
        code = code_of(line) if path.endswith(".gd") else line
        stores = {m.start(2) for m in WRITE.finditer(code) if m.group(1) == "."}
        dotted.update(m.group(1) for m in DOTTED.finditer(code) if m.start(1) not in stores)
        quoted.update(m.group(1) for m in QUOTED.finditer(line))

hits = []
for path, text in sorted(sources.items()):
    lines = text.splitlines()
    bare = set()
    for line in lines:
        code = code_of(line)
        decl = None if line[:1].isspace() else DECL.match(code.strip())
        if decl:
            code = decl.group(2) or ""
        stores = {m.start(2) for m in WRITE.finditer(code) if m.group(1) == ""}
        bare.update(m.group(1) for m in BARE.finditer(code) if m.start(1) not in stores)
    for n, line in enumerate(lines, 1):
        decl = None if line[:1].isspace() else DECL.match(code_of(line).strip())
        if decl and decl.group(1) not in bare | dotted | quoted:
            hits.append("  %s:%d  %s" % (os.path.relpath(path, root), n, line.strip()[:96]))
print('WRITE_ONLY_STATE={"count":%d}' % len(hits))
print("\n".join(hits))
PY
)" || exit 2
printf '%s\n' "$OUT"
n="$(printf '%s\n' "$OUT" | sed -n 's/^WRITE_ONLY_STATE={"count":\([0-9]*\)}$/\1/p')"
case "$n" in "" | *[!0-9]*) echo "check_write_only_state: the scan produced no count." >&2; exit 2 ;; esac
if [ "$n" -gt "$CEILING" ]; then
	echo "check_write_only_state: $n fields are written and never read, ceiling $CEILING. Delete each one" >&2
	echo "  and the stores into it: state nothing reads is a claim about the world that nothing checks." >&2
	exit 1
fi
. "$ROOT/scripts/lib_ceiling.sh"
ceiling_slack "WRITE_ONLY_STATE_CEILING" "$n" "$CEILING" 0 "$ROOT" || exit 1
echo "check_write_only_state: OK ($n against a ceiling of $CEILING)"

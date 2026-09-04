#!/usr/bin/env bash
# THE MAP IS PROSE, AND PROSE IS THE ONE THING HERE NOTHING CHECKED.
#
# CLAUDE.md says a comment is a claim, that claims here are reliably false, and that not one was ever
# caught by reading -- every one was caught by a gate firing. Then the project's own control surface was
# hundreds of lines of unchecked prose. Three of its claims were false in a single session: the open
# regression named the wrong cause, "lint is red on one gate" was green, and a seam listed as open was
# already fixed. All three were stale because nothing re-ran them.
#
# A claim that matters is written as a directive next to the prose it backs, and this gate evaluates it:
#
#   <!-- claim: nofile addons/local_agents/sim/sphere/SphereGrid.gd -->
#   <!-- claim: file  addons/local_agents/sim/voxel/VoxelGrid.gd -->
#   <!-- claim: absent  PLANET_SCALE  addons/local_agents/sim -->
#   <!-- claim: present link_partner  addons/local_agents/sim -->
#   <!-- claim: files 10 addons/local_agents/sim/material/kernels3d .glsl -->
#
# `absent` is the one that earns its keep: it is how "we deleted X" stops being a sentence and starts
# being a fact. Write the claim in the same commit that makes it true, and DELETE the claim when the
# prose goes -- a claim outliving its paragraph is the defect this gate exists to stop.
#
# EXIT 0 clean · 1 a false claim · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true

command -v rg >/dev/null 2>&1 || { echo "check_doc_claims: rg absent." >&2; exit 2; }

DOCS=()
for d in HANDOFF.md CLAUDE.md GODOT_BEST_PRACTICES.md docs/PHYSICS_TODO.md docs/PERFORMANCE_TODO.md; do
	[ -f "$ROOT/$d" ] && DOCS+=("$ROOT/$d")
done
[ "${#DOCS[@]}" -gt 0 ] || { echo "check_doc_claims: no doc to read." >&2; exit 2; }

fail=0
checked=0

verdict() {  # verdict <ok> <where> <text>
	if [ "$1" -ne 0 ]; then
		echo "FALSE CLAIM  $2" >&2
		echo "             $3" >&2
		fail=1
	fi
}

while IFS= read -r line; do
	src="${line%%:*}"; rest="${line#*:}"
	lno="${rest%%:*}"; body="${rest#*:}"
	# Strip everything outside the directive.
	claim="$(printf '%s' "$body" | sed -E 's/.*<!--[[:space:]]*claim:[[:space:]]*//; s/[[:space:]]*-->.*//')"
	set -- $claim
	kind="${1:-}"; shift || true
	where="$(basename "$src"):$lno"
	checked=$((checked + 1))
	case "$kind" in
		file)
			[ -e "$ROOT/$1" ]; verdict $? "$where" "$1 does not exist, but the map says it does." ;;
		nofile)
			[ ! -e "$ROOT/$1" ]; verdict $? "$where" "$1 still exists, but the map says it is deleted." ;;
		absent)
			pat="$1"; shift
			if rg -n --no-heading -e "$pat" "${@/#/$ROOT/}" >/dev/null 2>&1; then
				verdict 1 "$where" "'$pat' still appears under $*, but the map says it is gone."
			fi ;;
		present)
			pat="$1"; shift
			if ! rg -n --no-heading -e "$pat" "${@/#/$ROOT/}" >/dev/null 2>&1; then
				verdict 1 "$where" "'$pat' appears nowhere under $*, but the map says it is there."
			fi ;;
		files)
			n="$1"; dir="$2"; ext="$3"
			have="$(find "$ROOT/$dir" -maxdepth 1 -name "*$ext" 2>/dev/null | wc -l | tr -d ' ')"
			[ "$have" = "$n" ]; verdict $? "$where" "$dir holds $have '$ext' files, and the map says $n." ;;
		*)
			verdict 1 "$where" "unknown claim kind '$kind'. Known: file nofile absent present files." ;;
	esac
done < <(rg -n --no-heading -e '<!--[[:space:]]*claim:' "${DOCS[@]}" 2>/dev/null)

# A gate that examines nothing reports success, which is the failure mode this repo has shipped most.
if [ "$checked" -eq 0 ]; then
	echo "check_doc_claims: found NO claim directives. Either the docs lost them or the pattern rotted." >&2
	exit 2
fi

# EVERY FILE PATH A GATED DOC CITES MUST EXIST. No directive opts a path in: a path in backticks IS the
# claim, and the class it closes is the one nobody writes a directive for -- prose naming a file that was
# deleted out from under it. To say a path is absent ON PURPOSE, deleted and staying deleted or named as
# work not yet built, write a nofile claim beside it. That claim is checked above and goes red the day the
# file appears, so the escape cannot rot into a permanent exemption.
# ONE PASS over the gated docs, resolving each backticked span against the working tree and the index.
INDEX_FILE="$(mktemp "${TMPDIR:-/tmp}/la_doc_index.XXXXXX")" || exit 2
trap 'rm -f "$INDEX_FILE"' EXIT
git -C "$ROOT" ls-files > "$INDEX_FILE" 2>/dev/null
[ -s "$INDEX_FILE" ] || { echo "check_doc_claims: could not list the tree." >&2; exit 2; }

PATHS_OUT="$(ROOT="$ROOT" INDEX_FILE="$INDEX_FILE" python3 - "${DOCS[@]}" <<'PY'
import os, re, sys

root, index_file = os.environ["ROOT"], os.environ["INDEX_FILE"]
PATH_EXT = "gd|glsl|glsli|gdshader|sh|py|md|tscn|cfg|gdextension|cpp|hpp|yml|json|patch|txt"
PATH_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_.-]+)*\.(?:%s)(?::[0-9]+(?:,[0-9]+)*)?"
                     % PATH_EXT)
TICK = chr(96)
SPAN = re.compile(TICK + "[^" + TICK + "]+" + TICK)
NOFILE = re.compile(r"<!--\s*claim:\s*nofile\s+(\S+)")

index = [ln.strip() for ln in open(index_file, errors="replace") if ln.strip()]
by_tail = {}
for entry in index:
    by_tail.setdefault(entry.rsplit("/", 1)[-1], []).append(entry)

docs = {}
exempt = set()
for path in sys.argv[1:]:
    docs[path] = open(path, errors="replace").read().splitlines()
    for line in docs[path]:
        for m in NOFILE.finditer(line):
            exempt.add(m.group(1))

paths = 0
bad = []
for path, lines in docs.items():
    for lno, line in enumerate(lines, 1):
        if TICK not in line or ("<!--" in line and "claim:" in line):
            continue
        for span in SPAN.findall(line):
            for word in span.strip(TICK).split():
                if word.startswith("res://"):
                    word = word[len("res://"):]
                if word[-1:] in ",;)":
                    word = word[:-1]
                if word.startswith("("):
                    word = word[1:]
                if not PATH_RE.fullmatch(word):
                    continue
                p = word.split(":", 1)[0]
                if word in exempt or p in exempt:
                    continue
                paths += 1
                if os.path.exists(os.path.join(root, p)):
                    continue
                if any(e == p or e.endswith("/" + p) for e in by_tail.get(p.rsplit("/", 1)[-1], ())):
                    continue
                bad.append((os.path.basename(path), lno, word))

for base, lno, word in bad:
    print("FALSE CLAIM  %s:%d" % (base, lno), file=sys.stderr)
    print("             %s%s%s names a file that is not in the tree. Fix the path, or declare it nofile."
          % (TICK, word, TICK), file=sys.stderr)
print(paths)
raise SystemExit(1 if bad else 0)
PY
)"
rc=$?
[ "$rc" -le 1 ] || { echo "check_doc_claims: the path pass could not run." >&2; exit 2; }
[ "$rc" -eq 0 ] || fail=1
paths="$(printf '%s' "$PATHS_OUT" | tail -1)"
case "${paths:-}" in "" | *[!0-9]*) paths=0 ;; esac

if [ "$paths" -eq 0 ]; then
	echo "check_doc_claims: found NO cited file path. The docs lost them or the pattern rotted." >&2
	exit 2
fi

if [ "$fail" -ne 0 ]; then
	echo "" >&2
	echo "The map is wrong, not the code. Fix the sentence, or fix what it describes." >&2
	exit 1
fi
echo "check_doc_claims: OK ($checked claim(s) hold, $paths cited path(s) exist)"

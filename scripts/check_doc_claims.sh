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
for d in HANDOFF.md CLAUDE.md docs/PHYSICS_TODO.md docs/OPEN_BRANCHES.md; do
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
# work not yet built, write `<!-- claim: nofile <repo-relative path> -->` beside it. That claim is checked
# above and goes red the day the file appears, so the escape cannot rot into a permanent exemption.
PATH_EXT='gd|glsl|glsli|gdshader|sh|py|md|tscn|cfg|gdextension|cpp|hpp|yml|json|patch|txt'
PATH_RE="^[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_.-]+)*\.($PATH_EXT)(:[0-9]+(,[0-9]+)*)?$"

# rg skips hidden directories by default, and .github/workflows is cited by name.
INDEX="$(rg --files --hidden --glob '!.git/**' "$ROOT" 2>/dev/null | sed "s|^$ROOT/||")"
[ -n "$INDEX" ] || { echo "check_doc_claims: could not list the tree." >&2; exit 2; }
EXEMPT="$(rg -o --no-filename -e '<!--[[:space:]]*claim:[[:space:]]*nofile[[:space:]]+[^[:space:]]+' \
	"${DOCS[@]}" 2>/dev/null | awk '{print $NF}')"

paths=0
while IFS= read -r line; do
	src="${line%%:*}"; rest="${line#*:}"
	lno="${rest%%:*}"; body="${rest#*:}"
	case "$body" in *"<!--"*"claim:"*) continue ;; esac
	for span in $(printf '%s' "$body" | rg -o '`[^`]+`' | tr -d '`' | tr ' ' '\n'); do
		word="${span#res://}"
		word="${word%[,;)]}"
		word="${word#(}"
		printf '%s' "$word" | rg -q "$PATH_RE" || continue
		printf '%s\n' "$EXEMPT" | grep -qxF "$word" && continue
		p="${word%%:*}"
		printf '%s\n' "$EXEMPT" | grep -qxF "$p" && continue
		paths=$((paths + 1))
		[ -e "$ROOT/$p" ] && continue
		printf '%s\n' "$INDEX" \
			| awk -v s="/$p" '(i = index($0, s)) > 0 && i == length($0) - length(s) + 1 { hit = 1; exit }
				END { exit !hit }' \
			&& continue
		verdict 1 "$(basename "$src"):$lno" \
			"\`$word\` names a file that is not in the tree. Fix the path, or declare it nofile."
	done
done < <(rg -n --no-heading -e '`[^`]+`' "${DOCS[@]}" 2>/dev/null)

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

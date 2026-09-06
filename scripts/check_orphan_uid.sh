#!/usr/bin/env bash
# A .uid FILE IS GODOT'S NAME FOR ONE RESOURCE. Without that resource it is a name for nothing: the next
# editor scan hands the id back for a script nobody has, and the tree carries a record of a file somebody
# deleted. They are generated, so this reads the working tree rather than the index.
# EXIT 0 none · 1 orphans · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/addons/local_agents"
[ -d "$DIR" ] || { echo "check_orphan_uid: no $DIR." >&2; exit 2; }

all="$(find "$DIR" -name '*.uid' -print)"
[ -n "$all" ] || { echo "check_orphan_uid: no .uid files at all — the tree has not been imported." >&2; exit 2; }

orphans=""
while IFS= read -r u; do
	[ -n "$u" ] || continue
	[ -f "${u%.uid}" ] || orphans="$orphans${u#"$ROOT"/}"$'\n'
done <<< "$all"

n="$(printf '%s' "$orphans" | grep -c . || true)"
echo "ORPHAN_UID={\"count\":$n}"
if [ "$n" -gt 0 ]; then
	printf '%s' "$orphans" | sed 's/^/  /' >&2
	echo "check_orphan_uid: $n .uid file(s) name a resource that is not in the tree. Delete them." >&2
	exit 1
fi
echo "check_orphan_uid: OK"

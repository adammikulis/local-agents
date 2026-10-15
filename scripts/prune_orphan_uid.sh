#!/usr/bin/env bash
# Deletes every gitignored .uid under addons/local_agents whose resource is gone. A tracked one is left for
# check_orphan_uid.sh to report.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/addons/local_agents"
[ -d "$DIR" ] || exit 0
while IFS= read -r u; do
	[ -n "$u" ] && [ ! -f "${u%.uid}" ] || continue
	git -C "$ROOT" check-ignore -q "$u" && rm -f "$u"
done <<< "$(find "$DIR" -name '*.uid' -print)"

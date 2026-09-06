#!/usr/bin/env bash
# A QUALITY PRESET IS NOT A DISCRETISATION AND NOT A POPULATION. LAGameSettings holds what the player's
# machine can draw; how many cells the field has, how much matter is in the world and how many creatures
# exist are the world's, and they came from the graphics and simulation sliders. So: no key of
# LAGameSettings, and no name of that class, may be read anywhere under sim/ or creatures/.
# EXIT 0 none reach it · 1 one does · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$ROOT/addons/local_agents/game/menu/GameSettings.gd"
[ -f "$SETTINGS" ] || { echo "check_settings_reach: no $SETTINGS." >&2; exit 2; }
command -v rg >/dev/null 2>&1 || { echo "check_settings_reach: rg absent." >&2; exit 2; }

keys="$(rg -N -o '^@export var ([a-z_0-9]+)' -r '$1' "$SETTINGS")"
[ -n "$keys" ] || { echo "check_settings_reach: LAGameSettings declares no @export keys to look for." >&2; exit 2; }

DIRS=("$ROOT/addons/local_agents/sim" "$ROOT/addons/local_agents/creatures")
for d in "${DIRS[@]}"; do
	[ -d "$d" ] || { echo "check_settings_reach: no $d." >&2; exit 2; }
done

pat="LAGameSettings"
while IFS= read -r k; do
	[ -n "$k" ] && pat="$pat|\\b$k\\b"
done <<< "$keys"

hits="$(rg -n -e "$pat" --glob '*.gd' "${DIRS[@]}" || true)"
if [ -n "$hits" ]; then
	printf '%s\n' "$hits" | sed 's/^/  /' >&2
	echo "check_settings_reach: a player-quality setting decides something in the world." >&2
	echo "  The grid comes from docs/CELL_BUDGET and the declared cell edge; how much of anything exists" >&2
	echo "  comes from the seed. Delete the read." >&2
	exit 1
fi
echo "check_settings_reach: OK"

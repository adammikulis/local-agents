#!/usr/bin/env bash
# THE HUD PALETTE IS DECLARED ONCE, in addons/local_agents/game/ui/HudTheme.tres. A colour whose RGB the
# theme carries, written as a literal in any other .gd/.tscn/.tres under game/ui/, fails. Pure black
# (shadows, clear fills) is not palette.
# EXIT 0 none · 1 found · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" || { echo "check_hud_palette: lib_require.sh missing." >&2; exit 2; }
require_tool python3
UI="$ROOT/addons/local_agents/game/ui"
THEME="$UI/HudTheme.tres"
[ -f "$THEME" ] || { echo "check_hud_palette: no $THEME." >&2; exit 2; }

out="$(python3 - "$UI" "$THEME" <<'PY'
import os, re, sys
ui, theme = sys.argv[1], sys.argv[2]
lit = re.compile(r'Color\(\s*([-0-9.eE]+)\s*,\s*([-0-9.eE]+)\s*,\s*([-0-9.eE]+)\s*[,)]')
def rgbs(text):
    return [tuple(round(float(m.group(i)), 3) for i in (1, 2, 3)) for m in lit.finditer(text)]
palette = {c for c in rgbs(open(theme, encoding='utf-8').read()) if c != (0.0, 0.0, 0.0)}
scanned, hits = 0, []
for d, _, files in os.walk(ui):
    for f in sorted(files):
        p = os.path.join(d, f)
        if p == theme or not f.endswith(('.gd', '.tscn', '.tres')):
            continue
        scanned += 1
        for n, line in enumerate(open(p, encoding='utf-8', errors='replace'), 1):
            if any(c in palette for c in rgbs(line)):
                hits.append('  %s:%d: %s' % (os.path.relpath(p, ui), n, line.strip()))
print('HUD_PALETTE={"colours":%d,"files":%d,"count":%d}' % (len(palette), scanned, len(hits)))
print('\n'.join(hits))
PY
)" || { echo "check_hud_palette: the scan did not run." >&2; exit 2; }

summary="$(printf '%s\n' "$out" | head -n 1)"
echo "$summary"
colours="$(printf '%s' "$summary" | sed -n 's/.*"colours":\([0-9]*\).*/\1/p')"
files="$(printf '%s' "$summary" | sed -n 's/.*"files":\([0-9]*\).*/\1/p')"
count="$(printf '%s' "$summary" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
require_scanned "${colours:-0}" 5 "palette colours in HudTheme.tres"
require_scanned "${files:-0}" 10 "files under game/ui"
if [ "${count:-1}" -ne 0 ]; then
	echo "check_hud_palette: a HudTheme.tres colour written outside the theme; use a type variation:" >&2
	printf '%s\n' "$out" | tail -n +2 >&2
	exit 1
fi
echo "check_hud_palette: OK (no HudTheme.tres colour declared elsewhere under game/ui)"

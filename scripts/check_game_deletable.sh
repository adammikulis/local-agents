#!/usr/bin/env bash
# THE GAME IS DELETABLE. No script under addons/local_agents/ outside game/ names a class declared under
# game/: a class name resolves at parse time, so deleting game/ would fail the library script naming it.
# tests/ carries a .gdignore and is not the library. Comments are not code.
# EXIT 0 none does · 1 one does · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON="$ROOT/addons/local_agents"
[ -d "$ADDON/game" ] || { echo "check_game_deletable: no $ADDON/game." >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check_game_deletable: python3 absent." >&2; exit 2; }

python3 - "$ADDON" <<'PY'
import os, re, sys

addon = sys.argv[1]
game = os.path.join(addon, "game")
names = set()
for dp, _, fns in os.walk(game):
    for fn in fns:
        if fn.endswith(".gd"):
            m = re.search(r"^class_name\s+(\w+)", open(os.path.join(dp, fn), errors="replace").read(), re.M)
            if m:
                names.add(m.group(1))
if not names:
    print("check_game_deletable: game/ declares no class_name to look for.", file=sys.stderr)
    sys.exit(2)

word = re.compile(r"\b(" + "|".join(sorted(names)) + r")\b")
hits = []
for dp, dns, fns in os.walk(addon):
    dns[:] = [d for d in dns if os.path.join(dp, d) != game and d not in ("tests", "thirdparty", ".godot")]
    for fn in sorted(fns):
        if not fn.endswith(".gd"):
            continue
        path = os.path.join(dp, fn)
        for i, line in enumerate(open(path, errors="replace").read().splitlines(), 1):
            m = word.search(line.split("#", 1)[0])
            if m:
                hits.append("%s:%d names %s" % (os.path.relpath(path, addon), i, m.group(1)))

print('GAME_NAMED_OUTSIDE={"count":%d,"game_classes":%d}' % (len(hits), len(names)))
if hits:
    for h in hits:
        print("  " + h, file=sys.stderr)
    print("check_game_deletable: a library script names a game/ class, so deleting game/ breaks it. Move what it",
          file=sys.stderr)
    print("  needs out of game/, or reach it by node path.", file=sys.stderr)
    sys.exit(1)
print("check_game_deletable: OK (no script outside game/ names one of its %d classes)" % len(names))
PY

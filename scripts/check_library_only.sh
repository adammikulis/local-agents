#!/usr/bin/env bash
# Prove the documented library boundary actually holds.
#
# docs/USAGE.md tells a consumer they can copy addons/local_agents/, delete the game, and keep a
# working local-agent toolkit. Nothing enforced that, and it had already rotted: two of the three
# "library showcase" demos referenced the LAAppExit autoload that the same doc says consumers must
# NOT register, so they were parse errors in a clean install.
#
# This builds that clean install for real and fails on any parse error. It omits the game tree and the
# native binary, and it DOES install zylann.voxel (see the note at the symlink below for why). Whether
# the addon can generate text is a different question, checked by scripts/check_dropin_scene.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "check_library_only: staging a library-only project in $TMP"
mkdir -p "$TMP/addons/local_agents"

# Copy the addon WITHOUT the build tree. bin/ is excluded on purpose (and is a symlink in a
# worktree, which rsync -L would chase into gigabytes) — a consumer who has not built the extension
# yet must still get a clean scan.
rsync -a \
  --exclude 'gdextensions/localagents/thirdparty/' \
  --exclude 'gdextensions/localagents/build/' \
  --exclude 'gdextensions/localagents/build_native/' \
  --exclude 'gdextensions/localagents/bin/' \
  --exclude '.cache/' \
  "$ROOT/addons/local_agents/" "$TMP/addons/local_agents/"

# Delete everything the docs call game-only. What is left must stand on its own.
# audio/ is NOT deleted, and used to be. The docs called it game-only chrome, but the force-parse
# sweep showed five library files calling LocalAgentAudioDirector.emit(): creatures/creature/
# CreatureThink.gd:158 for a chomp, and sim/actors/{Meteor,LightningStrike,Flood,Volcano}.gd for
# impact and weather sounds. A creature making a noise is a stimulus broadcast like scent, which is
# core behaviour rather than game shell, so audio/ belongs to the library and the classification was
# wrong. Deleting it here only hid that.
rm -rf "$TMP/addons/local_agents/game" \
       "$TMP/addons/local_agents/assets" \
       "$TMP/addons/local_agents/voices"

# zylann.voxel IS installed, by symlink so the ~100 MB of committed binaries are not copied per run.
#
# It used to be omitted, on the theory that the library should parse without it. That made the gate
# unreadable rather than strict: sim/ genuinely needs godot_voxel for SPHERE mode, so leaving it out
# produced 26 unresolved ZN_*/Voxel* types plus a cascade of "Failed to load script" lines that carry
# no type name, and the one real break, StreamerHost preloading a game/ file, was a single line lost
# inside them. Filtering the expected noise by type name cannot work, because the cascade lines have
# no type name to filter on.
#
# So this gate asks the question the docs actually promise: with the game tree deleted and the
# optional extension present, does the library parse. Whether FLAT mode alone runs without
# godot_voxel is a narrower separate question that does not belong in the same log.
if [[ -d "$ROOT/addons/zylann.voxel" ]]; then
  ln -s "$ROOT/addons/zylann.voxel" "$TMP/addons/zylann.voxel"
fi

# A consumer's project.godot: the plugin, and the ONE core autoload. Deliberately no GameMode and no
# AppExit — registering those is exactly the mistake this gate is here to catch.
cat > "$TMP/project.godot" <<'PROJECT'
config_version=5

[application]
config/name="LibraryOnlyProbe"
config/features=PackedStringArray("4.7")

[autoload]
AgentManager="*res://addons/local_agents/agent_manager/AgentManager.gd"

[editor_plugins]
enabled=PackedStringArray("res://addons/local_agents/plugin.cfg")
PROJECT

LOG="$TMP/scan.log"
echo "check_library_only: scanning (no game tree, zylann.voxel symlinked, no native binary)"
"$GODOT" --headless --editor --quit-after 400 --path "$TMP" > "$LOG" 2>&1 || true

# Unresolved class_name references (the LAAppExit failure mode) surface as parse errors, so this
# single grep covers both a missing script and a missing global identifier.
if grep -qiE 'Parse Error|SCRIPT ERROR|Failed to load script|Could not resolve class' "$LOG"; then
  echo "check_library_only: FAIL — the library does not parse without the game tree:"
  grep -inE 'Parse Error|SCRIPT ERROR|Failed to load script|Could not resolve class' "$LOG" \
    | sed 's/^/    /' | head -40
  echo
  echo "Fix by removing the game dependency, not by re-adding the file to the library set."
  exit 1
fi

# The scan above is necessary and NOT sufficient. An editor scan only loads what something references,
# so a script nothing instantiates can preload a file the staging just deleted and never be looked at.
# That is not hypothetical: this gate printed OK while sim/streamer/StreamerHost.gd preloaded
# game/ui/SceneEnergyGraph.gd, which the rm -rf above removes. Three separate reviews found the hole
# before the gate did. So force every script in the staged tree to load.
cp "$ROOT/scripts/parse_all_scripts.gd" "$TMP/parse_all_scripts.gd"
PARSE_LOG="$TMP/parse.log"
parse_rc=0
"$GODOT" --headless --path "$TMP" -s parse_all_scripts.gd -- \
  --root=res://addons/local_agents > "$PARSE_LOG" 2>&1 || parse_rc=$?

parse_line="$(grep -a '^PARSE_ALL=' "$PARSE_LOG" | tail -n 1 || true)"
if [[ -z "$parse_line" ]]; then
  echo "check_library_only: FAIL — the parse sweep produced no verdict (exit $parse_rc). Last 20 lines:"
  tail -n 20 "$PARSE_LOG" | sed 's/^/    /'
  exit 1
fi
echo "  $parse_line"

# checked:0 reads exactly like a clean sweep — same failed:0, same empty failures list, same absence of
# error lines for the grep below to find. It means the rsync above copied nothing, or the addon moved.
# The staging is elaborate enough that "it silently produced an empty tree" is a real way for this gate
# to go quiet, so the count is checked rather than assumed.
checked="$(printf '%s' "$parse_line" | grep -oE '"checked":[0-9]+' | grep -oE '[0-9]+$' || true)"
if [[ -z "${checked:-}" || "$checked" -le 0 ]]; then
  echo "check_library_only: FAIL — the sweep examined ${checked:-no} scripts, so nothing was verified."
  echo "                    The staged tree at $TMP is empty or the addon path moved."
  exit 2
fi

# The sweep's exit code alone is not enough. load() on a script whose preload target is missing prints
# a Parse Error and still returns a non-null Script, so the null check inside the sweep never fires
# for the exact failure this gate exists to catch. Loading is what makes the engine parse every file;
# this grep is what notices. Both are required.
#
# Nothing is filtered out of this grep. zylann.voxel is installed above, so every type resolves and any
# line left here is a real break.
REAL_ERRS="$(grep -aiE 'Parse Error|SCRIPT ERROR|Failed to load script|Could not resolve class' "$PARSE_LOG" || true)"

if [[ "$parse_rc" -ne 0 || -n "$REAL_ERRS" ]]; then
  echo "check_library_only: FAIL — these do not parse from the library alone:"
  printf '%s\n' "$REAL_ERRS" | sed 's/^/    /' | head -30
  echo
  echo "Fix by removing the cross-boundary dependency, not by re-adding the file to the library set."
  exit 1
fi

echo "check_library_only: OK (library-only tree parses clean, every script force-loaded)"

#!/usr/bin/env bash
# Gate: a user can build the quickstart out of nodes and inspector values, writing no GDScript.
#
# That claim is the whole point of the addon-UX work, and it is not provable by reading the addon's
# own examples, because those ship inside the repo where every path already resolves and the plugin
# is already enabled. So this builds a consumer's project from scratch, hand-authors the scene into
# it as pure node declarations and property assignments, and runs it.
#
# The scene written below is the artifact under test. It contains no [ext_resource type="Script"]
# entry of its own: the only scripts it names belong to the addon, exactly as they would if the user
# had pressed A in the scene tree and picked LocalAgent from the Add Node dialog. Every value in it
# is a property that appears in the inspector. If a property needed here were not exported, this
# file could not be written, and that is the test.
#
# scripts/dropin_probe.gd observes the result from outside. It is test apparatus, not part of the
# scene, and it asserts that nothing in the tree carries a script from outside the addon.
#
# Two modes:
#   structure  (default)  no model needed. The scene loads, the agent and panel resolve, and
#                         LocalAgentStatus reports the model as the only thing missing.
#   reply      (LA_GATE_MODEL=/path/to/model.gguf)  additionally sends a prompt and requires text
#                         back. This is the acceptance run, and it needs the native extension built.
#
#   scripts/check_dropin_scene.sh
#   LA_GATE_MODEL=~/models/qwen3-4b.gguf scripts/check_dropin_scene.sh
#
# Exit 0 when the drop-in path works, 1 when it does not.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
MODEL="${LA_GATE_MODEL:-}"
TIMEOUT_S="${LA_GATE_TIMEOUT:-90}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "check_dropin_scene: staging a consumer project in $TMP"
mkdir -p "$TMP/addons/local_agents"

# The addon as a consumer would receive it, minus the build tree. bin/ is copied with -L because it
# is a symlink in a worktree and the native runtime has to actually be present for the reply mode.
rsync -a \
  --exclude 'gdextensions/localagents/thirdparty/' \
  --exclude 'gdextensions/localagents/build/' \
  --exclude 'gdextensions/localagents/build_native/' \
  --exclude 'gdextensions/localagents/bin/' \
  --exclude '.cache/' \
  "$ROOT/addons/local_agents/" "$TMP/addons/local_agents/"

BIN_SRC="$ROOT/addons/local_agents/gdextensions/localagents/bin"
if [[ -e "$BIN_SRC" ]]; then
  rsync -aL "$BIN_SRC/" "$TMP/addons/local_agents/gdextensions/localagents/bin/"
fi

# A consumer's project.godot. The plugin is enabled and nothing else is configured by hand: the
# AgentManager autoload is registered by the plugin itself, and the model path is a ProjectSetting.
{
  cat <<'PROJECT'
config_version=5

[application]
config/name="DropInProbe"
config/features=PackedStringArray("4.7")

[autoload]
AgentManager="*res://addons/local_agents/agent_manager/AgentManager.gd"

[editor_plugins]
enabled=PackedStringArray("res://addons/local_agents/plugin.cfg")
PROJECT
  if [[ -n "$MODEL" ]]; then
    printf '\n[local_agents]\n\nmodel/default_path="%s"\n' "$MODEL"
  fi
} > "$TMP/project.godot"

# --- the artifact under test ---------------------------------------------------------------------
# Node -> LocalAgent (system prompt typed into the inspector) + ChatPanel.tscn (agent picked from
# the dropdown). Three nodes, no script, which is the sequence README and USAGE.md tell a user to
# follow. Written by hand so that a property the inspector does not expose could not be set here.
cat > "$TMP/Quickstart.tscn" <<'SCENE'
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://addons/local_agents/agents/Agent.gd" id="1_agent"]
[ext_resource type="PackedScene" path="res://addons/local_agents/agents/ui/ChatPanel.tscn" id="2_panel"]

[node name="Quickstart" type="Node"]

[node name="Agent" type="Node" parent="."]
script = ExtResource("1_agent")
system_prompt = "Answer in one short sentence."

[node name="ChatPanel" parent="." node_paths=PackedStringArray("agent") instance=ExtResource("2_panel")]
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
agent = NodePath("../Agent")
greeting = "Ask me anything."
SCENE

# --- import, then run --------------------------------------------------------------------------
echo "check_dropin_scene: importing"
la_godot --headless --path "$TMP" --import > "$TMP/import.log" 2>&1 || true

PROBE_ARGS=("--scene=res://Quickstart.tscn" "--timeout=$TIMEOUT_S")
MODE="structure"
if [[ -n "$MODEL" ]]; then
  MODE="reply"
  PROBE_ARGS+=("--prompt=What is the capital of France? Answer in one word.")
  if [[ ! -f "$MODEL" ]]; then
    echo "check_dropin_scene: FAIL - LA_GATE_MODEL is set but does not exist: $MODEL"
    exit 1
  fi
fi

echo "check_dropin_scene: running in $MODE mode"
cp "$ROOT/scripts/dropin_probe.gd" "$TMP/dropin_probe.gd"

LOG="$TMP/run.log"
rc=0
la_godot --headless --path "$TMP" -s dropin_probe.gd -- "${PROBE_ARGS[@]}" > "$LOG" 2>&1 || rc=$?

gate_line="$(grep -a '^DROPIN_GATE=' "$LOG" | tail -n 1 || true)"
reply_line="$(grep -a '^DROPIN_REPLY=' "$LOG" | tail -n 1 || true)"

if [[ -z "$gate_line" ]]; then
  echo "check_dropin_scene: FAIL - the probe printed no verdict (exit $rc). Last 30 lines:"
  tail -n 30 "$LOG" | sed 's/^/    /'
  exit 1
fi

echo "  $gate_line"
[[ -n "$reply_line" ]] && echo "  $reply_line"

if [[ "$rc" -ne 0 ]]; then
  echo "check_dropin_scene: FAIL ($MODE mode, exit $rc)"
  grep -aiE 'Parse Error|SCRIPT ERROR|Failed to load' "$LOG" | head -20 | sed 's/^/    /' || true
  exit 1
fi

if [[ "$MODE" == "structure" ]]; then
  echo "check_dropin_scene: OK (scene builds from nodes and inspector values alone, no model needed)"
  echo "  set LA_GATE_MODEL=/path/to/model.gguf to run the reply mode as well"
else
  echo "check_dropin_scene: OK (a scene with no script produced a reply from a local model)"
fi

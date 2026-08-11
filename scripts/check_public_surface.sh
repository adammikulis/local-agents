#!/usr/bin/env bash
# Gate: only real public API may carry the LocalAgent prefix into a creation dialog.
#
# WHAT THIS PROTECTS. README.md tells a user to open Add Node, or the Create Resource dialog, and type
# "LocalAgent" to find what the addon gives them. That instruction is only true if the things matching
# it are the things they should use. Measured before this gate existed: 130 classes reach a creation
# dialog, 48 of those carried the LocalAgent prefix, and about 26 were public API. The rest were model
# download tabs, editor panels and audio nodes, so the filter returned roughly twice as much noise as
# signal.
#
# WHY THE CHECK IS SCOPED TO CREATION DIALOGS rather than to every class_name. Godot only lists Node
# descendants in Add Node and Resource descendants in Create Resource. A RefCounted or Object class
# with a class_name takes a global identifier but never appears in either dialog, so it cannot mislead
# anyone browsing for a node. It is namespace cost, not a broken promise, and this gate is about the
# promise. Those are reported at the bottom as a note and do not fail the build.
#
# WHY NOT JUST DROP class_name FROM INTERNALS. That was tried on paper and does not survive contact:
# only 2 files in the addon are referenced neither by identifier nor by res:// path, and there are 105
# pairs of classes that reference each other, which class_name resolves lazily and preload cannot.
# So internals keep a class_name, and take the LA prefix to stay out of this gate's way.
#
# ADDING A TYPE TO PUBLIC is deliberate. Ask: would someone press A in the scene tree and add this,
# assign it to an inspector slot, or write it as a type annotation in their own script? If yes, add it
# below and document it in addons/local_agents/docs/API.md. If no, prefix the class LA.
#
#   scripts/check_public_surface.sh            # table + verdict
#   scripts/check_public_surface.sh --quiet    # verdict only
# Exit: 0 when the dialog-visible surface matches this list, 1 when it does not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

QUIET=0
if [[ "${1:-}" == "--quiet" ]]; then QUIET=1; fi

# The sanctioned public surface. This list is the answer to "what does this addon give me", and it is
# read far more often than it is edited, so keep it grouped and commented.
read -r -d '' PUBLIC <<'LIST' || true
# --- Agents and chat ---
LocalAgent                     Node             The local LLM agent. think_async, speak, transcribe.
LocalAgent3D                   CharacterBody3D  An agent with a body and a speech label.
LocalAgentChatPanel            PanelContainer   Prompt box, transcript, status. Ships as a .tscn.
LocalAgentConversation         Node             N agents taking turns, optionally into a memory graph.
LocalAgentStatusLabel          Label            Drop-in readout of whether the addon is ready.
LocalAgentManager              Node             The AgentManager autoload: agent registry and lifecycle.
LocalAgentSpeechEngine         Node             Text to sound. Piper binary, python piper, or system voice.
# --- Driving a local model ---
LocalAgentLlmService           Node             Shared model host, in-process or llama-server.
LocalAgentCognitionScheduler   Node             Budgeted slow brain shared across many creatures.
# --- Memory ---
LocalAgentBackstoryGraphService Node            SQLite-backed NPC memory: relationships, beliefs, recall.
# --- Simulation nodes ---
LocalAgentCreature             CharacterBody3D  A creature with the fast and slow brain stack.
LocalAgentCreatureSpawner      Node3D           Populates a scene from a species-count dictionary.
LocalAgentSimWorld             Node3D           A whole world, planet or flat box, behind one node.
LocalAgentFieldBox             Node3D           The material field as a placeable box, with a slice view.
# --- Authoring and demos ---
LocalAgentDemoHarness          Node             --run-frames=N, a report line, a screenshot, then quit.
# --- Resources you assign in the inspector ---
LocalAgentGraph                Resource         The memory graph.
LocalAgentGraphNode            Resource         A node in it.
LocalAgentGraphEdge            Resource         An edge in it.
LocalAgentGraphRule            Resource         A rule over it.
LocalAgentNodeData             Resource         Node payload.
LocalAgentEdgeData             Resource         Edge payload.
LocalAgentModelProfile         Resource         Model path, context size, threads, GPU layers.
LocalAgentInferenceParams      Resource         Sampling, penalties, mirostat, backend.
LocalAgentTutorialStep         Resource         One step of a tutorial.
LocalAgentDemoEntry            Resource         One rung of the demo ladder.
LIST

export LA_PUBLIC_LIST="$PUBLIC"
export LA_QUIET="$QUIET"

python3 - <<'PY'
import os, re, sys

ADDON = "addons/local_agents"
quiet = os.environ.get("LA_QUIET") == "1"

public = {}
for line in os.environ["LA_PUBLIC_LIST"].splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split(None, 2)
    public[parts[0]] = parts[1] if len(parts) > 1 else "?"

# Every class_name in first-party code. tests/ is excluded: it carries a .gdignore, so those classes
# never reach a consumer's project and are not part of any surface.
info = {}
for dp, _, fns in os.walk(ADDON):
    if os.sep + "tests" in dp:
        continue
    for fn in fns:
        if not fn.endswith(".gd"):
            continue
        p = os.path.join(dp, fn)
        try:
            t = open(p, encoding="utf-8").read()
        except OSError:
            continue
        m = re.search(r"^class_name\s+(\w+)", t, re.M)
        if not m:
            continue
        e = re.search(r"^extends\s+(\S+)", t, re.M)
        info[m.group(1)] = (p, e.group(1).strip('"') if e else "RefCounted")

# Resolve `extends` transitively to whichever engine class it bottoms out in. A class may extend
# another first-party class, or a res:// path, so follow both.
by_path = {f: c for c, (f, _) in info.items()}

def engine_base(cls, seen=None):
    seen = seen or set()
    if cls in seen or cls not in info:
        return "?"
    seen.add(cls)
    _, ext = info[cls]
    if ext in info:
        return engine_base(ext, seen)
    if ext.startswith("res://"):
        target = ext.replace("res://", "")
        return engine_base(by_path[target], seen) if target in by_path else "?"
    return ext

# Godot lists Node descendants in Add Node and Resource descendants in Create Resource. Nothing else
# reaches a creation dialog.
NODE_ROOTS = ("Node", "Control", "Container", "Camera", "MeshInstance", "GPUParticles", "CanvasLayer",
              "CharacterBody", "StaticBody", "RigidBody", "PanelContainer", "Panel", "Label",
              "VBoxContainer", "HBoxContainer", "MarginContainer", "Editor", "Area", "Sprite")

def in_dialog(cls):
    b = engine_base(cls)
    return b == "Resource" or b.startswith(NODE_ROOTS)

errors = 0

# 1. Dialog-visible, public prefix, not sanctioned. This is the broken promise.
offenders = sorted(c for c in info
                   if c.startswith("LocalAgent") and c not in public and in_dialog(c))
if offenders:
    errors += len(offenders)
    print("check_public_surface: these appear in a creation dialog under the public LocalAgent")
    print("prefix but are not public API. Rename each to LA<Thing>, or add it to PUBLIC in this")
    print("script and document it in addons/local_agents/docs/API.md:")
    for c in offenders:
        print("    %-38s %-16s %s" % (c, engine_base(c), info[c][0]))
    print()

# 2. Sanctioned but undeclared: a rename missed a file, or the entry is stale.
missing = sorted(c for c in public if c not in info)
if missing:
    errors += len(missing)
    print("check_public_surface: listed as public API but no class declares them.")
    print("Either a rename missed a file, or the entry is stale and should be removed:")
    for c in missing:
        print("    %s" % c)
    print()

# 3. Sanctioned but not actually reachable from a dialog. Usually means it lost its class_name, or
# extends something that is not a Node or Resource, so a user cannot add it the way the docs claim.
unreachable = sorted(c for c in public if c in info and not in_dialog(c))
if unreachable:
    errors += len(unreachable)
    print("check_public_surface: listed as public API but not reachable from Add Node or Create")
    print("Resource, so the documented way to use them does not work:")
    for c in unreachable:
        print("    %-38s extends %s" % (c, engine_base(c)))
    print()

# A note, not a failure. These take a global identifier in the consumer's project but never show up
# in a creation dialog, so they cannot mislead anyone browsing for a node.
noise = sorted(c for c in info if c.startswith("LocalAgent") and c not in public and not in_dialog(c))

if errors == 0 and not quiet:
    print("check_public_surface: %d public types, and nothing else reaches a creation dialog" % len(public))
    for c in sorted(public):
        print("    %-38s %s" % (c, public[c]))
    if noise:
        print()
        print("  note: %d internal classes carry the LocalAgent prefix but are RefCounted/Object, so" % len(noise))
        print("  they take a global identifier without appearing in any dialog. Not a failure.")

total_dialog = sum(1 for c in info if in_dialog(c))
if errors == 0:
    print("check_public_surface: OK (%d public, %d classes reach a dialog)" % (len(public), total_dialog))
    sys.exit(0)

print("check_public_surface: FAIL (%d problem(s); %d classes reach a dialog, %d are public)"
      % (errors, total_dialog, len(public)))
sys.exit(1)
PY

#!/usr/bin/env bash
# Unified agent entrypoint that wraps the project's canonical test/run harnesses,
# tees full output to a log, and prints one machine-parseable result line.
#
# IMPORTANT: never invoke addons/local_agents/tests/test_*.gd directly; that is
# banned by scripts/check_no_direct_refcounted_invocation.sh. Always route
# through the canonical run_*.gd runners or the run_*.sh wrapper scripts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GODOT="${GODOT:-godot}"
# The headless smoke target. Deliberately the menu, not the voxel world. VoxelWorld.tscn does BOOT
# headless and exits rc 0 (measured 2026-07-28: 5.3s), but headless has no compute device, so its
# SIM_REPORT comes back EMPTY — biomass 0, heat_cells 0, sediment_total 0.00, temp flat, no field_* gauges
# — where the same run windowed reports sediment_total ~980. It fails silently rather than loudly, so a
# headless voxel smoke would be a green light that measured nothing. Use run_sim_offscreen.sh for it.
# Was pointing at scenes/simulation/WorldSimulation.tscn, deleted with the old stack.
MAIN_SCENE="res://addons/local_agents/game/menu/MainMenu.tscn"

# Any godot process this harness (or a test it spawns) launches inherits this: it makes the in-code
# LA_OFFSCREEN guards shove stray windows off-view — notably a model-download / model-manager panel run as
# its own scene root (the "DEBUG" banner + Qwen model list), which would otherwise pop up in front.
export LA_OFFSCREEN="${LA_OFFSCREEN:-1}"

# Portable default. This was an absolute path into one agent session's scratchpad
# (/private/tmp/claude-501/.../875e28b8-.../scratchpad), committed to the repo. It happened to exist on
# the machine that wrote it, so nobody noticed — until CI started running this script and `mkdir -p`
# on /private/... failed for a non-root user on Linux, killing the step under `set -euo pipefail`.
# Override with LOG_DIR when you want the logs somewhere specific.
DEFAULT_LOG_DIR="${TMPDIR:-/tmp}/local-agents-harness-logs"
LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"

usage() {
  cat <<'USAGE'
Usage: scripts/agent_harness.sh <command> [args...]

Commands:
  fast          Run the fast test sweep (run_all_tests.gd --fast).
  all [args]    Run the full test suite (run_all_tests.gd --timeout=120).
  bounded [a]   Run bounded runtime suite (run_runtime_tests_bounded.gd).
                e.g. bounded --suite=fast --workers=2
  single <f> [a] Run one test via scripts/run_single_test.sh <f> [--timeout=120].
  smoke         Boot the main scene headless briefly; fail on script/parse errors.
  demo [args]   Run example scenes BARE HEADLESS via scripts/run_demo.sh (~1s each).
                e.g. demo --list | demo --all [frames] | demo BoxFieldDemo [frames]
  extension     Validate the GDExtension via scripts/check_extension.gd.
  dropin        Prove the addon works as a drop-in: stage a consumer project holding only
                addons/local_agents/, author a scene with no script in it, and run it.
                Set LA_GATE_MODEL=/path/to/model.gguf to also require a real reply.
  sim [args]    Run the planet and print its books via scripts/sim_run.sh. Off-screen, streamer off,
                re-imports first so stale kernels cannot fake a report. Defaults to the standard
                verification arm (200 frames, seed 4242, --fast=8, --planet-only --no-fauna).
                e.g. agent_harness.sh sim --frames 600      agent_harness.sh sim --raw
  lint          Run every structural gate: file length (soft 1300 warn / hard 1500 fail),
                no-direct-refcounted, no ':=' typing, @tool write safety, demo catalogue,
                public surface, whole-tree parse, library-only parse, physical constants
                (GLSL kernel copies must equal LAPhysical), reaction balance. Policy markers
                stay advisory. CI runs this exact command, so a green here is a green there.
  -h | --help   Show this help and exit 0.

Environment:
  LOG_DIR   Directory for combined logs (default: session scratchpad).
  GODOT     Godot binary (default: godot on PATH).

Every command tees output to a log and prints a final line:
  AGENT_HARNESS_RESULT={"command":...,"status":...,"exit_code":...,...}
USAGE
}

# --- argument dispatch -------------------------------------------------------
cmd="${1:-}"
if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

case "$cmd" in
  fast|all|bounded|single|smoke|extension|lint|demo|dropin|sim) ;;
  *)
    echo "agent_harness: unknown command '$cmd'" >&2
    usage >&2
    exit 2
    ;;
esac

cd "$REPO_ROOT"
# Say WHY when the log directory cannot be created. Under `set -euo pipefail` a bare `mkdir -p` failure
# exits with nothing but "mkdir: ..." on stderr, which is exactly what a CI job saw: the lint step died in
# 20 seconds having run no gates, and the output gave no hint that logging was the problem, not linting.
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
  echo "agent_harness: cannot create log directory '$LOG_DIR'." >&2
  echo "               NO GATES HAVE RUN. Set LOG_DIR to a writable path and re-run." >&2
  exit 2
fi
LOG_FILE="$LOG_DIR/agent_harness_${cmd}_$(date +%s).log"

# --- build the child command as an argv array --------------------------------
child=()
case "$cmd" in
  sim)
    shift
    "$(dirname "${BASH_SOURCE[0]}")/sim_run.sh" "$@"
    exit $?
    ;;
  fast)
    child=("$GODOT" --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --fast)
    ;;
  all)
    child=("$GODOT" --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120 "$@")
    ;;
  bounded)
    child=("$GODOT" --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120 "$@")
    ;;
  single)
    if [[ $# -lt 1 ]]; then
      echo "agent_harness: 'single' requires a test file argument" >&2
      usage >&2
      exit 2
    fi
    target="$1"; shift
    child=("$SCRIPT_DIR/run_single_test.sh" "$target" "$@")
    ;;
  smoke)
    child=("$GODOT" --headless --no-window --quit-after 120 "$MAIN_SCENE")
    ;;
  demo)
    child=("$SCRIPT_DIR/run_demo.sh" "$@")
    ;;
  extension)
    child=("$GODOT" -s scripts/check_extension.gd)
    ;;
  # Kept OUT of lint on purpose. It stages a whole project and runs the importer, measured at 3s warm
  # and about 25s cold, and reply mode additionally loads a model. lint has to stay cheap enough to
  # run on every change.
  dropin)
    child=("$SCRIPT_DIR/check_dropin_scene.sh" "$@")
    ;;
  lint)
    : # handled specially below
    ;;
esac

# --- run the child, tee to the log, preserve its exit code -------------------
SECONDS=0
exit_code=0
if [[ "$cmd" == "lint" ]]; then
  set +e
  {
    set +e
    # Gate: file length, at the DOCUMENTED thresholds (soft 1300 warn, hard 1500 fail — the script's own
    # defaults, which is what CLAUDE.md describes). This used to run at MAX_FILE_LINES=1000 as advisory,
    # with the comment "matches docs + CI"; neither half was true. Docs said 1500, CI set 1000 — and CI's
    # copy examined ZERO files because ripgrep is not installed on the runner, so it passed vacuously on
    # every push. Three different numbers, none of them enforced. One number now, gating in both places.
    set +e
    "$SCRIPT_DIR/check_max_file_length.sh"
    rc_len=$?
    set -e
    if [[ $rc_len -ne 0 ]]; then
      echo "LINT_FAIL: check_max_file_length.sh ($rc_len)"
      exit 1
    fi
    # Advisory: policy/plan marker drift never gates.
    "$SCRIPT_DIR/check_policy_plan_markers.sh"
    # Gate: banning direct test_*.gd invocation is a genuine correctness check.
    "$SCRIPT_DIR/check_no_direct_refcounted_invocation.sh"
    rc_gate=$?
    set -e
    if [[ $rc_gate -ne 0 ]]; then
      echo "LINT_FAIL: check_no_direct_refcounted_invocation.sh ($rc_gate)"
      exit 1
    fi
    # Gate: no inferred typing (:=) in the enforced directories.
    set +e
    "$SCRIPT_DIR/check_no_inferred_typing.sh"
    rc_typing=$?
    set -e
    if [[ $rc_typing -ne 0 ]]; then
      echo "LINT_FAIL: check_no_inferred_typing.sh ($rc_typing)"
      exit 1
    fi
    # Gate: no @tool script writing serialised state in the editor. Two independently written nodes
    # shipped that bug (silently editing the user's .tscn) before this existed.
    set +e
    "$SCRIPT_DIR/check_tool_safety.sh"
    rc_tool=$?
    set -e
    if [[ $rc_tool -ne 0 ]]; then
      echo "LINT_FAIL: check_tool_safety.sh ($rc_tool)"
      exit 1
    fi
    # Gate: the demo catalogue matches the demos on disk (no orphan entry, no unlisted demo).
    set +e
    "$SCRIPT_DIR/check_demo_catalog.sh"
    rc_catalog=$?
    set -e
    if [[ $rc_catalog -ne 0 ]]; then
      echo "LINT_FAIL: check_demo_catalog.sh ($rc_catalog)"
      exit 1
    fi
    # Gate: only real public API reaches a creation dialog under the LocalAgent prefix. README tells
    # users to type "LocalAgent" into Add Node to find the addon's nodes, and that was returning about
    # twice as much noise as signal.
    set +e
    "$SCRIPT_DIR/check_public_surface.sh"
    rc_surface=$?
    set -e
    if [[ $rc_surface -ne 0 ]]; then
      echo "LINT_FAIL: check_public_surface.sh ($rc_surface)"
      exit 1
    fi
    # Gate: the GLSL kernels' copies of physical constants equal LAPhysical. A compute shader cannot
    # import a GDScript constant, so every kernel hand-copies the value — which is exactly how the
    # freezing point of water ended up in five files at three different values (12.5 / 13.0 / 14.0).
    # This is the import the language does not have. Exit 2 means the gate could not run.
    set +e
    "$SCRIPT_DIR/check_physical_constants.sh"
    rc_physical=$?
    set -e
    if [[ $rc_physical -ne 0 ]]; then
      echo "LINT_FAIL: check_physical_constants.sh ($rc_physical)"
      exit 1
    fi
    # Gate: every number is derived, bound, or written down in docs/MODEL_PARAMETERS.md. The gate above asks
    # whether a copy equals the authority; it cannot ask whether the thing should be a number at all. Scans
    # the GDScript sim layer too, which is where a second air density (1.225 against the authority's 1.18)
    # sat invisible to a GLSL-only gate. Exit 2 means the gate could not run.
    set +e
    "$SCRIPT_DIR/check_model_parameters.sh"
    rc_modelparams=$?
    set -e
    if [[ $rc_modelparams -ne 0 ]]; then
      echo "LINT_FAIL: check_model_parameters.sh ($rc_modelparams)"
      exit 1
    fi
    # Gate: ONE definition of a cell's volumetric heat capacity per side of the GPU boundary. The gate above
    # CANNOT see this class of defect and its own failure proves it — that one checks VALUES, and all nine
    # copies of this mix read the right values while putting them in four mutually incompatible formulas.
    # Two of the nine were the BOOKED and the STOCK sides of the energy ledger's own subtraction, so their
    # disagreement was published as planetary energy drift for as long as it existed. Exit 2 = could not run.
    set +e
    "$SCRIPT_DIR/check_heat_capacity_ssot.sh"
    rc_heatcap=$?
    set -e
    if [[ $rc_heatcap -ne 0 ]]; then
      echo "LINT_FAIL: check_heat_capacity_ssot.sh ($rc_heatcap)"
      exit 1
    fi
    # Gate: no reaction record may create or destroy matter. The DEFS engine took reactants and products as
    # two independent lists of hand-written coefficients with nothing relating them, and one rate model had
    # no reactant at all, so only its product credit ever ran — which is where every carbon atom in this
    # simulation came from. Conservation was asserted in comments and enforced nowhere; this is the
    # enforcement. Exit 2 means the gate could not run.
    set +e
    "$SCRIPT_DIR/check_reaction_balance.sh"
    rc_balance=$?
    set -e
    if [[ $rc_balance -ne 0 ]]; then
      echo "LINT_FAIL: check_reaction_balance.sh ($rc_balance)"
      exit 1
    fi
    # Gate: the render clock does not drive the simulation. The field steps on a fixed physics accumulator;
    # the master clock and the orbit advanced in _process, so the sun moved a framerate-dependent distance
    # across the sky per unit of chemistry. Static check — no run required. Exit 2 = could not run.
    set +e
    "$SCRIPT_DIR/check_framerate_independence.sh"
    rc_framerate=$?
    set -e
    if [[ $rc_framerate -ne 0 ]]; then
      echo "LINT_FAIL: check_framerate_independence.sh ($rc_framerate)"
      exit 1
    fi
    # Gate: every script in the REAL tree parses. An editor scan does not check this — it emits twenty
    # progress lines and nothing about any script — so a broken pass module let the sim run to
    # completion and print a full SIM_REPORT with a whole transport CA silently missing. The sweep
    # existed but ran only inside check_library_only.sh, which deletes game/ before scanning, so game/
    # (54 scripts) was force-parsed by nothing at all. Exit 2 means the gate could not run.
    set +e
    "$SCRIPT_DIR/check_parse_all.sh"
    rc_parseall=$?
    set -e
    if [[ $rc_parseall -ne 0 ]]; then
      echo "LINT_FAIL: check_parse_all.sh ($rc_parseall)"
      exit 1
    fi
    # Gate: the addon still parses with the game deleted. docs/USAGE.md promises this; nothing
    # enforced it, and it had already rotted once. Distinct from the sweep above: that one asks whether
    # the tree parses, this one asks whether the LIBRARY HALF parses on its own.
    set +e
    "$SCRIPT_DIR/check_library_only.sh"
    rc_libonly=$?
    set -e
    if [[ $rc_libonly -ne 0 ]]; then
      echo "LINT_FAIL: check_library_only.sh ($rc_libonly)"
      exit 1
    fi
    echo "All lint gates passed (file length gates at soft 1300 / hard 1500; policy markers are advisory)."
    exit 0
  } 2>&1 | tee "$LOG_FILE"
  exit_code=${PIPESTATUS[0]}
  set -e
else
  set +e
  "${child[@]}" 2>&1 | tee "$LOG_FILE"
  exit_code=${PIPESTATUS[0]}
  set -e
fi
duration=$SECONDS

# Remaining work is best-effort log parsing + result emission; a non-matching
# grep must not abort the script before the result line is printed.
set +e

# --- classify status ---------------------------------------------------------
if [[ "$exit_code" -eq 0 ]]; then
  status="pass"
elif [[ "$exit_code" -eq 124 ]]; then
  status="timeout"
else
  status="fail"
fi

# --- parse the log for pass/fail signal --------------------------------------
passed="null"
failed="null"

# Preferred: structured AGENT_TEST_RESULT={json}. Take the last one.
result_json="$(grep -o 'AGENT_TEST_RESULT=.*' "$LOG_FILE" 2>/dev/null | tail -n 1 | sed 's/^AGENT_TEST_RESULT=//')"
if [[ -n "$result_json" ]]; then
  p="$(printf '%s' "$result_json" | grep -oE '"passed"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)"
  f="$(printf '%s' "$result_json" | grep -oE '"failed"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)"
  [[ -n "$p" ]] && passed="$p"
  [[ -n "$f" ]] && failed="$f"
fi

# run_demo.sh --all closes with RUN_DEMO_ALL={"ran":N,"failed":N,...}; map it onto passed/failed so the
# demo command emits the same shape of result line as the test commands.
if [[ "$cmd" == "demo" && "$passed" == "null" ]]; then
  demo_json="$(grep -o 'RUN_DEMO_ALL=.*' "$LOG_FILE" 2>/dev/null | tail -n 1)"
  if [[ -n "$demo_json" ]]; then
    ran="$(printf '%s' "$demo_json" | grep -oE '"ran"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)"
    f="$(printf '%s' "$demo_json" | grep -oE '"failed"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' | head -n1)"
    if [[ -n "$ran" && -n "$f" ]]; then
      passed="$((ran - f))"
      failed="$f"
    fi
  fi
fi

# Legacy markers: "<N> passed" / "<N> failed" summary lines.
if [[ "$passed" == "null" ]]; then
  p="$(grep -oE '[0-9]+ passed' "$LOG_FILE" 2>/dev/null | tail -n1 | grep -oE '^[0-9]+')"
  [[ -n "$p" ]] && passed="$p"
fi
if [[ "$failed" == "null" ]]; then
  f="$(grep -oE '[0-9]+ failed' "$LOG_FILE" 2>/dev/null | tail -n1 | grep -oE '^[0-9]+')"
  [[ -n "$f" ]] && failed="$f"
fi

# Smoke: treat script/parse/dependency errors as failure even if exit was 0.
if [[ "$cmd" == "smoke" && "$status" == "pass" ]]; then
  if grep -qiE 'SCRIPT ERROR|Parse Error|dependency error|Failed loading resource' "$LOG_FILE" 2>/dev/null; then
    status="fail"
    if [[ "$exit_code" -eq 0 ]]; then exit_code=1; fi
  fi
fi

# --- emit exactly one machine-parseable result line --------------------------
extra=""
printf 'AGENT_HARNESS_RESULT={"command":"%s","status":"%s","exit_code":%d,"duration_s":%d,"log":"%s","passed":%s,"failed":%s%s}\n' \
  "$cmd" "$status" "$exit_code" "$duration" "$LOG_FILE" "$passed" "$failed" "$extra"

# Mirror the child's exit code.
exit "$exit_code"

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
# ONE launcher. A direct `godot` here is what put a window on the user's screen.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
# The headless smoke target is the menu, not the voxel world: headless has no compute device, so a
# headless VoxelWorld run publishes an empty SIM_REPORT and rc 0. Use run_sim_offscreen.sh for it.
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
                verification arm (200 steps, seed 4242, --planet-only --no-fauna).
                e.g. agent_harness.sh sim --frames 600      agent_harness.sh sim --raw
  score [args]  PHYSICS_RUBRIC.md, all ten criteria, COMPUTED. Never hand-enter a row: the half a person
                scores is the half that moves. Prints the table row ready to paste. Takes its own
                comparison runs for determinism and observer independence, so it is minutes.
                e.g. agent_harness.sh score --frames 300
  lint          Run every structural gate: file length (soft 1300 warn / hard 1500 fail),
                no-direct-refcounted, no ':=' typing, @tool write safety, demo catalogue,
                public surface, whole-tree parse, library-only parse, physical constants
                (GLSL kernel copies must equal LAPhysical), reaction balance. Policy markers
                stay advisory. CI runs this exact command, so a green here is a green there.
                Exit 0 clean · 1 a gate reported a violation · 2 a gate COULD NOT RUN.
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

# --- A LINKED WORKTREE REPAIRS ITSELF HERE, BEFORE ANY COMMAND RUNS ----------------------------------
# `git worktree add` gives you the source and none of the build state: no `bin/` symlink, no imported
# kernels, no `.godot/`. Each degrades QUIETLY — an unimported `.glsl` loads as null, the GPU field is
# silently dead, and SIM_REPORT still prints a full set of plausible numbers.
#
# CLAUDE.md has pointed at `scripts/new_worktree.sh` for as long as that section has existed, and it is
# still the right way to MAKE one. But the Workflow tool creates worktrees itself, so no instruction can
# cover that path — and an instruction is what failed. Every command routes through here instead. It is a
# few stat calls and silent when there is nothing to do; it exits 2 rather than let a broken tree run.
if [[ -x "$SCRIPT_DIR/ensure_worktree_ready.sh" ]]; then
  if ! "$SCRIPT_DIR/ensure_worktree_ready.sh"; then
    echo "AGENT_HARNESS_RESULT={\"command\":\"$cmd\",\"status\":\"fail\",\"exit_code\":2,\"reason\":\"worktree not usable\"}"
    exit 2
  fi
fi

case "$cmd" in
  fast|all|bounded|single|smoke|extension|lint|demo|dropin|sim|score) ;;
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
    # The subcommand is consumed above; a second shift here would eat the first argument.
    "$(dirname "${BASH_SOURCE[0]}")/sim_run.sh" "$@"
    exit $?
    ;;
  fast)
    child=(la_godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --fast)
    ;;
  all)
    child=(la_godot --headless --no-window -s addons/local_agents/tests/run_all_tests.gd -- --timeout=120 "$@")
    ;;
  bounded)
    child=(la_godot --headless --no-window -s addons/local_agents/tests/run_runtime_tests_bounded.gd -- --timeout=120 "$@")
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
    child=(la_godot --headless --no-window --quit-after 120 "$MAIN_SCENE")
    ;;
  demo)
    child=("$SCRIPT_DIR/run_demo.sh" "$@")
    ;;
  extension)
    child=(la_godot -s scripts/check_extension.gd)
    ;;
  # Kept OUT of lint on purpose. It stages a whole project and runs the importer, measured at 3s warm
  # and about 25s cold, and reply mode additionally loads a model. lint has to stay cheap enough to
  # run on every change.
  dropin)
    child=("$SCRIPT_DIR/check_dropin_scene.sh" "$@")
    ;;
  # The rubric, all ten criteria, computed. NOBODY HAND-ENTERS A ROW: the half a person scores is the half
  # that moves, and the criteria that used to be hand-entered were described in PHYSICS_RUBRIC.md itself as
  # "the ones to distrust". It takes its own comparison runs for determinism and observer independence, so
  # it is minutes, not seconds — a landing-time command, not a per-change one.
  score)
    child=("$SCRIPT_DIR/physics_score.sh" "$@")
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
    # A gate answers with 0 clean, 1 a violation, anything else it COULD NOT RUN. The two are different
    # facts about the tree and the caller reads only $?, so they get different exit codes: could-not-run
    # examined nothing, so its silence is not a pass, and it outranks a violation.
    lint_failed=0
    lint_unrunnable=0
    run_gate() {
      local label="$1"
      shift
      local rc=0
      "$@" || rc=$?
      case "$rc" in
        0) ;;
        1)
          echo "LINT_FAIL: $label ($rc)"
          lint_failed=$((lint_failed + 1))
          ;;
        *)
          echo "LINT_UNRUNNABLE: $label ($rc)"
          lint_unrunnable=$((lint_unrunnable + 1))
          ;;
      esac
    }
    gate() { run_gate "$1.sh" "$SCRIPT_DIR/$1.sh"; }

    gate check_max_file_length
    # Advisory: policy/plan marker drift never gates.
    "$SCRIPT_DIR/check_policy_plan_markers.sh"
    gate check_no_direct_refcounted_invocation
    gate check_no_inferred_typing
    gate check_tool_safety
    gate check_godot_launcher
    gate check_quiet_window
    gate check_demo_catalog
    gate check_public_surface
    gate check_physical_constants
    gate check_model_parameters
    gate check_kernel_paths
    gate check_no_stored_derived
    gate check_no_privileged_axis
    gate check_gdscript_budget
    gate check_run_budget
    gate check_comment_ratio
    gate check_comment_history
    gate check_neighbour_slots
    gate check_sim_determinism
    gate check_binding_collisions
    gate check_declared_and_dispatched
    gate check_gate_fixtures
    gate check_branch_integration
    gate check_doc_claims
    gate check_doc_prose
    gate check_approximations
    gate check_comment_density
    # Same gate over first-party GDScript; sim/material is covered by the call above.
    run_gate "check_comment_density.sh (gdscript)" env EXCLUDE_RE=/thirdparty/ \
      "$SCRIPT_DIR/check_comment_density.sh" "$REPO_ROOT/addons/local_agents"
    gate check_enthalpy_ssot
    gate check_generated_constants
    gate check_seed_phase
    gate check_reaction_balance
    gate check_framerate_independence
    gate check_parse_all
    gate check_library_only
    gate check_step_quantum
    gate check_comment_claims
    gate check_no_silent_fallback
    gate check_no_invented_fallback
    gate check_duplicate_logic
    gate check_never_assigned
    gate check_voxel_grid
    gate check_gravity_solve
    gate check_radiative_row
    gate check_shaders_compile
    gate check_reaction_energy
    # EVERY GATE RUNS. Fail-fast meant one red gate hid every gate after it.
    if [[ $lint_unrunnable -gt 0 ]]; then
      echo "LINT_SUMMARY: $lint_unrunnable gate(s) COULD NOT RUN, $lint_failed violation(s). Every gate ran;"
      echo "              a gate that could not run examined nothing, so this is not a physics failure."
      exit 2
    fi
    if [[ $lint_failed -gt 0 ]]; then
      echo "LINT_SUMMARY: $lint_failed gate(s) failed. Every gate ran; the list above is complete."
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
elif [[ "$cmd" == "lint" && "$exit_code" -eq 2 ]]; then
  status="unrunnable"
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

#!/usr/bin/env bash
#
# finetune_functiongemma.sh — drive the FunctionGemma slow-brain auto-finetune loop.
#
# Resolves the sim's trace file, checks that Python + the ML deps are present,
# runs scripts/functiongemma_train.py, and on success copies the resulting GGUF
# into addons/local_agents/models/functiongemma/ for the sim to load.
#
# It is deliberately NON-catastrophic when optional deps are missing: it prints
# guidance and still emits a machine-readable final line:
#
#     FUNCTIONGEMMA_FINETUNE_RESULT={...json...}
#
# Usage:
#     scripts/finetune_functiongemma.sh [extra args passed through to the trainer]
#
# Env overrides:
#     TRACES_PATH   path to functiongemma_traces.jsonl (else macOS Godot userdata)
#     OUT_DIR       output dir (default: addons/local_agents/models/functiongemma)
#     PYTHON        python interpreter (default: python3)

set -euo pipefail

# --------------------------------------------------------------------------- #
# Paths.
# --------------------------------------------------------------------------- #

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TRAINER="${SCRIPT_DIR}/functiongemma_train.py"

PYTHON="${PYTHON:-python3}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/addons/local_agents/models/functiongemma}"

DEFAULT_TRACES="${HOME}/Library/Application Support/Godot/app_userdata/LocalAgents/functiongemma_traces.jsonl"
TRACES_PATH="${TRACES_PATH:-${DEFAULT_TRACES}}"

# --------------------------------------------------------------------------- #
# Helpers.
# --------------------------------------------------------------------------- #

# Emit the machine-readable result line and exit with the given status.
emit_result() {
    local status="$1"; shift
    local message="$1"; shift
    local gguf="${1:-}"
    # Build compact JSON without relying on jq.
    printf 'FUNCTIONGEMMA_FINETUNE_RESULT={"status":"%s","message":"%s","gguf":"%s","traces":"%s","out_dir":"%s"}\n' \
        "${status}" "${message}" "${gguf}" "${TRACES_PATH}" "${OUT_DIR}"
}

fail_soft() {
    # Print guidance but do NOT exit non-zero for "expected" soft failures
    # (missing deps / missing traces) so callers can parse the result line.
    local status="$1"; shift
    local message="$1"; shift
    echo ">> ${message}" >&2
    emit_result "${status}" "${message}" ""
    exit 0
}

# --------------------------------------------------------------------------- #
# Pre-flight checks.
# --------------------------------------------------------------------------- #

echo ">> repo root:    ${REPO_ROOT}"
echo ">> trainer:      ${TRAINER}"
echo ">> traces:       ${TRACES_PATH}"
echo ">> out dir:      ${OUT_DIR}"

if [[ ! -f "${TRAINER}" ]]; then
    fail_soft "error" "trainer script not found at ${TRAINER}"
fi

if ! command -v "${PYTHON}" >/dev/null 2>&1; then
    fail_soft "no_python" "python interpreter '${PYTHON}' not found; install Python 3 or set PYTHON=..."
fi

if [[ ! -f "${TRACES_PATH}" ]]; then
    fail_soft "no_traces" "trace file not found at ${TRACES_PATH}; run the sim first or set TRACES_PATH=..."
fi

mkdir -p "${OUT_DIR}"

# Detect whether the ML stack is installed (non-fatal).
DEPS_OK=1
if ! "${PYTHON}" - <<'PY' >/dev/null 2>&1
import importlib.util, sys
mods = ["torch", "transformers", "datasets", "trl", "unsloth"]
missing = [m for m in mods if importlib.util.find_spec(m) is None]
sys.exit(1 if missing else 0)
PY
then
    DEPS_OK=0
fi

# --------------------------------------------------------------------------- #
# Run.
# --------------------------------------------------------------------------- #

if [[ "${DEPS_OK}" -eq 0 ]]; then
    echo ">> ML training deps missing; running conversion dry-run so you can inspect the data." >&2
    echo ">> Install with: pip install \"unsloth\" trl transformers datasets torch" >&2
    # Still exercise the (stdlib-only) conversion path to validate the traces.
    set +e
    "${PYTHON}" "${TRAINER}" \
        --traces "${TRACES_PATH}" \
        --out "${OUT_DIR}" \
        --dry-run \
        --emit-dataset "${OUT_DIR}/train_examples.jsonl" \
        "$@"
    RC=$?
    set -e
    if [[ "${RC}" -eq 0 ]]; then
        fail_soft "deps_missing" "converted traces OK (see ${OUT_DIR}/train_examples.jsonl); install ML deps to train"
    else
        fail_soft "convert_failed" "trace conversion failed (rc=${RC})"
    fi
fi

# Full run.
set +e
"${PYTHON}" "${TRAINER}" \
    --traces "${TRACES_PATH}" \
    --out "${OUT_DIR}" \
    "$@"
RC=$?
set -e

if [[ "${RC}" -ne 0 ]]; then
    echo ">> trainer exited non-zero (rc=${RC})." >&2
    emit_result "train_failed" "trainer exited rc=${RC}" ""
    exit 0
fi

# --------------------------------------------------------------------------- #
# Locate the produced GGUF and make sure it lives in the models dir.
# --------------------------------------------------------------------------- #

# The trainer writes into OUT_DIR (which already IS the models dir), so the GGUF
# should be here. Pick the newest .gguf as the trained model.
GGUF_PATH=""
if compgen -G "${OUT_DIR}/*.gguf" >/dev/null 2>&1; then
    # Newest by mtime.
    GGUF_PATH="$(ls -t "${OUT_DIR}"/*.gguf 2>/dev/null | head -n1)"
fi

if [[ -z "${GGUF_PATH}" ]]; then
    echo ">> training completed but no GGUF was produced (convert step may need llama.cpp)." >&2
    echo ">> Set LLAMA_CPP_DIR=/path/to/llama.cpp and re-run, or convert the merged model manually." >&2
    emit_result "trained_no_gguf" "training done; GGUF not produced (see merged model in ${OUT_DIR}/merged)" ""
    exit 0
fi

# Canonical destination name the sim can load.
DEST="${OUT_DIR}/functiongemma-slowbrain.gguf"
if [[ "${GGUF_PATH}" != "${DEST}" ]]; then
    cp -f "${GGUF_PATH}" "${DEST}"
fi
echo ">> slow-brain GGUF ready: ${DEST}"

emit_result "ok" "finetune complete" "${DEST}"
exit 0

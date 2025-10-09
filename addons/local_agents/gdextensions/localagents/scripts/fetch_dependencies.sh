#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
REPO_ROOT=$(cd "${EXT_DIR}/../../.." && pwd)
THIRDPARTY_DIR="${EXT_DIR}/thirdparty"
MODELS_DIR="${REPO_ROOT}/addons/local_agents/models"
VOICES_DIR="${REPO_ROOT}/addons/local_agents/voices"

GODOT_CPP_REPO="https://github.com/godotengine/godot-cpp.git"
LLAMA_CPP_REPO="https://github.com/ggerganov/llama.cpp.git"
WHISPER_CPP_REPO="https://github.com/ggerganov/whisper.cpp.git"
SQLITE_AMALGAMATION_URL="https://www.sqlite.org/2024/sqlite-autoconf-3450200.tar.gz"

DEFAULT_MODEL_NAME="Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
DEFAULT_MODEL_URL="https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/${DEFAULT_MODEL_NAME}"
DEFAULT_MODEL_FOLDER="qwen3-4b-instruct"

PIPER_VOICES=(
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US-ryan-high.onnx"
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US-ryan-high.onnx.json"
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US-kathleen-high.onnx"
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US-kathleen-high.onnx.json"
)

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --skip-models        Skip downloading default GGUF model.
  --skip-voices        Skip downloading Piper voices.
  --clean              Remove downloaded dependencies and assets.
  -h, --help           Show this help.
USAGE
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

clone_if_missing() {
    local url="$1" dest="$2"
    if [[ -d "$dest/.git" ]]; then
        echo "[skip] $(basename "$dest") already present"
    else
        echo "[git] cloning $url"
        git clone --depth 1 "$url" "$dest"
    fi
}

download_file() {
    local url="$1" dest="$2"
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
        echo "[skip] $(basename "$dest") already exists"
        return
    fi
    echo "[curl] $url"
    curl -L --fail --progress-bar "$url" -o "$dest"
}

extract_sqlite() {
    local archive="$THIRDPARTY_DIR/sqlite.tar.gz"
    if [[ -d "$THIRDPARTY_DIR/sqlite" ]]; then
        echo "[skip] sqlite amalgamation present"
        return
    fi
    download_file "$SQLITE_AMALGAMATION_URL" "$archive"
    mkdir -p "$THIRDPARTY_DIR/sqlite"
    tar -xzf "$archive" -C "$THIRDPARTY_DIR/sqlite" --strip-components=1
}

clean_all() {
    echo "[clean] removing third-party and asset directories"
    rm -rf "$THIRDPARTY_DIR" "$MODELS_DIR" "$VOICES_DIR"
}

main() {
    local skip_models=false skip_voices=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-models) skip_models=true ; shift ;;
            --skip-voices) skip_voices=true ; shift ;;
            --clean) clean_all ; exit 0 ;;
            -h|--help) usage ; exit 0 ;;
            *) echo "Unknown option: $1" >&2 ; usage ; exit 1 ;;
        esac
    done

    for bin in git curl tar; do
        if ! command_exists "$bin"; then
            echo "Error: required tool '$bin' not found in PATH" >&2
            exit 1
        fi
    done

    mkdir -p "$THIRDPARTY_DIR" "$MODELS_DIR" "$VOICES_DIR"

    clone_if_missing "$GODOT_CPP_REPO" "$THIRDPARTY_DIR/godot-cpp"
    clone_if_missing "$LLAMA_CPP_REPO" "$THIRDPARTY_DIR/llama.cpp"
    clone_if_missing "$WHISPER_CPP_REPO" "$THIRDPARTY_DIR/whisper.cpp"
    extract_sqlite

    if [[ "$skip_models" == false ]]; then
        local model_dir="$MODELS_DIR/$DEFAULT_MODEL_FOLDER"
        mkdir -p "$model_dir"
        download_file "$DEFAULT_MODEL_URL" "$model_dir/$DEFAULT_MODEL_NAME"
    fi

    if [[ "$skip_voices" == false ]]; then
        for url in "${PIPER_VOICES[@]}"; do
            local filename=$(basename "$url")
            local voice_id="${filename/en_US-/}"
            local dest_dir
            if [[ "$filename" == *"ryan"* ]]; then
                dest_dir="$VOICES_DIR/en_US-ryan"
            elif [[ "$filename" == *"kathleen"* ]]; then
                dest_dir="$VOICES_DIR/en_US-kathleen"
            else
                dest_dir="$VOICES_DIR/misc"
            fi
            download_file "$url" "$dest_dir/$filename"
        done
    fi

    echo "Dependencies fetched successfully."
}

main "$@"

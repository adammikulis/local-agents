#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
BIN_DIR="${EXT_DIR}/bin"
OUTPUT_FILE=""
INCLUDE_RUNTIMES="false"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Emit a deterministic release artifact size report for regression checks.

Options:
  --bin-dir <path>      Directory to scan (default: ./bin).
  --include-runtimes    Include files under bin/runtimes.
  --output <path>       Write report to file (also prints to stdout).
  -h, --help            Show this help.
USAGE
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

file_size_bytes() {
    local path="$1"
    if stat -f%z "$path" >/dev/null 2>&1; then
        stat -f%z "$path"
    else
        stat -c%s "$path"
    fi
}

file_hash() {
    local path="$1"
    if command_exists sha256sum; then
        sha256sum "$path" | awk '{print $1}'
    elif command_exists shasum; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        echo "unavailable"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin-dir)
            [[ $# -lt 2 ]] && { echo "Error: --bin-dir expects a value" >&2; exit 1; }
            BIN_DIR="$2"
            shift 2
            ;;
        --include-runtimes)
            INCLUDE_RUNTIMES="true"
            shift
            ;;
        --output)
            [[ $# -lt 2 ]] && { echo "Error: --output expects a value" >&2; exit 1; }
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown option '$1'" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ! -d "$BIN_DIR" ]]; then
    echo "Error: bin directory not found: $BIN_DIR" >&2
    exit 1
fi

declare -a FILES=()
while IFS= read -r path; do
    FILES+=("$path")
done < <(find "$BIN_DIR" -type f \
    \( -name '*.dylib' -o -name '*.so' -o -name '*.so.*' -o -name '*.dll' -o -name '*.exe' -o -name 'llama-cli' -o -name 'llama-server' -o -name 'whisper' -o -name 'piper' -o -name 'piper_phonemize' \) \
    | LC_ALL=C sort)

if [[ "$INCLUDE_RUNTIMES" != "true" ]]; then
    declare -a FILTERED=()
    for f in "${FILES[@]}"; do
        if [[ "$f" == *"/runtimes/"* ]]; then
            continue
        fi
        FILTERED+=("$f")
    done
    FILES=("${FILTERED[@]}")
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "[warn] no release artifacts matched in ${BIN_DIR}" >&2
    echo "SIZE_BYTES SHA256 PATH"
    echo "TOTAL_BYTES 0"
    echo "FILES 0"
    exit 0
fi

report_tmp=$(mktemp)
{
    echo "SIZE_BYTES SHA256 PATH"
    total_bytes=0
    for path in "${FILES[@]}"; do
        size=$(file_size_bytes "$path")
        hash=$(file_hash "$path")
        rel_path=${path#"$BIN_DIR"/}
        printf "%s %s %s\n" "$size" "$hash" "$rel_path"
        total_bytes=$((total_bytes + size))
    done
    echo "TOTAL_BYTES ${total_bytes}"
    echo "FILES ${#FILES[@]}"
} >"$report_tmp"

cat "$report_tmp"
if [[ -n "$OUTPUT_FILE" ]]; then
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    cp -f "$report_tmp" "$OUTPUT_FILE"
fi
rm -f "$report_tmp"

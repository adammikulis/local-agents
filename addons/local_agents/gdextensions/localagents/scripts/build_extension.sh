#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
BUILD_DIR="${EXT_DIR}/build"
BIN_DIR="${EXT_DIR}/bin"

mkdir -p "${BUILD_DIR}" "${BIN_DIR}"

cmake -S "${EXT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD_DIR}" --target localagents --config Release
cmake --install "${BUILD_DIR}" --prefix "${EXT_DIR}"

case "$(uname -s)" in
    Darwin)
        mv -f "${BIN_DIR}/liblocalagents.macos.dylib" "${BIN_DIR}/localagents.macos.dylib" 2>/dev/null || true
        ;;
    Linux)
        mv -f "${BIN_DIR}/liblocalagents.linux.so" "${BIN_DIR}/localagents.linux.so" 2>/dev/null || true
        ;;
esac

echo "Build complete. Binaries available in ${BIN_DIR}."

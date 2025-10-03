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

        # Bundle llama / ggml shared libraries next to the extension and rewrite install names
        shopt -s nullglob
        for lib_path in "${BUILD_DIR}/bin"/libllama.dylib "${BUILD_DIR}/bin"/libggml*.dylib; do
            [[ -f "${lib_path}" ]] || continue
            lib_name=$(basename "${lib_path}")
            cp -f "${lib_path}" "${BIN_DIR}/${lib_name}"
        done
        shopt -u nullglob

        if command -v install_name_tool >/dev/null 2>&1; then
            dylibs=(localagents.macos.dylib libllama.dylib libggml.dylib libggml-cpu.dylib libggml-blas.dylib libggml-metal.dylib libggml-base.dylib)

            for lib in "${dylibs[@]}"; do
                target_path="${BIN_DIR}/${lib}"
                [[ -f "${target_path}" ]] || continue
                install_name_tool -id "@loader_path/${lib}" "${target_path}" 2>/dev/null || true
            done

            for dep in "${dylibs[@]:1}"; do
                dep_path="@loader_path/${dep}"
                for lib in "${dylibs[@]}"; do
                    target_path="${BIN_DIR}/${lib}"
                    [[ -f "${target_path}" ]] || continue
                    install_name_tool -change "@rpath/${dep}" "${dep_path}" "${target_path}" 2>/dev/null || true
                done
            done
        fi

        for tool in llama-cli llama-server; do
            tool_path="${BUILD_DIR}/bin/${tool}"
            if [[ -f "${tool_path}" ]]; then
                cp -f "${tool_path}" "${BIN_DIR}/${tool}"
            fi
        done
        ;;
    Linux)
        mv -f "${BIN_DIR}/liblocalagents.linux.so" "${BIN_DIR}/localagents.linux.so" 2>/dev/null || true

        for tool in llama-cli llama-server; do
            tool_path="${BUILD_DIR}/bin/${tool}"
            if [[ -f "${tool_path}" ]]; then
                cp -f "${tool_path}" "${BIN_DIR}/${tool}"
            fi
        done
        ;;
esac

echo "Build complete. Binaries available in ${BIN_DIR}."

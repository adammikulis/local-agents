#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
BUILD_DIR="${EXT_DIR}/build"
BIN_DIR="${EXT_DIR}/bin"
PLATFORM=""
GENERATOR=""
TOOLCHAIN_FILE=""
CMAKE_ARGS=()
CLEAN_BUILD="false"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --platform <macos|linux|windows>  Target platform for post-build packaging.
  --build-dir <path>                CMake build directory (default: ./build).
  --bin-dir <path>                  Output binary directory (default: ./bin).
  --generator <name>                CMake generator name.
  --toolchain <file>                CMake toolchain file for cross-compilation.
  --cmake-arg <arg>                 Extra argument passed to CMake configure step.
  --clean                           Remove the build directory before configure.
  -h, --help                        Show this help.
USAGE
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

host_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) echo "linux" ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT) echo "windows" ;;
        *) echo "" ;;
    esac
}

resolve_platform() {
    if [[ -n "$PLATFORM" ]]; then
        echo "$PLATFORM"
        return
    fi
    host_platform
}

warn() {
    echo "[warn] $*" >&2
}

collect_from_build_bin() {
    local pattern="$1"
    shopt -s nullglob
    for src in "${BUILD_DIR}/bin"/${pattern}; do
        [[ -f "$src" ]] || continue
        cp -f "$src" "${BIN_DIR}/$(basename "$src")"
    done
    shopt -u nullglob
}

patch_macos_install_names() {
    if ! command_exists install_name_tool || ! command_exists otool; then
        warn "install_name_tool/otool unavailable; skipping macOS install-name patching."
        return
    fi

    shopt -s nullglob
    for target_path in "${BIN_DIR}"/localagents.macos.dylib "${BIN_DIR}"/libllama*.dylib "${BIN_DIR}"/libggml*.dylib "${BIN_DIR}"/libmtmd*.dylib; do
        [[ -f "${target_path}" ]] || continue
        local target_name
        target_name=$(basename "${target_path}")
        install_name_tool -id "@loader_path/${target_name}" "${target_path}" 2>/dev/null || true

        while IFS= read -r dep_path; do
            [[ -n "${dep_path}" ]] || continue
            local dep_name
            dep_name=$(basename "${dep_path}")
            install_name_tool -change "${dep_path}" "@loader_path/${dep_name}" "${target_path}" 2>/dev/null || true
        done < <(otool -L "${target_path}" | awk '/@rpath\/lib.*\.dylib/{print $1}')
    done
    shopt -u nullglob
}

patch_linux_rpath() {
    if ! command_exists patchelf; then
        warn "patchelf unavailable; skipping linux RPATH normalization."
        return
    fi
    shopt -s nullglob
    for target_path in "${BIN_DIR}"/localagents.linux.so "${BIN_DIR}"/libllama*.so* "${BIN_DIR}"/libggml*.so* "${BIN_DIR}"/libmtmd*.so*; do
        [[ -f "${target_path}" ]] || continue
        patchelf --set-rpath '$ORIGIN' "${target_path}" 2>/dev/null || true
    done
    shopt -u nullglob
}

stage_tools() {
    local platform="$1"
    local tools=(llama-cli llama-server)
    if [[ "$platform" == "windows" ]]; then
        tools=(llama-cli.exe llama-server.exe)
    fi
    for tool in "${tools[@]}"; do
        local tool_path="${BUILD_DIR}/bin/${tool}"
        [[ -f "${tool_path}" ]] || continue
        cp -f "${tool_path}" "${BIN_DIR}/${tool}"
        chmod +x "${BIN_DIR}/${tool}" 2>/dev/null || true
    done
}

package_artifacts() {
    local platform="$1"
    case "$platform" in
        macos)
            mv -f "${BIN_DIR}/liblocalagents.macos.dylib" "${BIN_DIR}/localagents.macos.dylib" 2>/dev/null || true
            collect_from_build_bin "libllama*.dylib"
            collect_from_build_bin "libggml*.dylib"
            collect_from_build_bin "libmtmd*.dylib"
            patch_macos_install_names
            stage_tools "$platform"
            ;;
        linux)
            mv -f "${BIN_DIR}/liblocalagents.linux.so" "${BIN_DIR}/localagents.linux.so" 2>/dev/null || true
            collect_from_build_bin "libllama*.so*"
            collect_from_build_bin "libggml*.so*"
            collect_from_build_bin "libmtmd*.so*"
            patch_linux_rpath
            stage_tools "$platform"
            ;;
        windows)
            mv -f "${BIN_DIR}/liblocalagents.windows.dll" "${BIN_DIR}/localagents.windows.dll" 2>/dev/null || true
            collect_from_build_bin "localagents.windows.dll"
            collect_from_build_bin "liblocalagents.windows.dll"
            collect_from_build_bin "*.dll"
            stage_tools "$platform"
            ;;
        *)
            warn "unknown platform '${platform}'; skipping packaging steps."
            ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            [[ $# -lt 2 ]] && { echo "Error: --platform expects a value" >&2; exit 1; }
            PLATFORM="$2"
            shift 2
            ;;
        --build-dir)
            [[ $# -lt 2 ]] && { echo "Error: --build-dir expects a value" >&2; exit 1; }
            BUILD_DIR="$2"
            shift 2
            ;;
        --bin-dir)
            [[ $# -lt 2 ]] && { echo "Error: --bin-dir expects a value" >&2; exit 1; }
            BIN_DIR="$2"
            shift 2
            ;;
        --generator)
            [[ $# -lt 2 ]] && { echo "Error: --generator expects a value" >&2; exit 1; }
            GENERATOR="$2"
            shift 2
            ;;
        --toolchain)
            [[ $# -lt 2 ]] && { echo "Error: --toolchain expects a value" >&2; exit 1; }
            TOOLCHAIN_FILE="$2"
            shift 2
            ;;
        --cmake-arg)
            [[ $# -lt 2 ]] && { echo "Error: --cmake-arg expects a value" >&2; exit 1; }
            CMAKE_ARGS+=("$2")
            shift 2
            ;;
        --clean)
            CLEAN_BUILD="true"
            shift
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

if ! command_exists cmake; then
    echo "Error: cmake not found in PATH." >&2
    exit 1
fi

TARGET_PLATFORM=$(resolve_platform)
if [[ -z "$TARGET_PLATFORM" ]]; then
    echo "Error: unable to resolve target platform. Pass --platform explicitly." >&2
    exit 1
fi

if [[ "$CLEAN_BUILD" == "true" ]]; then
    rm -rf "${BUILD_DIR}"
fi

mkdir -p "${BUILD_DIR}" "${BIN_DIR}"

configure_cmd=(cmake -S "${EXT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release)
if [[ -n "$GENERATOR" ]]; then
    configure_cmd+=(-G "${GENERATOR}")
fi
if [[ -n "$TOOLCHAIN_FILE" ]]; then
    configure_cmd+=(-DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN_FILE}")
fi
if [[ ${#CMAKE_ARGS[@]} -gt 0 ]]; then
    configure_cmd+=("${CMAKE_ARGS[@]}")
fi

"${configure_cmd[@]}"
cmake --build "${BUILD_DIR}" --target localagents --config Release
cmake --install "${BUILD_DIR}" --prefix "${EXT_DIR}"

package_artifacts "${TARGET_PLATFORM}"

echo "Build complete. Binaries available in ${BIN_DIR}."

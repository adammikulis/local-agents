#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
BUILD_SCRIPT="${SCRIPT_DIR}/build_extension.sh"
BIN_ROOT="${EXT_DIR}/bin"
BUILD_ROOT="${EXT_DIR}/build"

TARGETS=("macos" "linux" "windows")
FORCE_CLEAN="false"
REQUESTED_TARGETS=()

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Builds localagents extension artifacts for macOS, Linux, and Windows in separate
build directories. Targets unsupported by the current host are skipped with warnings.

Options:
  --target <name>     Build only one target (may be repeated): macos, linux, windows.
  --clean             Remove per-target build directories before each build.
  -h, --help          Show this help.

Environment:
  LOCAL_AGENTS_TOOLCHAIN_MACOS    CMake toolchain file for macOS target.
  LOCAL_AGENTS_TOOLCHAIN_LINUX    CMake toolchain file for Linux target.
  LOCAL_AGENTS_TOOLCHAIN_WINDOWS  CMake toolchain file for Windows target.
USAGE
}

warn() {
    echo "[warn] $*" >&2
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

toolchain_var_name() {
    case "$1" in
        macos) echo "LOCAL_AGENTS_TOOLCHAIN_MACOS" ;;
        linux) echo "LOCAL_AGENTS_TOOLCHAIN_LINUX" ;;
        windows) echo "LOCAL_AGENTS_TOOLCHAIN_WINDOWS" ;;
        *) echo "" ;;
    esac
}

detect_windows_cross_cmake_args() {
    local args=()
    if command_exists x86_64-w64-mingw32-gcc && command_exists x86_64-w64-mingw32-g++; then
        args+=("--cmake-arg" "-DCMAKE_SYSTEM_NAME=Windows")
        args+=("--cmake-arg" "-DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc")
        args+=("--cmake-arg" "-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++")
    fi
    printf "%s\n" "${args[@]}"
}

target_is_supported() {
    local target="$1" host="$2"
    local toolchain_var
    toolchain_var=$(toolchain_var_name "$target")
    local toolchain_path="${!toolchain_var:-}"

    if [[ "$target" == "$host" ]]; then
        return 0
    fi
    if [[ -n "$toolchain_path" && -f "$toolchain_path" ]]; then
        return 0
    fi
    if [[ "$target" == "windows" ]]; then
        if command_exists x86_64-w64-mingw32-gcc && command_exists x86_64-w64-mingw32-g++; then
            return 0
        fi
    fi
    return 1
}

build_target() {
    local target="$1" host="$2"
    local build_dir="${BUILD_ROOT}/${target}-release"
    local target_bin_dir="${BIN_ROOT}/${target}"
    local cmd=("${BUILD_SCRIPT}" "--platform" "$target" "--build-dir" "$build_dir" "--bin-dir" "$target_bin_dir")
    local toolchain_var
    toolchain_var=$(toolchain_var_name "$target")
    local toolchain_path="${!toolchain_var:-}"

    if [[ "$FORCE_CLEAN" == "true" ]]; then
        rm -rf "$build_dir"
    fi

    if [[ -n "$toolchain_path" ]]; then
        if [[ -f "$toolchain_path" ]]; then
            cmd+=("--toolchain" "$toolchain_path")
        else
            warn "${toolchain_var} is set but file does not exist: ${toolchain_path}"
        fi
    elif [[ "$target" == "windows" && "$host" != "windows" ]]; then
        mapfile -t cross_args < <(detect_windows_cross_cmake_args)
        if [[ ${#cross_args[@]} -gt 0 ]]; then
            cmd+=("${cross_args[@]}")
        fi
    fi

    mkdir -p "$target_bin_dir"
    echo "[build] target=${target}"
    if ! "${cmd[@]}"; then
        warn "build failed for ${target}; continuing with remaining targets."
        return 1
    fi
    return 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            [[ $# -lt 2 ]] && { echo "Error: --target expects a value" >&2; exit 1; }
            REQUESTED_TARGETS+=("$2")
            shift 2
            ;;
        --clean)
            FORCE_CLEAN="true"
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
if [[ ! -x "$BUILD_SCRIPT" ]]; then
    echo "Error: build script missing or not executable: $BUILD_SCRIPT" >&2
    exit 1
fi

if [[ ${#REQUESTED_TARGETS[@]} -eq 0 ]]; then
    REQUESTED_TARGETS=("${TARGETS[@]}")
fi

HOST=$(host_platform)
if [[ -z "$HOST" ]]; then
    warn "unknown host platform; only explicitly configured toolchain targets may build."
fi

declare -i built_count=0
declare -i failed_count=0
declare -i skipped_count=0

for target in "${REQUESTED_TARGETS[@]}"; do
    case "$target" in
        macos|linux|windows) ;;
        *)
            warn "unknown target '${target}' (supported: macos, linux, windows)"
            skipped_count+=1
            continue
            ;;
    esac

    if ! target_is_supported "$target" "$HOST"; then
        warn "skipping ${target}: no host support and no configured toolchain."
        skipped_count+=1
        continue
    fi

    if build_target "$target" "$HOST"; then
        built_count+=1
    else
        failed_count+=1
    fi
done

echo "[summary] built=${built_count} failed=${failed_count} skipped=${skipped_count}"
if (( built_count == 0 && failed_count > 0 )); then
    exit 1
fi

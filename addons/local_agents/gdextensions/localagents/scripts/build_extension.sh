#!/usr/bin/env bash
# godot-cpp and llama.cpp are built ONCE per (dependency commit, compiler, cmake, platform, flags) into
# ${LA_DEPS_CACHE:-$HOME/.cache/local-agents/extdeps}/<key>, outside every worktree and gitignored by
# living outside the tree. A worktree whose key matches links the cached artifacts and compiles only the
# extension's own sources. --clean-deps discards the entry for the current key.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
BUILD_DIR="${EXT_DIR}/build"
BIN_DIR="${EXT_DIR}/bin"
THIRDPARTY_DIR="${EXT_DIR}/thirdparty"
DEPS_CACHE_ROOT="${LA_DEPS_CACHE:-${HOME}/.cache/local-agents/extdeps}"
PLATFORM=""
GENERATOR=""
TOOLCHAIN_FILE=""
CMAKE_ARGS=()
CLEAN_BUILD="false"
CLEAN_DEPS="false"

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
  --clean-deps                      Remove this key's dependency cache entry, forcing a refill.
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
    for src in "${DEPS_BIN}"/${pattern}; do
        [[ -f "$src" ]] || continue
        cp -f "$src" "${BIN_DIR}/$(basename "$src")"
    done
    shopt -u nullglob
}

# The sources this bin was built from; lib_godot.sh refuses to launch a bin whose hash differs.
write_source_hash() {
    (cd "${EXT_DIR}" && cat CMakeLists.txt cmake/deps/CMakeLists.txt $(ls src/* include/* | sort) | md5 -q) > "${BIN_DIR}/SOURCE_HASH"
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

# An absolute path into a package manager is the build machine's, not the user's: a dylib linked against
# /opt/homebrew is missing on every Mac without that exact install. Copy each such dependency in beside
# the binaries and point at it with @loader_path, following the copies' own dependencies as they arrive.
vendor_macos_dependencies() {
    if ! command_exists install_name_tool || ! command_exists otool; then
        warn "install_name_tool/otool unavailable; skipping macOS dependency vendoring."
        return
    fi
    local queue=() i=0 target dep name
    shopt -s nullglob
    for target in "${BIN_DIR}"/*.dylib "${BIN_DIR}"/llama-cli "${BIN_DIR}"/llama-server; do
        [[ -f "${target}" ]] && queue+=("${target}")
    done
    shopt -u nullglob
    while (( i < ${#queue[@]} )); do
        target="${queue[$i]}"
        i=$((i + 1))
        while IFS= read -r dep; do
            [[ -n "${dep}" ]] || continue
            name=$(basename "${dep}")
            if [[ ! -f "${BIN_DIR}/${name}" ]]; then
                if [[ ! -f "${dep}" ]]; then
                    warn "vendoring: ${target} needs ${dep}, which is not on this machine."
                    continue
                fi
                cp -f "${dep}" "${BIN_DIR}/${name}"
                chmod u+w "${BIN_DIR}/${name}"
                install_name_tool -id "@loader_path/${name}" "${BIN_DIR}/${name}" 2>/dev/null || true
                queue+=("${BIN_DIR}/${name}")
            fi
            install_name_tool -change "${dep}" "@loader_path/${name}" "${target}" 2>/dev/null || true
        done < <(otool -L "${target}" | tail -n +2 | awk '{print $1}' | grep -E '^/(opt/homebrew|usr/local)/' || true)
        # install_name_tool invalidates the signature, and an arm64 binary without one will not load.
        command_exists codesign && codesign --force --sign - "${target}" >/dev/null 2>&1 || true
    done
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

# Make a staged executable load its sibling libraries out of its own directory.
#
# patch_macos_install_names/patch_linux_rpath only walk the LIBRARIES (localagents.*, libllama*,
# libggml*, libmtmd*), and stage_tools copies the executables in afterwards, so llama-cli and
# llama-server kept whatever absolute rpath the build machine baked in. A shipped llama-server then
# only ran on the machine it was built on, from that exact build directory: everywhere else it died
# with `Library not loaded: @rpath/libmtmd.0.dylib`, which took the whole llama_server backend down.
normalize_tool_linkage() {
    local target_path="$1"
    local platform="$2"
    case "$platform" in
        macos)
            command_exists install_name_tool && command_exists otool || return 0
            # Drop every absolute rpath the builder left behind, then point at the tool's own dir.
            while IFS= read -r rpath; do
                [[ -n "${rpath}" ]] || continue
                install_name_tool -delete_rpath "${rpath}" "${target_path}" 2>/dev/null || true
            done < <(otool -l "${target_path}" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}')
            install_name_tool -add_rpath "@loader_path" "${target_path}" 2>/dev/null || true
            # The libs were rewritten to @loader_path ids, so match that here too.
            while IFS= read -r dep_path; do
                [[ -n "${dep_path}" ]] || continue
                install_name_tool -change "${dep_path}" "@loader_path/$(basename "${dep_path}")" \
                    "${target_path}" 2>/dev/null || true
            done < <(otool -L "${target_path}" | awk '/@rpath\/lib.*\.dylib/{print $1}')
            ;;
        linux)
            command_exists patchelf || return 0
            patchelf --set-rpath '$ORIGIN' "${target_path}" 2>/dev/null || true
            ;;
    esac
}

stage_tools() {
    local platform="$1"
    local tools=(llama-cli llama-server)
    if [[ "$platform" == "windows" ]]; then
        tools=(llama-cli.exe llama-server.exe)
    fi
    for tool in "${tools[@]}"; do
        local tool_path="${DEPS_BIN}/${tool}"
        [[ -f "${tool_path}" ]] || continue
        cp -f "${tool_path}" "${BIN_DIR}/${tool}"
        chmod +x "${BIN_DIR}/${tool}" 2>/dev/null || true
        normalize_tool_linkage "${BIN_DIR}/${tool}" "$platform"
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
            vendor_macos_dependencies
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
    write_source_hash
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
        --clean-deps)
            CLEAN_DEPS="true"
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

LAUNCHER_ARGS=()
if command_exists ccache; then
    LAUNCHER_ARGS=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

# CONTENT, NEVER MTIME: the dependency commits actually checked out, the recipe that builds them, and the
# toolchain that compiles them. Anything that changes the artifacts changes this.
deps_key() {
    {
        git -C "${THIRDPARTY_DIR}/godot-cpp" rev-parse HEAD 2>/dev/null || echo "no-godot-cpp"
        git -C "${THIRDPARTY_DIR}/llama.cpp" rev-parse HEAD 2>/dev/null || echo "no-llama-cpp"
        cat "${EXT_DIR}/cmake/deps/CMakeLists.txt"
        printf '%s\n' "${TARGET_PLATFORM}" "$(uname -m)" "Release" "${LAUNCHER_ARGS[*]:-}"
        "${CXX:-c++}" --version 2>/dev/null | head -1
        cmake --version | head -1
    } | md5 -q
}

DEPS_KEY="$(deps_key)"
DEPS_DIR="${DEPS_CACHE_ROOT}/${DEPS_KEY}"
DEPS_BUILD="${DEPS_DIR}/build"
DEPS_BIN="${DEPS_BUILD}/bin"
if [[ "$CLEAN_DEPS" == "true" ]]; then
    rm -rf "${DEPS_DIR}"
fi

# Two lanes may reach an empty entry together. The loser waits for the winner's READY rather than
# configuring a second cmake into the same tree.
mkdir -p "${DEPS_CACHE_ROOT}"
LOCK="${DEPS_DIR}.lock"
waited=0
while [[ ! -f "${DEPS_DIR}/READY" ]]; do
    if mkdir "${LOCK}" 2>/dev/null; then
        echo $$ > "${LOCK}/pid"
        trap 'rm -rf "${LOCK}"' EXIT
        echo "[deps] filling ${DEPS_DIR} (key ${DEPS_KEY})"
        mkdir -p "${DEPS_BUILD}"
        cmake -S "${EXT_DIR}/cmake/deps" -B "${DEPS_BUILD}" -DCMAKE_BUILD_TYPE=Release \
            -DGODOT_CPP_DIR="${THIRDPARTY_DIR}/godot-cpp" -DLLAMA_CPP_DIR="${THIRDPARTY_DIR}/llama.cpp" \
            ${LAUNCHER_ARGS[@]+"${LAUNCHER_ARGS[@]}"}
        cmake --build "${DEPS_BUILD}" --target la_deps --config Release \
            --parallel "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
        [[ -f "${DEPS_BUILD}/la_deps.cmake" ]] || { echo "Error: the dependency build produced no la_deps.cmake." >&2; exit 1; }
        touch "${DEPS_DIR}/READY"
        rm -rf "${LOCK}"
        trap - EXIT
        break
    fi
    owner="$(cat "${LOCK}/pid" 2>/dev/null || echo "")"
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
        echo "[deps] clearing a lock left by dead pid ${owner}" >&2
        rm -rf "${LOCK}"
        continue
    fi
    if (( waited >= 1800 )); then
        echo "Error: waited ${waited}s for another build to fill ${DEPS_DIR}." >&2
        exit 1
    fi
    sleep 5
    waited=$(( waited + 5 ))
done

configure_cmd=(cmake -S "${EXT_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release
    -DLOCAL_AGENTS_DEPS_BUILD="${DEPS_BUILD}" ${LAUNCHER_ARGS[@]+"${LAUNCHER_ARGS[@]}"})
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
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
cmake --build "${BUILD_DIR}" --target localagents --config Release --parallel "${JOBS}"
cmake --install "${BUILD_DIR}" --prefix "${EXT_DIR}"

# Editor diagnostics read the repo-root .clangd, which points at this database.
ln -sf "${BUILD_DIR}/compile_commands.json" "${EXT_DIR}/compile_commands.json" 2>/dev/null || true

package_artifacts "${TARGET_PLATFORM}"

echo "Build complete. Binaries available in ${BIN_DIR}."

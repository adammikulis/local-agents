#!/usr/bin/env bash
# glslang and SPIRV-Cross are built ONCE per (dependency commit, recipe, platform, toolchain) into
# ${LA_NATIVE_DEPS_CACHE:-$HOME/.cache/local-agents/nativedeps}/<key>, outside every worktree. The entry
# names its own paths relative to itself, so any worktree whose key matches links it and compiles only
# lasim's own sources.
set -euo pipefail

NATIVE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "${NATIVE_DIR}/../../../scripts/lib_import.sh"
BUILD_DIR="${NATIVE_DIR}/build"
THIRDPARTY_DIR="${NATIVE_DIR}/thirdparty"
CACHE_ROOT="${LA_NATIVE_DEPS_CACHE:-${HOME}/.cache/local-agents/nativedeps}"
CLEAN_BUILD="false"
CLEAN_DEPS="false"
PRINT_KEY="false"
TARGET=""

usage() {
	cat <<USAGE
Usage: $(basename "$0") [--clean] [--clean-deps] [--print-deps-key] [--target NAME]
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="$2"; shift 2 ;;
		--clean) CLEAN_BUILD="true"; shift ;;
		--clean-deps) CLEAN_DEPS="true"; shift ;;
		--print-deps-key) PRINT_KEY="true"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Error: unknown option '$1'" >&2; usage; exit 1 ;;
	esac
done

command -v cmake >/dev/null 2>&1 || { echo "Error: cmake not in PATH." >&2; exit 1; }

LAUNCHER_ARGS=()
if command -v ccache >/dev/null 2>&1; then
	LAUNCHER_ARGS=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

# CONTENT, NEVER MTIME: the pinned dependency commits, the recipe that builds them, and the toolchain
# that compiles them. Anything that changes the staged artifacts changes this.
deps_key() {
	{
		"${NATIVE_DIR}/scripts/fetch_dependencies.sh" --print-refs
		cat "${NATIVE_DIR}/cmake/deps/CMakeLists.txt"
		printf '%s\n' "$(uname -s)" "$(uname -m)" "Release" "${LAUNCHER_ARGS[*]:-}"
		"${CXX:-c++}" --version 2>/dev/null | head -1
		cmake --version | head -1
	} | la_md5_stdin || {
		echo "Error: no MD5 tool is available, so this tree cannot name its cache entry." >&2
		exit 1
	}
}

DEPS_KEY="$(deps_key)"
if [ "$PRINT_KEY" = "true" ]; then
	echo "${DEPS_KEY}"
	exit 0
fi

DEPS_DIR="${CACHE_ROOT}/${DEPS_KEY}"
[ "$CLEAN_DEPS" = "true" ] && rm -rf "${DEPS_DIR}"
[ "$CLEAN_BUILD" = "true" ] && rm -rf "${BUILD_DIR}"

if [ ! -f "${DEPS_DIR}/READY" ]; then
	"${NATIVE_DIR}/scripts/fetch_dependencies.sh"
	mkdir -p "${DEPS_DIR}/build"
	cmake -S "${NATIVE_DIR}/cmake/deps" -B "${DEPS_DIR}/build" -DCMAKE_BUILD_TYPE=Release \
		-DGLSLANG_DIR="${THIRDPARTY_DIR}/glslang" -DSPIRV_CROSS_DIR="${THIRDPARTY_DIR}/SPIRV-Cross" \
		-DLA_NATIVE_DEPS_ENTRY="${DEPS_DIR}" ${LAUNCHER_ARGS[@]+"${LAUNCHER_ARGS[@]}"}
	cmake --build "${DEPS_DIR}/build" --target la_native_deps --config Release \
		--parallel "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
	[ -f "${DEPS_DIR}/la_native_deps.cmake" ] || {
		echo "Error: the dependency build produced no la_native_deps.cmake." >&2
		exit 1
	}
	# The build tree names the worktree it was configured in; the staged entry must not carry that.
	rm -rf "${DEPS_DIR}/build"
	touch "${DEPS_DIR}/READY"
fi

cmake -S "${NATIVE_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release \
	-DLA_NATIVE_DEPS_ENTRY="${DEPS_DIR}" ${LAUNCHER_ARGS[@]+"${LAUNCHER_ARGS[@]}"}
build_cmd=(cmake --build "${BUILD_DIR}" --config Release
	--parallel "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)")
[ -n "$TARGET" ] && build_cmd+=(--target "$TARGET")
"${build_cmd[@]}"
echo "Build complete. Binaries in ${NATIVE_DIR}/bin."

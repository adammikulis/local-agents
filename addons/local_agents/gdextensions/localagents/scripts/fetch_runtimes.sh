#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
RUNTIME_ROOT="${EXT_DIR}/bin/runtimes"
WHISPER_ROOT="${EXT_DIR}/thirdparty/whisper.cpp"

PIPER_VERSION="2023.11.14-2"
PIPER_BASE_URL="https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}"
PIPER_PHONEMIZE_VERSION="2023.11.14-4"
PIPER_PHONEMIZE_BASE_URL="https://github.com/rhasspy/piper-phonemize/releases/download/${PIPER_PHONEMIZE_VERSION}"

SUPPORTED_PLATFORMS=(
    "macos_arm64 tar piper_macos_aarch64.tar.gz piper-phonemize_macos_aarch64.tar.gz"
    "macos_x86_64 tar piper_macos_x64.tar.gz piper-phonemize_macos_x64.tar.gz"
    "linux_x86_64 tar piper_linux_x86_64.tar.gz"
    "linux_aarch64 tar piper_linux_aarch64.tar.gz"
    "linux_armv7l tar piper_linux_armv7l.tar.gz"
    "windows_x86_64 zip piper_windows_amd64.zip piper-phonemize_windows_amd64.zip"
)

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--platform <name>] [--all] [--skip-whisper] [--force]

Options:
  --platform <name>   Fetch runtimes for the given platform (may be passed multiple times).
                      Supported: macos_arm64, macos_x86_64, linux_x86_64, linux_aarch64, linux_armv7l, windows_x86_64
  --all               Fetch runtimes for every supported platform.
  --skip-whisper      Skip building whisper.cpp binary for the current host.
  --force             Re-download assets even if the destination directory already exists.
  -h, --help          Show this help.

By default the script fetches runtimes for the host platform and builds whisper.cpp.
USAGE
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

host_platform() {
    local uname_s=$(uname -s)
    local uname_m=$(uname -m)
    case "${uname_s}" in
        Darwin)
            if [[ "${uname_m}" == "arm64" ]]; then
                echo "macos_arm64"
            else
                echo "macos_x86_64"
            fi
            ;;
        Linux)
            case "${uname_m}" in
                x86_64) echo "linux_x86_64" ;;
                aarch64|arm64) echo "linux_aarch64" ;;
                armv7l) echo "linux_armv7l" ;;
                *) echo "" ;;
            esac
            ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
            echo "windows_x86_64"
            ;;
        *)
            echo ""
            ;;
    esac
}

ensure_tools() {
    local tools=(curl tar rsync)
    if ! command_exists unzip; then
        tools+=(unzip)
    fi
    for tool in "${tools[@]}"; do
        if ! command_exists "$tool"; then
            echo "Error: required tool '$tool' not found in PATH" >&2
            exit 1
        fi
    done
    if ! command_exists cmake; then
        echo "Warning: cmake not found. whisper.cpp binaries will not be rebuilt." >&2
    fi
}

fetch_archive() {
    local url="$1" dest="$2"
    if [[ -f "$dest" ]]; then
        echo "[skip] $(basename "$dest") already downloaded"
        return
    fi
    echo "[curl] $url"
    curl -L --fail --progress-bar "$url" -o "$dest"
}

clean_and_create() {
    local path="$1"
    mkdir -p "$path"
    rm -rf "$path"/*
}

copy_piper_payload() {
    local extract_dir="$1" platform="$2" dest="$3"
    local payload_dir="$extract_dir/piper"
    if [[ ! -d "$payload_dir" ]]; then
        echo "Error: expected directory '$payload_dir' missing in archive" >&2
        exit 1
    fi
    rsync -a --delete "$payload_dir/" "$dest/"
    rm -rf "$dest"/*.dSYM
}

merge_phonemize_libs() {
    local extract_dir="$1" dest="$2"
    local lib_root
    if [[ -d "$extract_dir/piper-phonemize/lib" ]]; then
        lib_root="$extract_dir/piper-phonemize/lib"
    elif [[ -d "$extract_dir/piper-phonemize/bin" ]]; then
        lib_root="$extract_dir/piper-phonemize/bin"
    else
        echo "Warning: piper-phonemize archive missing expected lib/bin directory" >&2
        return
    fi
    rsync -a "$lib_root/" "$dest/"
    # Also mirror espeak data if provided under share/
    if [[ -d "$extract_dir/piper-phonemize/share/espeak-ng-data" && ! -d "$dest/espeak-ng-data" ]]; then
        rsync -a "$extract_dir/piper-phonemize/share/espeak-ng-data/" "$dest/espeak-ng-data/"
    fi
}

patch_macos_binaries() {
    local dest="$1"
    if ! command_exists install_name_tool; then
        echo "Warning: install_name_tool not found; macOS binaries may require manual RPATH patching." >&2
        return
    fi
    local libs=(
        "libespeak-ng.1.52.0.1.dylib"
        "libpiper_phonemize.1.2.0.dylib"
        "libonnxruntime.1.14.1.dylib"
    )
    for lib in "${libs[@]}"; do
        local lib_path="${dest}/${lib}"
        [[ -f "$lib_path" ]] || continue
        install_name_tool -id "@loader_path/${lib}" "$lib_path" 2>/dev/null || true
        install_name_tool -add_rpath "@loader_path" "$lib_path" 2>/dev/null || true
        install_name_tool -change "@rpath/libespeak-ng.1.dylib" "@loader_path/libespeak-ng.1.dylib" "$lib_path" 2>/dev/null || true
        install_name_tool -change "@rpath/libonnxruntime.1.14.1.dylib" "@loader_path/libonnxruntime.1.14.1.dylib" "$lib_path" 2>/dev/null || true
    done
    for bin in piper piper_phonemize; do
        local bin_path="${dest}/${bin}"
        [[ -f "$bin_path" ]] || continue
        install_name_tool -add_rpath "@loader_path" "$bin_path" 2>/dev/null || true
        install_name_tool -change "@rpath/libespeak-ng.1.dylib" "@loader_path/libespeak-ng.1.dylib" "$bin_path" 2>/dev/null || true
        install_name_tool -change "@rpath/libpiper_phonemize.1.dylib" "@loader_path/libpiper_phonemize.1.dylib" "$bin_path" 2>/dev/null || true
        install_name_tool -change "@rpath/libonnxruntime.1.14.1.dylib" "@loader_path/libonnxruntime.1.14.1.dylib" "$bin_path" 2>/dev/null || true
    done
}

build_whisper() {
    local platform="$1" dest="$2"
    if ! command_exists cmake; then
        echo "[skip] cmake missing; whisper binary not rebuilt" >&2
        return
    fi
    if [[ ! -d "$WHISPER_ROOT" ]]; then
        echo "[skip] whisper.cpp sources missing. Run fetch_dependencies.sh first." >&2
        return
    fi
    local build_dir="${WHISPER_ROOT}/build/${platform}"
    mkdir -p "$build_dir"
    echo "[cmake] Generating whisper.cpp build for ${platform}"
    cmake -S "$WHISPER_ROOT" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release >/dev/null
    echo "[cmake] Building whisper.cpp"
    cmake --build "$build_dir" --target whisper-cli --config Release >/dev/null
    local src
    local dest_name="whisper"
    if [[ "$platform" == windows_* ]]; then
        src="$build_dir/bin/whisper-cli.exe"
        dest_name="whisper.exe"
    else
        src="$build_dir/bin/whisper-cli"
    fi
    if [[ ! -f "$src" ]]; then
        echo "Warning: whisper binary not found at $src" >&2
        return
    fi
    cp "$src" "$dest/${dest_name}"
    chmod +x "$dest/${dest_name}" 2>/dev/null || true
}

fetch_platform() {
    local platform="$1" force="$2" skip_whisper="$3"
    local archive_type="$4"
    local piper_archive="$5"
    local phonemize_archive="${6:-}"

    local dest="${RUNTIME_ROOT}/${platform}"
    if [[ -d "$dest" && "$force" != "true" ]]; then
        echo "[skip] ${platform} runtime already present (use --force to rebuild)"
    else
        clean_and_create "$dest"
        local tmpdir
        tmpdir=$(mktemp -d)
        local piper_url="${PIPER_BASE_URL}/${piper_archive}"
        local piper_path="${tmpdir}/${piper_archive}"
        fetch_archive "$piper_url" "$piper_path"
        case "$archive_type" in
            tar)
                tar -xzf "$piper_path" -C "$tmpdir"
                ;;
            zip)
                unzip -q "$piper_path" -d "$tmpdir"
                ;;
            *)
                echo "Error: unknown archive type '$archive_type'"
                rm -rf "$tmpdir"
                exit 1
                ;;
        esac
        copy_piper_payload "$tmpdir" "$platform" "$dest"

        if [[ -n "$phonemize_archive" ]]; then
            local phonemize_url phonemize_path
            if [[ "$archive_type" == "zip" && "$phonemize_archive" == "piper-phonemize_windows_amd64.zip" ]]; then
                phonemize_url="${PIPER_PHONEMIZE_BASE_URL}/${phonemize_archive}"
            else
                phonemize_url="${PIPER_PHONEMIZE_BASE_URL}/${phonemize_archive}"
            fi
            phonemize_path="${tmpdir}/${phonemize_archive}"
            fetch_archive "$phonemize_url" "$phonemize_path"
            case "$phonemize_archive" in
                *.tar.gz) tar -xzf "$phonemize_path" -C "$tmpdir" ;;
                *.zip) unzip -q "$phonemize_path" -d "$tmpdir" ;;
                *) echo "Warning: unknown phonemize archive format for ${phonemize_archive}" ;;
            esac
            merge_phonemize_libs "$tmpdir" "$dest"
        fi

        if [[ "$platform" == macos_* ]]; then
            patch_macos_binaries "$dest"
        fi

        chmod +x "$dest"/piper* 2>/dev/null || true
        rm -rf "$tmpdir"
        echo "[ok] Runtime payload staged at ${dest}"
    fi

    if [[ "$skip_whisper" != "true" ]]; then
        build_whisper "$platform" "$dest"
    fi
}

main() {
    ensure_tools

    local platforms=()
    local force="false"
    local skip_whisper="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --platform)
                [[ $# -lt 2 ]] && { echo "Error: --platform expects a value" >&2; exit 1; }
                platforms+=("$2")
                shift 2
                ;;
            --all)
                platforms=("all")
                shift
                ;;
            --skip-whisper)
                skip_whisper="true"
                shift
                ;;
            --force)
                force="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done

    if [[ ${#platforms[@]} -eq 0 ]]; then
        local host
        host=$(host_platform)
        if [[ -z "$host" ]]; then
            echo "Error: unsupported host platform; specify --platform manually" >&2
            exit 1
        fi
        platforms=("$host")
    fi

    if [[ "${platforms[*]}" == "all" ]]; then
        platforms=()
        for entry in "${SUPPORTED_PLATFORMS[@]}"; do
            platforms+=("$(awk '{print $1}' <<<"$entry")")
        done
    fi

    mkdir -p "$RUNTIME_ROOT"

    for platform in "${platforms[@]}"; do
        local match=""
        for entry in "${SUPPORTED_PLATFORMS[@]}"; do
            read -r name type archive phonemize <<<"$entry"
            if [[ "$platform" == "$name" ]]; then
                match="yes"
                local build_copy="$force"
                fetch_platform "$name" "$build_copy" "$skip_whisper" "$type" "$archive" "$phonemize"
                break
            fi
        done
        if [[ -z "$match" ]]; then
            echo "Warning: platform '$platform' not recognised" >&2
        fi
    done

    if [[ "$skip_whisper" == "true" ]]; then
        echo "[skip] whisper build disabled via flag"
    fi
}

main "$@"

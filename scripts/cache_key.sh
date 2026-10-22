#!/usr/bin/env bash
# THE ONE CONTENT ADDRESS every cache in this tree is keyed by. An mtime answers "when"; the question a
# cache asks is always "what".
#   scripts/cache_key.sh <kind> [--path DIR] [name=value ...]   kinds: import | scan | capture | bake (capture less docs/BAKE_KEY_EXCLUDED)
# A caller making many keys may pass engine=<hash> itself rather than pay the engine hash each time.
# Prints one hex digest. EXIT 0 · 2 no key, and a caller without one takes the miss.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_file_hash.sh"
require_tool git
require_tool python3

KIND="${1:-}"
[ -n "$KIND" ] || { echo "cache_key: no kind. Try import | scan | capture | bake." >&2; exit 2; }
shift
PROJ="$ROOT"
EXTRA=()
while [ $# -gt 0 ]; do
	case "$1" in
		--path) PROJ="$2"; shift 2 ;;
		*) EXTRA+=("$1"); shift ;;
	esac
done
[ -f "$PROJ/project.godot" ] || { echo "cache_key: no project.godot under $PROJ" >&2; exit 2; }

case "$KIND" in
	import) ;;
	scan|capture|bake)
		SH_FILE="$PROJ/addons/local_agents/gdextensions/localagents/bin/SOURCE_HASH"
		EXTRA+=("extension=$(cat "$SH_FILE" 2>/dev/null || echo absent)")
		;;
	*) echo "cache_key: unknown kind '$KIND'." >&2; exit 2 ;;
esac
# The importer IS the engine binary, so its content is an input. Asking it its version would be a
# direct launch, and every launch in this tree goes through la_godot.
case " ${EXTRA[*]-} " in *" engine="*) GIVEN_ENGINE=1 ;; *) GIVEN_ENGINE=0 ;; esac
if [ "$GIVEN_ENGINE" -eq 0 ]; then
GODOT_BIN="$(command -v "${GODOT:-godot}" 2>/dev/null || echo "")"
[ -n "$GODOT_BIN" ] || { echo "cache_key: no godot on PATH, so no key describes what would import." >&2; exit 2; }
EXTRA+=("engine=$(la_md5_memo "$GODOT_BIN")")
fi

python3 - "$PROJ" "$KIND" "${EXTRA[@]}" <<'PY'
import hashlib, os, subprocess, sys

proj, kind = sys.argv[1], sys.argv[2]
extra = sys.argv[3:]
# scripts/ decides which run a capture is; an import or a scan is the engine reading the project.
# A run, unlike an import or a scan, also opens the two declared data files.
paths = ["addons", "project.godot"]
if kind in ("capture", "bake"):
	paths += ["scripts", "docs/CELL_BUDGET", "docs/PLAYABLE_RUNG"]
excluded, kept = [], []
if kind == "bake":
	rules_path = os.path.join(proj, "docs", "BAKE_KEY_EXCLUDED")
	if not os.path.isfile(rules_path):
		print("cache_key: no docs/BAKE_KEY_EXCLUDED, so no key says what a seed reads.", file=sys.stderr)
		sys.exit(2)
	for line in open(rules_path):
		line = line.split("#", 1)[0].strip()
		if line:
			cls, glob = line.split(None, 1)
			(kept if cls == "keep" else excluded).append((":(glob)" if cls == "keep" else ":(exclude,glob)") + glob)

def git(*args):
	return subprocess.run(["git", "-C", proj, *args], capture_output=True).stdout

# A rule that keeps a file puts it back after the exclusions took it out.
def listed(*args):
	out = git(*args, "--", *paths, *excluded)
	return out + git(*args, "--", *kept) if kept else out

h = hashlib.md5()
h.update(kind.encode())
for e in sorted(extra):
	h.update(b"\0" + e.encode())

# The index's blob ids are the content of every tracked file, already computed.
h.update(b"\0tracked\0")
h.update(listed("ls-files", "-s"))

# Anything the index does not describe is read. Ignored files are not inputs: bin/ and thirdparty/ are
# build artifacts, and what the extension contributes arrives above as its SOURCE_HASH.
records = listed("status", "--porcelain=v1", "-z", "--untracked-files=all").split(b"\0")
i, dirty = 0, []
while i < len(records):
	rec = records[i]
	i += 1
	if len(rec) < 4:
		continue
	status, path = rec[:2], rec[3:].decode("utf-8", "surrogateescape")
	if status[:1] in b"RC":
		i += 1
	dirty.append(path)
h.update(b"\0dirty\0")
for path in sorted(dirty):
	h.update(path.encode("utf-8", "surrogateescape") + b"\0")
	full = os.path.join(proj, path)
	if os.path.isfile(full):
		with open(full, "rb") as fh:
			for chunk in iter(lambda: fh.read(1 << 20), b""):
				h.update(chunk)
	else:
		h.update(b"gone")
print(h.hexdigest())
PY

#!/usr/bin/env bash
# THE BAKE KEY NAMES WHAT A SEED READS: scripts/cache_key.sh bake is capture less docs/BAKE_KEY_EXCLUDED.
#   A a file in the key set moves it · B a file under each excluded path does not · C a kept file moves it
#   D every sourcehash file is an input of la_extension_hash · E no reader names an unread path
# EXIT 0 the key follows what a seed reads · 1 it does not · 2 could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib_require.sh"
. "$SCRIPT_DIR/lib_godot.sh"
require_tool git
require_tool python3

RULES="$ROOT/docs/BAKE_KEY_EXCLUDED"
[ -f "$RULES" ] || { echo "check_bake_key: MISSING docs/BAKE_KEY_EXCLUDED" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_bake_key.XXXXXX")" || {
	echo "check_bake_key: no writable temp directory." >&2; exit 2; }
PROBES=()
KEPT_FILE=""
cleanup() {
	local p
	for p in ${PROBES[@]+"${PROBES[@]}"}; do rm -f "$p"; done
	[ -z "$KEPT_FILE" ] || cp "$WORK/kept.orig" "$KEPT_FILE"
	rm -rf "$WORK"
}
trap cleanup EXIT

# An engine hash is given, so the key is a function of the tree alone and no engine starts.
key() { "$SCRIPT_DIR/cache_key.sh" bake --path "$ROOT" "engine=none" 2>/dev/null; }
probe() {  # probe <path relative to the root> <content>: a new file there
	PROBES+=("$ROOT/$1")
	mkdir -p "$(dirname "$ROOT/$1")" && printf '%s\n' "$2" > "$ROOT/$1"
}

fail=0
say() { echo "FAIL  $1" >&2; fail=1; }

base="$(key)"
[ -n "$base" ] || { echo "check_bake_key: cache_key.sh bake produced nothing." >&2; exit 2; }

# A. INSIDE THE KEY SET.
probe "addons/local_agents/sim/.la_bake_probe" one
k1="$(key)"
[ "$k1" != "$base" ] || say "a new file under addons/local_agents/sim did not move the bake key, so a seed source edit is not seen."
probe "addons/local_agents/sim/.la_bake_probe" two
[ "$(key)" != "$k1" ] || say "a change to a file in the key set did not move the bake key."
rm -f "$ROOT/addons/local_agents/sim/.la_bake_probe"
[ "$(key)" = "$base" ] || say "the bake key did not return to its own value once the tree did."

# B. UNDER EACH EXCLUDED DIRECTORY, AND AS A MARKDOWN FILE.
EXCLUDED_DIRS="$(python3 - "$RULES" <<'PY'
import sys
for line in open(sys.argv[1]):
	line = line.split("#", 1)[0].strip()
	if line:
		cls, glob = line.split(None, 1)
		if cls != "keep" and glob.endswith("/**"):
			print(glob[:-3])
PY
)"
n_dirs=0
while IFS= read -r d; do
	[ -n "$d" ] || continue
	n_dirs=$((n_dirs + 1))
	probe "$d/.la_bake_probe" excluded
	[ "$(key)" = "$base" ] || say "a new file under $d, which docs/BAKE_KEY_EXCLUDED excludes, moved the bake key."
	rm -f "$ROOT/$d/.la_bake_probe"
done <<< "$EXCLUDED_DIRS"
probe "addons/local_agents/docs/.la_bake_probe.md" excluded
[ "$(key)" = "$base" ] || say "a new markdown file under addons moved the bake key."
rm -f "$ROOT/addons/local_agents/docs/.la_bake_probe.md"
[ "$n_dirs" -ge 4 ] || say "docs/BAKE_KEY_EXCLUDED names $n_dirs excluded directories, so arm B barely looked."

# C. A KEPT FILE.
KEPT_FILE="$(python3 - "$RULES" "$ROOT" <<'PY'
import os, sys
for line in open(sys.argv[1]):
	line = line.split("#", 1)[0].strip()
	if line.startswith("keep "):
		print(os.path.join(sys.argv[2], line.split(None, 1)[1]))
		break
PY
)"
if [ -n "$KEPT_FILE" ] && [ -f "$KEPT_FILE" ]; then
	cp "$KEPT_FILE" "$WORK/kept.orig" || { echo "check_bake_key: cannot copy $KEPT_FILE." >&2; exit 2; }
	printf '\n' >> "$KEPT_FILE"
	[ "$(key)" != "$base" ] || say "an edit to ${KEPT_FILE#"$ROOT"/}, which a rule keeps, did not move the bake key."
	cp "$WORK/kept.orig" "$KEPT_FILE"
	KEPT_FILE=""
fi

# D AND E, off the tracked files.
python3 - "$ROOT" "$RULES" "$WORK" <<'PY'
import os, subprocess, sys

root, rules_file, work = sys.argv[1:4]
rules = []
for line in open(rules_file):
	line = line.split("#", 1)[0].strip()
	if line:
		cls, glob = line.split(None, 1)
		rules.append((cls, glob))


def tracked(*specs):
	out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", *specs], capture_output=True).stdout
	return sorted(p for p in out.decode("utf-8", "surrogateescape").split("\0") if p)


def files(cls):
	got = set()
	for c, g in rules:
		if c == cls:
			got.update(tracked(":(glob)" + g))
	return got


sourcehash, unread, kept = files("sourcehash"), files("unread"), files("keep")
unread -= kept
readers = (set(tracked("addons")) - unread - sourcehash) | kept
emit = []

# D. A sourcehash file is an input of la_extension_hash.
scratch = os.path.join(work, "root")
ext = os.path.join(scratch, "addons/local_agents/gdextensions/localagents")
for rel in sorted(sourcehash):
	dst = os.path.join(scratch, rel)
	os.makedirs(os.path.dirname(dst), exist_ok=True)
	with open(os.path.join(root, rel), "rb") as s, open(dst, "wb") as d:
		d.write(s.read())
HASH = ["bash", "-c", '. "$1/scripts/lib_godot.sh"; la_extension_hash "$2"', "x", root, scratch]


def ext_hash():
	return subprocess.run(HASH, capture_output=True).stdout.strip()


h0 = ext_hash()
if not h0 or not sourcehash:
	print("check_bake_key: could not hash the extension sources.", file=sys.stderr)
	sys.exit(2)
for rel in sorted(sourcehash):
	dst = os.path.join(scratch, rel)
	with open(dst, "ab") as f:
		f.write(b"\n")
	if ext_hash() == h0:
		emit.append("%s is excluded as keyed by SOURCE_HASH, and la_extension_hash does not read it." % rel)
	with open(os.path.join(root, rel), "rb") as s, open(dst, "wb") as d:
		d.write(s.read())

# E. NO READER NAMES AN UNREAD PATH, a document being prose and no reader. The tokens are each unread file's own path, each directory a rule
# excludes whole, and that directory named from its parent.
tokens = set(unread)
for c, g in rules:
	if c == "unread" and g.endswith("/**"):
		d = g[:-3]
		tokens.add(d + "/")
		tokens.add("../" + d.rsplit("/", 1)[-1] + "/")
for rel in sorted(r for r in readers | sourcehash if not r.endswith(".md")):
	try:
		body = open(os.path.join(root, rel), "r", errors="replace").read()
	except OSError:
		continue
	for tok in sorted(tokens):
		if tok in body:
			emit.append("%s, which a seed can read, names %s, which docs/BAKE_KEY_EXCLUDED holds out." % (rel, tok))
			break

for line in emit[:30]:
	print("FAIL  " + line, file=sys.stderr)
if emit:
	sys.exit(1)
print("check_bake_key: sourcehash %d files, unread %d, kept %d, readers %d"
	% (len(sourcehash), len(unread), len(kept), len(readers)))
PY
rc=$?
[ "$rc" -le 1 ] || exit "$rc"
[ "$rc" -eq 0 ] || fail=1

[ "$fail" -eq 0 ] || exit 1
echo "check_bake_key: OK (an edit a seed reads moves the key, a doc or test edit does not, and no reader names an excluded path)"

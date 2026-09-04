#!/usr/bin/env bash
# THE ONE ANSWER TO "IS THE COMPILED KERNEL THE ONE ON DISK", BY CONTENT ONLY. Godot writes the source md5
# it compiled from into a .md5 beside each artifact and records NOTHING about the .glsli that source
# #includes, so an edited include rebuilds nothing. la_kernel_hash closes that: one digest over the kernel
# and the transitive closure of its includes, recorded at import in .godot/la_kernel_includes.
# An mtime answers "when"; a checkout or a copied import cache moves every mtime without changing a byte,
# so nothing here is keyed on one — the whole sweep is a single pass that reads the bytes.

la_import_cache_root() { printf '%s' "${LA_IMPORT_CACHE:-$HOME/.cache/local-agents/import}"; }

LA_KERNEL_MANIFEST=".godot/la_kernel_includes"

la_md5_file() {
	if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
	elif command -v md5 >/dev/null 2>&1; then md5 -q "$1"
	else return 2
	fi
}

la_md5_stdin() {
	if command -v md5sum >/dev/null 2>&1; then md5sum | cut -d' ' -f1
	elif command -v md5 >/dev/null 2>&1; then md5 -q
	else return 2
	fi
}

la_recorded_md5() {  # la_recorded_md5 <src> <record> -> 0 match · 1 MISMATCH · 2 no record, no verdict
	[ -f "$2" ] || return 2
	local want have
	want="$(sed -n 's/^source_md5="\(.*\)"$/\1/p' "$2" | head -1)"
	[ -n "$want" ] || return 2
	have="$(la_md5_file "$1")" || return 2
	[ "$want" = "$have" ]
}

# ONE PASS FOR EVERY KERNEL QUESTION. The shell form spawned a digest per file per call and the answer was
# asked for four times in one import; this reads each file once, per call, and hashes in process.
la_kernel_tool() {  # la_kernel_tool <sources|includes|hash|manifest|stale> <arg>...
	python3 - "$@" <<'PY'
import hashlib, os, sys

op, arg = sys.argv[1], sys.argv[2]
MANIFEST = ".godot/la_kernel_includes"
SKIP = (".godot", ".claude", ".git", "thirdparty")


def md5_file(path):
    with open(path, "rb") as fh:
        return hashlib.md5(fh.read()).hexdigest()


def sources(proj):
    # SCOPE OR THE GUARD CRIES WOLF: .claude/worktrees holds whole sibling checkouts and thirdparty/
    # vendors llama.cpp's and whisper.cpp's Vulkan shaders, which no sim pass loads.
    found = []
    for dp, dns, fns in os.walk(proj):
        dns[:] = [d for d in dns if d not in SKIP]
        found += [os.path.join(dp, f) for f in fns if f.endswith(".glsl")]
    return sorted(found)


def include_names(path):
    names = []
    for line in open(path, errors="replace"):
        s = line.strip()
        if s.startswith("#include") and '"' in s:
            names.append(s.split('"')[1])
    return names


def includes(src):
    """Every include the kernel reaches, resolved against the kernel's own directory, sorted."""
    base = os.path.dirname(src)
    seen, pending = [], include_names(src)
    while pending:
        name = pending.pop(0)
        if not name:
            continue
        path = os.path.join(base, name)
        if path in seen or not os.path.isfile(path):
            continue
        seen.append(path)
        pending += include_names(path)
    return sorted(seen)


def kernel_hash(src):
    acc = md5_file(src)
    for inc in includes(src):
        acc += " %s=%s" % (os.path.basename(inc), md5_file(inc))
    return hashlib.md5(acc.encode()).hexdigest()


def recorded(proj):
    path = os.path.join(proj, MANIFEST)
    if not os.path.isfile(path):
        return None
    out = {}
    for line in open(path, errors="replace"):
        parts = line.split()
        if len(parts) >= 2:
            out.setdefault(parts[0], parts[1])
    return out


def recorded_source_md5(record):
    if not os.path.isfile(record):
        return None
    for line in open(record, errors="replace"):
        if line.startswith('source_md5="') and line.rstrip("\n").endswith('"'):
            return line.rstrip("\n")[len('source_md5="'):-1]
    return None


def stale(proj):
    imported = os.path.join(proj, ".godot", "imported")
    if not os.path.isdir(imported):
        return []
    manifest = recorded(proj)
    artifacts = os.listdir(imported)
    out = []
    for src in sources(proj):
        base = os.path.basename(src)
        # NO SIDECAR, NO LOADER. `*.import` is gitignored, so a fresh worktree has the compiled .res and
        # no mapping to it: load() returns null and the pass is silently dead.
        if not os.path.isfile(src + ".import"):
            out.append(base)
            continue
        res = [f for f in artifacts if f.startswith(base + "-") and f.endswith(".res")]
        if not res:
            out.append(base)
            continue
        newest = max(res, key=lambda f: os.stat(os.path.join(imported, f)).st_mtime)
        want = recorded_source_md5(os.path.join(imported, newest[:-4] + ".md5"))
        if want is None or want != md5_file(src):
            out.append(base)
            continue
        if manifest is None or base not in manifest or manifest[base] != kernel_hash(src):
            out.append(base)
    return out


if op == "sources":
    for p in sources(arg):
        print(p)
elif op == "includes":
    for p in includes(arg):
        print(p)
elif op == "hash":
    print(kernel_hash(arg))
elif op == "stale":
    for b in stale(arg):
        print(b)
elif op == "manifest":
    tmp = os.path.join(arg, MANIFEST + ".tmp")
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    with open(tmp, "w") as fh:
        for src in sources(arg):
            fh.write("%s %s\n" % (os.path.basename(src), kernel_hash(src)))
    os.replace(tmp, os.path.join(arg, MANIFEST))
else:
    raise SystemExit("la_kernel_tool: unknown op %r" % op)
PY
}

la_kernel_sources() { la_kernel_tool sources "$1"; }
la_kernel_includes() { la_kernel_tool includes "$1"; }
la_kernel_hash() { la_kernel_tool hash "$1"; }
la_write_kernel_manifest() { la_kernel_tool manifest "$1"; }
la_stale_kernels() { la_kernel_tool stale "$1"; }

la_recorded_kernel_hash() {  # la_recorded_kernel_hash <proj> <basename> -> the hash recorded at import
	local manifest="$1/$LA_KERNEL_MANIFEST"
	[ -f "$manifest" ] || return 1
	awk -v k="$2" '$1 == k { print $2; hit = 1 } END { exit !hit }' "$manifest"
}

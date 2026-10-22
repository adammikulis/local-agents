#!/usr/bin/env python3
# THE PASS CACHE FOR scripts/gate_runner.py. A gate's PASS is reusable while every byte it declares reading
# is unchanged: its script and the libs that script names, the files its `inputs` globs match, its row,
# the LA_* environment, and for an engine gate the extension build and the engine binary. Keys hash relative
# paths and content, so worktrees share hits. Only a pass is ever stored.
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from bisect import bisect_left

VERSION = "1"
BIN_HASH_REL = "addons/local_agents/gdextensions/localagents/bin/SOURCE_HASH"
KEEP_PER_GATE = 8
VOLATILE_ENV = frozenset({"LA_LINT_CAPTURE", "LA_LAUNCH_LOG", "LA_LINT_JOBS", "LA_GPU_LOCK_HELD",
                          "LA_LOCKS_HELD", "LA_LOCK_PRIORITY", "LA_INTEGRATE_BRANCH", "LA_INTEGRATE_SOURCE",
                          "LA_GATE_CACHE"})
CAPTURE_MARKS = ("LA_LINT_CAPTURE", "la_cap_dir")
LIB_REF = re.compile(r"\blib_[a-z0-9_]+\.(?:sh|py)\b")
PATH_REF = re.compile(r"(?<![A-Za-z0-9_.-])((?:addons|docs|scripts)/[A-Za-z0-9_./-]*[A-Za-z0-9_]"
                      r"|project\.godot|[A-Z][A-Z_]*\.md)(?![A-Za-z0-9_-])")
# Their repository reads are keyed elsewhere: ceiling_strict by Ambient.strict, cache_key.sh by the files it hashes.
KEYED_ELSEWHERE = ("scripts/lib_ceiling.sh", "scripts/lib_dev_branch.sh", "scripts/cache_key.sh",
                   "scripts/gate_runner.py", "scripts/lib_gate_cache.py")
SCRIPT_REF = re.compile(r"(?<![A-Za-z0-9_.-])(?:scripts/)?([A-Za-z0-9_]+\.(?:sh|py|gd))\b")
GIT_STATE = re.compile(r"\bgit\b[^\n|;&]*?\b(?:log|diff|status|rev-parse|rev-list|merge-base|branch|worktree|"
                       r"cherry|show|describe|blame|tag|stash|config|remote|cat-file|ls-tree)\b"
                       r"|\bls-files\b[^\n|;&]*(?:\s-[a-z]*s\b|--stage)")


def cache_root():
    return os.environ.get("LA_GATE_CACHE") or os.path.join(os.path.expanduser("~"), ".cache",
                                                           "local-agents", "gate_pass")


def digest_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def atomic_write(path, text):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
        return True
    except OSError:
        return False


def glob_regex(pat):
    out, i = [], 0
    while i < len(pat):
        if pat.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pat.startswith("**", i):
            out.append(".*")
            i += 2
        elif pat[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pat[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pat[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def expand_inputs(inputs, sets):
    """A row's `inputs` with each @name replaced by that set's globs."""
    out = []
    for item in inputs:
        if item.startswith("@"):
            if item[1:] not in sets:
                raise ValueError("inputs names @%s, which [sets] does not declare" % item[1:])
            out += sets[item[1:]]
        else:
            out.append(item)
    return out


def helpers(patterns):
    """The scripts a row names outright: a glob matches data, a literal path is code the gate runs."""
    return [p for p in patterns if p.startswith("scripts/") and p.endswith((".sh", ".py")) and not re.search(r"[*?\[]", p)]


def list_files(root):
    raw = subprocess.run(["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout
    names = sorted({p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0") if p})
    return [p for p in names if os.path.isfile(os.path.join(root, p))]


class Tree:
    """One checkout's files, listed once and each hashed at most once."""

    def __init__(self, root, files=None):
        self.root = root
        self.files = files if files is not None else list_files(root)
        self.fileset = set(self.files)
        self.digests, self._match, self._text, self._code = {}, {}, {}, {}

    def forget(self, rel):
        self.digests.pop(rel, None)
        self._text.pop(rel, None)
        if rel.endswith((".sh", ".py")):
            self._code.clear()

    def digest(self, rel):
        if rel not in self.digests:
            self.digests[rel] = digest_file(os.path.join(self.root, rel))
        return self.digests[rel]

    def match(self, pat):
        if pat not in self._match:
            lit = re.split(r"[*?\[]", pat, maxsplit=1)[0]
            rx = glob_regex(pat)
            i = bisect_left(self.files, lit)
            hits = []
            while i < len(self.files) and self.files[i].startswith(lit):
                if rx.match(self.files[i]):
                    hits.append(self.files[i])
                i += 1
            self._match[pat] = hits
        return self._match[pat]

    def matched(self, patterns):
        return sorted({p for pat in patterns for p in self.match(pat)})

    def text(self, rel):
        if rel not in self._text:
            with open(os.path.join(self.root, rel), errors="replace") as fh:
                self._text[rel] = fh.read()
        return self._text[rel]

    def code(self, script, declared):
        """The script, the declared scripts, and every lib_* any of them names, to a fixed point."""
        memo = (script, tuple(declared))
        if memo in self._code:
            return self._code[memo]
        seen = []
        todo = [script] + list(declared)
        while todo:
            rel = todo.pop(0)
            if rel in seen or not os.path.isfile(os.path.join(self.root, rel)):
                continue
            seen.append(rel)
            if rel.endswith((".sh", ".py")):
                todo += ["scripts/" + ref for ref in LIB_REF.findall(self.text(rel))]
        self._code[memo] = sorted(seen)
        return self._code[memo]


class Ambient:
    """What the machine and the build contribute: one value per run, the same for every gate."""

    def __init__(self, root, parent=None):
        self.root = root
        self.parent = parent
        self._strict = None
        self._engine = None
        self._captures = {}

    def env(self):
        keep = {k: v for k, v in os.environ.items()
                if (k.startswith("LA_") and k not in VOLATILE_ENV) or k == "GODOT"}
        return sorted(keep.items())

    def bin_hash(self):
        try:
            with open(os.path.join(self.root, BIN_HASH_REL)) as fh:
                return fh.read().strip()
        except OSError:
            return "absent"

    def engine(self):
        if self.parent:
            return self.parent.engine()
        if self._engine is None:
            path = shutil.which(os.environ.get("GODOT", "godot"))
            self._engine = "absent" if not path else self._engine_digest(os.path.realpath(path))
        return self._engine

    @staticmethod
    def _engine_digest(path):
        st = os.stat(path)
        sig = "%s|%d|%d" % (path, st.st_size, st.st_mtime_ns)
        memo_path = os.path.join(cache_root(), "engine_memo.json")
        try:
            with open(memo_path) as fh:
                memo = json.load(fh)
        except (OSError, ValueError):
            memo = {}
        if memo.get("sig") != sig:
            memo = {"sig": sig, "digest": digest_file(path)}
            atomic_write(memo_path, json.dumps(memo))
        return memo["digest"]

    def strict(self):
        if self.parent:
            return self.parent.strict()
        if self._strict is None:
            lib = os.path.join(self.root, "scripts", "lib_ceiling.sh")
            got = subprocess.run(["bash", "-c", '. "$1"; ceiling_strict "$2"', "_", lib, self.root],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout.strip()
            self._strict = got or "unknown"
        return self._strict

    def capture(self, path):
        if path not in self._captures:
            h = hashlib.sha256()
            for dp, dns, fns in os.walk(path):
                dns.sort()
                for fn in sorted(fns):
                    full = os.path.join(dp, fn)
                    if os.path.isfile(full):
                        h.update(os.path.relpath(full, path).encode() + b"\0" + digest_file(full).encode() + b"\0")
            self._captures[path] = h.hexdigest()
        return self._captures[path]


def reads_capture(g, tree):
    """Whether a gate may read the shared capture: an engine gate, or a script or lib of its own that says so."""
    if g["kind"] != "text" or "capture" in g["needs"]:
        return True
    return any(mark in strip_comments(tree.text(rel)) for rel in tree.code(g["script"], [])
               if rel.endswith((".sh", ".py")) for mark in CAPTURE_MARKS)


def key_parts(g, sets, tree, ambient, capture=None):
    """Everything a gate's pass is a function of."""
    patterns = expand_inputs(g["inputs"], sets)
    matched = tree.matched(patterns)
    code = tree.code(g["script"], helpers(patterns))
    engine = g["kind"] in ("gpu", "headless") or any(n in g["needs"] for n in ("import", "build"))
    uses_capture = capture is not None and reads_capture(g, tree)
    return {
        "version": VERSION, "platform": "%s/%s" % (sys.platform, os.uname().machine),
        "row": g["raw"], "patterns": patterns,
        "code": [[c, tree.digest(c)] for c in code],
        "inputs": [[m, tree.digest(m)] for m in matched if m not in code],
        "env": ambient.env(),
        "engine": [ambient.bin_hash(), ambient.engine()] if engine else None,
        "capture": ambient.capture(capture) if uses_capture else None,
        "ceiling_strict": ambient.strict() if "scripts/lib_ceiling.sh" in code else None,
    }


def gate_key(g, sets, tree, ambient, capture=None):
    body = json.dumps(key_parts(g, sets, tree, ambient, capture), sort_keys=True, separators=(",", ":"),
                      default=str)
    return hashlib.sha256(body.encode()).hexdigest()


class Cache:
    def __init__(self, root=None):
        self.root = root or cache_root()

    def path(self, name, key):
        return os.path.join(self.root, name, key)

    def has(self, name, key):
        p = self.path(name, key)
        if not os.path.isfile(p):
            return False
        try:
            os.utime(p)
        except OSError:
            pass
        return True

    def put(self, name, key, seconds):
        body = json.dumps({"gate": name, "seconds": round(seconds, 3), "at": time.strftime("%Y-%m-%dT%H:%M:%S")})
        if not atomic_write(self.path(name, key), body):
            return False
        d = os.path.join(self.root, name)
        entries = sorted((os.path.getmtime(os.path.join(d, f)), f) for f in os.listdir(d) if not f.endswith(".tmp"))
        for _, f in entries[:-KEEP_PER_GATE]:
            try:
                os.remove(os.path.join(d, f))
            except OSError:
                pass
        return True


def strip_comments(text):
    return "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))


def undeclared(g, tree, patterns):
    """Files and scripts the gate names that no input covers, and repository state no content hash can see."""
    out = []
    data = set(tree.matched(patterns))
    code = set(tree.code(g["script"], helpers(patterns)))
    for rel in sorted(code):
        if not rel.endswith((".sh", ".py")) or rel in KEYED_ELSEWHERE:
            continue
        text = strip_comments(tree.text(rel))
        state = GIT_STATE.search(text)
        if state:
            out.append("%s: %s reads repository state (%s), which no input declares"
                       % (g["name"], rel, state.group(0).strip()[:60]))
        named = {"scripts/" + ref for ref in SCRIPT_REF.findall(text) if not ref.startswith("lib_")}
        for tok in sorted(named | set(PATH_REF.findall(text))):
            tok = tok.rstrip("./")
            if tok in tree.fileset:
                unread = tok not in data and tok not in code
            else:
                under = tok + "/"
                unread = any(f.startswith(under) for f in tree.files) and not any(d.startswith(under) for d in data)
            if unread:
                out.append("%s: %s names %s, which no input covers" % (g["name"], rel, tok))
    return out


def moves(g, sets, scratch, ambient, base, rel, edit):
    """Whether the key leaves `base` once `rel` is edited; the file and its memo are restored."""
    path = os.path.join(scratch.root, rel)
    with open(path, "rb") as fh:
        original = fh.read()
    st = os.stat(path)
    try:
        edit(path, st)
        scratch.forget(rel)
        return gate_key(g, sets, scratch, ambient) != base
    finally:
        with open(path, "wb") as fh:
            fh.write(original)
        os.utime(path, (st.st_atime, st.st_mtime))
        scratch.forget(rel)


def append_byte(path, st):
    with open(path, "ab") as fh:
        fh.write(b"\n# gate_inputs mutation\n")


def touch_only(path, st):
    os.utime(path, (st.st_atime + 5, st.st_mtime + 5))


def probe_rows(rows, sets, tree, ambient, scratch_root, files):
    problems = []
    scratch = Tree(scratch_root, files)
    sambient = Ambient(scratch_root, parent=ambient)
    probed = set()
    for g in rows:
        name = g["name"]
        patterns = expand_inputs(g["inputs"], sets)
        base = gate_key(g, sets, tree, ambient)
        if gate_key(g, sets, scratch, sambient) != base:
            problems.append("%s: the key differs between two checkouts of the same bytes" % name)
            continue
        matched = scratch.matched(patterns)
        code = scratch.code(g["script"], helpers(patterns))
        # Rows sharing globs and a kind share how those globs move a key; each row's own script is its own.
        shape = (tuple(patterns), g["kind"] == "text")
        targets = {g["script"]} | (set() if shape in probed else {scratch.match(p)[0] for p in patterns})
        for rel in sorted(targets):
            if not moves(g, sets, scratch, sambient, base, rel, append_byte):
                problems.append("%s: changing %s did not move the key, so a stale pass would be reused" % (name, rel))
            if moves(g, sets, scratch, sambient, base, rel, touch_only):
                problems.append("%s: touching %s moved the key; a key follows content, not mtime" % (name, rel))
        stray = next((f for f in files if f not in matched and f not in code), None)
        if stray and shape not in probed and moves(g, sets, scratch, sambient, base, stray, append_byte):
            problems.append("%s: changing %s, which it does not read, moved the key" % (name, stray))
        probed.add(shape)
    return problems


def check_inputs(root, gates, sets):
    """Every declared input is real, moves the key when its bytes move, and nothing else does."""
    rows = [g for g in gates if g["inputs"] is not None]
    tree, ambient = Tree(root), Ambient(root)
    problems = []
    needed = set()
    for g in rows:
        patterns = expand_inputs(g["inputs"], sets)
        problems += ["%s: inputs glob %r matches no file" % (g["name"], p) for p in patterns if not tree.match(p)]
        if g["script"] not in tree.fileset:
            problems.append("%s: script %s is not in the tree" % (g["name"], g["script"]))
            continue
        problems += undeclared(g, tree, patterns)
        matched = tree.matched(patterns)
        needed |= set(matched) | set(tree.code(g["script"], helpers(patterns)))
    if problems:
        return problems
    scratch_root = tempfile.mkdtemp(prefix="la_gate_inputs.")
    try:
        built = [BIN_HASH_REL] if os.path.isfile(os.path.join(root, BIN_HASH_REL)) else []
        for rel in sorted(needed) + built:
            dst = os.path.join(scratch_root, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(root, rel), dst)
        return probe_rows(rows, sets, tree, ambient, scratch_root, sorted(needed))
    finally:
        shutil.rmtree(scratch_root, ignore_errors=True)

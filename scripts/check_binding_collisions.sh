#!/usr/bin/env bash
# TWO BUFFERS ON ONE BINDING NUMBER COMPILE, AND THE LATER WRITE WINS.
#
# state_derive.glsl once declared bindings 31/32/33 twice: one lane's gas-moles / condensed-density /
# conductivity aliased another lane's phase fractions, and the pass bound 33 twice. Both sides compiled,
# the merge was clean, and pressure.glsl spent every step computing the planet's lithostatic column from
# the LIQUID WATER FRACTION as if it were kg/m^3. A merge conflict would have been the good outcome.
#
# 1. no .glsl declares one (set, binding) twice, COUNTING WHAT ITS #includes DECLARE
# 2. no .glsli declares one (set, binding) twice
# 3. no pass builds a uniform set with the same index twice
# 4. no pass binds an index its kernel never declares
#
# 3 and 4 read a set built in a variable as well as an inline literal, and exit 2 rather than skip a set
# whose indices it cannot resolve — the three widest binding tables in the tree are built in a variable.
#
# EXIT 0 clean · 1 a collision · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "check_binding_collisions: python3 absent." >&2; exit 2; }

python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
KERNELS = os.path.join(root, "addons/local_agents/sim/material/kernels3d")
PASSES = os.path.join(root, "addons/local_agents/sim/material/sphere_passes")
for p in (KERNELS, PASSES):
    if not os.path.isdir(p):
        print("check_binding_collisions: MISSING %s" % p, file=sys.stderr); sys.exit(2)

# Any order and number of memory qualifiers, and set= / binding= in either order inside the layout.
DECL = re.compile(
    r"layout\s*\(([^)]*)\)\s*"
    r"(?:(?:restrict|readonly|writeonly|coherent|volatile|nonprivate)\s+)*"
    r"(?:buffer|uniform)\s+(\w+)")
SET_RE = re.compile(r"\bset\s*=\s*(\d+)")
BINDING_RE = re.compile(r"\bbinding\s*=\s*(\d+)")
INCLUDE = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)

bad = []
scanned = 0
missing = []


def read(path):
    return open(path, encoding="utf-8").read()


def decls(src, fn):
    # (set, binding) -> name, in declaration order. Bindings only; a layout without one is not a descriptor.
    out = []
    for m in DECL.finditer(src):
        layout, name = m.group(1), m.group(2)
        b = BINDING_RE.search(layout)
        if b is None:
            continue
        s = SET_RE.search(layout)
        out.append(((int(s.group(1)) if s else 0, int(b.group(1))), name, fn))
    return out


def includes_of(fn, seen):
    # Transitive #include closure, by filename, within kernels3d.
    src = read(os.path.join(KERNELS, fn))
    for inc in INCLUDE.findall(src):
        base = os.path.basename(inc)
        if base in seen:
            continue
        if not os.path.isfile(os.path.join(KERNELS, base)):
            missing.append("%s includes %s, which is not in kernels3d" % (fn, base))
            continue
        seen.add(base)
        includes_of(base, seen)
    return seen


def unit_decls(fn):
    # Everything the compiler sees for this translation unit: the file plus its include closure.
    units = [fn] + sorted(includes_of(fn, set()))
    out = []
    for u in units:
        out += decls(read(os.path.join(KERNELS, u)), u)
    return out


def check_collisions(label, entries):
    global scanned
    seen = {}
    for key, name, origin in entries:
        scanned += 1
        if key in seen:
            prev_name, prev_origin = seen[key]
            bad.append("%s declares set %d binding %d twice: %s (%s) and %s (%s)"
                       % (label, key[0], key[1], prev_name, prev_origin, name, origin))
        else:
            seen[key] = (name, origin)
    return seen


kernel_bindings = {}   # kernel filename -> set of binding indices in set 0
for fn in sorted(os.listdir(KERNELS)):
    if fn.endswith(".glsl"):
        entries = unit_decls(fn)
        seen = check_collisions(fn, entries)
        kernel_bindings[fn] = {b for (s, b) in seen if s == 0}
    elif fn.endswith(".glsli"):
        check_collisions(fn, decls(read(os.path.join(KERNELS, fn)), fn))

if missing:
    print("check_binding_collisions: cannot resolve an #include — the gate would under-count.", file=sys.stderr)
    for m in missing:
        print("  " + m, file=sys.stderr)
    sys.exit(2)

# A pass builds its set as a list of [index, rid] pairs. The list is either an inline literal or a
# variable the function appends to, and the three widest binding tables in the tree use the variable.
USET = re.compile(r"_uset\s*\(\s*[^,]+,\s*(\[.*?\]|\w+)\s*\)", re.S)
KERNEL_LIT = re.compile(r'"res://addons/local_agents/sim/material/kernels3d/([\w.]+\.glsl)"')
FOR = re.compile(r"^\s*for\s+(\w+)(?:\s*:\s*\w+)?\s+in\s+(.+?)\s*:", re.M)


def balanced(src, start):
    # Text inside the bracket opened at `start`, and the index one past its close.
    depth, i = 1, start + 1
    while i < len(src) and depth:
        if src[i] in "([":
            depth += 1
        elif src[i] in ")]":
            depth -= 1
        i += 1
    return (src[start + 1:i - 1], i) if depth == 0 else (None, i)


def pair_index(pair):
    # The index half of one `[index, rid]` entry. Bracket-aware: `int(D[k])` is one expression.
    depth = 0
    for i, c in enumerate(pair):
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == "," and depth == 0:
            return pair[:i].strip()
    return None


def array_pair_indices(inner):
    # The index half of every top-level `[...]` item of an array literal's inner text.
    out, i = [], 0
    while i < len(inner):
        if inner[i] == "[":
            pair, i = balanced(inner, i)
            out.append(None if pair is None else pair_index(pair))
            continue
        i += 1
    return out

# class_name -> source. A pass sizes a run of bindings off a const array that lives in another file.
CLASSES = {}
for dirpath, _dirs, names in os.walk(os.path.join(root, "addons/local_agents/sim")):
    for n in names:
        if not n.endswith(".gd"):
            continue
        s = read(os.path.join(dirpath, n))
        m = re.search(r"^class_name\s+(\w+)", s, re.M)
        if m:
            CLASSES[m.group(1)] = s


def const_block(src, name, opener, closer):
    # The text between the brackets of `const NAME ... = <opener>`, nesting-aware.
    m = re.search(r"^const\s+%s\s*(?::[^=]+)?=\s*\%s" % (name, opener), src, re.M)
    if m is None:
        return None
    depth, i = 1, m.end()
    while i < len(src) and depth:
        if src[i] == opener:
            depth += 1
        elif src[i] == closer:
            depth -= 1
        i += 1
    return src[m.end():i - 1] if depth == 0 else None


def const_array_len(src, local):
    b = const_block(src, local, "[", "]")
    if b is None:
        a = re.search(r"\b%s\s*(?::[^=]+)?=\s*(\w+)\.(\w+)\b" % local, src)
        if a is None:
            return None
        owner = CLASSES.get(a.group(1))
        b = const_block(owner, a.group(2), "[", "]") if owner else None
        if b is None:
            return None
    return len(re.findall(r'"[^"]*"', b))


def const_dict_values(src, name):
    b = const_block(src, name, "{", "}")
    if b is None:
        return None
    return [int(v) for v in re.findall(r":\s*(\d+)", b)]


def loop_ranges(src):
    # Loop variable -> the indices it takes, for `for i in N:` / `range(N)` / `NAME.size()`.
    out = {}
    for m in FOR.finditer(src):
        var, it = m.group(1), m.group(2).strip()
        r = re.match(r"^(?:range\(\s*)?(\d+)\s*\)?$", it)
        n = int(r.group(1)) if r else None
        if n is None:
            s = re.match(r"^(\w+)\.size\(\)$", it)
            n = const_array_len(src, s.group(1)) if s else None
        if n is not None:
            out.setdefault(var, set()).update(range(n))
    return out


def resolve(src, expr, ranges):
    # An index expression -> the concrete indices it binds, or None when the gate cannot say.
    expr = expr.strip()
    if re.match(r"^\d+$", expr):
        return [int(expr)]
    m = re.match(r"^(?:int\(\s*)?(\w+)\[\s*\w+\s*\]\s*\)?$", expr)
    if m:
        return const_dict_values(src, m.group(1))
    if expr in ranges:
        return sorted(ranges[expr])
    return None


unresolved = []
for fn in sorted(os.listdir(PASSES)):
    if not fn.endswith(".gd"):
        continue
    src = read(os.path.join(PASSES, fn))
    calls = list(USET.finditer(src))
    if not calls:
        continue
    kernels = sorted(set(KERNEL_LIT.findall(src)))
    if len(kernels) != 1:
        print("check_binding_collisions: %s builds a uniform set but names %d kernels — the gate cannot "
              "tell which kernel its bindings must exist in." % (fn, len(kernels)), file=sys.stderr)
        sys.exit(2)
    declared = kernel_bindings.get(kernels[0])
    if declared is None:
        print("check_binding_collisions: %s names %s, which is not in kernels3d."
              % (fn, kernels[0]), file=sys.stderr)
        sys.exit(2)
    ranges = loop_ranges(src)
    for call in calls:
        arg = call.group(1).strip()
        if arg.startswith("["):
            exprs = array_pair_indices(arg[1:-1])
        else:
            exprs = []
            for m in re.finditer(r"\b%s\s*\.append\(" % arg, src):
                a = balanced(src, m.end() - 1)[0]
                a = (a or "").strip()
                exprs.append(pair_index(a[1:-1]) if a.startswith("[") and a.endswith("]") else None)
            for m in re.finditer(r"\b%s\s*(?::[^=\n]+)?=\s*\[" % arg, src):
                inner = balanced(src, m.end() - 1)[0]
                if inner is not None:
                    exprs += array_pair_indices(inner)
            if not exprs:
                unresolved.append("%s passes `%s` to _uset and nothing builds an entry in it" % (fn, arg))
                continue
        idx = []
        for e in exprs:
            got = None if e is None else resolve(src, e, ranges)
            if got is None:
                unresolved.append("%s binds index expression `%s`, which the gate cannot resolve" % (fn, e))
                continue
            idx += got
        scanned += len(idx)
        for d in sorted({i for i in idx if idx.count(i) > 1}):
            bad.append("%s builds a uniform set binding %d twice" % (fn, d))
        for u in sorted({i for i in idx if i not in declared}):
            bad.append("%s binds %d, which %s never declares" % (fn, u, kernels[0]))

if unresolved:
    print("check_binding_collisions: a uniform set the gate cannot read is a set it cannot check.",
          file=sys.stderr)
    for u in sorted(set(unresolved)):
        print("  " + u, file=sys.stderr)
    sys.exit(2)

if scanned == 0:
    print("check_binding_collisions: found no bindings — the gate has no subject.", file=sys.stderr)
    sys.exit(2)

if bad:
    print("check_binding_collisions: FAILED", file=sys.stderr)
    for b in sorted(set(bad)):
        print("  " + b, file=sys.stderr)
    print("\nTwo buffers on one binding number compile. The later write wins and the kernel reads the\n"
          "wrong quantity, silently, for as long as nobody notices. A bound index the kernel never\n"
          "declares is a buffer nothing reads.", file=sys.stderr)
    sys.exit(1)

print("check_binding_collisions: OK (%d bindings, no collisions)" % scanned)
PY

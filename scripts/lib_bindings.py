"""The one reader of the binding registry, for the generator and the gates that hold it to the tree.

`material/Bindings.gd` declares every SSBO slot once: `SLOT` gives its number, `IN_KERNEL` the slots
each kernel's translation unit declares. A kernel writes `layout(binding = LA_BIND_<NAME>)`; a pass
calls `LABindings.set_for(<kernel>, bufs, own)`. Nothing else carries a binding number.
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MATERIAL = os.path.join(ROOT, "addons", "local_agents", "sim", "material")
KERNELS = os.path.join(MATERIAL, "kernels3d")
PASSES = os.path.join(MATERIAL, "sphere_passes")
TABLE_GD = os.path.join(MATERIAL, "Bindings.gd")
GLSLI_OUT = os.path.join(KERNELS, "bindings.glsli")

INCLUDE = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)
# Any order of qualifiers, set= and binding= either way round; only LA_BIND_ macros are accepted.
LAYOUT = re.compile(r"layout\s*\(([^)]*)\)")
MACRO = re.compile(r"\bbinding\s*=\s*LA_BIND_(\w+)")
LITERAL = re.compile(r"\bbinding\s*=\s*(\d+)")


class Missing(Exception):
    pass


def read(path):
    if not os.path.isfile(path):
        raise Missing("gone: %s" % os.path.relpath(path, ROOT))
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _const_body(name, opener, closer):
    m = re.search(r"^const %s: Dictionary = \%s" % (name, opener), read(TABLE_GD), re.M)
    if m is None:
        raise Missing("Bindings.gd declares no `const %s: Dictionary`" % name)
    src = read(TABLE_GD)
    depth, i = 1, m.end()
    while i < len(src) and depth:
        if src[i] == opener:
            depth += 1
        elif src[i] == closer:
            depth -= 1
        i += 1
    if depth:
        raise Missing("Bindings.gd's %s never closes" % name)
    return src[m.end():i - 1]


def slots():
    """[(name, binding), ...] in declaration order."""
    rows = [(m.group(1), int(m.group(2)))
            for m in re.finditer(r'"(\w+)":\s*(\d+)', _const_body("SLOT", "{", "}"))]
    if not rows:
        raise Missing("Bindings.gd's SLOT parsed to zero rows")
    return rows


def in_kernel():
    """kernel file -> [slot name, ...], the whole translation unit's."""
    body = _const_body("IN_KERNEL", "{", "}")
    out = {}
    for m in re.finditer(r'"([\w.]+\.glsl)":\s*\[(.*?)\]', body, re.S):
        out[m.group(1)] = re.findall(r'"(\w+)"', m.group(2))
    if not out:
        raise Missing("Bindings.gd's IN_KERNEL parsed to zero kernels")
    return out


def kernel_files():
    return sorted(f for f in os.listdir(KERNELS) if f.endswith(".glsl"))


def include_files():
    return sorted(f for f in os.listdir(KERNELS) if f.endswith(".glsli"))


def includes_of(fn, seen=None, missing=None):
    """Every include the compiler pulls into `fn`, transitively, within kernels3d."""
    seen = set() if seen is None else seen
    for inc in INCLUDE.findall(read(os.path.join(KERNELS, fn))):
        base = os.path.basename(inc)
        if base in seen:
            continue
        if not os.path.isfile(os.path.join(KERNELS, base)):
            if missing is not None:
                missing.append("%s includes %s, which is not in kernels3d" % (fn, base))
            continue
        seen.add(base)
        includes_of(base, seen, missing)
    return seen


def declared_in(fn):
    """[(name, origin file), ...] the layouts in one kernels3d file declare, in order."""
    out = []
    for m in LAYOUT.finditer(read(os.path.join(KERNELS, fn))):
        got = MACRO.search(m.group(1))
        if got is not None:
            out.append((got.group(1).lower(), fn))
    return out


def unit_declared(fn, missing=None):
    """[(name, origin file), ...] the whole translation unit of a .glsl declares."""
    out = []
    for u in [fn] + sorted(includes_of(fn, None, missing)):
        out += declared_in(u)
    return out


def literals_in(fn):
    """Binding numbers still written as integers in one kernels3d file."""
    return [m.group(1) for m in LITERAL.finditer(read(os.path.join(KERNELS, fn)))]


def pass_files():
    return sorted(f for f in os.listdir(PASSES) if f.endswith(".gd"))


def _const_list(src, name, classes):
    """The names of `const NAME ... = [...]`, following one hop into another class.

    An item is a quoted string or an identifier bound to one by `const NAME: String = "x"`; an item
    that is neither makes the whole list unreadable, so the gate refuses rather than under-counts.
    """
    m = re.search(r"^const\s+%s\s*(?::[^=]+)?=\s*\[" % re.escape(name), src, re.M)
    if m is None:
        hop = re.match(r"^(\w+)\.(\w+)$", name)
        if hop and hop.group(1) in classes:
            return _const_list(classes[hop.group(1)], hop.group(2), classes)
        return _const_str(src, name)
    depth, i = 1, m.end()
    while i < len(src) and depth:
        if src[i] == "[":
            depth += 1
        elif src[i] == "]":
            depth -= 1
        i += 1
    if depth:
        return None
    return list_items(src[m.end():i - 1], src)


def _const_str(src, name):
    """`const NAME: String = "x"` -> ["x"]. A one-name list, so callers treat both the same."""
    m = re.search(r'^const\s+%s\s*(?::\s*String\s*)?=\s*"(\w+)"' % re.escape(name), src, re.M)
    return [m.group(1)] if m else None


def list_items(inner, src):
    """The names in one array literal's text: quoted strings and String constants, in order."""
    out = []
    for tok in re.finditer(r'"(\w+)"|([A-Za-z_]\w*)', inner):
        if tok.group(1) is not None:
            out.append(tok.group(1))
            continue
        got = _const_str(src, tok.group(2))
        if got is None:
            return None
        out += got
    return out


def sim_classes():
    """class_name -> source, for every .gd under sim/."""
    out = {}
    for dirpath, _dirs, names in os.walk(os.path.join(ROOT, "addons", "local_agents", "sim")):
        for n in names:
            if not n.endswith(".gd"):
                continue
            src = read(os.path.join(dirpath, n))
            m = re.search(r"^class_name\s+(\w+)", src, re.M)
            if m:
                out[m.group(1)] = src
    return out


SET_FOR = re.compile(r'LABindings\.set_for\(\s*"([\w.]+)"\s*,\s*\w+\s*,\s*(\{|\w+)')
VAR_DICT = re.compile(r"^\s*var\s+%s\s*:\s*Dictionary\s*=\s*\{")
USET_INT = re.compile(r"\[\s*(\d+)\s*,")


def _braced(src, start):
    """The text of the dictionary literal whose `{` was consumed up to `start`."""
    depth, i = 1, start
    while i < len(src) and depth:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return None if depth else src[start:i - 1]


# A slot filled in a loop rather than in the literal: `own[SCRATCH[i]] = _scr[i]`.
LOOP_KEY = re.compile(r"^\s*\w+\[\s*(\w+)\[[^\]]*\]\s*\]\s*=", re.M)


def pass_sets(fn, classes):
    """[(kernel, [slot the pass supplies itself, ...]), ...], and unreadable calls."""
    src = read(os.path.join(PASSES, fn))
    out, unresolved = [], []
    looped = []
    for const in LOOP_KEY.findall(src):
        got = _const_list(src, const, classes)
        if got is None:
            unresolved.append("%s fills a slot from `%s`, which the gate cannot read" % (fn, const))
            continue
        looped += got
    for m in SET_FOR.finditer(src):
        if m.group(2) == "{":
            inner = _braced(src, m.end())
        else:
            # The dictionary was built in a variable first; find the literal it was declared with.
            v = re.search(VAR_DICT.pattern % re.escape(m.group(2)), src, re.M)
            inner = None if v is None else _braced(src, v.end())
        if inner is None:
            unresolved.append("%s calls set_for(\"%s\", ..., %s) and the gate cannot read the "
                              "dictionary it supplies" % (fn, m.group(1), m.group(2)))
            continue
        own = re.findall(r'^\s*"(\w+)"\s*:', inner, re.M) + looped
        out.append((m.group(1), sorted(set(own))))
    return out, unresolved


def pass_kernel(fn):
    """The one kernel a pass loads, or None."""
    src = read(os.path.join(PASSES, fn))
    got = sorted(set(re.findall(r'kernels3d/([\w.]+\.glsl)"', src)))
    return got[0] if len(got) == 1 else (None if not got else got)


def pass_literal_bindings(fn):
    """`[<int>, rid]` uniform-set entries a pass still writes as a number."""
    src = read(os.path.join(PASSES, fn))
    return [m.group(1) for m in USET_INT.finditer(src)]

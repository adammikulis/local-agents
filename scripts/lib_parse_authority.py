#!/usr/bin/env python3
"""Parse a GDScript constants file into NAME<TAB>VALUE on stdout.

With a second argument, also emits the substance table's scalar properties as
LASubstances.<id>.<property><TAB>VALUE, so a kernel copy of a material property binds to the SSOT for
matter rather than to a second declaration of the same fact in LAPhysical.

Evaluates each `const NAME: float = <expr>` over the constants already known, iterating until nothing
new resolves. The grammar is real: parentheses, unary minus, + - * / and ** , plus PI, TAU, INF and the
functions pow, sqrt, log, exp, abs, min, max. A flat +-*/ chain could not express a derivation like
Lilly's C_s = (1/pi) * (3*C_K/2)^(-3/4), so the constant fell out of the map and every kernel copy of it
became unbindable -- the gate getting weaker as the authority got better, four times over.

A name that cannot be resolved is printed to stderr and exits 3, never dropped silently.
"""
import ast
import math
import re
import sys

FUNCS = {
    "pow": pow, "sqrt": math.sqrt, "log": math.log, "exp": math.exp,
    "abs": abs, "min": min, "max": max,
}
BUILTIN = {"PI": math.pi, "TAU": math.tau, "INF": math.inf}

BINOP = {
    ast.Add: lambda a, b: a + b,
    ast.Sub: lambda a, b: a - b,
    ast.Mult: lambda a, b: a * b,
    ast.Div: lambda a, b: a / b,
    ast.Pow: lambda a, b: a ** b,
}


class Unresolved(Exception):
    pass


def _eval(node, known):
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return float(node.value)
    if isinstance(node, ast.Name):
        if node.id in known:
            return known[node.id]
        if node.id in BUILTIN:
            return BUILTIN[node.id]
        raise Unresolved(node.id)
    if isinstance(node, ast.UnaryOp):
        v = _eval(node.operand, known)
        if isinstance(node.op, ast.USub):
            return -v
        if isinstance(node.op, ast.UAdd):
            return v
        raise Unresolved("unary")
    if isinstance(node, ast.BinOp):
        fn = BINOP.get(type(node.op))
        if fn is None:
            raise Unresolved("operator")
        return fn(_eval(node.left, known), _eval(node.right, known))
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        fn = FUNCS.get(node.func.id)
        if fn is None:
            raise Unresolved(node.func.id)
        return float(fn(*[_eval(a, known) for a in node.args]))
    raise Unresolved(type(node).__name__)


def _consts(src):
    out = []
    for line in src.split("\n"):
        m = re.match(r"^\s*const\s+([A-Za-z_]\w*)\s*:\s*float\s*=\s*(.+)$", line)
        if not m:
            continue
        expr = re.sub(r"#.*$", "", m.group(2)).strip()
        if expr:
            out.append((m.group(1), expr))
    return out


def substances(path, known):
    # The substance table is the SSOT for matter, so a kernel copy of a material property binds to it the
    # same way one binds to LAPhysical. Emitted as LASubstances.<id>.<property>.
    src = re.sub(r"\\\n", " ", open(path, encoding="utf-8").read()).replace("PC.", "")
    local = dict(known)
    for name, expr in _consts(src):
        try:
            local[name] = _eval(ast.parse(expr, mode="eval").body, local)
        except (SyntaxError, Unresolved):
            continue
    out, sid = [], None
    for line in src.split("\n"):
        m = re.match(r'^\t\t"(\w+)"\s*:\s*\{', line)
        if m:
            sid = m.group(1)
            continue
        m = re.match(r'^\t\t\t"(\w+)"\s*:\s*(.+?),?\s*$', line)
        if sid is None or not m:
            continue
        try:
            out.append(("LASubstances.%s.%s" % (sid, m.group(1)),
                        _eval(ast.parse(m.group(2), mode="eval").body, local)))
        except (SyntaxError, Unresolved, TypeError, ValueError):
            continue      # a formula dict, a string, an array: not a scalar property
    return out


def main() -> int:
    src = open(sys.argv[1], encoding="utf-8").read()
    src = re.sub(r"\\\n", " ", src)                       # join line continuations before reading
    decls = _consts(src)
    if not decls:
        print("lib_parse_authority: no `const NAME: float =` declarations found.", file=sys.stderr)
        return 2

    known, order, pending = {}, [], list(decls)
    while True:
        progressed = False
        still = []
        for name, expr in pending:
            try:
                known[name] = _eval(ast.parse(expr, mode="eval").body, known)
            except SyntaxError:
                still.append((name, expr))
                continue
            except Unresolved:
                still.append((name, expr))
                continue
            order.append(name)
            progressed = True
        pending = still
        if not progressed or not pending:
            break

    if pending:
        print("lib_parse_authority: FAILED — the authority declares constants this parser cannot read:",
              file=sys.stderr)
        for name, expr in pending:
            print("  %-40s = %s" % (name, expr), file=sys.stderr)
        print("\nA constant absent from the map makes every kernel copy of it unbindable, and the gate\n"
              "reports a misleading 'the authority does not define it'. Teach the parser or fix the\n"
              "declaration — do not let it vanish.", file=sys.stderr)
        return 3

    for name in order:
        print("%s\t%.10g" % (name, known[name]))
    if len(sys.argv) > 2:
        rows = substances(sys.argv[2], known)
        if not rows:
            print("lib_parse_authority: %s yielded no substance properties." % sys.argv[2], file=sys.stderr)
            return 3
        for name, value in rows:
            print("%s\t%.10g" % (name, value))
    return 0


if __name__ == "__main__":
    sys.exit(main())

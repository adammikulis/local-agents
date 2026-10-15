#!/usr/bin/env bash
# A BULK MODULUS NAMES ITS PATH. A name holding BULK_MODULUS, COMPRESSIBILITY, or KS_/KT_ before PA or DERIV is
# isothermal by BULK_MODULUS_T, ISOTHERMAL_COMPRESSIBILITY or KT_, adiabatic by BULK_MODULUS_S,
# ADIABATIC_COMPRESSIBILITY, ISENTROPIC_COMPRESSIBILITY or KS_. Every `bulk_modulus*` key reads K_T, so an
# adiabatic constant is read only as the first argument of `isothermal_modulus(` or inside a `MgFit` isentrope.
# EXIT 0 every modulus declares its path and none is read as K_T off the adiabat · 1 one does · 2 could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib_require.sh"
require_tool git
require_tool python3
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

python3 - "$ROOT" <<'PY'
import os, re, subprocess, sys

SELF = "scripts/check_modulus_paths.sh"
C_LIKE = (".cpp", ".hpp", ".h", ".mm", ".glsl", ".glsli")
DECL_HASH = re.compile(r"^\s*const\s+([A-Z][A-Z0-9_]*)\b", re.M)
DECL_C = re.compile(r"^\s*(?:static\s+)?(?:inline\s+)?(?:constexpr|const)\s+(?:double|float|int)\s+([A-Z][A-Z0-9_]*)\s*=|"
                    r"^\s*#define\s+([A-Z][A-Z0-9_]*)\b", re.M)
MODULUS = re.compile(r"BULK_MODULUS|COMPRESSIBILITY|(^|_)K[ST]_(PA|DERIV)")
ISO = re.compile(r"BULK_MODULUS_T(_|$)|ISOTHERMAL_COMPRESSIBILITY|(^|_)KT_(PA|DERIV)")
ADI = re.compile(r"BULK_MODULUS_S(_|$)|(ADIABATIC|ISENTROPIC)_COMPRESSIBILITY|(^|_)KS_(PA|DERIV)")
CONVERT = re.compile(r"isothermal_modulus\(\s*(?:pc\(\s*\")?\Z")
FIT = re.compile(r"\bconst\s+MgFit\s+\w+\s*=\s*\{[^;]*\};")


def scanned(f):
    if f.startswith("addons/local_agents/"):
        return f.endswith(C_LIKE + (".gd",))
    return f.startswith("scripts/") and f.endswith((".sh", ".gd"))


def strip(text, path):
    """Comments out, strings and newlines kept, so offsets and line numbers stay the source's."""
    if path.endswith(".sh"):
        return "\n".join("" if l.lstrip().startswith("#") else l for l in text.split("\n"))
    out, i, n, q, block = [], 0, len(text), None, False
    hash_comment = path.endswith(".gd")
    while i < n:
        c = text[i]
        if block:
            if text.startswith("*/", i):
                block, i = False, i + 2
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
            continue
        if q:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            q = None if c in (q, "\n") else q
            i += 1
            continue
        if c in "\"'":
            q = c
        elif (hash_comment and c == "#") or (not hash_comment and text.startswith("//", i)):
            while i < n and text[i] != "\n":
                i += 1
            continue
        elif not hash_comment and text.startswith("/*", i):
            block, i = True, i + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def main(root):
    ls = subprocess.run(["git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard"],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if ls.returncode != 0:
        print("check_modulus_paths: git ls-files exited %d: %s" % (ls.returncode, ls.stderr.strip()), file=sys.stderr)
        return 2
    files = [f for f in sorted(set(ls.stdout.splitlines())) if f != SELF and "/thirdparty/" not in f
             and scanned(f) and os.path.isfile(os.path.join(root, f))]
    gd_scripts = sum(1 for f in files if f.startswith("scripts/") and f.endswith(".gd"))
    if len(files) < 100 or gd_scripts == 0:
        print("check_modulus_paths: %d source files listed, %d GDScript under scripts/; the scan collapsed."
              % (len(files), gd_scripts), file=sys.stderr)
        return 2

    src, bare, decl = {}, {}, {}
    for f in files:
        text = open(os.path.join(root, f), errors="replace").read()
        s = strip(text, f)
        src[f], bare[f] = text.split("\n"), s
        for m in (DECL_C if f.endswith(C_LIKE) else DECL_HASH).finditer(s):
            name = m.group(1) or m.group(2)
            if MODULUS.search(name):
                decl.setdefault(name, (f, s.count("\n", 0, m.start(m.lastindex)) + 1))

    undeclared, misread, adiabatic = [], [], []
    for name, (f, ln) in sorted(decl.items()):
        iso, adi = bool(ISO.search(name)), bool(ADI.search(name))
        if iso == adi:
            undeclared.append("%s:%d  %s names %s path" % (f, ln, name, "both a" if iso else "no"))
        if adi:
            adiabatic.append(name)

    fits = {f: [m.span() for m in FIT.finditer(s)] for f, s in bare.items()}
    for name in adiabatic:
        word = re.compile(r"\b%s\b" % name)
        for f, s in bare.items():
            for m in (word.finditer(s) if name in s else ()):
                ln = s.count("\n", 0, m.start()) + 1
                if (f, ln) == decl[name] or CONVERT.search(s[max(0, m.start() - 160):m.start()]):
                    continue
                if any(a <= m.start() < b for a, b in fits[f]):
                    continue
                misread.append("%s:%d  adiabatic %s is read where K_T is: %s" % (f, ln, name, src[f][ln - 1].strip()))

    for v in undeclared:
        print("undeclared path: " + v, file=sys.stderr)
    for v in misread:
        print(v, file=sys.stderr)
    print('MODULUS_PATHS={"files":%d,"constants":%d,"adiabatic":%d,"undeclared":%d,"read_as_kt":%d}'
          % (len(files), len(decl), len(adiabatic), len(undeclared), len(misread)))
    if len(decl) < 10:
        print("check_modulus_paths: %d modulus constants found; the declaration scan collapsed." % len(decl),
              file=sys.stderr)
        return 2
    return 1 if undeclared or misread else 0


try:
    rc = main(sys.argv[1])
except Exception as exc:
    print("check_modulus_paths: could not run: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
    rc = 2
sys.exit(rc)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
echo "check_modulus_paths: OK"

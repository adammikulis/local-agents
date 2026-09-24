#!/usr/bin/env bash
# A BULK MODULUS NAMES ITS PATH: `_T_`, `ISOTHERMAL_` or `_KT_` isothermal; `_S_`, `ADIABATIC_`, `ISENTROPIC_`
# or `_KS_` adiabatic. Every `bulk_modulus*` key and Birch-Murnaghan isotherm reads K_T, so an adiabatic
# constant is read only as the first argument of `isothermal_modulus(`, as an isentrope fit's own K_S
# (`MgFit`), or under an `LA_APPROX:` whose docs/APPROXIMATIONS.md row names it.
# EXIT 0 every modulus declares its path and none is read as K_T off the adiabat · 1 one does · 2 could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib_require.sh"
require_tool git
require_tool python3
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
[ -f "$ROOT/docs/APPROXIMATIONS.md" ] || { echo "check_modulus_paths: MISSING docs/APPROXIMATIONS.md" >&2; exit 2; }

python3 - "$ROOT" <<'PY'
import os, re, subprocess, sys

root = sys.argv[1]
SELF = "scripts/check_modulus_paths.sh"
C_LIKE = (".cpp", ".hpp", ".h", ".mm", ".glsl", ".glsli")
listed = subprocess.run(["git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard"],
                        stdout=subprocess.PIPE, text=True, check=True).stdout.splitlines()
files = [f for f in sorted(set(listed)) if f != SELF and "/thirdparty/" not in f and os.path.isfile(os.path.join(root, f))
         and ((f.startswith("addons/local_agents/") and f.endswith(C_LIKE + (".gd",)))
              or (f.startswith("scripts/") and f.endswith(".sh")))]
if len(files) < 100:
    print("check_modulus_paths: %d source files listed; the scan collapsed." % len(files), file=sys.stderr)
    sys.exit(2)


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


DECL = {".gd": re.compile(r"^\s*const\s+([A-Z][A-Z0-9_]*)\b", re.M),
        ".sh": re.compile(r"^\s*const\s+([A-Z][A-Z0-9_]*)\b", re.M)}
DECL_C = re.compile(r"^\s*(?:static\s+)?(?:inline\s+)?(?:constexpr|const)\s+(?:double|float|int)\s+([A-Z][A-Z0-9_]*)\s*=|"
                    r"^\s*#define\s+([A-Z][A-Z0-9_]*)\b", re.M)
MODULUS = re.compile(r"BULK_MODULUS|COMPRESSIBILITY|(^|_)K[ST]_(PA|DERIV)")
ISO = re.compile(r"BULK_MODULUS_T(_|$)|ISOTHERMAL_COMPRESSIBILITY|(^|_)KT_(PA|DERIV)")
ADI = re.compile(r"BULK_MODULUS_S(_|$)|(ADIABATIC|ISENTROPIC)_COMPRESSIBILITY|(^|_)KS_(PA|DERIV)")
CONVERT = re.compile(r"isothermal_modulus\(\s*(?:pc\(\s*\")?\Z")
FIT = re.compile(r"\bconst\s+MgFit\s+\w+\s*=\s*\{[^;]*\};")
APPROX = re.compile(r"LA_APPROX:\s*([a-z0-9_]+)")

rows = {}
for line in open(os.path.join(root, "docs/APPROXIMATIONS.md"), errors="replace"):
    m = re.match(r"^\| `([a-z0-9_]+)` \|", line)
    if m:
        rows[m.group(1)] = line

src, bare = {}, {}
decl = {}
for f in files:
    text = open(os.path.join(root, f), errors="replace").read()
    s = strip(text, f)
    src[f], bare[f] = text.split("\n"), s
    rx = DECL_C if f.endswith(C_LIKE) else DECL[os.path.splitext(f)[1]]
    for m in rx.finditer(s):
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
        if name not in s:
            continue
        lines = s.split("\n")
        for m in word.finditer(s):
            ln = s.count("\n", 0, m.start()) + 1
            if (f, ln) == decl[name]:
                continue
            if CONVERT.search(s[max(0, m.start() - 160):m.start()]):
                continue
            if any(a <= m.start() < b for a, b in fits[f]):
                continue
            top = ln - 1
            while top > 0 and lines[top - 1].strip() and not lines[top - 1].rstrip().endswith((";", "{", "}")):
                top -= 1
            mark = APPROX.search(src[f][top - 1]) if top > 0 else None
            if mark and "`%s`" % name in rows.get(mark.group(1), ""):
                continue
            misread.append("%s:%d  adiabatic %s is read where K_T is: %s" % (f, ln, name, src[f][ln - 1].strip()))

for v in undeclared:
    print("undeclared path: " + v, file=sys.stderr)
for v in misread:
    print(v, file=sys.stderr)
print('MODULUS_PATHS={"constants":%d,"adiabatic":%d,"undeclared":%d,"read_as_kt":%d}'
      % (len(decl), len(adiabatic), len(undeclared), len(misread)))
if len(decl) < 10:
    print("check_modulus_paths: %d modulus constants found; the declaration scan collapsed." % len(decl), file=sys.stderr)
    sys.exit(2)
sys.exit(1 if undeclared or misread else 0)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
echo "check_modulus_paths: OK"

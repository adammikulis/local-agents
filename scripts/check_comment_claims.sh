#!/usr/bin/env bash
# =====================================================================================================
# COMMENT-CLAIM GATE — a source comment may not carry a measurement or a date.
#
# A comment stating a CONTRACT stays true. A comment stating a MEASUREMENT or a HISTORY is true for one commit, and this
# repo is full of the corpses: "the sweep is 0.36 s" (it is 1.0), "-26.7% carbon" (the sign was wrong),
# "matches atmos_evap_sphere3d.glsl" (deleted file). CLAUDE.md has banned this in prose since 2026-08-10 and
# it kept happening, including by the agent that re-read the ban the same hour.
#
# So: numbers that decay and dates belong in git, docs/ and gates. Source carries what the code promises.
#
# RATCHET. MAX_CLAIMS caps the count; it may fall and may not rise. Lower it when you delete some.
#
# EXIT CODES. 0 pass · 1 over the cap or a new file offends · 2 could not run.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAX_CLAIMS="${LA_MAX_COMMENT_CLAIMS:-}"
CAP_FILE="$REPO_ROOT/docs/COMMENT_CLAIMS_CEILING"

command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -d "$REPO_ROOT/addons/local_agents" ] || { echo "ERROR: source root missing." >&2; exit 2; }

python3 - "$REPO_ROOT" "$CAP_FILE" "$MAX_CLAIMS" <<'PY'
import os, re, sys

root, cap_file, cap_arg = sys.argv[1], sys.argv[2], sys.argv[3]

# A percentage, an ISO date, or "measured"/"was"/"reads" next to a figure. Version-like triples (1.2.3) and
# bare small integers are not measurements, so they are not matched.
PCT   = re.compile(r"\d+(?:\.\d+)?\s?%")
DATE  = re.compile(r"\b20\d\d-\d\d-\d\d\b")
MEAS  = re.compile(r"\b(measured|read|reads|was|were|took|costs?)\b[^.\n]{0,40}?\b\d+(?:\.\d+)?(?:e[-+]?\d+)?\b",
                   re.I)
# HISTORY WITH NO NUMBER IN IT ROTS IDENTICALLY, and the first version of this gate could not see it. A
# verifier found 13 such sentences left standing in files the sweep had just edited — including one whose
# same claim had been rewritten into a contract two hundred lines away.
# A LIVE CONDITION BECOMES A MEMOIR THE INSTANT IT CHANGES, so "it is currently true" is not a defence —
# it identifies the class that rots. Every stale claim this repo has produced was true when written:
# "matches atmos_evap_sphere3d.glsl" (that file was deleted), "the always-hot CPU mirror is the honest
# source" (those channels are SLOW_CHANNELS), "dust_loft raining flag parity" (dust_loft was deleted).
# "no longer" and "obsolete" were excluded here on the grounds that they describe present behaviour. That
# was backwards.
HIST  = re.compile(r"\b(used to|previously|formerly|no longer|obsolete|was replaced|replaced by|"
                   r"the old (code|kernel|version|comment|value|way)|before the refactor)\b", re.I)

def comment_of(line, ext):
    if ext == ".gd":
        i = line.find("#")
    else:
        i = line.find("//")
    return line[i:] if i >= 0 else ""

hits = []
for dp, dns, fns in os.walk(os.path.join(root, "addons", "local_agents")):
    dns[:] = [d for d in dns if d not in (".godot", "thirdparty")]
    for fn in sorted(fns):
        ext = os.path.splitext(fn)[1]
        if ext not in (".gd", ".glsl", ".glsli"):
            continue
        path = os.path.join(dp, fn)
        rel = os.path.relpath(path, root)
        try:
            lines = open(path, errors="replace").read().splitlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            c = comment_of(line, ext)
            if not c:
                continue
            why = "percentage" if PCT.search(c) else "date" if DATE.search(c) else \
                  "measurement" if MEAS.search(c) else "history" if HIST.search(c) else None
            if why:
                hits.append((rel, n, why, c.strip()[:88]))

by_file = {}
for rel, n, why, txt in hits:
    by_file.setdefault(rel, []).append((n, why, txt))

cap = None
if cap_arg.strip():
    cap = int(cap_arg)
elif os.path.exists(cap_file):
    for ln in open(cap_file):
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            cap = int(ln); break

print("COMMENT_CLAIMS={\"count\":%d,\"files\":%d,\"cap\":%s}" % (len(hits), len(by_file), cap))
for rel in sorted(by_file)[:12]:
    for n, why, txt in by_file[rel][:2]:
        print("  %s:%d  %s  %s" % (rel, n, why, txt))

if cap is None:
    print("\nERROR: no ceiling. Write the current count to docs/COMMENT_CLAIMS_CEILING.", file=sys.stderr)
    sys.exit(2)
if len(hits) > cap:
    print("\n%d comment claims against a ceiling of %d. A measurement in a comment is true for one commit;"
          % (len(hits), cap))
    print("put it in a gate, a test, or docs/. Source comments say what the code promises.")
    sys.exit(1)
if len(hits) < cap:
    print("NOTE  %d below the ceiling — lower docs/COMMENT_CLAIMS_CEILING to %d to bank it."
          % (cap - len(hits), len(hits)))
print("check_comment_claims: OK")
PY

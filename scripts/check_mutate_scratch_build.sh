#!/usr/bin/env bash
# A MUTATION IS PROVED AGAINST THE TREE THAT HOLDS IT. gate_runner.py's scratch copy carries the tree's own
# extension build: a lane that changed the native sources has every launch refused against another build.
# Staged here from a throwaway repository whose build no primary checkout holds.
# EXIT 0 the scratch carries it · 1 it does not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3
require_tool git

python3 - "$ROOT" <<'PY'
import os, shutil, subprocess, sys, tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import gate_runner

work = tempfile.mkdtemp(prefix="la_scratch_build.")
repo, scratch = os.path.join(work, "repo"), os.path.join(work, "scratch")
try:
    os.makedirs(repo)
    with open(os.path.join(repo, ".gitignore"), "w") as fh:
        fh.write(gate_runner.BIN_REL + "\n")
    for argv in (["init", "-q"], ["add", ".gitignore"], ["commit", "-q", "-m", "base"]):
        subprocess.run(["git", "-C", repo, "-c", "user.name=gate", "-c", "user.email=gate@local"] + argv,
                       check=True, stdout=subprocess.DEVNULL)
    built = os.path.join(repo, gate_runner.BIN_REL)
    os.makedirs(built)
    with open(os.path.join(built, "SOURCE_HASH"), "w") as fh:
        fh.write("this-tree\n")
    gate_runner.ROOT = repo
    gate_runner.stage_scratch(scratch)
    got_path = os.path.join(scratch, gate_runner.BIN_REL, "SOURCE_HASH")
    got = open(got_path).read().strip() if os.path.isfile(got_path) else "absent"
except (OSError, subprocess.CalledProcessError, AttributeError) as exc:
    print("check_mutate_scratch_build: could not stage a scratch tree: %s" % exc, file=sys.stderr)
    sys.exit(2)
finally:
    shutil.rmtree(work, ignore_errors=True)
if got != "this-tree":
    print("check_mutate_scratch_build: a mutation's scratch tree carries build '%s', not the tree's own."
          % got, file=sys.stderr)
    sys.exit(1)
print("check_mutate_scratch_build: OK")
PY

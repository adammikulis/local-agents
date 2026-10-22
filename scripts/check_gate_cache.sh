#!/usr/bin/env bash
# A CACHE HIT AND A COLD RUN AGREE. Real runner and cache code on synthetic gates in a throwaway repository: a
# pass is stored and reused by content; a failure, a silent exit 0, an unrunnable gate and a pass whose inputs
# changed while it ran never are; an integration run, CI and --no-cache read nothing; a `last` row sees the
# launches of the rows after it and declares no inputs. EXIT 0 clean · 1 the cache lied · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3
require_tool git

python3 - "$ROOT" <<'PY'
import json, os, re, shutil, subprocess, sys, tempfile

root = sys.argv[1]
work = tempfile.mkdtemp(prefix="la_gate_cache.")
repo = os.path.join(work, "repo")
failures = []


def put(rel, text, mode=0o755):
    path = os.path.join(repo, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)
    os.chmod(path, mode)


def lint(*args, env=None):
    base = {k: v for k, v in os.environ.items() if k not in ("CI", "LA_INTEGRATE_BRANCH", "LA_LAUNCH_LOG",
                                                              "LA_LINT_CAPTURE", "LA_NO_GPU", "LA_LINT_TIMING_LOG",
                                                              "LA_LOCK_WAIT_LOG", "LA_LINT_LAUNCHES")}
    base.update({"LA_GATE_CACHE": os.path.join(work, "cache"), "GODOT": "true"})
    base.update(env or {})
    run = subprocess.run([sys.executable, "scripts/gate_runner.py", *args], cwd=repo, env=base,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    cache = re.search(r"^LINT_CACHE=(\{.*\})$", run.stdout, re.M)
    return run.returncode, run.stdout, json.loads(cache.group(1)) if cache else None


def expect(label, ok, detail=""):
    if not ok:
        failures.append("%s %s" % (label, detail))


try:
    os.makedirs(repo)
    os.makedirs(os.path.join(repo, "scripts"))
    for name in ("gate_runner.py", "lib_gate_cache.py"):
        shutil.copyfile(os.path.join(root, "scripts", name), os.path.join(repo, "scripts", name))
    put("scripts/lint_capture.sh", '#!/usr/bin/env bash\nmkdir -p "$PWD/.capture" && printf "%s\\n" "$PWD/.capture"\n')
    put("scripts/check_data.sh", '#!/usr/bin/env bash\ngrep -q good "$(dirname "$0")/../data/a.txt" || exit 1\n'
        'echo "check_data: OK"\n')
    put("scripts/check_quiet.sh", '#!/usr/bin/env bash\nexit 0\n')
    put("scripts/check_broken.sh", '#!/usr/bin/env bash\nexit 7\n')
    put("scripts/check_launcher.sh", '#!/usr/bin/env bash\nsleep 0.4\necho "la_godot --headless" >> "$LA_LAUNCH_LOG"\n'
        'echo "check_launcher: OK"\n')
    put("scripts/check_count.sh", '#!/usr/bin/env bash\nn="$(grep -c . "$LA_LAUNCH_LOG")"\n'
        '[ "$n" -ge 1 ] || exit 1\necho "check_count: OK ($n)"\n')
    put("data/a.txt", "good\n", 0o644)
    put("data/b.txt", "x\n", 0o644)
    put("scripts/check_race.sh", '#!/usr/bin/env bash\necho "edited while it ran" >> "$(dirname "$0")/../data/b.txt"\n'
        'echo "check_race: OK"\n')
    put("scripts/gates.toml", "\n".join([
        '[[gate]]\nname = "check_count"\nscript = "scripts/check_count.sh"\nkind = "headless"\n'
        'marker = "^check_count: OK"\nlast = true\n',
        '[[gate]]\nname = "check_data"\nscript = "scripts/check_data.sh"\nkind = "text"\n'
        'marker = "^check_data: OK"\ninputs = ["data/**"]\n',
        '[[gate]]\nname = "check_race"\nscript = "scripts/check_race.sh"\nkind = "text"\n'
        'marker = "^check_race: OK"\ninputs = ["data/**"]\n',
        '[[gate]]\nname = "check_quiet"\nscript = "scripts/check_quiet.sh"\nkind = "text"\n'
        'marker = "^check_quiet: OK"\ninputs = []\n',
        '[[gate]]\nname = "check_broken"\nscript = "scripts/check_broken.sh"\nkind = "text"\n'
        'marker = "^check_broken: OK"\ninputs = []\n',
        '[[gate]]\nname = "check_launcher"\nscript = "scripts/check_launcher.sh"\nkind = "headless"\n'
        'marker = "^check_launcher: OK"\n']), 0o644)
    for argv in (["init", "-q"], ["add", "-A"]):
        subprocess.run(["git", "-C", repo] + argv, check=True, stdout=subprocess.DEVNULL)
    only = ("--only", "check_data")

    rc, out, c = lint(*only)
    expect("cold run", rc == 0 and c == {"declared": 1, "hits": 0, "stored": 1}, (rc, c))
    rc, out, c = lint(*only)
    expect("warm run", rc == 0 and c["hits"] == 1 and "LINT_CACHED: check_data.sh" in out, (rc, c))

    put("data/a.txt", "bad\n", 0o644)
    rc, out, c = lint(*only)
    expect("edited input", rc == 1 and c["hits"] == 0 and c["stored"] == 0, (rc, c))
    rc, out, c = lint(*only)
    expect("a failure is never stored", rc == 1 and c["hits"] == 0, (rc, c))
    put("data/a.txt", "good\n", 0o644)
    rc, out, c = lint(*only)
    expect("the same bytes again", rc == 0 and c["hits"] == 1, (rc, c))

    rc, out, c = lint(*only, env={"LA_INTEGRATE_BRANCH": "lane"})
    expect("integration run", rc == 0 and c["hits"] == 0, (rc, c))
    rc, out, c = lint(*only, env={"CI": "true"})
    expect("CI", rc == 0 and c is None and "LINT_CACHED" not in out, (rc, c))
    rc, out, c = lint("--no-cache", *only)
    expect("--no-cache", rc == 0 and c is None and "LINT_CACHED" not in out, (rc, c))
    rc, out, c = lint(*only, env={"LA_PROBE_KNOB": "1"})
    expect("an LA_ variable is an input", rc == 0 and c["hits"] == 0, (rc, c))

    rc, out, c = lint("--only", "check_race")
    expect("an input edited while the gate ran", rc == 0 and c["stored"] == 0, (rc, c))
    rc, out, c = lint("--only", "check_race")
    expect("and is not stored on the next run either", rc == 0 and c["hits"] == 0 and c["stored"] == 0, (rc, c))

    rc, out, c = lint("--only", "check_quiet")
    expect("a silent exit 0 is unrunnable", rc == 2 and c["stored"] == 0, (rc, c))
    rc, out, c = lint("--only", "check_broken")
    expect("a gate that could not run is unrunnable", rc == 2 and c["stored"] == 0, (rc, c))
    rc, out, c = lint("--only", "check_broken")
    expect("an unrunnable gate is run again", rc == 2 and c["hits"] == 0, (rc, c))

    rows = open(os.path.join(repo, "scripts/gates.toml")).read().split("[[gate]]")
    last, launcher = [r for r in rows if "check_count" in r][0], [r for r in rows if "check_launcher" in r][0]
    put("scripts/gates.toml", "[[gate]]" + last + "[[gate]]" + launcher, 0o644)
    rc, out, c = lint("--all")
    expect("a last row counts the launches after it", rc == 0 and "check_count: OK (1)" in out, (rc, out[-400:]))
    put("scripts/gates.toml", "[[gate]]" + last.replace("last = true\n", "last = true\ninputs = []\n"), 0o644)
    rc, out, c = lint("--all")
    expect("a last row declares no inputs", rc == 2 and "never reusable" in out, (rc, out[-300:]))
except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError) as exc:
    print("check_gate_cache: could not build the fixture: %r" % exc, file=sys.stderr)
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(2)
shutil.rmtree(work, ignore_errors=True)
for line in failures:
    print("FAIL  " + line, file=sys.stderr)
if failures:
    sys.exit(1)
print("check_gate_cache: OK (a pass is stored and reused by content; a failure, a silent pass and an "
      "unrunnable gate never are; integration, CI and --no-cache read nothing)")
PY

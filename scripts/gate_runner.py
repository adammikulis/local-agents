#!/usr/bin/env python3
# ONE RUNNER FOR EVERY STRUCTURAL GATE, driven by scripts/gates.toml.
# Text gates run in a worker pool, engine-touching ones alone and in order; output replays in
# definition order, so the log does not depend on how the work was scheduled.
# EXIT 0 clean · 1 a gate reported a violation · 2 a gate COULD NOT RUN.
import argparse
import concurrent.futures
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import tomllib

# A read refreshes git's index, and that write takes .git/index.lock, which a second gate then cannot
# get. Off, the same comparison happens in core; a diff is decided by content, never by the stat cache.
os.environ.setdefault("GIT_OPTIONAL_LOCKS", "0")

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPTS)
GATES_TOML = os.path.join(SCRIPTS, "gates.toml")
KINDS = ("text", "headless", "gpu")
NEEDS = ("import", "capture", "body", "build")


def load_gates(path=GATES_TOML):
    with open(path, "rb") as fh:
        doc = tomllib.load(fh)
    defaults = doc.get("defaults", {})
    gates = []
    seen = set()
    for i, g in enumerate(doc.get("gate", [])):
        name = g.get("name")
        if not name:
            raise ValueError("gates.toml entry %d has no name" % i)
        if name in seen:
            raise ValueError("gates.toml declares %s twice" % name)
        seen.add(name)
        if g.get("kind") not in KINDS:
            raise ValueError("%s: kind must be one of %s" % (name, ", ".join(KINDS)))
        if not g.get("marker"):
            raise ValueError("%s: no marker, so a silent exit 0 would read as a pass" % name)
        needs = g.get("needs", [] if g["kind"] == "text" else ["import", "capture"])
        if not isinstance(needs, list) or any(n not in NEEDS for n in needs):
            raise ValueError("%s: needs must be a list drawn from %s, not %r" % (name, ", ".join(NEEDS), needs))
        for flag in ("launches", "capture_reader", "last"):
            if flag in g and not isinstance(g[flag], bool):
                raise ValueError("%s: %s must be a boolean" % (name, flag))
        gates.append({
            "name": name,
            "label": g.get("label", name + ".sh"),
            "script": g["script"],
            "kind": g["kind"],
            "marker": g["marker"],
            "mutations": [m for m in ([g["mutation"]] if isinstance(g.get("mutation"), str)
                                      else g.get("mutation", [])) if m],
            "args": list(g.get("args", [])),
            "env": dict(g.get("env", {})),
            "needs": needs,
            # A gate that starts no engine takes no device and waits on no machine lock, so it runs
            # beside the others whatever kind it is. Declared, and the launch ledger holds it to it.
            "launches": bool(g.get("launches", g["kind"] != "text")),
            # Reads the whole run's ledgers, so it runs after every other gate has finished.
            "last": bool(g.get("last", False)),
            "capture_reader": g.get("capture_reader", False),
            "timeout_s": int(g.get("timeout_s", defaults.get("timeout_s", 900))),
        })
    if not gates:
        raise ValueError("gates.toml lists no gate")
    tail = [i for i, g in enumerate(gates) if g["last"]]
    if tail and tail != list(range(len(gates) - len(tail), len(gates))):
        raise ValueError("a gate declaring last = true must be among the final rows: %s"
                         % ", ".join(gates[i]["name"] for i in tail))
    return gates


def effective_launcher(g, capture):
    return g["launches"] or (g["capture_reader"] and not capture)


def launch_count(ledger):
    if not ledger or not os.path.isfile(ledger):
        return 0
    with open(ledger) as source:
        return sum(bool(line.strip()) for line in source)


def run_gate(g, root, ledger, stream):
    """Run one gate. Returns (rc, output, seconds); rc 2 when it could not be started."""
    path = os.path.join(root, g["script"])
    if not os.path.exists(path):
        return 2, "%s is missing from the tree.\n" % g["script"], 0.0
    env = dict(os.environ)
    env.update({k: str(v) for k, v in g["env"].items()})
    if ledger:
        env["LA_LAUNCH_LOG"] = ledger
        open(ledger, "a").close()
    launches_before = launch_count(ledger)
    started = time.monotonic()
    try:
        proc = subprocess.Popen([path] + g["args"], cwd=root, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace",
                                start_new_session=(os.name == "posix"))
    except OSError as exc:
        return 2, "%s could not be started: %s\n" % (g["script"], exc), 0.0
    chunks, read_errors = [], []
    def read_output():
        try:
            for line in proc.stdout:
                chunks.append(line)
                if stream:
                    sys.stdout.write(line)
                    sys.stdout.flush()
        except (OSError, ValueError) as error:
            read_errors.append(str(error))
    reader = threading.Thread(target=read_output, daemon=True, name="gate-output-%s" % proc.pid)
    reader.start()
    deadline = started + g["timeout_s"]
    try:
        rc = proc.wait(timeout=max(0, deadline - time.monotonic()))
        reader.join(timeout=max(0, deadline - time.monotonic()))
        if reader.is_alive():
            raise subprocess.TimeoutExpired(proc.args, g["timeout_s"])
    except subprocess.TimeoutExpired:
        if os.name == "posix":
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            reader.join(timeout=1)
            if proc.poll() is None or reader.is_alive():
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        else:
            proc.kill()
        proc.wait()
        reader.join(timeout=1)
        chunks.append("%s printed no verdict inside %ds.\n" % (g["label"], g["timeout_s"]))
        rc = 2
    if reader.is_alive():
        chunks.append("%s output reader did not stop during owned-process cleanup.\n" % g["label"])
        rc = 2
    if read_errors:
        chunks.append("%s output could not be read: %s\n" % (g["label"], "; ".join(read_errors)))
        rc = 2
    capture = os.path.isdir(env.get("LA_LINT_CAPTURE", ""))
    if launch_count(ledger) > launches_before and not effective_launcher(g, capture):
        chunks.append("%s launched an engine despite its no-launch declaration.\n" % g["label"])
        rc = 1
    return rc, "".join(chunks), time.monotonic() - started


def silent_pass(g, rc, out):
    """A gate that exits 0 without printing its verdict examined nothing."""
    return rc == 0 and re.search(g["marker"], out, re.M) is None


def timing_line(rows, marker):
    body = ",".join('"%s":%.3f' % (label.replace('"', ""), secs)
                    for secs, label in sorted(rows, key=lambda r: -r[0]))
    return "%s={%s}" % (marker, body)


def make_capture(tree=ROOT, arm=None):
    """The shared arm for this lint. Returns (capture dir or None, what it said on stderr)."""
    argv = [os.path.join(tree, "scripts/lint_capture.sh")] + (["--" + arm] if arm else [])
    proc = subprocess.run(argv, cwd=tree,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          errors="replace")
    if proc.returncode != 0 or not proc.stdout.strip():
        return None, proc.stderr
    return proc.stdout.strip(), proc.stderr


def merge_ledger(shared, ledger):
    """Fold one gate's launch ledger into the run's, and say how many launches it held."""
    if not ledger or not os.path.exists(ledger):
        return 0
    with open(ledger) as src:
        text = src.read()
    if text and shared:
        with open(shared, "a") as dst:
            dst.write(text)
    return len([ln for ln in text.splitlines() if ln.strip()])


def note_seconds(label, secs):
    """One line per finished gate, so a gate declaring last = true can add up the run it sits in."""
    path = os.environ.get("LA_LINT_TIMING_LOG")
    if not path:
        return
    with open(path, "a") as fh:
        fh.write("%.3f\t%s\n" % (secs, label.replace("\t", " ")))


def pool_size():
    n = os.environ.get("LA_LINT_JOBS")
    if n and n.isdigit():
        return max(1, int(n))
    return min(8, os.cpu_count() or 4)


def drain(gates, root, jobs, ledger_dir, shared_ledger, no_gpu, on_result, pooled=True):
    """Pool every gate that starts no engine, run the launchers in place, replay in definition order."""
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=jobs)
    ledger_of = {i: os.path.join(ledger_dir, "%d.launch" % i) for i in range(len(gates))}
    # LA_NO_GPU=1 SKIPS A gpu ROW, and a pool that submitted it would run the very gate the arm excludes.
    def in_pool(g):
        return pooled and not effective_launcher(g, pooled) and not g["last"] and not (no_gpu and g["kind"] == "gpu")

    futures = {i: pool.submit(run_gate, g, root, ledger_of[i], False)
               for i, g in enumerate(gates) if in_pool(g)}
    concurrent.futures.wait(futures.values())
    try:
        for i, g in enumerate(gates):
            if no_gpu and g["kind"] == "gpu":
                line = ("LINT_SKIPPED_NO_GPU: %s (declared kind=gpu in gates.toml; run it on a "
                        "machine with a GPU)\n" % g["label"])
                sys.stdout.write(line)
                on_result(g, None, line, 0.0, 0)
                continue
            if i in futures:
                rc, out, secs = futures[i].result()
                sys.stdout.write(out)
            else:
                rc, out, secs = run_gate(g, root, ledger_of[i], True)
            sys.stdout.flush()
            on_result(g, rc, out, secs, merge_ledger(shared_ledger, ledger_of[i]))
    finally:
        pool.shutdown(wait=True)


def summarise(t):
    if t["unrunnable"] > 0:
        print("LINT_SUMMARY: %d gate(s) COULD NOT RUN, %d violation(s). Every gate ran;"
              % (t["unrunnable"], t["failed"]))
        print("              a gate that could not run examined nothing, so this is not a physics "
              "failure.")
        return 2
    if t["failed"] > 0:
        print("LINT_SUMMARY: %d gate(s) failed. Every gate ran; the list above is complete."
              % t["failed"])
        return 1
    if t["skipped"] > 0 or t["not_examined"] > 0:
        print("LINT_SUMMARY: passed, with %d GPU gate(s) SKIPPED and %d NOT EXAMINED by this arm — "
              "this run did not examine them." % (t["skipped"], t["not_examined"]))
        return 0
    print("All lint gates passed (file length gates at soft 1300 / hard 1500; policy markers are "
          "advisory).")
    return 0


def cmd_lint(args):
    gates = load_gates()
    if args.only:
        gates = [g for g in gates if args.only in (g["name"], g["label"])]
        if not gates:
            print("gate_runner: no gate named '%s' in gates.toml." % args.only, file=sys.stderr)
            return 2
    no_gpu = os.environ.get("LA_NO_GPU", "0") == "1"
    tally = {"failed": 0, "unrunnable": 0, "skipped": 0, "not_examined": 0}
    timing, records = [], []
    ledger_dir = tempfile.mkdtemp(prefix="la_gate_ledger.")

    # WHICH TREE THIS LINT WEIGHED. LOG_DIR is machine-wide, so a reader of "the newest lint log" would
    # otherwise bank another worktree's numbers into this one's ceilings.
    print("LINT_TREE=%s" % ROOT)
    print("LINT_SCOPE=" + json.dumps({"full": not bool(args.only), "gpu": not no_gpu,
                                    "arm": "body" if args.body else "slice"}, sort_keys=True))
    for name in ("LA_LINT_TIMING_LOG", "LA_LOCK_WAIT_LOG"):
        if os.environ.get(name):
            open(os.environ[name], "w").close()
    capture_started = time.monotonic()
    cap, cap_err = make_capture(arm="body" if args.body else "slice")
    capture_seconds = time.monotonic() - capture_started
    note_seconds("lint_capture.sh", capture_seconds)
    if cap_err:
        sys.stdout.write(cap_err)
    if cap:
        os.environ["LA_LINT_CAPTURE"] = cap
        print("LINT_CAPTURE=%s" % cap)
    else:
        print("LINT_UNRUNNABLE: lint_capture.sh (2)")
        tally["unrunnable"] += 1

    def on_result(g, rc, out, secs, launches):
        timing.append((secs, g["label"]))
        if not g["last"]:
            note_seconds(g["label"], secs)
        records.append({"name": g["name"], "label": g["label"], "kind": g["kind"],
                        "rc": rc, "seconds": round(secs, 3), "launches": launches})
        if rc is None:
            tally["skipped"] += 1
        elif not effective_launcher(g, bool(cap)) and launches:
            print("LINT_FAIL: %s (1) — declared launches = false in gates.toml and started the engine "
                  "%d time(s). A gate that starts one runs alone: drop the declaration."
                  % (g["label"], launches))
            tally["failed"] += 1
        elif silent_pass(g, rc, out):
            print("LINT_UNRUNNABLE: %s (2) — exited 0 without printing the verdict line its "
                  "gates.toml marker /%s/ names, so it examined nothing." % (g["label"], g["marker"]))
            tally["unrunnable"] += 1
        elif rc == 1:
            print("LINT_FAIL: %s (1)" % g["label"])
            tally["failed"] += 1
        elif rc == 3:
            tally["not_examined"] += 1
        elif rc != 0:
            print("LINT_UNRUNNABLE: %s (%s)" % (g["label"], rc))
            tally["unrunnable"] += 1

    try:
        # A gate declares launches = false because the capture answers instead. With no capture every
        # one of them falls through to its own launch, so nothing is pooled and none of them races.
        drain(gates, ROOT, args.jobs or pool_size(), ledger_dir,
              os.environ.get("LA_LAUNCH_LOG"), no_gpu, on_result, pooled=bool(cap))
    finally:
        shutil.rmtree(ledger_dir, ignore_errors=True)

    print(timing_line(timing, "LINT_TIMING"))
    if args.timing:
        for secs, label in sorted(timing, key=lambda r: -r[0])[:20]:
            print("  %8.3f  %s" % (secs, label), file=sys.stderr)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"gates": records, "summary": tally}, fh, indent=2, sort_keys=True)
    result = summarise(tally)
    if result == 0 and not args.only and not no_gpu and not args.body and cap:
        print("LINT_BANKABLE=1")
    return result


def git(root, *argv, check=True):
    return subprocess.run(["git", "-C", root] + list(argv), stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, errors="replace", check=check)


BIN_REL = os.path.join("addons", "local_agents", "gdextensions", "localagents", "bin")


def stage_scratch(scratch):
    """A detached copy of HEAD carrying this tree's uncommitted work, so it tests what is here."""
    git(ROOT, "worktree", "add", "--detach", scratch, "HEAD")
    # THIS TREE'S EXTENSION BUILD: a lane that changed the native sources carries its own, and the primary
    # checkout's, which ensure_worktree_ready.sh would copy in its place, is refused against these sources.
    if os.path.isdir(os.path.join(ROOT, BIN_REL)):
        shutil.copytree(os.path.join(ROOT, BIN_REL), os.path.join(scratch, BIN_REL), symlinks=True)
    diff = git(ROOT, "diff", "HEAD", "--binary").stdout
    if diff.strip():
        subprocess.run(["git", "-C", scratch, "apply", "--whitespace=nowarn", "-"],
                       input=diff, text=True, check=True)
    for rel in git(ROOT, "ls-files", "--others", "--exclude-standard").stdout.splitlines():
        src, dst = os.path.join(ROOT, rel), os.path.join(scratch, rel)
        if os.path.isfile(src):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)


def arm_ledgers(scratch):
    """The ledgers a lint keeps, for a gate that reads the run around it. Both arms get the same ones."""
    os.environ["LA_LINT_LAUNCHES"] = os.path.join(scratch, "mutate_launches.log")
    os.environ["LA_LINT_TIMING_LOG"] = os.path.join(scratch, "mutate_seconds.log")
    os.environ["LA_LOCK_WAIT_LOG"] = os.path.join(scratch, "mutate_lock_waits.log")
    open(os.environ["LA_LINT_LAUNCHES"], "w").close()
    open(os.environ["LA_LOCK_WAIT_LOG"], "w").close()
    with open(os.environ["LA_LINT_TIMING_LOG"], "w") as fh:
        fh.write("0.100\tcheck_mutate_arm_a.sh\n0.100\tcheck_mutate_arm_b.sh\n")


EXT_REL = "addons/local_agents/gdextensions/localagents"


def build_scratch(scratch):
    """A native mutation is one only once compiled: every launch refuses a bin built from other sources."""
    deps = os.path.join(scratch, EXT_REL, "thirdparty")
    if not os.path.lexists(deps):
        os.symlink(os.path.realpath(os.path.join(ROOT, EXT_REL, "thirdparty")), deps)
    return subprocess.run([os.path.join(scratch, EXT_REL, "scripts/build_extension.sh"), "--platform", "macos"],
                          cwd=scratch, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def arm_scratch(g, scratch, first=False):
    """Give the scratch tree what the gate declares it needs. A mutation may break either, on purpose.
    False when the tree's own extension does not build, which leaves nothing to run the gate on."""
    if "build" in g["needs"] and not build_scratch(scratch):
        return False
    if "import" in g["needs"]:
        if subprocess.run([os.path.join(scratch, "scripts/ensure_worktree_ready.sh")], cwd=scratch).returncode != 0:
            return False
    os.environ.pop("LA_LINT_CAPTURE", None)
    if "capture" in g["needs"]:
        cap, _ = make_capture(scratch, arm="body" if "body" in g["needs"] else "slice")
        if not cap:
            return False
        os.environ["LA_LINT_CAPTURE"] = cap
    # ONCE, BEFORE EITHER ARM: a mutation that writes into the ledger must survive the re-arming.
    if g["last"] and first:
        arm_ledgers(scratch)
    return True


def cmd_mutate(args):
    gates = {g["name"]: g for g in load_gates()}
    g = gates.get(args.mutate)
    if g is None:
        print("gate_runner: no gate named '%s'." % args.mutate, file=sys.stderr)
        return 2
    if not g["mutations"]:
        print("gate_runner: %s declares no mutation in gates.toml. A gate nobody can make fail on "
              "purpose is not a gate — write one." % g["name"], file=sys.stderr)
        return 2
    return max(mutate_one(g, m) for m in g["mutations"])


def mutate_one(g, mutation):
    """One mutation, in its own scratch tree."""
    scratch = os.path.join(tempfile.mkdtemp(prefix="la_mutate_"), "tree")
    ledger = os.path.join(tempfile.mkdtemp(prefix="la_mutate_ledger."), "launches.log")
    open(ledger, "w").close()
    os.environ["LA_LAUNCH_LOG"] = ledger
    try:
        stage_scratch(scratch)
        if not arm_scratch(g, scratch, first=True):
            print("MUTATION_UNRUNNABLE: %s — the unmutated scratch tree's extension did not build." % g["name"])
            return 2
        rc0, out0, _ = run_gate(g, scratch, ledger, False)
        sys.stdout.write(out0)
        if rc0 != 0:
            print("MUTATION_UNRUNNABLE: %s is already %d on the unmutated tree, so this proves "
                  "nothing." % (g["name"], rc0))
            return 2
        if subprocess.run(["bash", "-c", mutation], cwd=scratch).returncode != 0:
            print("MUTATION_UNRUNNABLE: %s — the mutation command itself failed." % g["name"])
            return 2
        if not arm_scratch(g, scratch):
            print("MUTATION_UNRUNNABLE: %s — `%s` left an extension that does not build." % (g["name"], mutation))
            return 2
        rc1, out1, _ = run_gate(g, scratch, ledger, False)
        sys.stdout.write(out1)
        # A gate that could not run under the mutation reported no violation, so it caught nothing.
        if rc1 not in (0, 1):
            print("MUTATION_UNRUNNABLE: %s could not run under `%s`, which proves nothing." % (g["name"], mutation))
            return 2
        if rc1 == 0:
            print("MUTATION_SURVIVED: %s stayed green under `%s`. It cannot fail, so it is not a "
                  "gate." % (g["name"], mutation))
            return 1
        print("MUTATION_KILLED: %s went %d under `%s`." % (g["name"], rc1, mutation))
        return 0
    finally:
        git(ROOT, "worktree", "remove", "--force", scratch, check=False)
        shutil.rmtree(os.path.dirname(scratch), ignore_errors=True)


def cmd_list():
    for g in load_gates():
        print("%s\t%s\t%s\t%s" % (g["name"], g["kind"], g["label"], g["script"]))
    return 0


def main(argv):
    p = argparse.ArgumentParser(description="Run the structural gates in scripts/gates.toml.")
    p.add_argument("--only", metavar="NAME", help="run one gate by name")
    p.add_argument("--mutate", metavar="NAME", help="prove one gate can fail, in a scratch worktree")
    p.add_argument("--list", action="store_true", help="print name/kind/label/script, one per line")
    p.add_argument("--timing", action="store_true", help="also print the slowest gates to stderr")
    p.add_argument("--json", metavar="OUT", help="write per-gate results to a JSON file")
    p.add_argument("--jobs", type=int, help="pool width (default LA_LINT_JOBS or the core count)")
    p.add_argument("--body", action="store_true",
                   help="take the shared arm over the whole planet instead of a slice of it")
    args = p.parse_args(argv)
    try:
        if args.list:
            return cmd_list()
        if args.mutate:
            return cmd_mutate(args)
        return cmd_lint(args)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        print("LINT_UNRUNNABLE: gates.toml (2) — %s" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

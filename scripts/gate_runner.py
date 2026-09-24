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
import subprocess
import sys
import tempfile
import time
import tomllib

# A read refreshes git's index, and that write takes .git/index.lock, which a second gate then cannot
# get. Off, the same comparison happens in core; a diff is decided by content, never by the stat cache.
os.environ.setdefault("GIT_OPTIONAL_LOCKS", "0")

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPTS)
GATES_TOML = os.path.join(SCRIPTS, "gates.toml")
KINDS = ("text", "headless", "gpu")
NEEDS = ("import", "capture", "body")


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
            "timeout_s": int(g.get("timeout_s", defaults.get("timeout_s", 900))),
        })
    if not gates:
        raise ValueError("gates.toml lists no gate")
    return gates


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
    started = time.monotonic()
    try:
        proc = subprocess.Popen([path] + g["args"], cwd=root, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace")
    except OSError as exc:
        return 2, "%s could not be started: %s\n" % (g["script"], exc), 0.0
    chunks = []
    try:
        if stream:
            for line in proc.stdout:
                chunks.append(line)
                sys.stdout.write(line)
                sys.stdout.flush()
            rc = proc.wait(timeout=g["timeout_s"])
        else:
            chunks.append(proc.communicate(timeout=g["timeout_s"])[0])
            rc = proc.returncode
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        chunks.append("%s printed no verdict inside %ds.\n" % (g["label"], g["timeout_s"]))
        rc = 124
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


def pool_size():
    n = os.environ.get("LA_LINT_JOBS")
    if n and n.isdigit():
        return max(1, int(n))
    return min(8, os.cpu_count() or 4)


def drain(gates, root, jobs, ledger_dir, shared_ledger, no_gpu, on_result):
    """Pool the text gates, run the rest in place, replay every verdict in definition order."""
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=jobs)
    ledger_of = {i: os.path.join(ledger_dir, "%d.launch" % i) for i in range(len(gates))}
    futures = {i: pool.submit(run_gate, g, root, ledger_of[i], False)
               for i, g in enumerate(gates) if g["kind"] == "text"}
    # An engine gate times frames on this machine: none starts while the pool still holds a core.
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

    cap, cap_err = make_capture(arm="body" if args.body else "slice")
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
        records.append({"name": g["name"], "label": g["label"], "kind": g["kind"],
                        "rc": rc, "seconds": round(secs, 3), "launches": launches})
        if rc is None:
            tally["skipped"] += 1
        elif g["kind"] == "text" and launches:
            print("LINT_FAIL: %s (1) — declared kind=text in gates.toml and launched the engine %d "
                  "time(s). A gate that starts one runs alone: declare it kind=headless."
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
        drain(gates, ROOT, args.jobs or pool_size(), ledger_dir,
              os.environ.get("LA_LAUNCH_LOG"), no_gpu, on_result)
    finally:
        shutil.rmtree(ledger_dir, ignore_errors=True)

    print(timing_line(timing, "LINT_TIMING"))
    if args.timing:
        for secs, label in sorted(timing, key=lambda r: -r[0])[:20]:
            print("  %8.3f  %s" % (secs, label), file=sys.stderr)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"gates": records, "summary": tally}, fh, indent=2, sort_keys=True)
    return summarise(tally)


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


def arm_scratch(g, scratch):
    """Give the scratch tree what the gate declares it needs. A mutation may break either, on purpose."""
    if "import" in g["needs"]:
        subprocess.run([os.path.join(scratch, "scripts/ensure_worktree_ready.sh")], cwd=scratch)
    os.environ.pop("LA_LINT_CAPTURE", None)
    if "capture" in g["needs"]:
        cap, _ = make_capture(scratch, arm="body" if "body" in g["needs"] else "slice")
        if cap:
            os.environ["LA_LINT_CAPTURE"] = cap


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
        arm_scratch(g, scratch)
        rc0, out0, _ = run_gate(g, scratch, ledger, False)
        sys.stdout.write(out0)
        if rc0 != 0:
            print("MUTATION_UNRUNNABLE: %s is already %d on the unmutated tree, so this proves "
                  "nothing." % (g["name"], rc0))
            return 2
        if subprocess.run(["bash", "-c", mutation], cwd=scratch).returncode != 0:
            print("MUTATION_UNRUNNABLE: %s — the mutation command itself failed." % g["name"])
            return 2
        arm_scratch(g, scratch)
        rc1, out1, _ = run_gate(g, scratch, ledger, False)
        sys.stdout.write(out1)
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

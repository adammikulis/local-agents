#!/usr/bin/env python3
# ONE RUNNER FOR EVERY STRUCTURAL GATE, driven by scripts/gates.toml. A worker pool runs every gate that needs
# no device beside one in-order queue of gpu gates; `exclusive` rows run with the pool idle, `last` rows after
# every other gate; a gate whose `inputs` are unchanged since its last pass is not run (lib_gate_cache.py).
# Output replays in definition order. EXIT 0 clean · 1 a gate reported a violation · 2 a gate COULD NOT RUN.
import argparse
import concurrent.futures
import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import tomllib

sys.dont_write_bytecode = True  # no .pyc beside the scripts
import lib_gate_cache as gate_cache  # noqa: E402

# A read refreshes git's index, and that write takes .git/index.lock, which a second gate then cannot
# get. Off, the same comparison happens in core; a diff is decided by content, never by the stat cache.
os.environ.setdefault("GIT_OPTIONAL_LOCKS", "0")

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPTS)
GATES_TOML = os.path.join(SCRIPTS, "gates.toml")
KINDS = ("text", "headless", "gpu")
NEEDS = ("import", "capture", "body", "build")


def mutation_of(name, m):
    """A mutation turns the gate red. A table names the exit, and the line, of the arm it must fire."""
    if isinstance(m, str):
        return {"cmd": m, "exit": None, "says": None}
    if not isinstance(m, dict) or not all(isinstance(m.get(k), t) for k, t in
                                          (("cmd", str), ("exit", int), ("says", str))):
        raise ValueError("%s: a mutation is a command, or a table with cmd, exit and says" % name)
    return {"cmd": m["cmd"], "exit": m["exit"], "says": m["says"]}


def load_doc(path=GATES_TOML):
    """The gate rows and the named input sets of gates.toml."""
    with open(path, "rb") as fh:
        doc = tomllib.load(fh)
    defaults = doc.get("defaults", {})
    sets = doc.get("sets", {})
    for set_name, globs in sets.items():
        if not isinstance(globs, list) or not all(isinstance(x, str) and not x.startswith("@") for x in globs):
            raise ValueError("[sets].%s must be a list of globs, none of them another set" % set_name)
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
        inputs = g.get("inputs")
        if inputs is not None:
            if not isinstance(inputs, list) or not all(isinstance(x, str) for x in inputs):
                raise ValueError("%s: inputs must be a list of globs" % name)
            if g.get("last"):
                raise ValueError("%s: a `last` row reads the whole run's ledger, so a pass is never reusable; "
                                 "it declares no inputs" % name)
            gate_cache.expand_inputs(inputs, sets)
        gates.append({
            "name": name,
            "label": g.get("label", name + ".sh"),
            "script": g["script"],
            "kind": g["kind"],
            "marker": g["marker"],
            "mutations": [mutation_of(name, m) for m in ([g["mutation"]] if isinstance(g.get("mutation"), str)
                                                        else g.get("mutation", [])) if m],
            "args": list(g.get("args", [])),
            "env": dict(g.get("env", {})),
            "needs": needs,
            "inputs": inputs,
            "last": bool(g.get("last", False)),
            "exclusive": bool(g.get("exclusive", False)),
            "timeout_s": int(g.get("timeout_s", defaults.get("timeout_s", 900))),
            "raw": g,
        })
    if not gates:
        raise ValueError("gates.toml lists no gate")
    return gates, sets


def load_gates(path=GATES_TOML):
    return load_doc(path)[0]


def run_gate(g, root, ledger, sink=None, extra_env=None):
    """Run one gate. Returns (rc, output, seconds); rc 2 when it could not be started. `sink` takes each
    line as it arrives."""
    path = os.path.join(root, g["script"])
    if not os.path.exists(path):
        return 2, "%s is missing from the tree.\n" % g["script"], 0.0
    env = dict(os.environ)
    env.update({k: str(v) for k, v in g["env"].items()})
    env.update(extra_env or {})
    if ledger:
        env["LA_LAUNCH_LOG"] = ledger
        open(ledger, "a").close()
    started = time.monotonic()
    try:
        proc = subprocess.Popen([path] + g["args"], cwd=root, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    except OSError as exc:
        return 2, "%s could not be started: %s\n" % (g["script"], exc), 0.0
    chunks = []

    def pump():
        for line in proc.stdout:
            chunks.append(line)
            if sink:
                sink(line)

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    timed_out = False
    try:
        rc = proc.wait(timeout=g["timeout_s"])
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        rc, timed_out = 124, True
    reader.join(timeout=30)
    if timed_out:
        late = "%s printed no verdict inside %ds.\n" % (g["label"], g["timeout_s"])
        chunks.append(late)
        if sink:
            sink(late)
    return rc, "".join(chunks), time.monotonic() - started


def silent_pass(g, rc, out):
    """A gate that exits 0 without printing its verdict examined nothing."""
    return rc == 0 and re.search(g["marker"], out, re.M) is None


def verdict(g, rc, out, launches):
    """What one finished gate came to: pass, fail, unrunnable, not_examined, silent or text_launched."""
    if g["kind"] == "text" and launches:
        return "text_launched"
    if silent_pass(g, rc, out):
        return "silent"
    if rc == 1:
        return "fail"
    if rc == 3:
        return "not_examined"
    return "pass" if rc == 0 else "unrunnable"


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


def pool_size():
    n = os.environ.get("LA_LINT_JOBS")
    if n and n.isdigit():
        return max(1, int(n))
    return min(8, os.cpu_count() or 4)


class Quiet:
    """Shared holders run side by side; an exclusive one runs alone, and a waiting one is not overtaken."""

    def __init__(self):
        self.cv = threading.Condition()
        self.readers = 0
        self.writer = False
        self.waiting = 0

    @contextlib.contextmanager
    def shared(self):
        with self.cv:
            while self.writer or self.waiting:
                self.cv.wait()
            self.readers += 1
        try:
            yield
        finally:
            with self.cv:
                self.readers -= 1
                self.cv.notify_all()

    @contextlib.contextmanager
    def alone(self):
        with self.cv:
            self.waiting += 1
            while self.writer or self.readers:
                self.cv.wait()
            self.waiting -= 1
            self.writer = True
        try:
            yield
        finally:
            with self.cv:
                self.writer = False
                self.cv.notify_all()


class Job:
    def __init__(self, index, gate):
        self.index, self.gate = index, gate
        self.lines, self.done = [], False
        self.rc, self.seconds, self.launches = None, 0.0, 0
        self.verdict, self.key = None, None


class Lint:
    """Every gate of one run: planned, run in two lanes, and replayed in definition order. A gate that may
    read the shared capture waits for `release`; every other gate starts at once."""

    def __init__(self, gates, root, width, ledger_dir, shared_ledger, no_gpu, cache, waits):
        self.root, self.cache, self.waits = root, cache, waits
        self.jobs = [Job(i, g) for i, g in enumerate(gates)]
        self.width, self.shared = width, shared_ledger
        self.ledger_of = {j.index: os.path.join(ledger_dir, "%d.launch" % j.index) for j in self.jobs}
        self.cv = threading.Condition()
        self.merge_lock = threading.Lock()
        self.quiet = Quiet()
        self.ready = threading.Event()
        self.extra_env = {}
        self.aborted = False
        self.stored = 0
        self.driver = None
        for j in self.jobs:
            if no_gpu and j.gate["kind"] == "gpu":
                self.settle(j, None, "LINT_SKIPPED_NO_GPU: %s (declared kind=gpu in gates.toml; run it on a "
                            "machine with a GPU)\n" % j.gate["label"], 0.0, 0, "skipped")

    def plan(self, keys, read_cache):
        """Give each keyed gate its key, and settle the ones whose pass is already on file."""
        for index, key in keys.items():
            job = self.jobs[index]
            job.key = key
            if read_cache and not job.done and self.cache.has(job.gate["name"], key):
                self.settle(job, 0, "LINT_CACHED: %s\n" % job.gate["label"], 0.0, 0, "cached")

    def settle(self, job, rc, out, secs, launches, verdict_):
        with self.cv:
            job.lines = [out] if out else []
            job.rc, job.seconds, job.launches, job.verdict, job.done = rc, secs, launches, verdict_, True
            self.cv.notify_all()

    def merge(self, ledger):
        """Fold one gate's launch ledger into the run's, and say how many launches it held."""
        if not os.path.exists(ledger):
            return 0
        with self.merge_lock, open(ledger) as src:
            text = src.read()
            if text and self.shared:
                with open(self.shared, "a") as dst:
                    dst.write(text)
        return len([ln for ln in text.splitlines() if ln.strip()])

    def execute(self, job):
        g = job.gate
        if job.done:
            return
        if self.aborted:
            self.settle(job, 2, "%s: the run was abandoned before it started.\n" % g["label"], 0.0, 0, "unrunnable")
            return
        try:
            ledger = self.shared if g["last"] else self.ledger_of[job.index]
            rc, out, secs = run_gate(g, self.root, ledger, self.emit(job), self.extra_env)
            launches = 0 if g["last"] else self.merge(ledger)
            found = verdict(g, rc, out, launches)
        except Exception as exc:
            rc, secs, launches, found = 2, 0.0, 0, "unrunnable"
            self.emit(job)("%s: the runner failed while running it: %r\n" % (g["label"], exc))
        if found == "pass" and job.key and self.cache and self.cache.put(g["name"], job.key, secs):
            self.stored += 1
        with self.cv:
            job.rc, job.seconds, job.launches, job.verdict, job.done = rc, secs, launches, found, True
            self.cv.notify_all()

    def emit(self, job):
        def sink(line):
            with self.cv:
                job.lines.append(line)
                self.cv.notify_all()
        return sink

    def in_pool(self, job):
        if job.index in self.waits:
            self.ready.wait()
        with self.quiet.shared():
            self.execute(job)

    def engine_lane(self, queue):
        for job in queue:
            if job.index in self.waits:
                self.ready.wait()
            if job.gate["exclusive"]:
                with self.quiet.alone():
                    self.execute(job)
            else:
                self.execute(job)

    def drive(self):
        def order(jobs):
            return [j for j in jobs if j.index not in self.waits] + [j for j in jobs if j.index in self.waits]

        pool_jobs = order([j for j in self.jobs if not j.gate["last"] and j.gate["kind"] != "gpu"
                           and not j.gate["exclusive"]])
        queue = order([j for j in self.jobs if not j.gate["last"]
                       and (j.gate["kind"] == "gpu" or j.gate["exclusive"])])
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=self.width) as pool:
                futures = [pool.submit(self.in_pool, j) for j in pool_jobs]
                lane = threading.Thread(target=self.engine_lane, args=(queue,))
                lane.start()
                lane.join()
                concurrent.futures.wait(futures)
            self.ready.wait()
            for job in self.jobs:
                if job.gate["last"]:
                    self.execute(job)
        finally:
            for job in self.jobs:
                if not job.done:
                    self.settle(job, 2, "%s: the runner never ran it.\n" % job.gate["label"], 0.0, 0, "unrunnable")

    def start(self):
        self.driver = threading.Thread(target=self.drive, daemon=True)
        self.driver.start()

    def release(self, capture):
        """The capture stands (or could not be made): the gates waiting on it may run."""
        if capture:
            self.extra_env = {"LA_LINT_CAPTURE": capture}
        self.ready.set()

    def replay(self, on_result):
        for job in self.jobs:
            printed = 0
            while True:
                with self.cv:
                    while printed == len(job.lines) and not job.done:
                        self.cv.wait(1.0)
                    chunk, done = job.lines[printed:], job.done
                for line in chunk:
                    sys.stdout.write(line)
                sys.stdout.flush()
                printed += len(chunk)
                if done:
                    break
            on_result(job)

    def finish(self):
        """Wait for the run; one abandoned before its capture stood runs nothing more."""
        self.aborted = self.aborted or not self.ready.is_set()
        self.ready.set()
        self.driver.join()


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


def open_cache(args):
    """(cache, may_read). CI earns every pass; an integration run reads none, but its passes are real."""
    if args.no_cache or os.environ.get("CI"):
        return None, False
    return gate_cache.Cache(), not os.environ.get("LA_INTEGRATE_BRANCH")


def plan_keys(gates, sets, no_gpu, tree, ambient, capture, indexes):
    """A content key for each of `indexes` that declares inputs, or none when the tree cannot be read."""
    try:
        return {i: gate_cache.gate_key(gates[i], sets, tree, ambient, capture) for i in indexes
                if gates[i]["inputs"] is not None and not (no_gpu and gates[i]["kind"] == "gpu")}
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print("LINT_CACHE_OFF: %s" % exc)
        return {}


def cmd_lint(args):
    gates, sets = load_doc()
    if args.only:
        known = {n for g in gates for n in (g["name"], g["label"])}
        absent = [n for n in args.only if n not in known]
        if absent:
            print("gate_runner: no gate named '%s' in gates.toml." % absent[0], file=sys.stderr)
            return 2
        gates = [g for g in gates if g["name"] in args.only or g["label"] in args.only]
    no_gpu = os.environ.get("LA_NO_GPU", "0") == "1"
    tally = {"failed": 0, "unrunnable": 0, "skipped": 0, "not_examined": 0, "cached": 0}
    timing, records = [], []
    ledger_dir = tempfile.mkdtemp(prefix="la_gate_ledger.")
    shared = os.environ.get("LA_LAUNCH_LOG")
    if not shared:
        shared = os.path.join(ledger_dir, "run.launch")
        os.environ["LA_LAUNCH_LOG"] = shared
    open(shared, "a").close()

    cache, read_cache = open_cache(args)
    tree, ambient = gate_cache.Tree(ROOT), gate_cache.Ambient(ROOT)
    waits = {i for i, g in enumerate(gates) if gate_cache.reads_capture(g, tree)}
    lint = Lint(gates, ROOT, args.jobs or pool_size(), ledger_dir, shared, no_gpu, cache, waits)
    keys = {}
    if cache:
        keys = plan_keys(gates, sets, no_gpu, tree, ambient, None, [i for i in range(len(gates)) if i not in waits])
        lint.plan(keys, read_cache)

    def on_result(job):
        g, v = job.gate, job.verdict
        timing.append((job.seconds, g["label"]))
        records.append({"name": g["name"], "label": g["label"], "kind": g["kind"], "rc": job.rc,
                        "seconds": round(job.seconds, 3), "launches": job.launches, "cached": v == "cached"})
        if v in ("skipped", "cached", "not_examined"):
            tally[v] += 1
        elif v == "text_launched":
            print("LINT_FAIL: %s (1) — declared kind=text in gates.toml and launched the engine %d "
                  "time(s). A gate that starts one runs alone: declare it kind=headless."
                  % (g["label"], job.launches))
            tally["failed"] += 1
        elif v == "silent":
            print("LINT_UNRUNNABLE: %s (2) — exited 0 without printing the verdict line its "
                  "gates.toml marker /%s/ names, so it examined nothing." % (g["label"], g["marker"]))
            tally["unrunnable"] += 1
        elif v == "fail":
            print("LINT_FAIL: %s (1)" % g["label"])
            tally["failed"] += 1
        elif v == "unrunnable":
            print("LINT_UNRUNNABLE: %s (%s)" % (g["label"], job.rc))
            tally["unrunnable"] += 1

    lint.start()
    try:
        cap, cap_err = make_capture(arm="body" if args.body else "slice")
        if cap_err:
            sys.stdout.write(cap_err)
        if cap:
            print("LINT_CAPTURE=%s" % cap)
        else:
            print("LINT_UNRUNNABLE: lint_capture.sh (2)")
            tally["unrunnable"] += 1
        if cache:
            late = plan_keys(gates, sets, no_gpu, tree, ambient, cap, sorted(waits))
            keys.update(late)
            lint.plan(late, read_cache)
        lint.release(cap)
        lint.replay(on_result)
    finally:
        lint.finish()
        shutil.rmtree(ledger_dir, ignore_errors=True)

    if cache:
        print('LINT_CACHE={"declared":%d,"hits":%d,"stored":%d}' % (len(keys), tally["cached"], lint.stored))
    print(timing_line(timing, "LINT_TIMING"))
    if args.timing:
        for secs, label in sorted(timing, key=lambda r: -r[0])[:20]:
            print("  %8.3f  %s" % (secs, label), file=sys.stderr)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"gates": records, "summary": tally}, fh, indent=2, sort_keys=True)
    return summarise(tally)


def cmd_check_inputs():
    gates, sets = load_doc()
    rows = [g for g in gates if g["inputs"] is not None]
    if not rows:
        print("check_gate_inputs: gates.toml declares no `inputs` row, so no pass is ever reused.", file=sys.stderr)
        return 2
    problems = gate_cache.check_inputs(ROOT, gates, sets)
    for problem in problems:
        print("FAIL  " + problem, file=sys.stderr)
    if problems:
        return 1
    print("check_gate_inputs: OK (%d row(s) declare inputs; each glob matches, each moves the key when its "
          "bytes change, and a file no row reads does not)" % len(rows))
    return 0


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


EXT_REL = "addons/local_agents/gdextensions/localagents"


def build_scratch(scratch):
    """A native mutation is one only once compiled: every launch refuses a bin built from other sources."""
    deps = os.path.join(scratch, EXT_REL, "thirdparty")
    if not os.path.lexists(deps):
        os.symlink(os.path.realpath(os.path.join(ROOT, EXT_REL, "thirdparty")), deps)
    return subprocess.run([os.path.join(scratch, EXT_REL, "scripts/build_extension.sh"), "--platform", "macos"],
                          cwd=scratch, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def arm_scratch(g, scratch):
    """Give the scratch tree what the gate declares it needs. A mutation may break either, on purpose.
    False when the tree's own extension does not build, which leaves nothing to run the gate on."""
    if "build" in g["needs"] and not build_scratch(scratch):
        return False
    if "import" in g["needs"]:
        subprocess.run([os.path.join(scratch, "scripts/ensure_worktree_ready.sh")], cwd=scratch)
    os.environ.pop("LA_LINT_CAPTURE", None)
    if "capture" in g["needs"]:
        cap, _ = make_capture(scratch, arm="body" if "body" in g["needs"] else "slice")
        if cap:
            os.environ["LA_LINT_CAPTURE"] = cap
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


def mutate_one(g, m):
    """One mutation, in its own scratch tree."""
    mutation = m["cmd"]
    scratch = os.path.join(tempfile.mkdtemp(prefix="la_mutate_"), "tree")
    ledger = os.path.join(tempfile.mkdtemp(prefix="la_mutate_ledger."), "launches.log")
    open(ledger, "w").close()
    os.environ["LA_LAUNCH_LOG"] = ledger
    try:
        stage_scratch(scratch)
        if not arm_scratch(g, scratch):
            print("MUTATION_UNRUNNABLE: %s — the unmutated scratch tree's extension did not build." % g["name"])
            return 2
        rc0, out0, _ = run_gate(g, scratch, ledger)
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
        rc1, out1, _ = run_gate(g, scratch, ledger)
        sys.stdout.write(out1)
        if m["exit"] is not None:
            if rc1 == m["exit"] and re.search(m["says"], out1, re.M):
                print("MUTATION_KILLED: %s went %d under `%s`, the arm it declares." % (g["name"], rc1, mutation))
                return 0
            print("MUTATION_SURVIVED: %s went %d under `%s`, where the declared arm exits %d saying %r."
                  % (g["name"], rc1, mutation, m["exit"], m["says"]))
            return 1
        # A gate that could not run under the mutation reported no violation, so it caught nothing.
        if rc1 == 2:
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
    p.add_argument("--only", metavar="NAME", action="append", help="run this gate by name; repeat for more")
    p.add_argument("--mutate", metavar="NAME", help="prove one gate can fail, in a scratch worktree")
    p.add_argument("--list", action="store_true", help="print name/kind/label/script, one per line")
    p.add_argument("--check-inputs", action="store_true",
                   help="prove every `inputs` row names real files and moves its key with their bytes")
    p.add_argument("--no-cache", action="store_true", help="run every gate; reuse no earlier pass")
    p.add_argument("--timing", action="store_true", help="also print the slowest gates to stderr")
    p.add_argument("--json", metavar="OUT", help="write per-gate results to a JSON file")
    p.add_argument("--jobs", type=int, help="pool width (default LA_LINT_JOBS or the core count)")
    p.add_argument("--body", action="store_true",
                   help="take the shared arm over the whole planet instead of a slice of it")
    args = p.parse_args(argv)
    try:
        if args.list:
            return cmd_list()
        if args.check_inputs:
            return cmd_check_inputs()
        if args.mutate:
            return cmd_mutate(args)
        return cmd_lint(args)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        print("LINT_UNRUNNABLE: gates.toml (2) — %s" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

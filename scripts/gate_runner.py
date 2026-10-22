#!/usr/bin/env python3
# ONE RUNNER FOR EVERY STRUCTURAL GATE, driven by scripts/gates.toml. A gate is `fast` (starts no engine) or `slow`;
# a run takes the fast tier, `--slow` the slow tier, `--all` both, `--affected-by REF` only the slow gates a diff
# reaches. A pool runs the gates that need no device beside one in-order queue of gpu gates; `exclusive` rows run
# with it idle, `last` rows after the rest; a gate whose `inputs` are unchanged since its last pass is not run.
# Output replays in definition order. EXIT 0 clean · 1 a gate reported a violation · 2 a gate COULD NOT RUN.
import argparse
import concurrent.futures
import contextlib
import json
import math
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
TIERS = ("fast", "slow")
GATE_SECONDS_REL = "docs/GATE_SECONDS"
DEFAULT_SECONDS = {"fast": 30, "slow": 300}
BUDGET_FLOOR, BUDGET_FACTOR = 60, 10
SLOW_LIST_REL = "docs/SLOW_GATES_WITHOUT_INPUTS"
SLOW_CEILING_REL = "docs/SLOW_GATES_WITHOUT_INPUTS_CEILING"


def mutation_of(name, m):
    """A mutation turns the gate red. A table names the exit, and the line, of the arm it must fire."""
    if isinstance(m, str):
        return {"cmd": m, "exit": None, "says": None}
    if not isinstance(m, dict) or not all(isinstance(m.get(k), t) for k, t in
                                          (("cmd", str), ("exit", int), ("says", str))):
        raise ValueError("%s: a mutation is a command, or a table with cmd, exit and says" % name)
    return {"cmd": m["cmd"], "exit": m["exit"], "says": m["says"]}


def tier_of(name, kind, launches, capture_reader, declared):
    """`slow` for a row that starts an engine, reads the capture one made, or needs a device; else `fast`. A
    declared tier may only say what the row is not already derived to be, and never `fast` over an engine."""
    engine = launches or capture_reader or kind == "gpu"
    derived = "slow" if engine else "fast"
    if declared is None:
        return derived
    if declared not in TIERS:
        raise ValueError("%s: tier must be one of %s, not %r" % (name, ", ".join(TIERS), declared))
    if declared == "fast" and engine:
        raise ValueError("%s: tier = fast, but the row launches an engine, reads the capture or needs a device"
                         % name)
    if declared == derived:
        raise ValueError("%s: tier = %s restates what kind, launches and capture_reader already derive" % (name, declared))
    return declared


def read_seconds(root):
    """{gate: seconds} from docs/GATE_SECONDS, one `<gate> <seconds>` per line."""
    path = os.path.join(root, GATE_SECONDS_REL)
    entries = {}
    if not os.path.isfile(path):
        return entries
    with open(path) as fh:
        for n, line in enumerate(fh, 1):
            words = line.split("#", 1)[0].split()
            if not words:
                continue
            if len(words) != 2 or not words[1].isdigit():
                raise ValueError("%s:%d: expected `<gate> <seconds>`" % (GATE_SECONDS_REL, n))
            entries[words[0]] = int(words[1])
    return entries


def budget_of(name, tier, entries):
    """Seconds a gate may take: five times its entry, never under the floor; a gate with none has its tier's."""
    if name in entries:
        return max(BUDGET_FLOOR, BUDGET_FACTOR * entries[name])
    return DEFAULT_SECONDS[tier]


def load_doc(path=GATES_TOML):
    """The gate rows and the named input sets of gates.toml."""
    with open(path, "rb") as fh:
        return parse_doc(tomllib.load(fh), read_seconds(ROOT))


def parse_doc(doc, entries):
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
        for flag in ("launches", "capture_reader", "last", "exclusive"):
            if flag in g and not isinstance(g[flag], bool):
                raise ValueError("%s: %s must be a boolean" % (name, flag))
        inputs = g.get("inputs")
        if inputs is not None:
            if not isinstance(inputs, list) or not all(isinstance(x, str) for x in inputs):
                raise ValueError("%s: inputs must be a list of globs" % name)
            if g.get("last"):
                raise ValueError("%s: a `last` row reads the whole run's ledger, so a pass is never reusable; "
                                 "it declares no inputs" % name)
            gate_cache.expand_inputs(inputs, sets)
        launches = bool(g.get("launches", g["kind"] != "text"))
        tier = tier_of(name, g["kind"], launches, bool(g.get("capture_reader", False)), g.get("tier"))
        gates.append({
            "name": name,
            "label": g.get("label", name + ".sh"),
            "script": g["script"],
            "kind": g["kind"],
            "tier": tier,
            "marker": g["marker"],
            "mutations": [mutation_of(name, m) for m in ([g["mutation"]] if isinstance(g.get("mutation"), str)
                                                        else g.get("mutation", [])) if m],
            "args": list(g.get("args", [])),
            "env": dict(g.get("env", {})),
            "needs": needs,
            "inputs": inputs,
            "launches": launches,
            "last": bool(g.get("last", False)),
            "capture_reader": g.get("capture_reader", False),
            "exclusive": bool(g.get("exclusive", False)),
            "timeout_s": budget_of(name, tier, entries),
            "raw": g,
        })
    if not gates:
        raise ValueError("gates.toml lists no gate")
    return gates, sets


def load_gates(path=GATES_TOML):
    return load_doc(path)[0]


def effective_launcher(g, capture):
    return g["launches"] or (g["capture_reader"] and not capture)


def capture_standing(env):
    return os.path.isdir(env.get("LA_LINT_CAPTURE", ""))


def launch_count(ledger):
    if not ledger or not os.path.isfile(ledger):
        return 0
    with open(ledger) as source:
        return sum(bool(line.strip()) for line in source)


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
    launches_before = launch_count(ledger)
    started = time.monotonic()
    try:
        proc = subprocess.Popen([path] + g["args"], cwd=root, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
                                start_new_session=(os.name == "posix"))
    except OSError as exc:
        return 2, "%s could not be started: %s\n" % (g["script"], exc), 0.0
    chunks, read_errors = [], []

    def note(text):
        chunks.append(text)
        if sink:
            sink(text)

    def read_output():
        try:
            for line in proc.stdout:
                note(line)
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
            except PermissionError as error:
                read_errors.append("owned process group termination was refused: %s" % error)
            reader.join(timeout=1)
            if proc.poll() is None or reader.is_alive():
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError as error:
                    read_errors.append("owned process group cleanup was refused: %s" % error)
                    if proc.poll() is None:
                        try:
                            proc.kill()
                        except (ProcessLookupError, PermissionError) as direct_error:
                            read_errors.append("owned process cleanup failed: %s" % direct_error)
        else:
            try:
                proc.kill()
            except (ProcessLookupError, PermissionError) as error:
                read_errors.append("owned process cleanup failed: %s" % error)
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            read_errors.append("owned process survived the cleanup deadline")
        reader.join(timeout=1)
        note("LINT_SLOW: %s ran %.0fs against %ds.\n" % (g["name"], time.monotonic() - started, g["timeout_s"]))
        rc = 1
    if reader.is_alive():
        note("%s output reader did not stop during owned-process cleanup.\n" % g["label"])
        rc = 2
    if read_errors:
        note("%s output could not be read: %s\n" % (g["label"], "; ".join(read_errors)))
        rc = 2
    capture = capture_standing(env)
    if launch_count(ledger) > launches_before and not effective_launcher(g, capture):
        note("%s launched an engine despite its no-launch declaration.\n" % g["label"])
        if rc in (0, 1):
            rc = 1
    return rc, "".join(chunks), time.monotonic() - started


def silent_pass(g, rc, out):
    """A gate that exits 0 without printing its verdict examined nothing."""
    return rc == 0 and re.search(g["marker"], out, re.M) is None


def verdict(g, rc, out, launches, capture):
    """What one finished gate came to: pass, fail, unrunnable, not_examined, silent or undeclared_launch."""
    if rc in (0, 1) and launches and not effective_launcher(g, capture):
        return "undeclared_launch"
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


def note_seconds(label, secs, tier):
    """One line per finished gate, seconds then label then tier, so a gate declaring last = true can add up
    the tier of the run it sits in."""
    path = os.environ.get("LA_LINT_TIMING_LOG")
    if not path:
        return
    with open(path, "a") as fh:
        fh.write("%.3f\t%s\t%s\n" % (secs, label.replace("\t", " "), tier))


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
        self.verdict, self.key, self.watch = None, None, []


class Lint:
    """Every gate of one run: planned, run in two lanes, and replayed in definition order. A gate that may
    read the shared capture waits for `release`; every other gate starts at once. A gpu gate that starts an
    engine holds `device`, so one runs at a time."""

    def __init__(self, gates, root, width, ledger_dir, shared_ledger, no_gpu, cache, waits, tree):
        self.root, self.cache, self.waits, self.tree = root, cache, waits, tree
        self.jobs = [Job(i, g) for i, g in enumerate(gates)]
        self.width, self.shared = width, shared_ledger
        self.ledger_of = {j.index: os.path.join(ledger_dir, "%d.launch" % j.index) for j in self.jobs}
        self.cv = threading.Condition()
        self.merge_lock = threading.Lock()
        self.quiet = Quiet()
        self.device = threading.Lock()
        self.ready = threading.Event()
        self.extra_env = {}
        self.capture = False
        self.aborted = False
        self.stored = 0
        self.driver = None
        for j in self.jobs:
            if no_gpu and j.gate["kind"] == "gpu":
                self.settle(j, None, "LINT_SKIPPED_NO_GPU: %s (declared kind=gpu in gates.toml; run it on a "
                            "machine with a GPU)\n" % j.gate["label"], 0.0, 0, "skipped")

    def plan(self, keys, read_cache):
        """Give each keyed gate its key, and settle the ones whose pass is already on file."""
        for index, (key, watch) in keys.items():
            job = self.jobs[index]
            job.key, job.watch = key, watch
            if read_cache and not job.done and self.cache.has(job.gate["name"], key):
                self.settle(job, 0, "LINT_CACHED: %s\n" % job.gate["label"], 0.0, 0, "cached")

    def record(self, job, rc, secs, launches, verdict_, lines=None):
        if not job.gate["last"]:
            note_seconds(job.gate["label"], secs, job.gate["tier"])
        with self.cv:
            if lines is not None:
                job.lines = lines
            job.rc, job.seconds, job.launches, job.verdict, job.done = rc, secs, launches, verdict_, True
            self.cv.notify_all()

    def settle(self, job, rc, out, secs, launches, verdict_):
        self.record(job, rc, secs, launches, verdict_, [out] if out else [])

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
        extra = self.extra_env
        try:
            ledger = self.shared if g["last"] else self.ledger_of[job.index]
            rc, out, secs = run_gate(g, self.root, ledger, self.emit(job), extra)
            launches = 0 if g["last"] else self.merge(ledger)
            found = verdict(g, rc, out, launches, capture_standing(dict(os.environ, **extra)))
        except Exception as exc:
            rc, secs, launches, found = 2, 0.0, 0, "unrunnable"
            self.emit(job)("%s: the runner failed while running it: %r\n" % (g["label"], exc))
        if found == "pass" and job.key and self.cache and self.tree.unchanged(job.watch) \
                and self.cache.put(g["name"], job.key, secs):
            self.stored += 1
        self.record(job, rc, secs, launches, found)

    def emit(self, job):
        def sink(line):
            with self.cv:
                job.lines.append(line)
                self.cv.notify_all()
        return sink

    def takes_device(self, g):
        return g["kind"] == "gpu" and effective_launcher(g, self.capture)

    def in_pool(self, job):
        if job.index in self.waits:
            self.ready.wait()
        if job.done:
            return
        with self.quiet.shared():
            if self.takes_device(job.gate):
                with self.device:
                    self.execute(job)
            else:
                self.execute(job)

    def engine_lane(self, queue):
        for job in queue:
            if job.index in self.waits:
                self.ready.wait()
            if job.done:
                continue
            if job.gate["exclusive"]:
                with self.quiet.alone():
                    self.execute(job)
            else:
                with self.device:
                    self.execute(job)

    def drive(self):
        def order(jobs):
            return [j for j in jobs if j.index not in self.waits] + [j for j in jobs if j.index in self.waits]

        def queued(j):
            return j.gate["exclusive"] or (j.gate["kind"] == "gpu" and j.gate["launches"])

        pool_jobs = order([j for j in self.jobs if not j.gate["last"] and not queued(j)])
        queue = order([j for j in self.jobs if not j.gate["last"] and queued(j)])
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
        self.capture = capture_standing(dict(os.environ, **self.extra_env))
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


def summarise(t, tier):
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
    print("All %s-tier lint gates passed (file length gates at soft 1300 / hard 1500; policy markers are "
          "advisory)." % tier)
    return 0


def open_cache(args):
    """(cache, may_read). CI earns every pass; an integration run reads none, but its passes are real."""
    if args.no_cache or os.environ.get("CI"):
        return None, False
    return gate_cache.Cache(), not os.environ.get("LA_INTEGRATE_BRANCH")


def plan_keys(gates, sets, no_gpu, tree, ambient, capture, indexes):
    """A (content key, files) for each of `indexes` that declares inputs, or none when the tree cannot be read."""
    try:
        return {i: gate_cache.keyed(gates[i], sets, tree, ambient, capture) for i in indexes
                if gates[i]["inputs"] is not None and not (no_gpu and gates[i]["kind"] == "gpu")}
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print("LINT_CACHE_OFF: %s" % exc)
        return {}


def changed_paths(ref):
    """(merge base with HEAD, every path this tree differs from it in, a deleted or renamed one included)."""
    base = git(ROOT, "merge-base", ref, "HEAD").stdout.strip()
    names = set()
    for argv in (("diff", "--name-only", "--no-renames", "-z", base),
                 ("ls-files", "-z", "--others", "--exclude-standard")):
        names |= {n for n in git(ROOT, *argv).stdout.split("\0") if n}
    return base, sorted(names)


def declaration(raw, sets):
    inputs = raw.get("inputs")
    return json.dumps([raw, gate_cache.expand_inputs(inputs, sets) if inputs is not None else None], sort_keys=True)


def moved_rows(base_text, gates, sets):
    """Names of the rows whose declaration, expanded inputs included, differs from the base's gates.toml."""
    old = tomllib.loads(base_text)
    before = {g["name"]: declaration(g, old.get("sets", {})) for g in old.get("gate", [])}
    return {g["name"] for g in gates if before.get(g["name"]) != declaration(g["raw"], sets)}


def reaches(g, sets, tree, changed, moved):
    """Why a slow gate must run for this diff: the first changed path among its inputs, its script and the libs
    that script names, or its own row; None when it reads none of them."""
    if g["inputs"] is None:
        return "declares no inputs"
    if g["name"] in moved:
        return "its row in scripts/gates.toml changed"
    patterns = gate_cache.expand_inputs(g["inputs"], sets)
    code = set(tree.code(g["script"], gate_cache.helpers(patterns)))
    rx = [gate_cache.glob_regex(pat) for pat in patterns]
    for path in changed:
        if path in code or any(r.match(path) for r in rx):
            return path
    return None


def select_slow(gates, sets, tree, changed, moved):
    """{name: why} for each slow gate the diff reaches. A `last` row weighs the run around it, so it is
    selected only beside another slow gate."""
    why = {}
    for g in gates:
        if g["tier"] == "slow" and not g["last"]:
            found = reaches(g, sets, tree, changed, moved)
            if found:
                why[g["name"]] = found
    if why:
        for g in gates:
            if g["tier"] == "slow" and g["last"]:
                why[g["name"]] = "it weighs the slow gates selected beside it"
    return why


def narrow_to_diff(gates, sets, ref):
    """The fast gates and the slow ones `ref`..HEAD reaches, with what was selected and skipped printed."""
    tree = gate_cache.Tree(ROOT)
    base, changed = changed_paths(ref)
    moved = set()
    if "scripts/gates.toml" in changed:
        moved = moved_rows(git(ROOT, "show", "%s:scripts/gates.toml" % base).stdout, gates, sets)
    why = select_slow(gates, sets, tree, changed, moved)
    slow = [g for g in gates if g["tier"] == "slow"]
    for g in slow:
        if g["name"] in why:
            print("LINT_SELECTED: %s (%s)" % (g["label"], why[g["name"]]))
    print('LINT_AFFECTED={"changed":%d,"selected":%d,"skipped":%d}'
          % (len(changed), len(why), len(slow) - len(why)))
    skipped = [g["label"] for g in slow if g["name"] not in why]
    if skipped:
        print("LINT_UNAFFECTED: %s" % ", ".join(skipped))
    return [g for g in gates if g["tier"] == "fast" or g["name"] in why]


def cmd_lint(args):
    gates, sets = load_doc()
    if args.only:
        known = {n for g in gates for n in (g["name"], g["label"])}
        absent = [n for n in args.only if n not in known]
        if absent:
            print("gate_runner: no gate named '%s' in gates.toml." % absent[0], file=sys.stderr)
            return 2
        gates = [g for g in gates if g["name"] in args.only or g["label"] in args.only]
    else:
        gates = [g for g in gates if args.tier == "all" or g["tier"] == args.tier]
        if args.affected_by:
            gates = narrow_to_diff(gates, sets, args.affected_by)
    no_gpu = os.environ.get("LA_NO_GPU", "0") == "1"
    tally = {"failed": 0, "unrunnable": 0, "skipped": 0, "not_examined": 0, "cached": 0}
    timing, records = [], []
    ledger_dir = tempfile.mkdtemp(prefix="la_gate_ledger.")
    shared = os.environ.get("LA_LAUNCH_LOG")
    if not shared:
        shared = os.path.join(ledger_dir, "run.launch")
        os.environ["LA_LAUNCH_LOG"] = shared
    open(shared, "a").close()

    # WHICH TREE THIS LINT WEIGHED: LOG_DIR is machine-wide.
    print("LINT_TREE=%s" % ROOT)
    print("LINT_SCOPE=" + json.dumps({"full": not args.only and args.tier == "all" and not args.affected_by,
                                    "tier": "named" if args.only else args.tier, "gpu": not no_gpu,
                                    "affected_by": args.affected_by, "arm": "body" if args.body else "slice"},
                                   sort_keys=True))
    for name in ("LA_LINT_TIMING_LOG", "LA_LOCK_WAIT_LOG"):
        if os.environ.get(name):
            open(os.environ[name], "w").close()

    cache, read_cache = open_cache(args)
    tree, ambient = gate_cache.Tree(ROOT), gate_cache.Ambient(ROOT)
    waits = {i for i, g in enumerate(gates) if gate_cache.reads_capture(g, tree)}
    wanted = any(gates[i]["tier"] == "slow" and not (no_gpu and gates[i]["kind"] == "gpu") for i in waits)
    lint = Lint(gates, ROOT, args.jobs or pool_size(), ledger_dir, shared, no_gpu, cache, waits, tree)
    keys = {}
    if cache:
        keys = plan_keys(gates, sets, no_gpu, tree, ambient, None, [i for i in range(len(gates)) if i not in waits])
        lint.plan(keys, read_cache)

    def on_result(job):
        g, v = job.gate, job.verdict
        timing.append((job.seconds, g["label"]))
        records.append({"name": g["name"], "label": g["label"], "kind": g["kind"], "tier": g["tier"], "rc": job.rc,
                        "seconds": round(job.seconds, 3), "launches": job.launches, "cached": v == "cached"})
        if v in ("skipped", "cached", "not_examined"):
            tally[v] += 1
        elif v == "undeclared_launch":
            print("LINT_FAIL: %s (1) — a %s-tier gate declaring launches = false started the engine %d "
                  "time(s). A gate that starts one is a launcher and slow: drop the declaration."
                  % (g["label"], g["tier"], job.launches))
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
        cap = None
        if wanted:
            capture_started = time.monotonic()
            cap, cap_err = make_capture(arm="body" if args.body else "slice")
            note_seconds("lint_capture.sh", time.monotonic() - capture_started, "slow")
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
    result = summarise(tally, "named" if args.only else args.tier)
    if result == 0 and args.tier == "all" and not args.only and not args.affected_by and not no_gpu \
            and not args.body and cap and not tally["cached"]:
        print("LINT_BANKABLE=1")
    return result


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


def cmd_bank_seconds(log):
    """Lower docs/GATE_SECONDS to the per-gate seconds of one passing lint; an entry never rises, a cached
    gate (0 s) is not measured."""
    gates, _ = load_doc()
    by_label = {g["label"]: g["name"] for g in gates}
    with open(log) as fh:
        text = fh.read()
    timing = re.search(r"^LINT_TIMING=(\{.*\})$", text, re.M)
    if not re.search(r"^All \S+-tier lint gates passed", text, re.M) or not timing:
        print("gate_runner: %s is not a passing lint, so %s stands." % (log, GATE_SECONDS_REL))
        return 0
    entries = read_seconds(ROOT)
    for label, secs in json.loads(timing.group(1)).items():
        name = by_label.get(label)
        if name and secs > 0:
            entries[name] = min(entries.get(name, math.inf), max(1, math.ceil(secs)))
    with open(os.path.join(ROOT, GATE_SECONDS_REL), "w") as fh:
        fh.write("# Seconds each gate is expected to take, `<gate> <seconds>`. gate_runner.py fails a gate past max(60, 10x its\n"
                 "# entry); a gate with none has 30 s fast, 300 s slow. May fall, may not rise: scripts/write_ceilings.sh\n"
                 "# writes it from a passing lint.\n")
        fh.writelines("%s %d\n" % (name, entries[name]) for name in sorted(entries))
    return 0


def number_in(path):
    with open(path) as fh:
        for line in fh:
            if re.fullmatch(r"[0-9]+", line.strip()):
                return int(line.strip())
    return None


def cmd_check_tiers():
    """A slow gate without `inputs` cannot be skipped by a diff, so each is on a named list that may not grow."""
    gates, _ = load_doc()
    try:
        with open(os.path.join(ROOT, SLOW_LIST_REL)) as fh:
            listed = [ln.strip() for ln in fh if ln.strip() and not ln.lstrip().startswith("#")]
        ceiling = number_in(os.path.join(ROOT, SLOW_CEILING_REL))
    except OSError as exc:
        print("check_gate_tiers: %s" % exc, file=sys.stderr)
        return 2
    if ceiling is None:
        print("check_gate_tiers: %s carries no number." % SLOW_CEILING_REL, file=sys.stderr)
        return 2
    by_name = {g["name"]: g for g in gates}
    bare = {g["name"] for g in gates if g["tier"] == "slow" and not g["last"] and g["inputs"] is None}
    problems = ["%s is slow and declares no inputs: declare them, so a diff can skip it" % n
                for n in sorted(bare - set(listed))]
    for name in sorted(set(listed)):
        if name not in by_name:
            problems.append("%s names no gate in %s; delete the line" % (name, SLOW_LIST_REL))
        elif name not in bare:
            problems.append("%s is on the list but declares inputs, is fast or is a `last` row; delete the line" % name)
    problems += ["%s is listed twice" % n for n in sorted({n for n in listed if listed.count(n) > 1})]
    if len(listed) > ceiling:
        problems.append("%d gates are listed against a ceiling of %d, which may fall and may not rise"
                        % (len(listed), ceiling))
    print('SLOW_GATES_WITHOUT_INPUTS={"count":%d,"ceiling":%d}' % (len(listed), ceiling))
    for problem in problems:
        print("FAIL  " + problem, file=sys.stderr)
    if problems:
        return 1
    print("check_gate_tiers: OK (%d slow gate(s) without inputs, ceiling %d; every other slow row declares "
          "them)" % (len(listed), ceiling))
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


def arm_ledgers(scratch):
    """The ledgers a lint keeps, for a gate that reads the run around it. Both arms get the same ones."""
    os.environ["LA_LINT_LAUNCHES"] = os.path.join(scratch, "mutate_launches.log")
    os.environ["LA_LINT_TIMING_LOG"] = os.path.join(scratch, "mutate_seconds.log")
    os.environ["LA_LOCK_WAIT_LOG"] = os.path.join(scratch, "mutate_lock_waits.log")
    open(os.environ["LA_LINT_LAUNCHES"], "w").close()
    open(os.environ["LA_LOCK_WAIT_LOG"], "w").close()
    with open(os.environ["LA_LINT_TIMING_LOG"], "w") as fh:
        for name, tier in (("a", "fast"), ("b", "fast"), ("c", "slow"), ("d", "slow")):
            fh.write("0.100\tcheck_mutate_arm_%s.sh\t%s\n" % (name, tier))


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


def mutate_one(g, m):
    """One mutation, in its own scratch tree."""
    mutation = m["cmd"]
    scratch = os.path.join(tempfile.mkdtemp(prefix="la_mutate_"), "tree")
    ledger = os.path.join(tempfile.mkdtemp(prefix="la_mutate_ledger."), "launches.log")
    open(ledger, "w").close()
    os.environ["LA_LAUNCH_LOG"] = ledger
    try:
        stage_scratch(scratch)
        if not arm_scratch(g, scratch, first=True):
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
        if "LINT_SLOW:" in out1:
            print("MUTATION_UNRUNNABLE: %s ran past its time budget under `%s`, which proves nothing." % (g["name"], mutation))
            return 2
        if m["exit"] is not None:
            if rc1 == m["exit"] and re.search(m["says"], out1, re.M):
                print("MUTATION_KILLED: %s went %d under `%s`, the arm it declares." % (g["name"], rc1, mutation))
                return 0
            print("MUTATION_SURVIVED: %s went %d under `%s`, where the declared arm exits %d saying %r."
                  % (g["name"], rc1, mutation, m["exit"], m["says"]))
            return 1
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
        print("%s\t%s\t%s\t%s\t%s" % (g["name"], g["kind"], g["label"], g["script"], g["tier"]))
    return 0


def main(argv):
    p = argparse.ArgumentParser(description="Run the structural gates in scripts/gates.toml.")
    p.add_argument("--only", metavar="NAME", action="append", help="run this gate by name; repeat for more")
    p.add_argument("--mutate", metavar="NAME", help="prove one gate can fail, in a scratch worktree")
    p.add_argument("--list", action="store_true", help="print name/kind/label/script/tier, one per line")
    tiers = p.add_mutually_exclusive_group()
    tiers.add_argument("--fast", dest="tier", action="store_const", const="fast",
                       help="run the fast tier, which starts no engine (the default)")
    tiers.add_argument("--slow", dest="tier", action="store_const", const="slow",
                       help="run the slow tier: every gate that launches an engine or needs a device")
    tiers.add_argument("--all", dest="tier", action="store_const", const="all", help="run both tiers")
    p.set_defaults(tier="fast")
    p.add_argument("--affected-by", metavar="REF",
                   help="keep only the slow gates that read a path this tree changed since REF, or declare no inputs")
    p.add_argument("--check-inputs", action="store_true",
                   help="prove every `inputs` row names real files and moves its key with their bytes")
    p.add_argument("--check-tiers", action="store_true",
                   help="prove every slow gate without `inputs` is on docs/SLOW_GATES_WITHOUT_INPUTS, which may not grow")
    p.add_argument("--bank-seconds", metavar="LOG", help="lower docs/GATE_SECONDS to a passing lint's log")
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
        if args.check_tiers:
            return cmd_check_tiers()
        if args.bank_seconds:
            return cmd_bank_seconds(args.bank_seconds)
        if args.mutate:
            return cmd_mutate(args)
        return cmd_lint(args)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        print("LINT_UNRUNNABLE: gates.toml (2) — %s" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

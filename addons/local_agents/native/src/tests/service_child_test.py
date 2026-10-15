#!/usr/bin/env python3
import argparse
import contextlib
import os
from pathlib import Path
import select
import struct
import sys
import subprocess
import tempfile
import time

HEADER = struct.Struct("<IHHIQQQ")
MAGIC = 0x5350414C
ERROR = 0xFFFF


class GateUnavailable(RuntimeError):
    pass


def string(value):
    data = str(value).encode()
    return struct.pack("<I", len(data)) + data


class Cursor:
    def __init__(self, data):
        self.data, self.at = data, 0

    def take(self, fmt):
        result = struct.unpack_from(fmt, self.data, self.at)
        self.at += struct.calcsize(fmt)
        return result[0] if len(result) == 1 else result

    def text(self):
        size = self.take("<I")
        result = self.data[self.at:self.at + size]
        assert len(result) == size, "truncated text"
        self.at += size
        return result.decode()

    def done(self):
        assert self.at == len(self.data), "unexamined response bytes"


def metadata(payload):
    data = Cursor(payload)
    assert data.take("<I") == 1, "resident world absent"
    result = dict(zip(("revision", "time", "snapshot", "plan", "kernels", "cells"), data.take("<QdQQQI")))
    result["world"] = data.text()
    return result, data


def fixture(root, missing=False):
    world = "1,1,1,1,0/0/0,1,0"
    snapshot = root / ("missing.lafs" if missing else "world.lafs")
    names = ["sentinel", "omitted"] if missing else ["sentinel"]
    snapshot.write_bytes(struct.pack("<IIII", 0x5346414C, 1, 1, len(names)) + string(world)
                        + b"".join(string(name) for name in names)
                        + struct.pack("<" + "f" * len(names), *([3.5] * len(names))))
    plan = root / "world.lapl"
    buffers = [("sentinel", 0, struct.pack("<f", 0)),
               ("vector", 0, struct.pack("<fff", 1, 2, 3)),
               ("flags", 1, struct.pack("<IIII", 10, 20, 30, 40))]
    encoded = struct.pack("<IIIII", 0x4C50414C, 1, 1, 0, len(buffers))
    for name, kind, values in buffers:
        encoded += string(name) + struct.pack("<II", len(values) // 4, kind) + values
    encoded += struct.pack("<IIII", 0, 1, 0, 0)
    plan.write_bytes(encoded)
    return snapshot, plan


def content_hash(data):
    result = 1469598103934665603
    for value in data:
        result = ((result ^ value) * 1099511628211) & ((1 << 64) - 1)
    return result


class Client:
    def __init__(self, binary, blob, root):
        self.root, self.generation, self.request, self.hello = root, 0, 0, False
        self.errors = tempfile.TemporaryFile()
        self.process = subprocess.Popen([str(binary), "--kernels", str(blob), "--serve", "--publications", str(root)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors, bufsize=0)

    def read(self, size):
        result = b""
        deadline = time.monotonic() + 20
        while len(result) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise GateUnavailable("service reply timeout")
            piece = os.read(self.process.stdout.fileno(), size - len(result))
            assert piece, "service disconnected before reply"
            result += piece
        return result

    def call(self, operation, payload=b"", generation=None, session=17, request=None):
        self.request += 1
        request = self.request if request is None else request
        generation = self.generation if generation is None else generation
        self.process.stdin.write(HEADER.pack(MAGIC, 1, operation, len(payload), session, request, generation) + payload)
        self.process.stdin.flush()
        magic, version, reply, size, nonce, matched, current = HEADER.unpack(self.read(HEADER.size))
        assert (magic, version, matched) == (MAGIC, 1, request), "mismatched protocol reply"
        assert nonce == 17, "reply lost service identity"
        self.generation = current
        data = self.read(size)
        if reply == ERROR:
            cursor = Cursor(data)
            reason = cursor.text()
            cursor.done()
            return reason, None
        assert reply == operation | 0x8000, "wrong response operation"
        return None, data

    def start(self):
        error, payload = self.call(1)
        assert error is None, error
        data = Cursor(payload)
        assert data.take("<I") & 8, "fixture expects algebraic service capability"
        assert data.text(), "device name absent"
        assert data.text() == "metal", "hardware gate did not use Metal"
        data.done()
        self.hello = True

    def load(self, snapshot, plan, passes="derive"):
        error, payload = self.call(2, string(snapshot) + string(plan) + string(passes) + struct.pack("<d", 19.5))
        return error, metadata(payload)[0] if payload is not None else None

    def status(self):
        error, payload = self.call(9)
        assert error is None, error
        result, data = metadata(payload)
        result["prepared"], count = data.take("<QI")
        result["audits"] = {}
        for _ in range(count):
            key, value, present = data.text(), data.take("<d"), data.take("<I")
            assert present in (0, 1), "invalid audit presence"
            if present:
                result["audits"][key] = value
        data.done()
        return result

    def view(self, fields, seen=0):
        error, payload = self.call(4, struct.pack("<QI", seen, len(fields)) + b"".join(string(name) for name in fields))
        if error:
            return error, None
        state, data = metadata(payload)
        if data.take("<I") == 0:
            data.done()
            return None, None
        sequence, path = data.take("<Q"), Path(data.text())
        data.done()
        assert path.parent.parent.resolve() == self.root.resolve(), "publication escaped session root"
        view = Cursor(path.read_bytes())
        assert view.take("<II") == (0x5756414C, 1), "invalid immutable view header"
        nonce, generation, published, revision, timestamp, cells = view.take("<QQQQdI")
        assert (nonce, generation, published, revision, timestamp, cells) == (
            17, self.generation, sequence, state["revision"], state["time"], state["cells"]), "view state identity mismatch"
        assert view.text() == state["world"], "view world differs from reply"
        values = {}
        for _ in range(view.take("<I")):
            name, kind, count = view.text(), view.take("<I"), view.take("<I")
            assert kind in (0, 1), "unknown selected buffer kind"
            values[name] = view.take("<" + ("f" if kind == 0 else "I") * count)
        view.done()
        assert list(values) == fields, "selected fields changed"
        return None, (sequence, path, values)

    def close(self):
        if self.process.poll() is None and self.hello:
            with contextlib.suppress(Exception):
                error, _ = self.call(8)
                assert error is None, error
        if self.process.stdin:
            with contextlib.suppress(OSError):
                self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.errors.close()


def run(binary, blob, scenario):
    with tempfile.TemporaryDirectory(prefix="la_service_child.") as directory:
        root = Path(directory)
        snapshot, plan = fixture(root)
        loaded_blob = root / "kernels.blob"
        original_blob = blob.read_bytes()
        loaded_blob.write_bytes(original_blob)
        client = Client(binary, loaded_blob, root / "publications")
        try:
            client.start()
            if scenario == "identity":
                loaded_blob.write_bytes(b"path replaced after device load")
            if scenario == "malformed":
                client.process.stdin.write(HEADER.pack(MAGIC, 2, 9, 0, 17, client.request + 1, 0))
                client.process.stdin.flush()
                client.process.stdin.close()
                reply = HEADER.unpack(client.read(HEADER.size))
                assert reply[2] == ERROR, "obsolete wire version was accepted by child"
                data = Cursor(client.read(reply[3]))
                assert data.text(), "malformed frame produced no reason"
                data.done()
                assert client.process.wait(timeout=5) == 2, "malformed child did not fail explicitly"
                client.hello = False
                assert not list((root / "publications").iterdir()), "malformed disconnect leaked publication session"
                return
            error, initial = client.load(snapshot, plan)
            assert error is None, error
            if scenario == "identity":
                assert initial["kernels"] == content_hash(original_blob), "kernel identity reopens changed source path"
                assert initial["snapshot"] == content_hash(snapshot.read_bytes()), "snapshot identity differs from imported bytes"
                assert initial["plan"] == content_hash(plan.read_bytes()), "plan identity differs from imported bytes"
            if scenario == "import":
                missing, _ = fixture(root, missing=True)
                error, _ = client.load(missing, plan)
                assert error == "LOAD_FAILED", "incomplete authoritative snapshot was accepted"
                assert client.generation == 1 and client.status()["revision"] == initial["revision"], "failed load replaced world"
            if scenario == "resident":
                error, view = client.view(["sentinel", "vector", "flags"])
                assert error is None and view, error
                sequence, path, values = view
                assert values == {"sentinel": 3.5, "vector": (1.0, 2.0, 3.0), "flags": (10, 20, 30, 40)}, "resident buffers were lost or truncated"
                original = path.read_bytes()
                before = client.status()["prepared"]
                for _ in range(3):
                    assert client.view(["vector"])[0] == "VIEW_BUSY", "slow consumer did not bound publication"
                assert client.status()["prepared"] == before and path.read_bytes() == original, "busy request extracted or changed pending view"
                assert client.call(5, struct.pack("<QI", sequence + 1, 1))[0] == "VIEW_STALE_ACK" and path.exists(), "wrong ack discarded pending view"
                assert client.call(5, struct.pack("<QI", sequence, 1))[0] is None and not path.exists(), "matching ack did not release publication"
                assert client.view(["sentinel", "vector", "flags"], seen=1) == (None, None), "accepted unchanged view was extracted again"
                assert client.status()["prepared"] == before, "unchanged view incurred extraction"
                assert client.call(3, struct.pack("<I", 0))[0] is None, "resident derive request failed"
                assert client.status()["time"] == initial["time"], "algebraic derive advanced physical time"
                error, newer = client.view(["sentinel"])
                assert error is None and newer[2]["sentinel"] == 3.5, "resident state did not survive requests"
                client.process.stdin.close()
                assert client.process.wait(timeout=5) == 0, "disconnect failed owned-child shutdown"
                client.hello = False
                assert not list((root / "publications").iterdir()), "disconnect left unacknowledged files"
            if scenario == "lifecycle":
                before = client.status()
                for fields in (["missing"], ["sentinel", "sentinel"], []):
                    assert client.view(fields)[0] in ("VIEW_FAILED", "INVALID_VIEW"), "invalid fields accepted"
                    assert client.status() == before, "invalid fields extracted or changed state"
                assert client.call(3, struct.pack("<I", 1))[0] == "INVALID_DERIVE", "invalid step accepted"
                assert client.status() == before, "invalid step changed resident state"
                error, pending = client.view(["sentinel"])
                assert error is None and pending, error
                sequence, path, _ = pending
                assert client.call(5, struct.pack("<QI", sequence, 0))[0] is None and not path.exists(), "rejected view not released"
                error, pending = client.view(["sentinel"], seen=1)
                assert error is None and pending, "rejected view counted as accepted"
                old_generation = client.generation
                error, loaded = client.load(snapshot, plan)
                assert error is None and client.generation == old_generation + 1, "reload did not replace generation"
                assert not pending[1].exists(), "reload retained obsolete publication"
                error, replacement = client.view(["sentinel"], seen=1)
                assert error is None and replacement, "reload reused prior generation credit"
                payload = struct.pack("<QI", replacement[0], 1)
                assert client.call(5, payload, generation=old_generation)[0] == "STALE_GENERATION", "stale generation acknowledged current view"
                assert replacement[1].exists(), "stale generation removed current view"
                error, cancelled = client.call(7)
                assert error is None and metadata(cancelled)[1].take("<I") == 1, "cancel did not discard pending view"
                assert not replacement[1].exists(), "cancel retained view"
                error, cancelled = client.call(7)
                state, data = metadata(cancelled)
                assert error is None and data.take("<I") == 0, "empty cancel reported a pending view"
                data.done()
                assert state["revision"] == loaded["revision"] and state["time"] == loaded["time"], "cancel changed world"
            if scenario == "validation":
                before = client.status()
                assert client.call(9, session=18)[0] == "STALE_SESSION", "stale session accepted"
                assert client.call(9, generation=0)[0] == "STALE_GENERATION", "stale generation accepted"
                assert client.call(9, request=1)[0] == "STALE_REQUEST", "obsolete request accepted"
                assert client.call(6, struct.pack("<d", 1))[0] == "INTEGRATION_NOT_AVAILABLE", "unsupported integration accepted"
                assert client.status() == before, "rejected requests changed committed state"
        finally:
            client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("blob", type=Path)
    parser.add_argument("--only", choices=("identity", "import", "resident", "validation", "lifecycle", "malformed"))
    args = parser.parse_args()
    try:
        for scenario in ([args.only] if args.only else ("identity", "import", "resident", "validation", "lifecycle", "malformed")):
            run(args.binary, args.blob, scenario)
    except GateUnavailable as error:
        print("native_service_child: UNRUNNABLE: " + str(error), file=sys.stderr)
        sys.exit(2)
    print("native_service_child: OK")

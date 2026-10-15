#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path
import struct
import sys
import subprocess
import tempfile
from service_child_test import Client, Cursor, GateUnavailable


def snapshots(path):
    data = Cursor(path.read_bytes())
    assert data.take("<II") == (0x5346414C, 1), "invalid oracle snapshot"
    cells, count = data.take("<II")
    data.text()
    names = [data.text() for _ in range(count)]
    fields = {name: data.take("<" + "f" * cells) for name in names}
    data.done()
    return cells, fields


def same(a, b):
    if a is None:
        return not math.isfinite(b)
    return a == b or (math.isnan(a) and math.isnan(b))


def run(binary, blob, oracle):
    with tempfile.TemporaryDirectory(prefix="la_service_compute.") as directory:
        root = Path(directory)
        mirrors = root / "expected.lafs"
        completed = subprocess.run([str(binary), "--kernels", str(blob), "--load", str(oracle / "field.lafs"),
                                    "--plan", str(oracle / "plan.lapl"), "--passes", "derive,reduce", "--steps", "1",
                                    "--mirrors", str(mirrors), "--report"], check=False, capture_output=True, text=True, timeout=60)
        assert completed.returncode == 0, "native oracle failed: " + completed.stderr
        reports = [json.loads(line.removeprefix("SIM_REPORT=")) for line in completed.stdout.splitlines()
                   if line.startswith("SIM_REPORT=")]
        assert len(reports) == 1 and reports[0], "one-shot oracle produced no audits"
        cells, expected = snapshots(mirrors)
        _, seeded = snapshots(oracle / "field.lafs")
        changed = [key for key in expected if key in seeded and expected[key] != seeded[key]]
        assert changed, "oracle dispatches changed no imported buffers"
        client = Client(binary, blob, root / "publications")
        try:
            client.start()
            error, initial = client.load(oracle / "field.lafs", oracle / "plan.lapl", "derive,reduce")
            assert error is None and initial["cells"] == cells, error
            assert client.call(3, struct.pack("<I", 0))[0] is None, "resident computation failed"
            status = client.status()
            assert status["revision"] == initial["revision"] + 1 and status["time"] == initial["time"], "algebraic commit changed clock or failed revision"
            assert status["audits"].keys() == reports[0].keys(), "resident audit rows differ from executed plan"
            for key, value in reports[0].items():
                assert same(value, status["audits"][key]), "resident audit differs from native oracle: " + key
            error, view = client.view(list(expected))
            assert error is None and view, error
            for key, values in expected.items():
                actual = view[2][key]
                if not isinstance(actual, tuple):
                    actual = (actual,)
                assert len(actual) >= cells and all(same(a, b) for a, b in zip(values, actual[:cells])), "resident output differs: " + key
            assert client.status() == status | {"prepared": client.status()["prepared"]}, "view extraction changed physics or audits"
        finally:
            client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("blob", type=Path)
    parser.add_argument("oracle", type=Path)
    args = parser.parse_args()
    try:
        run(args.binary, args.blob, args.oracle)
    except GateUnavailable as error:
        print("native_service_compute: UNRUNNABLE: " + str(error), file=sys.stderr)
        sys.exit(2)
    print("native_service_compute: OK")

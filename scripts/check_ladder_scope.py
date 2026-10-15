#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def check(args, expected_status, expected_rungs, failure=""):
    with tempfile.TemporaryDirectory(prefix="la-ladder-scope-") as temporary:
        root = Path(temporary)
        scripts = root / "scripts"
        scripts.mkdir()
        (root / "addons/local_agents/tests").mkdir(parents=True)
        (root / "docs").mkdir()
        declaration = root / "docs/PLAYABLE_RUNG"
        declaration.write_text("0\n")
        for name in ("check_process_ladder.sh", "lib_rung.sh"):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)
        (scripts / "lib_godot.sh").write_text("la_godot() {\n" + "\n".join(
            f"printf 'LADDER_ROW={n}\\trung{n}\\tgate{n}.sh\\n'" for n in range(4)) + "\n}\n")
        (scripts / "lib_lint_queue.sh").write_text("la_timing_line() { :; }\n")
        (scripts / "check_process_set.sh").write_text("#!/bin/bash\nexit 0\n")
        (scripts / "check_process_set.sh").chmod(0o755)
        (scripts / "sim_run.sh").write_text(
            "#!/bin/bash\nwhile [ $# -gt 0 ]; do\n"
            "if [ \"$1\" = --rung ]; then rung=\"$2\"; break; fi\nshift\ndone\n"
            "echo \"$rung\" >> \"$TRACE\"\n"
            "printf 'field_ms=1\\n'\n"
            "if [ \"$FAIL_ARM\" = \"$rung\" ]; then exit 122; fi\nexit 0\n")
        (scripts / "sim_run.sh").chmod(0o755)
        for n in range(4):
            (scripts / f"gate{n}.sh").write_text(
                f'if [ "$FAIL_GATE" = "{n}" ]; then exit 1; fi\nexit 0\n')
        trace = root / "trace"
        env = dict(os.environ, GODOT="true", TRACE=str(trace), FAIL_ARM="", FAIL_GATE="")
        if failure:
            kind, rung = failure.split(":")
            env[f"FAIL_{kind.upper()}"] = rung
        result = subprocess.run(["bash", str(scripts / "check_process_ladder.sh"), *args],
                                env=env, text=True, capture_output=True, timeout=10)
        actual = trace.read_text().splitlines() if trace.exists() else []
        assert result.returncode == expected_status, (args, result.stdout, result.stderr)
        assert actual == [str(n) for n in expected_rungs], (args, actual)
        assert declaration.read_text() == "0\n", "Validation advanced the playable declaration"


check([], 0, range(4))
check(["--through-rung", "2"], 0, range(3))
check(["--through-rung", "0"], 0, [0])
check(["--through-rung", "2"], 1, [0, 1], "gate:1")
check(["--through-rung", "2"], 1, [0, 1], "arm:1")
for invalid in ("-1", "unknown", "99", "1;false"):
    check(["--through-rung", invalid], 2, [])
check(["--through-rung"], 2, [])
print("check_ladder_scope: OK")

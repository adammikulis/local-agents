from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

pytest.importorskip("huggingface_hub")
pytest.importorskip("llama_cpp")

from local_agents import ensure_qwen3_model, run_chat_completion


@pytest.fixture(scope="session")
def model_path() -> Path:
    return ensure_qwen3_model()


def test_qwen3_chat_via_python(model_path: Path) -> None:
    response = run_chat_completion(model_path, prompt="Say hello in one short sentence.", max_tokens=64)
    assert response
    assert "hello" in response.lower()


def test_qwen3_chat_via_cli(tmp_path: Path, model_path: Path) -> None:
    prompt = "Introduce yourself in a friendly tone."
    cmd = [
        sys.executable,
        str(Path(__file__).resolve().parents[1] / "scripts" / "run_inference.py"),
        "--model",
        str(model_path),
        "--prompt",
        prompt,
        "--max-tokens",
        "64",
    ]
    env = os.environ.copy()
    env.setdefault("PYTHONWARNINGS", "ignore")
    completed = subprocess.run(cmd, check=True, capture_output=True, text=True, env=env)
    stdout = completed.stdout.strip()
    assert stdout
    assert any(word in stdout.lower() for word in ["hello", "hi", "hey"])

from __future__ import annotations

import os
from pathlib import Path
from typing import Optional

try:
    from huggingface_hub import hf_hub_download  # type: ignore
except ModuleNotFoundError:  # pragma: no cover - handled at runtime
    hf_hub_download = None

try:
    from llama_cpp import Llama  # type: ignore
except ModuleNotFoundError:  # pragma: no cover - handled at runtime
    Llama = None

REPO_ID = "Qwen/Qwen3-0.6B-Instruct-GGUF"
FILENAME = "Qwen3-0.6B-Instruct-Q4_K_M.gguf"
DEFAULT_MODEL_DIR = Path(os.environ.get("LOCAL_AGENTS_MODEL_DIR", ".models"))


def ensure_qwen3_model(cache_dir: Optional[Path] = None) -> Path:
    """Download the Qwen3-0.6B-Instruct model if it is not already cached."""

    if hf_hub_download is None:
        raise RuntimeError("huggingface_hub is required to download models. Install it before running inference.")

    target_dir = cache_dir or DEFAULT_MODEL_DIR
    target_dir.mkdir(parents=True, exist_ok=True)
    model_path = hf_hub_download(
        repo_id=REPO_ID,
        filename=FILENAME,
        repo_type="model",
        local_dir=target_dir,
        local_dir_use_symlinks=False,
    )
    return Path(model_path)


def _format_chat_prompt(system_prompt: str, user_prompt: str) -> str:
    return (
        "<|im_start|>system\n"
        f"{system_prompt}\n"
        "<|im_end|>\n"
        "<|im_start|>user\n"
        f"{user_prompt}\n"
        "<|im_end|>\n"
        "<|im_start|>assistant\n"
    )


def run_chat_completion(
    model_path: Path,
    prompt: str,
    *,
    system_prompt: str = "You are a helpful assistant.",
    max_tokens: int = 128,
    temperature: float = 0.7,
    n_threads: Optional[int] = None,
    n_ctx: int = 2048,
) -> str:
    """Run a chat-style completion using llama.cpp via the python bindings."""

    if n_threads is None:
        cpu_count = os.cpu_count() or 1
        n_threads = max(1, min(8, cpu_count))

    if Llama is None:
        raise RuntimeError("llama_cpp is required for inference. Install llama-cpp-python before running inference.")

    llm = Llama(
        model_path=str(model_path),
        n_ctx=n_ctx,
        n_threads=n_threads,
        n_gpu_layers=0,
        logits_all=False,
    )

    raw_prompt = _format_chat_prompt(system_prompt, prompt)
    result = llm.create_completion(
        raw_prompt,
        temperature=temperature,
        max_tokens=max_tokens,
        top_p=0.95,
        stop=["<|im_end|>", "<|im_start|>"],
    )
    text = result["choices"][0]["text"].strip()
    return text

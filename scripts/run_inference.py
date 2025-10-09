#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from local_agents import ensure_qwen3_model, run_chat_completion


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run llama.cpp inference against a local GGUF model.")
    parser.add_argument("--model", type=Path, help="Path to a GGUF model. Overrides --download when supplied.")
    parser.add_argument("--download", action="store_true", help="Download the Qwen3-0.6B-Instruct model if needed and use it for inference.")
    parser.add_argument("--prompt", default="Say hi in one short sentence.", help="Prompt to send to the model.")
    parser.add_argument("--system", default="You are a helpful assistant.", help="System prompt for chat formatting.")
    parser.add_argument("--max-tokens", type=int, default=128, help="Maximum number of tokens to generate.")
    parser.add_argument("--temperature", type=float, default=0.7, help="Sampling temperature.")
    parser.add_argument("--threads", type=int, default=None, help="Number of CPU threads for inference (defaults to heuristic).")
    parser.add_argument("--context", type=int, default=2048, help="Context window for inference.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    model_path: Path
    if args.model:
        model_path = args.model.expanduser().resolve()
        if not model_path.exists():
            raise SystemExit(f"Model not found: {model_path}")
    else:
        if not args.download:
            print("--download not supplied; falling back to downloading Qwen3-0.6B-Instruct.", file=sys.stderr)
        model_path = ensure_qwen3_model()

    response = run_chat_completion(
        model_path=model_path,
        prompt=args.prompt,
        system_prompt=args.system,
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        n_threads=args.threads,
        n_ctx=args.context,
    )
    print(response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

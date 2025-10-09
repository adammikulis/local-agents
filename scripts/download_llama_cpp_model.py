#!/usr/bin/env python3
"""CLI helper to download llama.cpp GGUF models using local_agents utilities."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from local_agents import download_llama_cpp_model


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Download a GGUF model from the llama.cpp catalog.",
    )
    parser.add_argument("--family", required=True, help="Model family identifier (for example 'qwen3').")
    parser.add_argument("--variant", help="Specific model variant identifier (for example 'qwen3-0.6b-instruct').")
    parser.add_argument("--quantization", help="Preferred artifact quantization (for example 'Q4_K_M').")
    parser.add_argument(
        "--cache-dir",
        type=Path,
        help="Directory where the downloaded artifact should be stored (defaults to the standard cache).",
    )
    parser.add_argument(
        "--offline",
        action="store_true",
        help="Do not attempt to refresh the catalog from the network before downloading.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="Timeout in seconds for catalog refresh attempts when the network is enabled.",
    )
    return parser


def main(argv: list[str]) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    try:
        model_path = download_llama_cpp_model(
            args.family,
            variant_id=args.variant,
            quantization=args.quantization,
            cache_dir=args.cache_dir,
            prefer_remote=not args.offline,
            timeout=args.timeout,
        )
    except Exception as exc:  # pragma: no cover - surfaced to Godot UI
        print(str(exc), file=sys.stderr)
        return 1

    print(model_path)
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    raise SystemExit(main(sys.argv[1:]))

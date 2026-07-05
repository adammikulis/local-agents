#!/usr/bin/env python3
"""Auto-finetune the creatures' slow brain (FunctionGemma) from sim traces.

This script closes the sim's self-improvement loop:

  functiongemma_traces.jsonl  ->  chat / tool-calling examples  ->  LoRA finetune
  google/functiongemma-270m-it  ->  merged model  ->  GGUF for llama.cpp.

It is written to be *genuinely runnable* when the optional ML stack
(unsloth / torch / transformers / trl / datasets) is installed, but to degrade
gracefully with a clear message when it is not. In particular, the conversion
step (traces -> training examples) runs with only the Python standard library,
so you can always inspect what the trainer would learn from via `--dry-run`.

Usage:

    # Inspect what would be trained on, no ML deps needed:
    python scripts/functiongemma_train.py --dry-run

    # Full finetune (requires unsloth + torch + transformers + trl + datasets):
    python scripts/functiongemma_train.py --out addons/local_agents/models/functiongemma

    # Override the trace file location:
    python scripts/functiongemma_train.py --traces /path/to/functiongemma_traces.jsonl

See addons/local_agents/models/functiongemma/README.md for the loop overview and
docs/functiongemma-finetuning.md for the fine-tuning details.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

# --------------------------------------------------------------------------- #
# Constants: the creature action vocabulary (== the program's functions).
# --------------------------------------------------------------------------- #

# The complete, fixed action vocabulary. These are the tool names the model
# chooses from. Order is stable so declarations are deterministic.
ACTION_VOCAB: List[str] = [
    "flee",
    "hunt",
    "throw_rock",
    "scavenge",
    "graze",
    "drink",
    "seek_water",
    "flock",
    "wander",
    "rest",
    "migrate",
]

# Only `migrate` takes a parameter (a compass direction).
MIGRATE_DIRECTIONS: List[str] = ["north", "south", "east", "west"]

# One-line intent for each action, used both in the tool `description` and to
# help the tiny model ground the choice.
ACTION_DESCRIPTIONS: Dict[str, str] = {
    "flee": "Run away from a nearby predator to stay alive.",
    "hunt": "Chase and attack visible prey to get food.",
    "throw_rock": "Throw a rock at a predator or prey from a distance.",
    "scavenge": "Eat nearby carrion instead of hunting live prey.",
    "graze": "Eat nearby plants (for herbivores/omnivores).",
    "drink": "Drink water when standing at a water source.",
    "seek_water": "Travel toward water when thirsty and not at water.",
    "flock": "Move together with nearby same-species creatures.",
    "wander": "Explore the area with no urgent goal.",
    "rest": "Stay put and recover energy.",
    "migrate": "Travel a long distance in a compass direction to find better range.",
}

# Default macOS Godot userdata path for this project (config/name="LocalAgents").
DEFAULT_TRACES = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Godot"
    / "app_userdata"
    / "LocalAgents"
    / "functiongemma_traces.jsonl"
)

BASE_MODEL = "google/functiongemma-270m-it"

SYSTEM_PROMPT = (
    "You are an animal in a survival simulation. Given your species, your "
    "hunger and thirst, the time of day, and what you can see around you, call "
    "exactly one function from the available tools that best keeps you alive."
)


# --------------------------------------------------------------------------- #
# Tool schema (OpenAI-style) for all 11 actions.
# --------------------------------------------------------------------------- #


def build_tools() -> List[Dict[str, Any]]:
    """OpenAI-style JSON-schema tool declarations for every action.

    All actions declare an empty parameter object except `migrate`, which takes
    a required `direction` enum. Declaring *all* tools on every example teaches
    the model to discriminate rather than to imitate a single output.
    """
    tools: List[Dict[str, Any]] = []
    for name in ACTION_VOCAB:
        if name == "migrate":
            parameters: Dict[str, Any] = {
                "type": "object",
                "properties": {
                    "direction": {
                        "type": "string",
                        "enum": list(MIGRATE_DIRECTIONS),
                        "description": "Compass direction to migrate toward.",
                    }
                },
                "required": ["direction"],
            }
        else:
            parameters = {"type": "object", "properties": {}}
        tools.append(
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": ACTION_DESCRIPTIONS.get(name, name),
                    "parameters": parameters,
                },
            }
        )
    return tools


# --------------------------------------------------------------------------- #
# Trace loading + natural-language rendering.
# --------------------------------------------------------------------------- #


def load_traces(path: Path) -> List[Dict[str, Any]]:
    """Load JSONL traces, tolerating blank/garbled lines."""
    if not path.exists():
        raise FileNotFoundError(f"Trace file not found: {path}")
    rows: List[Dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                print(f"  warn: skipping malformed line {lineno}: {exc}", file=sys.stderr)
    return rows


def _frac_word(frac: float, low: str, mid: str, high: str) -> str:
    if frac <= 0.34:
        return low
    if frac <= 0.66:
        return mid
    return high


def render_situation(row: Dict[str, Any]) -> str:
    """Render a trace row as a natural-language user message.

    Example: "You are a nocturnal wolf (carnivore). You are very hungry and
    somewhat thirsty. It is night. You are not at water. You can see prey and
    carrion. No predators or plants are visible."
    """
    ctx: Dict[str, Any] = row.get("context", {}) or {}
    species = str(row.get("species", "animal"))
    diet = str(row.get("diet", "unknown diet"))

    energy = float(ctx.get("energy_frac", 1.0))
    hydration = float(ctx.get("hydration_frac", 1.0))
    hunger = _frac_word(energy, "starving", "somewhat hungry", "well fed")
    thirst = _frac_word(hydration, "parched", "somewhat thirsty", "hydrated")

    time_of_day = "It is night." if ctx.get("night") else "It is day."
    at_water = "You are at water." if ctx.get("at_water") else "You are not at water."

    seen: List[str] = []
    if ctx.get("predator_visible"):
        seen.append("a predator")
    if ctx.get("prey_visible"):
        seen.append("prey")
    if ctx.get("plant_visible"):
        seen.append("plants")
    if ctx.get("carrion_visible"):
        seen.append("carrion")
    if seen:
        sight = "You can see " + ", ".join(seen) + "."
    else:
        sight = "You cannot see anything of interest."

    return (
        f"You are a {species} ({diet}). You are {hunger} and {thirst}. "
        f"{time_of_day} {at_water} {sight}"
    )


def make_assistant_tool_call(action: str) -> Dict[str, Any]:
    """Build the assistant message that calls `action`.

    `migrate` needs a direction argument; the trace does not carry one, so we
    default to a stable placeholder. All other actions take no arguments.
    """
    if action == "migrate":
        arguments = json.dumps({"direction": "north"})
    else:
        arguments = json.dumps({})
    return {
        "role": "assistant",
        "content": "",
        "tool_calls": [
            {
                "type": "function",
                "function": {"name": action, "arguments": arguments},
            }
        ],
    }


def trace_to_example(row: Dict[str, Any], tools: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Convert one trace row to a chat example (messages + tools)."""
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": render_situation(row)},
        make_assistant_tool_call(str(row["chosen_action"])),
    ]
    return {"messages": messages, "tools": tools}


# --------------------------------------------------------------------------- #
# Filtering / quality control.
# --------------------------------------------------------------------------- #


def filter_rows(
    rows: Iterable[Dict[str, Any]],
    include_teacher: bool,
    consistent_only: bool,
) -> Tuple[List[Dict[str, Any]], Dict[str, int]]:
    """Keep mainly positive / consistent decisions; drop noise.

    Drops:
      - rows whose chosen_action is not in the vocabulary,
      - rows missing chosen_action,
      - teacher-sourced rows unless --include-teacher,
      - (optionally) rows where chosen_action == innate_action collapses learning
        signal; we instead keep them but this hook is here if needed.
    """
    kept: List[Dict[str, Any]] = []
    stats: Dict[str, int] = {
        "total": 0,
        "dropped_no_action": 0,
        "dropped_bad_action": 0,
        "dropped_teacher": 0,
        "dropped_inconsistent": 0,
        "kept": 0,
    }
    vocab = set(ACTION_VOCAB)
    for row in rows:
        stats["total"] += 1
        action = row.get("chosen_action")
        if not action:
            stats["dropped_no_action"] += 1
            continue
        if action not in vocab:
            stats["dropped_bad_action"] += 1
            continue
        source = row.get("source")
        if source == "teacher" and not include_teacher:
            stats["dropped_teacher"] += 1
            continue
        # Optional stricter gate: only train on rows where the model's own
        # choice agreed with the innate/teacher signal (a proxy for "positive").
        if consistent_only:
            innate = row.get("innate_action")
            if innate is not None and innate != action and source == "llm":
                stats["dropped_inconsistent"] += 1
                continue
        kept.append(row)
        stats["kept"] += 1
    return kept, stats


# --------------------------------------------------------------------------- #
# Optional-dependency probe.
# --------------------------------------------------------------------------- #


def probe_ml_stack() -> Tuple[bool, List[str]]:
    """Return (all_present, missing_module_names) without importing heavy code."""
    import importlib.util

    required = ["torch", "transformers", "datasets", "trl", "unsloth"]
    missing = [m for m in required if importlib.util.find_spec(m) is None]
    return (len(missing) == 0, missing)


# --------------------------------------------------------------------------- #
# Training.
# --------------------------------------------------------------------------- #


def train(
    examples: List[Dict[str, Any]],
    out_dir: Path,
    max_steps: int,
    lora_r: int,
    lr: float,
    max_seq_length: int,
    make_gguf: bool,
) -> Dict[str, Any]:
    """LoRA-finetune FunctionGemma with Unsloth and export a merged model + GGUF.

    Returns a result dict describing what was produced. Raises on hard failure.
    """
    # Imports are deferred so `--dry-run` and the conversion path work without
    # the ML stack installed.
    from unsloth import FastModel  # type: ignore
    from unsloth.chat_templates import train_on_responses_only  # type: ignore
    from datasets import Dataset  # type: ignore
    from trl import SFTTrainer, SFTConfig  # type: ignore

    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading base model {BASE_MODEL} (4-bit) ...")
    model, tokenizer = FastModel.from_pretrained(
        model_name=BASE_MODEL,
        max_seq_length=max_seq_length,
        load_in_4bit=True,
        full_finetuning=False,
    )

    model = FastModel.get_peft_model(
        model,
        r=lora_r,
        lora_alpha=lora_r,
        lora_dropout=0.0,
        target_modules=[
            "q_proj",
            "k_proj",
            "v_proj",
            "o_proj",
            "gate_proj",
            "up_proj",
            "down_proj",
        ],
        bias="none",
        random_state=3407,
    )

    # Render each example through the FunctionGemma chat template WITH tools.
    def _format(example: Dict[str, Any]) -> Dict[str, str]:
        text = tokenizer.apply_chat_template(
            example["messages"],
            tools=example["tools"],
            tokenize=False,
            add_generation_prompt=False,
        )
        return {"text": text}

    dataset = Dataset.from_list(examples).map(_format)

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=dataset,
        args=SFTConfig(
            per_device_train_batch_size=2,
            gradient_accumulation_steps=4,
            warmup_steps=5,
            max_steps=max_steps,
            learning_rate=lr,
            logging_steps=10,
            optim="adamw_8bit",
            weight_decay=0.01,
            lr_scheduler_type="linear",
            seed=3407,
            output_dir=str(out_dir / "checkpoints"),
            report_to="none",
            dataset_text_field="text",
            max_seq_length=max_seq_length,
        ),
    )

    # Train only on the assistant tool-call turn, not the situation prompt.
    try:
        trainer = train_on_responses_only(
            trainer,
            instruction_part="<start_of_turn>user\n",
            response_part="<start_of_turn>model\n",
        )
    except Exception as exc:  # noqa: BLE001 - template masking is best-effort
        print(f"  warn: train_on_responses_only unavailable ({exc}); "
              "training on full sequence.", file=sys.stderr)

    print(f"Training for {max_steps} steps on {len(examples)} examples ...")
    trainer.train()

    lora_dir = out_dir / "lora"
    model.save_pretrained(str(lora_dir))
    tokenizer.save_pretrained(str(lora_dir))
    print(f"Saved LoRA adapter -> {lora_dir}")

    merged_dir = out_dir / "merged"
    model.save_pretrained_merged(str(merged_dir), tokenizer, save_method="merged_16bit")
    print(f"Saved merged model -> {merged_dir}")

    result: Dict[str, Any] = {
        "status": "trained",
        "examples": len(examples),
        "lora_dir": str(lora_dir),
        "merged_dir": str(merged_dir),
        "gguf": None,
    }

    gguf_path = out_dir / "functiongemma-finetuned.gguf"
    if make_gguf:
        produced = try_export_gguf(model, merged_dir, gguf_path)
        result["gguf"] = str(produced) if produced else None
    else:
        print(convert_command(merged_dir, gguf_path))

    return result


def convert_command(merged_dir: Path, gguf_path: Path) -> str:
    """The llama.cpp conversion command to turn the merged HF model into GGUF."""
    return (
        "\nTo produce the GGUF, run llama.cpp's converter:\n\n"
        f"  python /path/to/llama.cpp/convert_hf_to_gguf.py \\\n"
        f"      {merged_dir} \\\n"
        f"      --outfile {gguf_path} \\\n"
        f"      --outtype bf16\n"
    )


def try_export_gguf(model: Any, merged_dir: Path, gguf_path: Path) -> Optional[Path]:
    """Best-effort GGUF export.

    Tries Unsloth's built-in exporter first, then falls back to invoking
    llama.cpp's convert_hf_to_gguf.py if it can be found on PATH or via
    the LLAMA_CPP_DIR env var. Returns the produced path or None.
    """
    # 1) Unsloth native GGUF export.
    try:
        model.save_pretrained_gguf(  # type: ignore[attr-defined]
            str(gguf_path.parent), quantization_method="bf16"
        )
        # Unsloth writes into the directory; find the newest .gguf.
        ggufs = sorted(gguf_path.parent.glob("*.gguf"), key=lambda p: p.stat().st_mtime)
        if ggufs:
            print(f"Exported GGUF (unsloth) -> {ggufs[-1]}")
            return ggufs[-1]
    except Exception as exc:  # noqa: BLE001
        print(f"  note: unsloth GGUF export unavailable ({exc}); trying llama.cpp.",
              file=sys.stderr)

    # 2) llama.cpp convert_hf_to_gguf.py fallback.
    converter = find_llama_converter()
    if converter is None:
        print("  note: convert_hf_to_gguf.py not found; skipping GGUF export.",
              file=sys.stderr)
        print(convert_command(merged_dir, gguf_path))
        return None

    import subprocess

    cmd = [
        sys.executable,
        str(converter),
        str(merged_dir),
        "--outfile",
        str(gguf_path),
        "--outtype",
        "bf16",
    ]
    print("Running:", " ".join(cmd))
    proc = subprocess.run(cmd)
    if proc.returncode == 0 and gguf_path.exists():
        print(f"Exported GGUF (llama.cpp) -> {gguf_path}")
        return gguf_path
    print("  warn: llama.cpp conversion failed.", file=sys.stderr)
    return None


def find_llama_converter() -> Optional[Path]:
    """Locate llama.cpp's convert_hf_to_gguf.py."""
    env = os.environ.get("LLAMA_CPP_DIR")
    candidates: List[Path] = []
    if env:
        candidates.append(Path(env) / "convert_hf_to_gguf.py")
    which = shutil.which("convert_hf_to_gguf.py")
    if which:
        candidates.append(Path(which))
    for c in candidates:
        if c.exists():
            return c
    return None


# --------------------------------------------------------------------------- #
# CLI.
# --------------------------------------------------------------------------- #


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Finetune FunctionGemma (the creatures' slow brain) from sim traces.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--traces", type=Path, default=DEFAULT_TRACES,
                   help="Path to functiongemma_traces.jsonl.")
    p.add_argument("--out", type=Path,
                   default=Path("addons/local_agents/models/functiongemma"),
                   help="Output directory for LoRA / merged model / GGUF.")
    p.add_argument("--include-teacher", action="store_true",
                   help="Also train on rows with source=='teacher' (default: drop them).")
    p.add_argument("--consistent-only", action="store_true",
                   help="Drop llm rows where chosen_action != innate_action.")
    p.add_argument("--max-steps", type=int, default=300,
                   help="Training steps.")
    p.add_argument("--lora-r", type=int, default=16, help="LoRA rank.")
    p.add_argument("--lr", type=float, default=2e-4, help="Learning rate.")
    p.add_argument("--max-seq-length", type=int, default=4096,
                   help="Max sequence length (model supports up to 32768).")
    p.add_argument("--no-gguf", action="store_true",
                   help="Skip GGUF export; just print the convert command.")
    p.add_argument("--dry-run", action="store_true",
                   help="Convert + filter traces and print stats/samples; do not train.")
    p.add_argument("--emit-dataset", type=Path, default=None,
                   help="Also write the converted chat examples to this JSONL file.")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)

    # 1) Load + convert traces (stdlib only).
    try:
        rows = load_traces(args.traces)
    except FileNotFoundError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print("Run the sim first to generate traces, or pass --traces <path>.",
              file=sys.stderr)
        return 2

    kept, stats = filter_rows(
        rows,
        include_teacher=args.include_teacher,
        consistent_only=args.consistent_only,
    )
    print("Trace filtering:")
    for k, v in stats.items():
        print(f"  {k:22s} {v}")

    if not kept:
        print("ERROR: no usable rows after filtering; nothing to train on.",
              file=sys.stderr)
        return 3

    tools = build_tools()
    examples = [trace_to_example(r, tools) for r in kept]

    if args.emit_dataset is not None:
        args.emit_dataset.parent.mkdir(parents=True, exist_ok=True)
        with args.emit_dataset.open("w", encoding="utf-8") as fh:
            for ex in examples:
                fh.write(json.dumps(ex) + "\n")
        print(f"Wrote {len(examples)} examples -> {args.emit_dataset}")

    if args.dry_run:
        print("\n--- sample converted example ---")
        print(json.dumps(examples[0], indent=2))
        print("\n(dry run: not training)")
        return 0

    # 2) Ensure the ML stack is present before attempting to train.
    ok, missing = probe_ml_stack()
    if not ok:
        print("\nThe ML training stack is not installed; skipping training.",
              file=sys.stderr)
        print(f"Missing modules: {', '.join(missing)}", file=sys.stderr)
        print("Install with, e.g.:", file=sys.stderr)
        print('  pip install "unsloth" trl transformers datasets torch', file=sys.stderr)
        print(f"\nConverted {len(examples)} examples successfully; re-run without "
              "--dry-run once deps are installed (or use --emit-dataset to save them).",
              file=sys.stderr)
        return 4

    # 3) Train.
    try:
        result = train(
            examples=examples,
            out_dir=args.out,
            max_steps=args.max_steps,
            lora_r=args.lora_r,
            lr=args.lr,
            max_seq_length=args.max_seq_length,
            make_gguf=not args.no_gguf,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR during training: {exc}", file=sys.stderr)
        return 5

    print("\nDone.")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

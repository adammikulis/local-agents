# FunctionGemma slow brain — auto-finetune loop

This directory holds the **FunctionGemma** model used as the creatures' *slow brain* in the
voxel ecosystem sim, plus the reference docs and the trained GGUF that the sim loads.

FunctionGemma (`google/functiongemma-270m-it`) is Google's 270M-parameter, on-device
function-calling model, built on Gemma 3 270M and **designed to be fine-tuned**. See
[`docs/functiongemma-overview.md`](docs/functiongemma-overview.md) and
[`docs/functiongemma-finetuning.md`](docs/functiongemma-finetuning.md).

## The loop

The sim continuously improves its own slow brain from lived experience:

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │ 1. RUN THE SIM                                                        │
  │    Creatures act on a fast innate brain; hard decisions are          │
  │    escalated to the slow brain. Every escalated decision is logged   │
  │    to functiongemma_traces.jsonl in the Godot user data dir.         │
  │                                                                       │
  │ 2. CONVERT  (scripts/functiongemma_train.py)                         │
  │    Traces -> FunctionGemma chat / tool-calling training examples.    │
  │    Keep mainly positive / consistent decisions; drop noise.          │
  │                                                                       │
  │ 3. FINETUNE  (Unsloth LoRA on google/functiongemma-270m-it)          │
  │    r=16, lr=2e-4, a few hundred steps. Merge the adapter.            │
  │                                                                       │
  │ 4. EXPORT   Convert merged model -> GGUF, drop it back into          │
  │    addons/local_agents/models/functiongemma/ for the sim to load.    │
  └─────────────────────────────────────────────────────────────────────┘
                          ▲                                   │
                          └───────────── better brain ────────┘
```

Wrapper entry point: [`scripts/finetune_functiongemma.sh`](../../../../scripts/finetune_functiongemma.sh),
which resolves the trace path, checks Python deps, runs the trainer, and copies the
resulting GGUF here. The heavy lifting is in
[`scripts/functiongemma_train.py`](../../../../scripts/functiongemma_train.py).

## Where traces live

The Godot sim writes `functiongemma_traces.jsonl` to the project user data dir. On macOS
(project name `LocalAgents`) that is:

```
~/Library/Application Support/Godot/app_userdata/LocalAgents/functiongemma_traces.jsonl
```

The trainer defaults to that path and accepts `--traces <path>` to override it.

## Trace schema (fixed)

Each line of `functiongemma_traces.jsonl` is one escalated decision:

```jsonc
{
  "sig_key": int,            // stable hash of the situation signature
  "sig_text": String,        // human-readable signature
  "species": String,
  "diet": String,
  "context": {
    "energy_frac":      float,   // 0..1 hunger inverse (1 = full)
    "hydration_frac":   float,   // 0..1 thirst inverse (1 = hydrated)
    "at_water":         bool,
    "night":            bool,
    "predator_visible": bool,
    "prey_visible":     bool,
    "plant_visible":    bool,
    "carrion_visible":  bool
  },
  "tools":          [ /* action-name strings available this turn */ ],
  "innate_action":  String,      // what the fast brain would have done
  "chosen_action":  String,      // what was actually taken (the training label)
  "source":         "llm" | "teacher"
}
```

`source` distinguishes decisions made by the model in the loop (`"llm"`) from
teacher/heuristic-labelled decisions (`"teacher"`). By default the trainer trains on all
rows; pass `--include-teacher` semantics are documented in the script (teacher rows can be
dropped to train only on the model's own consistent choices).

## Action vocabulary (the program's functions)

The creature's complete action set — these are the tool names the model chooses from:

```
flee, hunt, throw_rock, scavenge, graze, drink, seek_water, flock, wander, rest, migrate
```

All actions take **no parameters** except `migrate`, which takes a `direction` enum
(`north`, `south`, `east`, `west`). The trainer emits an OpenAI-style JSON-schema tool
declaration for all 11 actions on every example so the model learns to *discriminate*
between them, and an assistant tool call to the row's `chosen_action` as the label.

## Contents of this directory

- `docs/functiongemma-overview.md` — what FunctionGemma is, run commands, chat template.
- `docs/functiongemma-finetuning.md` — how fine-tuning + GGUF export works.
- `README.md` — this file.
- `*.gguf` — the trained slow-brain model (produced by the loop; not checked in).

# Fine-tuning FunctionGemma

Practical notes on adapting `google/functiongemma-270m-it` to a custom tool set with
Unsloth LoRA, then exporting to GGUF for llama.cpp. This mirrors the flow used by
`scripts/functiongemma_train.py` in this repo.

## Why fine-tune

The released checkpoint is a strong general function-caller, but Google explicitly ships
it as a base to specialise. Fine-tuning on *your* tools and *your* decision style is how
you get the big accuracy gains (Google reported ~58% → ~85% on their eval). For a game
NPC / creature brain, "your tools" is a small fixed vocabulary of actions, and "your
decision style" is what a good survival policy would choose in each situation.

## What a training example looks like

Fine-tuning FunctionGemma is supervised learning on **chat examples that end in a tool
call**. Each example is a list of messages plus the tool declarations that were visible
for that turn:

1. A **system / developer message** framing the task (e.g. "You are an animal; pick the
   one function that best keeps you alive.").
2. A **user message** — the natural-language situation ("A hungry wolf at night sees prey
   nearby and is not near water.").
3. An **assistant message** whose content is a single **tool call** to the correct
   function (`hunt`, with any required arguments).
4. The **`tools`** list: OpenAI-style JSON schema for every function the model is allowed
   to choose from on that turn. Declaring all tools (not just the correct one) teaches the
   model to *discriminate*, not just to imitate one output.

You render these with the tokenizer's chat template, which knows how to place the tool
declarations in the developer turn and format the assistant tool call with the
`<start_function_call>call:...<end_function_call>` special tokens:

```python
text = tokenizer.apply_chat_template(
    messages,
    tools=tools,               # OpenAI-style JSON-schema tool list
    tokenize=False,
    add_generation_prompt=False,  # False for training (label includes the assistant turn)
)
```

Only the assistant turn should contribute to the loss. Unsloth's
`train_on_responses_only` helper (or a Gemma response template) masks the prompt tokens so
the model is trained to *produce* the tool call, not to reproduce the developer/user text.

## Data quality matters more than volume

Because the model is tiny and the task is narrow, a few hundred to a few thousand *clean,
consistent* examples go a long way. Keep decisions that reflect the policy you want; drop
noisy or contradictory rows. Balance across the actions so rare-but-important choices
(e.g. `flee`, `throw_rock`) are represented and the model does not collapse onto the
majority action.

## Unsloth LoRA recipe

Unsloth loads the model in 4-bit and attaches a LoRA adapter so training fits on a single
consumer GPU. A minimal recipe (see the tutorial in Sources):

```python
from unsloth import FastModel   # or FastLanguageModel
from trl import SFTTrainer, SFTConfig

model, tokenizer = FastModel.from_pretrained(
    model_name = "google/functiongemma-270m-it",
    max_seq_length = 32768,
    load_in_4bit = True,
    full_finetuning = False,
)

model = FastModel.get_peft_model(
    model,
    r = 16,                     # LoRA rank
    lora_alpha = 16,
    lora_dropout = 0.0,
    target_modules = ["q_proj", "k_proj", "v_proj", "o_proj",
                      "gate_proj", "up_proj", "down_proj"],
    bias = "none",
    random_state = 3407,
)

trainer = SFTTrainer(
    model = model,
    tokenizer = tokenizer,
    train_dataset = dataset,    # column "text" from apply_chat_template
    args = SFTConfig(
        per_device_train_batch_size = 2,
        gradient_accumulation_steps = 4,
        max_steps = 300,        # a few hundred steps is plenty for this size
        learning_rate = 2e-4,
        warmup_steps = 5,
        logging_steps = 10,
        optim = "adamw_8bit",
        lr_scheduler_type = "linear",
        seed = 3407,
    ),
)
trainer.train()
```

Sensible defaults for a 270M model: **r = 16**, **lr = 2e-4**, a **few hundred steps**.
Watch that loss decreases and, ideally, hold out a handful of situations to eyeball that
the model calls the right function.

## Export to GGUF for llama.cpp

The sim's slow brain runs the model through llama.cpp, so after training you merge the
LoRA into the base weights and convert to GGUF.

1. **Merge + save** the adapter into a full HF model:

   ```python
   model.save_pretrained_merged("functiongemma-merged", tokenizer,
                                save_method = "merged_16bit")
   ```

   (Unsloth can also export GGUF directly via
   `model.save_pretrained_gguf(...)` when the toolchain is available.)

2. **Convert** the merged HF model to GGUF with llama.cpp's converter:

   ```bash
   python /path/to/llama.cpp/convert_hf_to_gguf.py \
       functiongemma-merged \
       --outfile functiongemma-finetuned.gguf \
       --outtype bf16
   ```

3. Optionally **quantise** for smaller/faster on-device inference:

   ```bash
   llama-quantize functiongemma-finetuned.gguf \
       functiongemma-finetuned-Q4_K_M.gguf Q4_K_M
   ```

4. Serve as before with `--jinja` so the tool-calling template is applied:

   ```bash
   llama-server -m functiongemma-finetuned.gguf --jinja -ngl 99 --ctx-size 32768
   ```

## Gotchas

- **Keep `--jinja`.** Without the chat template the fine-tuned model will not frame tool
  calls correctly and llama-server will not parse `tool_calls`.
- **Declare all candidate tools per example**, not only the correct one — otherwise the
  model learns to always call whatever single tool it was shown.
- **Mask the prompt** (train on responses only) so you optimise the tool call, not the
  situation text.
- **Match the chat template** used at training and inference time; use the tokenizer that
  ships with `google/functiongemma-270m-it`.

## Sources

- https://unsloth.ai/docs/models/tutorials/functiongemma
- https://ai.google.dev/gemma/docs/functiongemma
- https://huggingface.co/google/functiongemma-270m-it
- https://blog.google/technology/developers/functiongemma/

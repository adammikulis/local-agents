# FunctionGemma — Overview

Vendored reference notes for in-project RAG. Summarised from Google, Hugging Face,
and Unsloth documentation (see **Sources** below).

## What it is

**FunctionGemma** (`google/functiongemma-270m-it`) is a small, open-weights language
model from Google purpose-built for **on-device function calling** (a.k.a. tool
calling). Instead of being a general chat model, it is specialised to read a set of
declared tools plus a user request and emit a structured call to the single most
appropriate tool. This makes it a good fit for embedded agents, robotics, games, and
other latency- or privacy-sensitive settings where a full-size model is impractical.

## Key facts

- **Base model:** Gemma 3 270M (the 270-million-parameter Gemma 3 variant).
- **Size:** ~270M parameters — small enough to run comfortably on CPU or a modest GPU,
  and to fine-tune on a single consumer GPU.
- **Context length:** 32K tokens (`--ctx-size 32768`).
- **Task:** function / tool calling. Given tool declarations and a user turn, it selects
  and fills a function call.
- **Designed to be fine-tuned.** Google positions the released checkpoint as a strong
  *starting point* that teams are expected to adapt to their own tool set. In Google's
  own evaluation, task-specific fine-tuning raised function-calling accuracy from about
  **58% to 85%** — a large jump that is the whole point of the model.
- **Instruction-tuned** (`-it`) so it already follows the chat template out of the box.

## Chat template & output format

FunctionGemma uses the Gemma chat template with an extra **developer turn** that carries
the tool declarations. The important special tokens are:

- Tools are declared in a developer turn, each wrapped in
  `<start_function_declaration>...<end_function_declaration>`.
- The model emits a call wrapped in
  `<start_function_call>call:{name}{args}<end_function_call>`.
- The model may optionally emit a `<think>...</think>` reasoning block before the call.

Conceptually a turn looks like:

```
<start_of_turn>developer
<start_function_declaration>
name: get_weather
description: Get the current weather for a city.
parameters: { "city": "string" }
<end_function_declaration>
<end_of_turn>
<start_of_turn>user
What's the weather in Paris?<end_of_turn>
<start_of_turn>model
<start_function_call>call:get_weather{"city": "Paris"}<end_function_call><end_of_turn>
```

### Served through llama.cpp / llama-server

When you serve the GGUF with **llama.cpp `llama-server --jinja`**, the bundled chat
template handles the special tokens for you. You pass tools using the standard OpenAI
`tools` array on the `/v1/chat/completions` request, and the model's function calls come
back as standard **OpenAI-style `tool_calls`** in the response — you do not have to parse
the raw `<start_function_call>` tokens yourself. This is why `--jinja` is required: it
activates the model's Jinja chat template so the tool-call framing is applied and parsed.

## GGUF repositories

Ready-to-run quantised builds for llama.cpp:

- `unsloth/functiongemma-270m-it-GGUF`
- `ggml-org/functiongemma-270m-it-GGUF`

## Running with llama.cpp

Quick interactive run (downloads the GGUF from Hugging Face automatically):

```bash
llama-cli -hf unsloth/functiongemma-270m-it-GGUF:BF16 --jinja -ngl 99 --ctx-size 32768
```

As a local OpenAI-compatible server:

```bash
llama-server -hf unsloth/functiongemma-270m-it-GGUF:BF16 --jinja -ngl 99 --ctx-size 32768
```

Flag notes:

- `-hf <repo>:<quant>` pulls the model from Hugging Face (`:BF16` here; smaller quants
  such as `:Q4_K_M` also exist and trade accuracy for size/speed).
- `--jinja` activates the model's chat template so tool declarations and `tool_calls`
  work — **required** for correct function calling.
- `-ngl 99` offloads all layers to GPU (use `-ngl 0` for CPU-only).
- `--ctx-size 32768` uses the full 32K context.

## Sources

- https://ai.google.dev/gemma/docs/functiongemma
- https://blog.google/technology/developers/functiongemma/
- https://huggingface.co/google/functiongemma-270m-it
- https://unsloth.ai/docs/models/tutorials/functiongemma

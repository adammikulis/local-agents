Note: Mind Game is back as Local Agents! The current active branch is https://github.com/adammikulis/local-agents/tree/0.3-dev and I look forward to merging changes into main soon.


This is a plugin for the Godot game engine that allows the user to load and run a local Large Language Model (LLM) in-engine using the [LLamaSharp](https://github.com/SciSharp/LLamaSharp) (v0.13.0) C# library.
# Current Local Agents features
## Fast, local chat models in your games
![mindgame_inference](https://github.com/adammikulis/MindGame/assets/27887607/bb9da9c0-622d-4b6d-af08-40cf7f2bdba9)

## Easy configuration
![mindgame_config](https://github.com/adammikulis/MindGame/assets/27887607/3ecd86f9-cf92-473f-a667-76b62b7cfdb0)

# Run Local Agents stand-alone

1) Install [CUDA Toolkit 12.1](https://developer.nvidia.com/cuda-12-1-0-download-archive) if you haven't already (12.1 recommended for compatibility with other projects like [Unsloth](https://github.com/unslothai/unsloth)).
2) Download the [latest Mind Game release](https://github.com/adammikulis/MindGame/releases) for your platform and run the executable
3) Download a .gguf model of the Llama, Phi, or Mistral families
4) Load your model and have fun!

Smallest well-performing model: [Phi-3](https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/tree/main)

Larger, high-quality model: [Llama3-8B-Instruct](https://huggingface.co/bartowski/Meta-Llama-3-8B-Instruct-GGUF/tree/main)

Another 7B model: [Mistral-7B-Instruct-v0.2](https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/tree/main)



# Run Local Agents as a Godot plug-in

1) Install [CUDA Toolkit 12.1](https://developer.nvidia.com/cuda-12-1-0-download-archive) if you haven't already (12.1 recommended for compatibility with other projects like [Unsloth](https://github.com/unslothai/unsloth)).
2) Download and extract [Godot 4.3 (.NET version)](https://godotengine.org/download/archive/4.3-beta2/)
3) Download/install [.NET8](https://dotnet.microsoft.com/en-us/download)
4) Clone/download this repo (or the most recent dev branch to have the most current features) and open it with Godot 4.3 .NET,
5) Click Project > Project Settings > Plugins > Enabled (Mind Game). Go to the Autoload tab and make sure MindManager is enabled.
6) Load a .gguf file of the Llama, Mistral, Mixtral, or [Phi](https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf) families to get going!


The lower quantization (q), the smaller the model is to run but at the cost of accuracy. Llama-3-8B-Instruct.Q4_K_M is a great middle-ground for those with 8GB of VRAM. The absolute smallest model [Phi-3-mini-4k-instruct.IQ1_S.gguf](https://huggingface.co/bartowski/Phi-3-mini-4k-instruct-GGUF/blob/main/Phi-3-mini-4k-instruct-IQ1_S.gguf) can run on less than 1GB of VRAM. Note: quantizations that start with 'I' run very slowly on CPU, I recommend those for GPU inference only.

# Architecture of Local Agents
This plugin revolves around the MindManager autoload, which handles all backend model loading and allows every scene to access it. The user does not have to ever interact with the MindManager directly, as the configurations are handled on their own screens.

To send/receive input to the model, you add a MindAgent node to your scene, which talks with the MindManager node. It can signal out the text it receives so that you can connect it to a Label3D, as in the example. By attaching a MindAgent to a CharacterBody3D (or anything else that moves), you can give the agent a body (example scene is MindAgent3D). When I transition to the BatchedExecutor, the user will be able to have n-conversations simultaneously (limited only by the user's hardware).

# Future steps
- ~~Make a singleton to be able to access currently loaded model in-game~~ (complete 0.2.0)
- Transition to BatchedExecutor (begun 0.3-dev)
- Add conversation save/load, forking, and rewinding (begun 0.3-dev)
- Add network graph generation (begun 0.3-dev)
- Implement LLaVa support, including live viewport analysis
- Make Download Manager functional
- Add project script crawling
- Expose LLamaSharp methods like quantization
- Integrate Kernel Memory for document ingestion

# Release Version History

## 0.2.0: 
- MindManager is now an autoload
- Model configurations can be saved/loaded
- MindAgent nodes can be added in the inspector
- 3D chat example with MindAgent3D
  
## 0.1.3:
- First release, model loading and chat enabled in engine bottom bar

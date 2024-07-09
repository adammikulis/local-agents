# Mind Game Contributing Guide

Hello and welcome to Mind Game! This is a Godot plugin born out of a love of AI and video games.

## The Goal of Mind Game

My vision for Mind Game is for the user to be able to say what sort of story/game they want and for it to be generated for them. It utilizes [LLamaSharp](https://github.com/SciSharp/LLamaSharp), which is a C# wrapper for llama.cpp to run popular language models like Llama, Mistral, and Phi. 

## Current Features of Mind Game (0.3-dev)
1. Local inference with both CPU and GPU
2. Saving/loading model and inference parameters
2. 3D chat example
3. Batched conversation processing for better throughput

## Features in Development
I have recently transitioned to the BatchedExecutor and am adding conversation saving/loading. Additionally, I have started to implement a graph network that will serve as the RAG system.

## How to Contribute
Download the addon, downloaded a .gguf language model, and run the ChatExample. See if you can integrate a MindAgent into a game or example scene of your own. Either add (via PR) or suggest features you would like to see, and please report any issues!

I currently only have Windows/Linux releases, so if you use MacOS I could use a tester!
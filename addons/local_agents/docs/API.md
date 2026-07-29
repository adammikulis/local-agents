# API reference

This is the per-type reference for the Local Agents addon: exports as the inspector groups them, methods with their real signatures,
signals, and the configuration warnings each node shows in the editor before you press Play. `addons/local_agents/docs/USAGE.md`
covers how to assemble these into something that works.

Godot 4.7. Every file path here is relative to the project root, so you can paste one straight into a `res://` load or an editor
FileSystem search.

## Contents

The reference is split by area. Each page documents exports as the inspector groups them, methods with their real
signatures, signals, and the configuration warnings each node shows in the editor before you press Play.

| Page | Types |
| --- | --- |
| [Agents and chat](API_AGENTS.md) | `LocalAgent`, `LocalAgent3D`, `LocalAgentChatPanel`, `LocalAgentConversation`, `LocalAgentStatusLabel`, `LocalAgentLlmService`, `LocalAgentLlmClient` |
| [Configuration, status and settings](API_CONFIG.md) | `LocalAgentModelProfile`, `LocalAgentInferenceParams`, `LocalAgentStatus`, `LocalAgentSettings`, `LocalAgentManager` |
| [The memory graph](API_MEMORY.md) | `LocalAgentGraph`, `LocalAgentGraphNode`, `LocalAgentGraphEdge`, `LocalAgentGraphRule`, `LocalAgentBackstoryGraphService` |
| [Simulation nodes](API_SIMULATION.md) | `LocalAgentCreature`, `LocalAgentCreatureSpawner`, `LocalAgentCognitionScheduler`, `LocalAgentSimWorld`, `LocalAgentFieldBox` |
| [Demo harness and catalogue](API_DEMOS.md) | `LocalAgentDemoHarness`, `LocalAgentDemoEntry`, `LocalAgentTutorialStep` |

## What is public

The addon declares about 80 `class_name LocalAgent*` scripts. Most are internal modules that happen to sit in that namespace, and
this file does not document them. The types here are the ones you instantiate in a scene or assign in the inspector, plus two you
reach from code at runtime: `LocalAgentLlmClient` and the `AgentManager` autoload. Thirteen of the types carry an editor icon
(`@icon`), which is how you recognise them in the Create Node dialog: the twelve nodes LocalAgent,
LocalAgent3D, LocalAgentChatPanel, LocalAgentConversation, LocalAgentStatusLabel, LocalAgentLlmService,
LocalAgentCognitionScheduler, LocalAgentCreature, LocalAgentCreatureSpawner, LocalAgentSimWorld, LocalAgentFieldBox and
LocalAgentDemoHarness, plus the LocalAgentGraph resource. `LocalAgentStatus` and `LocalAgentSettings` are static-only and never
added to a scene.

`LocalAgentBackstoryGraphService` is public too: it is the node you assign to `LocalAgent`'s Backstory slot to give an
agent a long memory, and it is a typed `@export`.

Everything else is an implementation detail: the editor panels, the runtime plumbing (`LocalAgentLlamaServerManager`,
`LocalAgentRuntimePaths`, `LocalAgentExtensionLoader`, `LocalAgentModelSettingsStore`), the audio engine, the Backstory
ops scripts behind that service, and the four helper modules `LocalAgent` delegates to (`LocalAgentAgentHistory`,
`LocalAgentAgentJobs`, `LocalAgentAgentServer`, `LocalAgentAgentSpeech`). You can call them, but their signatures move
without notice.

The plugin registers no custom node types. Every script here declares a `class_name`, so Godot already lists them.

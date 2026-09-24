#pragma once

// The agent bundle (com.localagents.godot-agent) is never activated and runs as a watched foreground app
// would. No-op in any other process.
void la_agent_process_policy();

# Agent Roster

| Agent        | Mission Scope | Core Responsibilities | Key Interfaces | Agent Assigned |
|--------------|---------------|------------------------|----------------|----------------|
| **Frontend Agent** | Editor/UI & in-game UX | - Maintain bottom-panel plugin UI and runtime widgets<br>- Restore demo scenes and reusable HUD components<br>- Keep GDScript controllers `@tool`-friendly and Godot 4 compliant | Runtime Agent (signals/state), Experience Agent (UX feedback) | [ ] Unassigned |
| **Runtime Agent** | Native GDExtension & inference pipeline | - Evolve `AgentRuntime`, `AgentNode`, and native helpers<br>- Track llama.cpp API changes and keep bindings current<br>- Extend NetworkGraph, embedding, speech/transcription support | Data Agent (config/runtime IO), DevOps Agent (build tooling) | [ ] Unassigned |
| **Data Agent** | Assets, downloads, persistence | - Maintain dependency scripts and metadata manifests<br>- Own NetworkGraph schema, memory/embedding APIs<br>- Coordinate configuration resources and asset packaging | Runtime Agent (native API needs), Experience Agent (docs/demos) | [ ] Unassigned |
| **Quality Agent** | Documentation, testing, architecture health | - Audit docs for accuracy, publish changelog & migration notes<br>- Drive refactor backlog and lint/test adoption<br>- Monitor third-party updates & compatibility | All agents; especially DevOps (CI), Experience (docs) | [ ] Unassigned |
| **DevOps Agent** | CI/CD, packaging, release automation | - Bundle native deps across platforms, maintain build scripts<br>- Own CI pipelines, release artifacts, and regression monitoring<br>- Manage export templates and distribution channels | Runtime Agent (native builds), Quality Agent (test strategy) | [ ] Unassigned |
| **Experience Agent** | Tutorials, demos, onboarding | - Produce quickstarts, videos, and sample scenes<br>- Update screenshots/release notes and gather user feedback<br>- Coordinate localisation/content strategy | Frontend/Data (feature handoff), Quality (doc reviews) | [ ] Unassigned |

## Cross-Agent Expectations

- Communicate breaking changes via `ARCHITECTURE_PLAN.md` before landing them.
- Prefer additive changes; leave TODOs rather than deleting another agent’s work.
- Log blockers or ownership gaps in this file so the right agent can act.
- Default to feature branches and avoid force pushes on shared branches.
- Keep the “Agent Assigned” checkboxes up to date as owners rotate.

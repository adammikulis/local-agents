# Local Agents documentation

These files live inside the addon, so they travel with it when you copy
`addons/local_agents/` into another project.

- INSTALL.md: getting the native extension and a `.gguf` model, enabling the plugin, and the
  per-platform library filenames Godot looks for.
- USAGE.md: what is in the addon, what you can delete, the nodes you drop into a scene, the project
  settings, the two adapter contracts, and how to run a scene headless.
- API.md: the per-type reference for every public class the addon registers.
- DEMOS.md: the example scenes, rendered by `scripts/gen_demos_doc.sh` from the
  `LocalAgentDemoEntry` catalogue in `addons/local_agents/examples/demos/`.
- img/: the screenshots and diagrams the repo root README links to.

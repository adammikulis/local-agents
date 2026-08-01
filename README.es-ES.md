

# Local Agents (Godot)

**Modelos de lenguaje grandes locales, ejecutándose completamente sin conexión, impulsando tanto acciones como respuestas dentro de un juego de Godot.** Sin nube, sin claves API, sin ida y vuelta por la red: el modelo se ejecuta en la propia máquina del jugador a través de una GDExtension respaldada por llama.cpp. Un nodo `LocalAgentsAgent` carga un modelo GGUF y te proporciona dos cosas a la vez: **respuestas** (chat, diálogo, un comentarista en vivo) y **acciones** (una criatura que decide huir, un streamer que reacciona a lo que acaba de ocurrir en pantalla).

La demostración principal es un planeta voxel emergente donde las manadas piensan, los desastres surgen de la física y un streamer con LLM local narra el caos en vivo: todo sin conexión.

![La demostración del planeta voxel emergente](addons/local_agents/docs/img/planet.png)

## Qué es

- **LLM local priorizado para offline en un motor.** Coloca un nodo, apúntalo a un modelo GGUF, llama a `think()` y lee la respuesta. Todo se ejecuta en el mismo proceso en el hardware del jugador.
- **Acciones y respuestas desde el mismo runtime.** El mismo agente que responde a un prompt de chat puede emitir una señal `action_requested` que el código del juego convierte en comportamiento. Las criaturas en la simulación voxel usan reglas locales rápidas para el caso común y llaman al modelo para situaciones nuevas; una superposición de streamer observa la simulación y comenta sobre ella con voz generada (TTS) y, opcionalmente, escucha (STT).
- **Una GDExtension nativa** (`localagents`) que envuelve llama.cpp para la generación de texto, más whisper.cpp para transcripción y Piper para voz: todo integrado, todo local.

## Historia de origen (un agente LLM local temprano, desde marzo de 2024)

Este proyecto comenzó el **14 de marzo de 2024** como **MindGame** (`adammikulis/MindGame`), un complemento de Godot en C# / LlamaSharp para cargar un modelo `.gguf` y chatear con él localmente, con un gestor de descargas de modelos integrado. Eso lo convierte en **uno de los primeros agentes LLM locales incrustados en un software** de los que tenemos conocimiento.

Se lo escribió a mano por un motivo concreto: en ese momento, el enlace LLM local del que dependía (LlamaSharp, sobre el entonces joven llama.cpp) era **demasiado nuevo para que los asistentes de codificación de la época lo conocieran**: esos modelos tenían poca o ninguna cobertura de entrenamiento sobre las bibliotecas que el proyecto necesitaba, por lo que no había atajos. Tenía que escribirse manualmente.

En aproximadamente 2,3 años y ~830 commits, creció desde ese prototipo de chat en C# hasta el proyecto actual: un complemento GDScript respaldado por una GDExtension nativa en C++/llama.cpp, y una simulación de ecosistema voxel emergente usada como demostración en vivo. Hay una leve ironía de círculo completo en que un agente de codificación pueda ahora ayudar a terminar un proyecto temprano de agente de codificación local: las bibliotecas que necesitaba finalmente llegaron a las herramientas que no pudieron ayudar a construirlas en 2024.

## Requisitos previos (ambos son necesarios para ejecutar)

Un clon recién hecho **no** se ejecutará hasta que tengas estas dos cosas. Ninguna está comprometida en el repositorio.

### 1. El binario de la extensión nativa

La GDExtension `localagents` es una biblioteca compilada en C++ (`bin/` es un artefacto de compilación ignorado por git). Consíguelo de una de dos formas:

- **Descargar un artefacto de CI (no se necesita cadena de herramientas).** El flujo de trabajo de GitHub Actions [Build Extension (Cross-Platform)](.github/workflows/build-extension.yml) compila binarios para Linux, Windows y macOS y carga cada uno como un artefacto llamado `localagents-<platform>-bin`. Descarga el de tu plataforma desde la ejecución del flujo de trabajo y descomprímelo en `addons/local_agents/gdextensions/localagents/bin/`.
- **Compilarlo localmente.** Desde el directorio de la extensión:

  ```bash
  cd addons/local_agents/gdextensions/localagents
  ./scripts/fetch_dependencies.sh        # godot-cpp, llama.cpp, whisper.cpp, sqlite (+ the default model & voices)
  ./scripts/build_extension.sh --platform macos   # or: linux | windows
  ```

  Esto genera `bin/localagents.<platform>.{dylib,so,dll}` más los runtimes incluidos. (Ejecutar `fetch_dependencies.sh` sin `--skip-models` también descarga el modelo GGUF predeterminado, cubriendo el paso 2 de una sola vez.)

Si falta el binario, el estado del runtime lo indicará ("Native runtime missing…") en lugar de no hacer nada en silencio.

### 2. Un modelo GGUF

El modelo predeterminado es **`Qwen3-4B-Instruct-2507-Q4_K_M.gguf`**, resuelto desde `user://local_agents/models/qwen3-4b-instruct/` (o el `addons/local_agents/models/` dentro del repositorio, obtenido por el script de compilación).

La forma más sencilla de conseguir uno: abre el proyecto en Godot, habilita el complemento **Local Agents** y usa el panel inferior **Local Agents → Descargas** para obtener un modelo. Se almacena automáticamente en el directorio de modelos del usuario.

## Inicio rápido en 60 segundos

1. **Obtén el binario nativo** (arriba): descarga el artefacto de CI o compílalo localmente.
2. **Obtén un modelo** (arriba): el panel del editor **Local Agents → Descargas** es el camino fácil.
3. **Abre la escena de inicio rápido** `addons/local_agents/examples/AgentQuickstart.tscn`, presiona reproducir, escribe un prompt y pulsa enter.

![La escena de inicio rápido respondiendo a un prompt con un modelo local](addons/local_agents/docs/img/quickstart.png)

Esa escena es literalmente **un nodo `Agent` más un cuadro de prompt y una etiqueta de respuesta**. Para construir lo mismo desde cero, coloca un nodo `LocalAgentsAgent` (una vez habilitado el complemento aparece como **Agent** en el diálogo Añadir nodo) y conecta cinco líneas:

```gdscript
@onready var agent: LocalAgentsAgent = %Agent

func _ready() -> void:
    agent.configure()                                  # picks up the default model + runtime
    agent.model_output_received.connect(_on_reply)     # fires when the model answers
    var result: Dictionary = agent.think("Say hello.") # runs the local model
    if not result.get("ok", true):
        push_warning("Agent unavailable: %s" % result.get("error", ""))

func _on_reply(text: String) -> void:
    print(text)
```

`think(prompt)` registra el prompt, ejecuta el modelo local, devuelve un diccionario de resultado `Dictionary` y emite `model_output_received` con el texto. Para TTS/STT usa `say(text)` / `listen()`; para impulsar el comportamiento del juego, conecta la señal `action_requested(action, params)`.

## Demos

Cada demo es una escena que puedes abrir y ejecutar. Los ejemplos forman una **escalera**: cada escalón añade una capacidad sobre el anterior, para que puedas ver cómo se superponen las funciones, desde un chatbot de un solo nodo hasta la simulación planetaria principal. El punto de entrada más amigable es el **lanzador**, que lista cada demo con una descripción de una línea y un botón Abrir.

| Demo | Escena | Qué muestra |
| --- | --- | --- |
| **Lanzador de demos** (comienza aquí) | `addons/local_agents/examples/DemoLauncher.tscn` | La puerta principal: un menú de cada demo de abajo, ordenado de más simple a más completo, cada uno con un botón Abrir con un clic. |
| **1. Inicio rápido** | `addons/local_agents/examples/AgentQuickstart.tscn` | La escena más pequeña de "hablar con un LLM local": un nodo `Agent`, un cuadro de prompt, una respuesta. |
| **2. El agente impulsa acciones** | `addons/local_agents/examples/AgentActionsDemo.tscn` | El bucle de acciones que convierte a un agente en más que un chatbot: la respuesta del modelo se convierte en llamadas a `enqueue_action` que recoloran y hacen pulsar una esfera en pantalla (los botones manuales disparan las mismas acciones, así que funciona sin modelo). |
| **3. Dos agentes conversan** | `addons/local_agents/examples/AgentConversationDemo.tscn` | Cognición + memoria: Ada y Ben se turnan, y cada línea se registra como un nodo en un `LocalAgentsGraph` compartido (encadenado por aristas `then`) que crece como la memoria de la conversación. |
| **4. Chat** | `addons/local_agents/examples/ChatExample.tscn` | Una interfaz de chat más completa con configuración de modelo/inferencia, estado de salud del runtime y conversaciones guardadas. |
| **5. Agente 3D** | `addons/local_agents/examples/Agent3DExample.tscn` | Un prefab de agente 3D que habla impulsado por el mismo runtime, con una lista de verificación de configuración en pantalla. |
| **6. Graph** | `addons/local_agents/examples/GraphExample.tscn` | El recurso `LocalAgentsGraph` (nodos/aristas) para conocimiento estructurado del agente: se ejecuta sin un modelo. |
| **Simulación de planeta voxel** (principal) | `addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn` | Un ecosistema emergente en un planeta voxel: un sustrato material tipo química (calor, agua, viento, fuego, lava, erosión…), manadas que buscan alimento/huyen/cazan con parentesco, desastres que surgen de la física en lugar de scripts, y un streamer con LLM local narrándolo en vivo. |

La simulación voxel también es la `run/main_scene` del proyecto, por lo que presionar reproducir en el proyecto la inicia.
Dispone de su propio arnés para ejecuciones no interactivas:

```bash
# headless smoke boot: prints one SIM_REPORT={...} telemetry line, then quits
godot --headless res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --run-frames=300

# windowed screenshot (whole-planet vista); also --auto-meteor / --auto-volcano / --auto-lightning
godot res://addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn -- --shoot=/tmp/shot.png --overview
```

> Un nuevo `.gd` `class_name` o `.gdextension` solo se registra después de un escaneo del editor: ejecuta `godot --headless --editor --quit-after 400` una vez, o las nuevas clases se reportarán como faltantes.

## Pruebas

El arnés unificado envuelve los ejecutores canónicos, deriva un registro e imprime una línea `AGENT_HARNESS_RESULT={...}`:

```bash
scripts/agent_harness.sh fast       # fast test sweep
scripts/agent_harness.sh all        # full suite
scripts/agent_harness.sh bounded    # bounded runtime-heavy suite
scripts/agent_harness.sh extension  # validate the GDExtension
scripts/agent_harness.sh lint       # typing + process gates
```

Ejecuta un módulo a través del ayudante canónico (nunca inicies un `test_*.gd` directamente):

```bash
scripts/run_single_test.sh test_agent_integration.gd
```

## Notas

- El runtime es priorizando escenas y impulsado por recursos; los objetivos de computación autoritativa de simulación apuntan a GPU/nativo y fallan rápido (`GPU_REQUIRED` / `NATIVE_REQUIRED`) en lugar de degradarse silenciosamente. La única forma legítima de ejecución en CPU es la alternativa sin cabeza/sin GPU.
- Las reglas de proceso y Godot son referencia en `CLAUDE.md` y `GODOT_BEST_PRACTICES.md`; `ARCHITECTURE_PLAN.md` registra cambios rupturistas. La estrella norte del diseño emergente y los ejemplos trabajados están en `addons/local_agents/scenes/simulation/voxel/EMERGENCE.md`.

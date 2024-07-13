using Godot;
using LLama;
using LLama.Common;
using System.Threading.Tasks;
using LLama.Native;
using LLama.Batched;
using System;

namespace MindGame
{
    [Tool]
    public partial class MindManager : Node
    {
        public ModelParams CurrentModelConfigs { get; set; }

        [Signal]
        public delegate void ClipModelStatusUpdateEventHandler(bool isLoaded);
        [Signal]
        public delegate void EmbedderModelStatusUpdateEventHandler(bool isLoaded);
        [Signal]
        public delegate void ExecutorStatusUpdateEventHandler(bool isLoaded);

        // Chat Executor
        public BatchedExecutor BatchedExecutor { get; private set; }


        // Clip model vars
        //public LLavaWeights clipWeights { get; private set; }

        // Embedder model vars
        //public LLamaEmbedder embedder { get; private set; }

        public ConfigList ConfigList;
        public readonly string ConfigListPath = "res://addons/mind_game/configuration/parameters/ConfigList.tres";

  

        /// <summary>
        /// Function that is called when node and all children are initialized
        /// </summary>
        public override void _Ready()
        {
            EnsureConfigListResourceExists();
        }

        private void EnsureConfigListResourceExists()
        {
            if (FileAccess.FileExists(ConfigListPath))
            {
                try
                {
                    ConfigList = GD.Load<ConfigList>(ConfigListPath);
                    if (ConfigList == null)
                    {
                        GD.PrintErr($"Failed to load ConfigList from {ConfigListPath}. Creating a new one.");
                        CreateNewConfigList();
                    }
                }
                catch (Exception e)
                {
                    GD.PrintErr($"Error loading ConfigList: {e.Message}. Creating a new one.");
                    CreateNewConfigList();
                }
            }
            else
            {
                GD.Print($"ConfigList file does not exist at {ConfigListPath}. Creating a new one.");
                CreateNewConfigList();
            }
        }

        private void CreateNewConfigList()
        {
            ConfigList = new ConfigList();
            SaveConfigList();
        }

        private void SaveConfigList()
        {
            var error = ResourceSaver.Save(ConfigList, ConfigListPath);
            if (error != Error.Ok)
            {
                GD.PrintErr($"Failed to save ConfigList to {ConfigListPath}. Error: {error}");
            }
        }

        public async Task InitializeAsync(ModelParams config)
        {
            CurrentModelConfigs = config;
            await LoadModelsAsync();
        }

        private async Task LoadModelsAsync()
        {
            // await LoadEmbedderAsync(CurrentModelConfigs.EmbedderModelPath, CurrentModelConfigs.EmbedderContextSize, CurrentModelConfigs.EmbedderGpuLayerCount, CurrentModelConfigs.EmbedderRandomSeed);
            // await LoadClipModelAsync(CurrentModelConfigs.ClipModelPath);
            await InitializeChatExecutorAsync();
        }

        //private async Task LoadEmbedderAsync()
        //{
        //    await Task.Run(() =>
        //    {
        //        var parameters = new ModelParams(CurrentModelConfigs.EmbedderModelPath)
        //        {
        //            ContextSize = CurrentModelConfigs.EmbedderContextSize,
        //            Seed = CurrentModelConfigs.EmbedderRandomSeed,
        //            GpuLayerCount = CurrentModelConfigs.EmbedderGpuLayerCount,
        //            Embeddings = true
        //        };

        //        using var embedderWeights = LLamaWeights.LoadFromFile(parameters);
        //        embedder = new LLamaEmbedder(embedderWeights, parameters);
        //    });
        //}

        //public void UnloadEmbedderModel()
        //{
        //    embedder?.Dispose();
        //}

        public async Task InitializeChatExecutorAsync()
        {
            if (!string.IsNullOrEmpty(CurrentModelConfigs.ChatModelPath))
            {
                var parameters = new LLama.Common.ModelParams(CurrentModelConfigs.ChatModelPath)
                {
                    ContextSize = CurrentModelConfigs.ChatContextSize,
                    Seed = CurrentModelConfigs.ChatRandomSeed,
                    GpuLayerCount = CurrentModelConfigs.ChatGpuLayerCount,
                    Embeddings = false
                };

                await Task.Run(() =>
                {
                    using var chatWeights = LLamaWeights.LoadFromFile(parameters);

                    BatchedExecutor = new BatchedExecutor(chatWeights, parameters);
                    CallDeferred("emit_signal", SignalName.ExecutorStatusUpdate, true);
                });
            }
        }

        //public async Task LoadClipModelAsync(string modelPath)
        //{
        //    if (!string.IsNullOrEmpty(modelPath))
        //    {
        //        await Task.Run(() =>
        //        {
        //            clipWeights = LLavaWeights.LoadFromFile(modelPath);
        //            CallDeferred("emit_signal", SignalName.ClipModelStatusUpdate, true);
        //        });
        //    }
        //    else
        //    {
        //        GD.Print("Clip model path not set, no model loaded.");
        //    }
        //}

        //public async Task DisposeClipWeightsAsync()
        //{
        //    await Task.Run(() =>
        //    {
        //        clipWeights = null;
        //        CallDeferred("emit_signal", SignalName.ClipModelStatusUpdate, false);
        //    });
        //}

        public async Task DisposeExecutorAsync()
        {
            await Task.Run(() =>
            {
                BatchedExecutor = null;
                CallDeferred("emit_signal", SignalName.ExecutorStatusUpdate, false);
            });
        }

        public async Task DisposeAll()
        {
            //await DisposeClipWeightsAsync();
            await DisposeExecutorAsync();
        }

        public override void _ExitTree()
        {
        }
    }
}

using Godot;
using LLama;
using LLama.Batched;
using LLama.Common;
using LLama.Grammars;
using LLama.Native;
using LLama.Sampling;
using System;
using System.Threading.Tasks;
using System.IO;
using System.Linq;

namespace MindGame
{
    public partial class MindAgent : Node
    {
        private const int n_len = 18;
        
        [Signal]
        public delegate void ModelOutputReceivedEventHandler(string text);
        [Signal]
        public delegate void ConversationsSavedEventHandler();

        private ConfigList configListResource;
        private MindManager _mindManager;
        private Grammar grammar;
        private SafeLLamaGrammarHandle grammarInstance;
        public string[] antiPrompts = { "<|eot_id|>", "<|end|>", "user:", "User:", "USER:", "\nUser:", "\nUSER:", "}" };
        public float temperature = 0.75f;
        public int maxTokens = 4000;
        public bool outputJson = false;

        private Conversation _currentConversation;

        public override void _Ready()
        {
            InitializeNodeRefs();
            using var file = Godot.FileAccess.Open("res://addons/mind_game/assets/grammar/json.gbnf", Godot.FileAccess.ModeFlags.Read);
            string gbnf = file.GetAsText().Trim();
            grammar = Grammar.Parse(gbnf, "root");
        }

        private void InitializeNodeRefs()
        {
            _mindManager = GetNode<MindGame.MindManager>("/root/MindManager");
        }

        public async Task InferAsync(string prompt)
        {
            if (_mindManager.BatchedExecutor == null)
            {
                GD.PrintErr("BatchedExecutor not initialized. Please check the model configuration.");
                return;
            }

            if (_currentConversation == null)
            {
                _currentConversation = _mindManager.BatchedExecutor.Create();
            }

            _currentConversation.Prompt(_mindManager.BatchedExecutor.Context.Tokenize(prompt));

            var decoder = new StreamingTokenDecoder(_mindManager.BatchedExecutor.Context);
            var sampler = new DefaultSamplingPipeline();
            var lastToken = await GenerateTokens(_mindManager.BatchedExecutor, _currentConversation, sampler, decoder, n_len);

            
            if (_currentConversation.RequiresInference)
            {
                await _mindManager.BatchedExecutor.Infer();
            }
;
            var result = decoder.Read();

            CallDeferred("emit_signal", SignalName.ModelOutputReceived, result);
        }

        private static async Task<LLamaToken> GenerateTokens(BatchedExecutor executor, Conversation conversation, ISamplingPipeline sampler, StreamingTokenDecoder decoder, int count = 15)
        {
            var token = (LLamaToken)0;
            for (var i = 0; i < count; i++)
            {
                await executor.Infer();
                token = sampler.Sample(executor.Context.NativeHandle, conversation.Sample(), ReadOnlySpan<LLamaToken>.Empty);
                decoder.Add(token);
                conversation.Prompt(token);
            }
            return token;
        }

        public void SaveConversation(string fileName)
        {
            if (_currentConversation == null)
            {
                GD.PrintErr("No active conversation to save.");
                return;
            }

            string savePath = $"res://addons/mind_game/examples/conversations/{fileName}.state";
            Directory.CreateDirectory(Path.GetDirectoryName(savePath));

            _currentConversation.Save(savePath);
            GD.Print($"Conversation saved to: {savePath}");
            EmitSignal(SignalName.ConversationsSaved);
        }

        public void LoadConversation(string fileName)
        {
            string loadPath = $"res://addons/mind_game/examples/conversations/{fileName}.state";

            if (!File.Exists(loadPath))
            {
                GD.PrintErr($"Conversation file not found: {loadPath}");
            }

            _currentConversation?.Dispose();
            _currentConversation = _mindManager.BatchedExecutor.Load(loadPath);
            GD.Print($"Conversation loaded from: {loadPath}");
        }

        public string[] GetSavedConversations()
        {
            string conversationsDir = "user://conversations";
            if (!Directory.Exists(conversationsDir))
            {
                return Array.Empty<string>();
            }

            return Directory.GetFiles(conversationsDir, "*.state")
                .Select(Path.GetFileNameWithoutExtension)
                .ToArray();
        }
    }
}
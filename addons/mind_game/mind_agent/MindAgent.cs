// Adapted from https://github.com/SciSharp/LLamaSharp/blob/master/LLama.Examples/Examples/BatchedExecutorFork.cs

using Godot;
using LLama;
using LLama.Batched;
using LLama.Grammars;
using LLama.Native;
using LLama.Sampling;
using System;
using System.Threading.Tasks;

namespace MindGame
{
    public partial class MindAgent : Node
    {

        /// <summary>
        /// Set how many tokens to generate before forking
        /// </summary>
        private const int ForkTokenCount = 100;

        /// <summary>
        /// Set total length of the sequence to generate
        /// </summary>
        private const int TokenCount = 256;


        [Signal]
        public delegate void ChatOutputReceivedEventHandler(string text);

        private ConfigList configListResource;
        private MindManager _mindManager;
        private Grammar grammar;
        private SafeLLamaGrammarHandle grammarInstance;
        public string[] antiPrompts = { "<|eot_id|>", "<|end|>",  "user:", "User:", "USER:", "\nUser:", "\nUSER:", "}" };
        public float temperature = 0.75f;
        public int maxTokens = 4000;
        public bool outputJson = false;

        public override void _EnterTree()
        {
            
        }

        /// <summary>
        /// Function that is called when node and all children are initialized
        /// </summary>
        public override void _Ready()
        {
            InitializeNodeRefs();

            // Load the grammar definition
            using var file = FileAccess.Open("res://addons/mind_game/assets/grammar/json.gbnf", FileAccess.ModeFlags.Read);
            string gbnf = file.GetAsText().Trim();
            grammar = Grammar.Parse(gbnf, "root");
        }

        private void InitializeNodeRefs()
        {
            _mindManager = GetNode<MindGame.MindManager>("/root/MindManager");
        }

        public async Task InferAsync(string prompt)
        {
            if (_mindManager.batchedExecutor == null)
            {
                GD.PrintErr("BatchedExecutor not initialized. Please check the model configuration.");
                return;
            }

            // Evaluate the initial prompt to create one conversation
            using var start = _mindManager.batchedExecutor.Create();
            start.Prompt(_mindManager.batchedExecutor.Context.Tokenize(prompt));
            await _mindManager.batchedExecutor.Infer();

            // Create the root node of the tree
            var root = new Node(start);

            await Task.Run(async () =>
            {
                for (var i = 0; i < TokenCount; i++)
                {
                    if (i != 0)
                        await _mindManager.batchedExecutor.Infer();

                    if (i != 0 && i % ForkTokenCount == 0)
                        root.Fork();

                    root.Sample();
                }
            });

            var result = root.Read();
            CallDeferred("emit_signal", SignalName.ChatOutputReceived, result);
        }




        public override void _ExitTree() 
        {
            
        }

        private class Node
        {
            private readonly StreamingTokenDecoder _decoder;
            private readonly DefaultSamplingPipeline _sampler = new();
            private Conversation _conversation;

            private Node _left;
            private Node _right;

            public int ActiveConversationCount => _conversation != null ? 1 : _left.ActiveConversationCount + _right.ActiveConversationCount;

            public Node(Conversation conversation)
            {
                _conversation = conversation;
                _decoder = new StreamingTokenDecoder(conversation.Executor.Context);
            }

            public void Sample()
            {
                if (_conversation == null)
                {
                    _left?.Sample();
                    _right?.Sample();
                    return;
                }

                if (_conversation.RequiresInference)
                    return;

                var ctx = _conversation.Executor.Context.NativeHandle;
                var token = _sampler.Sample(ctx, _conversation.Sample(), Array.Empty<LLamaToken>());
                _sampler.Accept(ctx, token);
                _decoder.Add(token);
                _conversation.Prompt(token);
            }

            public void Fork()
            {
                if (_conversation != null)
                {
                    _left = new Node(_conversation.Fork());
                    _right = new Node(_conversation.Fork());

                    _conversation.Dispose();
                    _conversation = null;
                }
                else
                {
                    _left?.Fork();
                    _right?.Fork();
                }
            }

            public string Read()
            {
                return _decoder.Read();
            }
        }
    }
}


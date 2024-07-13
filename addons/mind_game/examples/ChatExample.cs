using Godot;
using System;


namespace MindGame
{
    public partial class ChatExample : Node
    {
        private MindAgent _mindAgent;
        private ModelConfig _modelConfig;
        private InferenceConfig _inferenceConfig;
        private ChatController _chatController;

        /// <summary>
        /// Function that is called when node and all children are initialized
        /// </summary>
        public override void _Ready()
        {
            InitializeNodeRefs();
            InitializeSignals();
        }

        /// <summary>
        /// Function that is called to assign scene tree nodes to script variables
        /// </summary>
        private void InitializeNodeRefs()
        {
            _mindAgent = GetNode<MindAgent>("%MindAgent");
            _inferenceConfig = GetNode<InferenceConfig>("%InferenceConfig");
            _modelConfig = GetNode<ModelConfig>("%ModelConfig");
            _chatController = GetNode<ChatController>("%ChatController");
        }

        /// <summary>
        /// Function that is called to connect signals to callbacks
        /// </summary>
        private void InitializeSignals()
        {
            _mindAgent.ChatOutputReceived += OnChatOutputReceived;
            _chatController.PromptInputReceived += OnPromptInputReceived;
        }

        /// <summary>
        /// Function that calls for model inference when prompt input is received
        /// </summary>
        /// <param name="text"></param>
        private async void OnPromptInputReceived(string text)
        {
            await _mindAgent.InferAsync(text);
        }

        /// <summary>
        /// Function that sends inference output to chat controller when received
        /// </summary>
        /// <param name="text"></param>
        private void OnChatOutputReceived(string text)
        {
            _chatController.OnChatOutputReceived(text);
        }
    }
}
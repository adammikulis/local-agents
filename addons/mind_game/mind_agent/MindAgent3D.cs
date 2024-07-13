using Godot;
using System;
using System.Threading.Tasks;
using static Godot.HttpRequest;

namespace MindGame
{
    public partial class MindAgent3D : CharacterBody3D
    {

        [Signal]
        public delegate void ModelOutputReceivedEventHandler(string text);

        public Label3D ChatLabel3D { get; set; }
        public MindGame.MindAgent MindAgent { get; set; }
        public MindGame.MindManager MindManager { get; set; }
        public AnimationPlayer AnimationPlayer { get; set; }


        /// <summary>
        /// Function that is called when node and all children are initialized
        /// </summary>
        public override void _Ready()
        {
            MindManager = GetNode<MindGame.MindManager>("/root/MindManager");
            MindAgent = GetNode<MindGame.MindAgent>("%MindAgent");
            ChatLabel3D = GetNode<Label3D>("%ChatLabel3D");
            AnimationPlayer = GetNode<AnimationPlayer>("%AnimationPlayer");

            MindAgent.ModelOutputReceived += OnChatOutputReceived;
        }

        public async Task InferAsync(string prompt)
        {
            ChatLabel3D.Text = "";
            await MindAgent.InferAsync(prompt);
        }

        public void OnChatOutputReceived(string text)
        {
            ChatLabel3D.Text += text;
            if (AnimationPlayer.GetCurrentAnimation() ==  "")
            {
                AnimationPlayer.SetCurrentAnimation("bobble");
            }
            CallDeferred("emit_signal", SignalName.ModelOutputReceived, text);

        }
    }
}

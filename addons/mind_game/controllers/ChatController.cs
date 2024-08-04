using Godot;
using MindGame;
using System;

public partial class ChatController : Control
{
    [Signal]
    public delegate void PromptInputReceivedEventHandler(string text);

    private MindManager _mindManager;
    private ModelConfig _modelConfig;
    private InferenceConfig _inferenceConfig;


    private LineEdit _modelInputLineEdit;
    private RichTextLabel _modelOutputRichTextLabel;


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
        _mindManager = GetNode<MindGame.MindManager>("/root/MindManager");
        _modelInputLineEdit = GetNode<LineEdit>("%ModelInputLineEdit");
        _inferenceConfig = GetNode<InferenceConfig>("%InferenceConfig");
        _modelConfig = GetNode<ModelConfig>("%ModelConfig");
        

        _modelOutputRichTextLabel = GetNode<RichTextLabel>("%ModelOutputRichTextLabel");

    }

    /// <summary>
    /// Function that is called to connect signals to callbacks
    /// </summary>
    private void InitializeSignals()
    {
        _modelInputLineEdit.TextSubmitted += OnPromptInputReceived;

        // _inferenceConfigButton.Pressed += OnInferenceConfigPressed;

    }

    private void OnConfigAndLoadModelsPressed()
    {
        _modelConfig.Visible = true;
    }
   

    private void OnPromptInputReceived(string prompt)
    {
        _modelInputLineEdit.Text = "";
        _modelOutputRichTextLabel.Text += $"{prompt}\n";
        CallDeferred("emit_signal", SignalName.PromptInputReceived, prompt);
    }

    public void OnChatOutputReceived(string text)
    {
        _modelOutputRichTextLabel.Text += $"{text}\n";
    }
}
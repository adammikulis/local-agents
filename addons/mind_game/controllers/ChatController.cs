using Godot;
using MindGame;
using System;

public partial class ChatController : Control
{
    [Signal]
    public delegate void PromptInputReceivedEventHandler(string text);

    private MindGame.MindManager _mindManager;
    private MindGame.ModelConfig _modelConfig;
    private MindGame.InferenceConfig _inferenceConfig;

    private Button _configAndLoadModelsButton, _exitButton;
    private LineEdit _modelInputLineEdit;
    private ItemList _savedConversationsItemList;
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
        _savedConversationsItemList = GetNode<ItemList>("%SavedConversationsItemList");

        _modelOutputRichTextLabel = GetNode<RichTextLabel>("%ModelOutputRichTextLabel");

        _configAndLoadModelsButton = GetNode<Button>("%ConfigAndLoadModelsButton");

        _exitButton = GetNode<Button>("%ExitButton");

    }

    /// <summary>
    /// Function that is called to connect signals to callbacks
    /// </summary>
    private void InitializeSignals()
    {
        _modelInputLineEdit.TextSubmitted += OnPromptInputReceived;
        _configAndLoadModelsButton.Pressed += OnConfigAndLoadModelsPressed;
        // _inferenceConfigButton.Pressed += OnInferenceConfigPressed;

        _exitButton.Pressed += OnExitPressed;
    }

    private void OnConfigAndLoadModelsPressed()
    {
        _modelConfig.Visible = true;
    }

    private void OnChatSessionStatusUpdate(bool isLoaded)
    {
        _modelInputLineEdit.Editable = isLoaded;
        if (isLoaded)
        {
            _modelInputLineEdit.PlaceholderText = $"Type prompt and hit Enter";
        }
        else
        {
            _modelInputLineEdit.PlaceholderText = $"Load a model to chat!";
        }
    }


    private async void OnExitPressed()
    {
        await _mindManager.DisposeExecutorAsync();
        GetTree().Quit();
    }

    /// <summary>
    /// Function to save configuration list
    /// </summary>
    private void SaveConfigList()
    {
        Error saveError = ResourceSaver.Save(_mindManager.ConfigList, _mindManager.ConfigListPath);
        if (saveError != Error.Ok)
        {
            GD.PrintErr("Failed to save configuration list: ", saveError);
        }
    }

    private void OnPromptInputReceived(string prompt)
    {
        _modelInputLineEdit.Text = "";
        _modelOutputRichTextLabel.Text += $"{prompt}\n";
        CallDeferred("emit_signal", SignalName.PromptInputReceived, prompt);
        // await _mindAgent3D.InferAsync(prompt); need to move back to ChatExample
    }

    public void OnChatOutputReceived(string text)
    {
        _modelOutputRichTextLabel.Text += $"{text}\n";
    }


}

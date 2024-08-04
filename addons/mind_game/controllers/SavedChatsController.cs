using Godot;
using MindGame;
using System;

public partial class SavedChatsController : Control
{
    private MindManager _mindManager;
    private Button _configAndLoadModelsButton, _exitButton, _hideMenuButton;
    private ItemList _savedConversationsItemList;

    public override void _Ready()
    {
        InitializeNodeRefs();
        InitializeSignals();
    }

    private void InitializeNodeRefs()
    {
        _mindManager = GetNode<MindGame.MindManager>("/root/MindManager");
        _savedConversationsItemList = GetNode<ItemList>("%SavedConversationsItemList");
        _configAndLoadModelsButton = GetNode<Button>("%ConfigAndLoadModelsButton");

        _exitButton = GetNode<Button>("%ExitButton");
    }

    private void InitializeSignals()
    {
        _exitButton.Pressed += OnExitPressed;

        // _configAndLoadModelsButton.Pressed += OnConfigAndLoadModelsPressed;
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

    private void OnHideMenuButtonPressed()
    {
        Hide();
    }
}

using Godot;
using System;

namespace MindGame
{
    public partial class ModelConfig : Control
    {
        
        private MindManager _mindManager;

        // UI elements
        private Button _addNewConfigButton, _deleteConfigButton, _selectChatPathButton, _clearChatPathButton, _selectEmbedderPathButton, _clearEmbedderPathButton, _selectClipPathButton, _clearClipPathButton, _loadConfigButton, _unloadConfigButton;
        private Label _chatContextSizeLabel, _chatGpuLayerCountLabel, _embedderContextSizeLabel, _embedderGpuLayerCountLabel, _chatCurrentModelPathLabel, _embedderCurrentModelPathLabel, _clipCurrentModelPathLabel;
        private FileDialog _selectChatPathFileDialog, _selectClipPathFileDialog, _selectEmbedderPathFileDialog;
        private HSlider _chatContextSizeHSlider, _chatGpuLayerCountHSlider, _embedderContextSizeHSlider, _embedderGpuLayerCountHSlider;
        private LineEdit _configNameLineEdit, _chatRandomSeedLineEdit, _embedderRandomSeedLineEdit;
        private ItemList _savedConfigsItemList;
        private CheckBox _autoloadLastGoodConfigCheckBox;

        // Model params
        private ModelParams _modelParamsConfig;
        private string _configName;
        private int _chatGpuLayerCount, _embedderGpuLayerCount;
        private uint _chatContextSize, _embedderContextSize, _chatRandomSeed, _embedderRandomSeed;
        private string _chatModelPath, _clipModelPath, _embedderModelPath;

        /// <summary>
        /// Function that is called when node and all children are initialized
        /// </summary>
        public override void _Ready()
        {
            InitializeDefaultValues();
            InitializeNodeRefs();
            InitializeSignals();
            InitializeUiElements();
            AutoloadLastGoodConfig();
        }


        private void SaveConfigList()
        {
            Error saveError = ResourceSaver.Save(_mindManager.ConfigList, _mindManager.ConfigListPath);
            if (saveError != Error.Ok)
            {
                GD.PrintErr("Failed to save configuration list: ", saveError);
            }
        }

        /// <summary>
        /// Loads the configuration list resource
        /// </summary>
        private void InitializeConfigList()
        {
            UpdateConfigItemList();
        }

        /// <summary>
        /// Updates the ItemList with saved model configurations
        /// </summary>
        private void UpdateConfigItemList()
        {
            _savedConfigsItemList.Clear();
            GD.Print($"Updating config list. Config count: {_mindManager.ConfigList.ModelConfigurations.Count}");
            foreach (var config in _mindManager.ConfigList.ModelConfigurations)
            {
                GD.Print($"Adding config: {config.ModelConfigName}");
                _savedConfigsItemList.AddItem(config.ModelConfigName);
            }
        }

        /// <summary>
        /// Function that is called to iniatialize default model config values
        /// </summary>
        private void InitializeDefaultValues()
        {
            _configName = "<default>";
            _chatContextSize = 4000;
            _chatGpuLayerCount = 33;
            _chatRandomSeed = 0;
            _chatModelPath = "";
            _embedderContextSize = 4000;
            _embedderGpuLayerCount = 33;
            _embedderRandomSeed = 0;
            _embedderModelPath = "";
            _clipModelPath = "";
        }

        /// <summary>
        /// Function that is called to assign scene tree nodes to script variables
        /// </summary>
        private void InitializeNodeRefs()
        {
            // Mind manager autoload
            _mindManager = GetNode<MindManager>("/root/MindManager");

            // Manage config nodes
            _configNameLineEdit = GetNode<LineEdit>("%ConfigNameLineEdit");
            _savedConfigsItemList = GetNode<ItemList>("%SavedConfigsItemList");
            _addNewConfigButton = GetNode<Button>("%AddNewConfigButton");
            _deleteConfigButton = GetNode<Button>("%DeleteConfigButton");
            _loadConfigButton = GetNode<Button>("%LoadConfigButton");
            _unloadConfigButton = GetNode<Button>("%UnloadConfigButton");
            _autoloadLastGoodConfigCheckBox = GetNode<CheckBox>("%AutoloadLastGoodConfigCheckBox");

            // Chat param nodes
            _chatContextSizeHSlider = GetNode<HSlider>("%ChatContextSizeHSlider");
            _chatContextSizeLabel = GetNode<Label>("%ChatContextSizeLabel");
            _chatGpuLayerCountHSlider = GetNode<HSlider>("%ChatModelGpuLayerCountHSlider");
            _chatGpuLayerCountLabel = GetNode<Label>("%ChatModelGpuLayerCountLabel");
            _chatRandomSeedLineEdit = GetNode<LineEdit>("%ChatRandomSeedLineEdit");

            // Chat path nodes
            _selectChatPathButton = GetNode<Button>("%SelectChatPathButton");
            _clearChatPathButton = GetNode<Button>("%ClearChatPathButton");
            _selectChatPathFileDialog = GetNode<FileDialog>("%SelectChatPathFileDialog");
            _chatCurrentModelPathLabel = GetNode<Label>("%ChatCurrentModelPathLabel");

            // Embedder param nodes
            _embedderContextSizeHSlider = GetNode<HSlider>("%EmbedderContextSizeHSlider");
            _embedderContextSizeLabel = GetNode<Label>("%EmbedderContextSizeLabel");
            _embedderGpuLayerCountHSlider = GetNode<HSlider>("%EmbedderGpuLayerCountHSlider");
            _embedderGpuLayerCountLabel = GetNode<Label>("%EmbedderGpuLayerCountLabel");
            _embedderRandomSeedLineEdit = GetNode<LineEdit>("%EmbedderRandomSeedLineEdit");

            // Embedder path nodes
            _selectEmbedderPathButton = GetNode<Button>("%SelectEmbedderPathButton");
            _clearEmbedderPathButton = GetNode<Button>("%ClearEmbedderPathButton");
            _selectEmbedderPathFileDialog = GetNode<FileDialog>("%SelectEmbedderPathFileDialog");
            _embedderCurrentModelPathLabel = GetNode<Label>("%EmbedderCurrentModelPathLabel");

            // Clip path nodes
            _selectClipPathButton = GetNode<Button>("%SelectClipPathButton");
            _clearClipPathButton = GetNode<Button>("%ClearClipPathButton");
            _selectClipPathFileDialog = GetNode<FileDialog>("%SelectClipPathFileDialog");
            _clipCurrentModelPathLabel = GetNode<Label>("%ClipCurrentModelPathLabel");
        }

        /// <summary>
        /// Function that is called to connect signals to callbacks
        /// </summary>
        private void InitializeSignals()
        {
            // Chat signals
            _addNewConfigButton.Pressed += OnAddNewConfigPressed;
            _deleteConfigButton.Pressed += OnDeleteConfigPressed;
            _loadConfigButton.Pressed += OnLoadModelConfigPressed;
            _unloadConfigButton.Pressed += OnUnloadModelConfigPressed;
            _autoloadLastGoodConfigCheckBox.Toggled += OnAutoloadLastGoodConfigToggled;


            _clearChatPathButton.Pressed += OnClearChatPathPressed;
            _clearClipPathButton.Pressed += OnClearClipPathPressed;
            _clearEmbedderPathButton.Pressed += OnClearEmbedderPathPressed;

            // HSlider signals
            _chatContextSizeHSlider.ValueChanged += OnChatContextSizeHSliderValueChanged;
            _chatGpuLayerCountHSlider.ValueChanged += OnChatGpuLayerCountHSliderValueChanged;
            _embedderContextSizeHSlider.ValueChanged += OnEmbedderContextSizeHSliderValueChanged;
            _embedderGpuLayerCountHSlider.ValueChanged += OnEmbedderGpuLayerCountHSliderValueChanged;

            // File path signals
            _selectChatPathButton.Pressed += OnSelectChatPathPressed;
            _selectClipPathButton.Pressed += OnSelectClipPathPressed;
            _selectEmbedderPathButton.Pressed += OnSelectEmbedderPathPressed;

            _selectChatPathFileDialog.FileSelected += OnChatPathSelected;
            _selectClipPathFileDialog.FileSelected += OnClipPathSelected;
            _selectEmbedderPathFileDialog.FileSelected += OnEmbedderPathSelected;

            _configNameLineEdit.TextChanged += OnConfigNameTextChanged;
            _savedConfigsItemList.ItemSelected += OnSavedConfigsItemSelected;
        }

        private void OnAutoloadLastGoodConfigToggled(bool toggledOn)
        {
            if (_mindManager.ConfigList != null)
            {
                _mindManager.ConfigList.AutoloadLastGoodModelConfig = toggledOn;
                SaveConfigList();
            }
        }

        public void AutoloadLastGoodConfig()
        {
            if (_mindManager.ConfigList != null && _mindManager.ConfigList.AutoloadLastGoodModelConfig && _mindManager.ConfigList.LastGoodModelConfig != null)
            {
                _modelParamsConfig = _mindManager.ConfigList.LastGoodModelConfig;
                LoadConfig(_modelParamsConfig);
                OnLoadModelConfigPressed();
            }
        }

        private void LoadConfig(ModelParams config)
        {
            _configNameLineEdit.Text = config.ModelConfigName;
            _chatContextSizeHSlider.Value = CalculateLogContextSize(config.ChatContextSize);
            _chatGpuLayerCountHSlider.Value = config.ChatGpuLayerCount;
            _chatRandomSeedLineEdit.Text = config.ChatRandomSeed.ToString();
            _chatCurrentModelPathLabel.Text = config.ChatModelPath;
            _embedderContextSizeHSlider.Value = CalculateLogContextSize(config.EmbedderContextSize);
            _embedderGpuLayerCountHSlider.Value = config.EmbedderGpuLayerCount;
            _embedderRandomSeedLineEdit.Text = config.EmbedderRandomSeed.ToString();
            _embedderCurrentModelPathLabel.Text = config.EmbedderModelPath;
            _clipCurrentModelPathLabel.Text = config.ClipModelPath;
        }

        private async void OnUnloadModelConfigPressed()
        {
            await _mindManager.DisposeExecutorAsync();
        }

        private async void OnLoadModelConfigPressed()
        {
            if (_modelParamsConfig != null)
            {
                await _mindManager.InitializeAsync(_modelParamsConfig);
                _mindManager.ConfigList.LastGoodModelConfig = _modelParamsConfig;
                SaveConfigList();
            }
        }


        private void InitializeUiElements()
        {
            _configNameLineEdit.Text = _configName;

            // Initialize chat sliders and labels
            InitializeSliderAndLabel(_chatGpuLayerCountHSlider, _chatGpuLayerCountLabel, _chatGpuLayerCount);
            InitializeSliderAndLabel(_chatContextSizeHSlider, _chatContextSizeLabel, _chatContextSize, CalculateLogContextSize);

            _chatRandomSeedLineEdit.Text = _chatRandomSeed.ToString();

            // Initialize embedder sliders and labels
            InitializeSliderAndLabel(_embedderGpuLayerCountHSlider, _embedderGpuLayerCountLabel, _embedderGpuLayerCount);
            InitializeSliderAndLabel(_embedderContextSizeHSlider, _embedderContextSizeLabel, _embedderContextSize, CalculateLogContextSize);

            _embedderRandomSeedLineEdit.Text = _embedderRandomSeed.ToString();

            // Initialize autoload checkbox
            if (_mindManager.ConfigList != null)
            {
                _autoloadLastGoodConfigCheckBox.ButtonPressed = _mindManager.ConfigList.AutoloadLastGoodModelConfig;
            }

            InitializeConfigList();
        }

        private void InitializeSliderAndLabel(HSlider slider, Label label, int value)
        {
            slider.Value = value;
            label.Text = value.ToString();
        }

        private void InitializeSliderAndLabel(HSlider slider, Label label, uint value, Func<uint, double> conversionFunc)
        {
            slider.Value = conversionFunc(value);
            label.Text = value.ToString();
        }

        private void OnSavedConfigsItemSelected(long index)
        {
            _modelParamsConfig = _mindManager.ConfigList.ModelConfigurations[(int)index];
            LoadConfig(_modelParamsConfig);
        }

        private void OnDeleteConfigPressed()
        {
            var selectedIndices = _savedConfigsItemList.GetSelectedItems();

            if (selectedIndices.Length > 0 && _mindManager.ConfigList.ModelConfigurations.Count > 0)
            {
                int selectedIndex = selectedIndices[0];
                if (selectedIndex >= 0 && selectedIndex < _mindManager.ConfigList.ModelConfigurations.Count)
                {
                    _mindManager.ConfigList.ModelConfigurations.RemoveAt(selectedIndex);
                    SaveConfigList();
                    UpdateConfigItemList();
                }
            }
            else
            {
                GD.Print("No configuration selected or list is empty.");
            }
        }

        private void OnAddNewConfigPressed()
        {
            ModelParams newConfig = new()
            {
                ModelConfigName = _configName,
                ChatContextSize = _chatContextSize,
                ChatGpuLayerCount = _chatGpuLayerCount,
                ChatRandomSeed = _chatRandomSeed,
                ChatModelPath = _chatModelPath,
                EmbedderContextSize = _embedderContextSize,
                EmbedderGpuLayerCount = _embedderGpuLayerCount,
                EmbedderRandomSeed = _embedderRandomSeed,
                EmbedderModelPath = _embedderModelPath,
                ClipModelPath = _clipModelPath
            };

            _mindManager.ConfigList.ModelConfigurations.Add(newConfig);
            SaveConfigList();
            UpdateConfigItemList();
        }

        private void UpdateConfigurationValue(Action<ModelParams> updateAction)
        {
            var selectedIndices = _savedConfigsItemList.GetSelectedItems();
            if (selectedIndices.Length > 0)
            {
                int selectedIndex = selectedIndices[0];
                if (selectedIndex >= 0 && selectedIndex < _mindManager.ConfigList.ModelConfigurations.Count)
                {
                    var config = _mindManager.ConfigList.ModelConfigurations[selectedIndex];
                    updateAction(config);
                    SaveConfigList();
                }
            }
        }


        private void ClearPath(Action updatePathAction, Label pathLabel, Action<ModelParams, string> updateAction)
        {
            updatePathAction();
            pathLabel.Text = "";
            UpdateConfigurationValue(config => updateAction(config, ""));
        }

        private void OnClearEmbedderPathPressed() => ClearPath(() => _embedderModelPath = "", _embedderCurrentModelPathLabel, (config, path) => config.EmbedderModelPath = path);
        private void OnClearClipPathPressed() => ClearPath(() => _clipModelPath = "", _clipCurrentModelPathLabel, (config, path) => config.ClipModelPath = path);
        private void OnClearChatPathPressed() => ClearPath(() => _chatModelPath = "", _chatCurrentModelPathLabel, (config, path) => config.ChatModelPath = path);

        private void OnConfigNameTextChanged(string newText)
        {
            _configName = newText;
            UpdateConfigurationValue(config =>
            {
                config.ModelConfigName = _configName;
                _savedConfigsItemList.SetItemText(_savedConfigsItemList.GetSelectedItems()[0], _configName);
            });
        }

        private void OnChatGpuLayerCountHSliderValueChanged(double value) => UpdateSliderValue((int)value, _chatGpuLayerCountLabel, v => _chatGpuLayerCount = v, config => config.ChatGpuLayerCount = _chatGpuLayerCount);
        private void OnEmbedderGpuLayerCountHSliderValueChanged(double value) => UpdateSliderValue((int)value, _embedderGpuLayerCountLabel, v => _embedderGpuLayerCount = v, config => config.EmbedderGpuLayerCount = _embedderGpuLayerCount);
        private void OnChatContextSizeHSliderValueChanged(double value) => UpdateSliderValue(CalculateExpContextSize(value), _chatContextSizeLabel, v => _chatContextSize = v, config => config.ChatContextSize = _chatContextSize);
        private void OnEmbedderContextSizeHSliderValueChanged(double value) => UpdateSliderValue(CalculateExpContextSize(value), _embedderContextSizeLabel, v => _embedderContextSize = v, config => config.EmbedderContextSize = _embedderContextSize);

        private void UpdateSliderValue<T>(T value, Label label, Action<T> setValue, Action<ModelParams> updateConfig)
        {
            setValue(value);
            label.Text = value.ToString();
            UpdateConfigurationValue(updateConfig);
        }

        private void OnSelectChatPathPressed() => _selectChatPathFileDialog.PopupCentered();
        private void OnChatPathSelected(string path) => UpdatePath(() => _chatModelPath = path, _chatCurrentModelPathLabel, config => config.ChatModelPath = _chatModelPath);
        private void OnSelectClipPathPressed() => _selectClipPathFileDialog.PopupCentered();
        private void OnClipPathSelected(string path) => UpdatePath(() => _clipModelPath = path, _clipCurrentModelPathLabel, config => config.ClipModelPath = _clipModelPath);
        private void OnSelectEmbedderPathPressed() => _selectEmbedderPathFileDialog.PopupCentered();
        private void OnEmbedderPathSelected(string path) => UpdatePath(() => _embedderModelPath = path, _embedderCurrentModelPathLabel, config => config.EmbedderModelPath = _embedderModelPath);

        private void UpdatePath(Action updatePathAction, Label pathLabel, Action<ModelParams> updateConfig)
        {
            updatePathAction();
            pathLabel.Text = pathLabel.Text;
            UpdateConfigurationValue(updateConfig);
        }

        private static uint CalculateExpContextSize(double value) => (uint)Math.Pow(2, value) * 1000;
        private static double CalculateLogContextSize(uint value) => Math.Log2(value / 1000.0);

        public override void _ExitTree() { }
    }
}

using System.Globalization;
using System.Xml.Linq;
using CodonProteinFactory.Application;
using CodonProteinFactory.Persistence;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace CodonProteinFactory.Windows;

internal sealed partial class WorkspaceView
{
    private readonly Window window;
    private readonly WorkspaceStore store;
    private readonly QueueCoordinator queue;
    private readonly bool smoke;
    private UserSettings settings;
    private Strings strings;
    private readonly Grid root = new();
    private NavigationView navigation = null!;
    private StackPanel page = null!;
    private InfoBar feedback = null!;
    private Border pageFooter = null!;
    private Grid contentArea = null!;
    private TextBlock windowSubtitle = null!;
    private FrameworkElement? brand;
    private string section = "NewBatch";
    private bool closing;
    private bool allowClose;
    private bool dialogOpen;
    private bool refreshScheduled;
    private Exception? queueFault;

    public WorkspaceView(Window window, WorkspaceStore store, QueueCoordinator queue, UserSettings settings, bool smoke)
    {
        this.window = window;
        this.store = store;
        this.queue = queue;
        this.settings = smoke ? settings with { Language = "en" } : settings;
        this.smoke = smoke;
        strings = new Strings(this.settings.Language);
        root.Resources["NavigationViewDefaultPaneBackground"] = palette.Sidebar;
        root.Resources["NavigationViewExpandedPaneBackground"] = palette.Sidebar;
        root.Resources["NavigationViewContentBackground"] = palette.Canvas;
        root.Resources["NavigationViewSelectionIndicatorForeground"] = palette.Accent;
        root.Resources["NavigationViewItemBackgroundSelected"] = palette.AccentSurface;
        root.Resources["NavigationViewItemBackgroundSelectedPointerOver"] = palette.AccentSurface;
        root.Resources["NavigationViewItemForegroundSelected"] = palette.Text;
        root.Resources["AccentFillColorDefaultBrush"] = palette.Accent;
        root.Resources["AccentFillColorSecondaryBrush"] = palette.Accent;
        root.Resources["AccentFillColorTertiaryBrush"] = palette.Accent;
        root.Resources["TextOnAccentFillColorPrimaryBrush"] = palette.AccentText;
        root.Resources["TextControlBackground"] = palette.Inset;
        root.Resources["TextControlBackgroundPointerOver"] = palette.Inset;
        root.Resources["TextControlBackgroundFocused"] = palette.Surface;
        root.Resources["TextControlBorderBrush"] = palette.Border;
        root.Resources["TextControlBorderBrushFocused"] = palette.Accent;
        root.Resources["ComboBoxBackground"] = palette.Inset;
        root.Resources["ComboBoxBorderBrush"] = palette.Border;
        root.Background = palette.Canvas;
        root.ActualThemeChanged += (sender, _) => palette.Update(sender.ActualTheme);
        ResizeForDisplay();
        window.AppWindow.Closing += (sender, args) =>
        {
            if (allowClose) return;
            args.Cancel = true;
            if (!closing) _ = CloseAsync();
        };
        queue.Changed += OnQueueChanged;
        queue.Faulted += OnQueueFaulted;
        BuildShell();
    }

    public FrameworkElement View => root;

    private void ResizeForDisplay()
    {
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(window.AppWindow.Id,
            Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        window.AppWindow.Resize(new global::Windows.Graphics.SizeInt32(Math.Min(1240, area.Width), Math.Min(820, area.Height)));
    }

    private void BuildShell()
    {
        root.Children.Clear();
        ApplyTheme();
        navigation = new NavigationView
        {
            PaneDisplayMode = NavigationViewPaneDisplayMode.Left,
            OpenPaneLength = 192,
            Background = palette.Sidebar,
            IsSettingsVisible = false,
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            IsPaneToggleButtonVisible = true,
            AlwaysShowHeader = false,
            IsPaneOpen = true
        };
        AutomationProperties.SetName(navigation, L("Nav"));
        var brandImage = new Image
        {
            Width = 29, Height = 29, VerticalAlignment = VerticalAlignment.Center,
            Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "BrandIcon.png")))
        };
        var brandName = Text("Codon\nProteinFactory");
        brandName.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        brandName.IsTextSelectionEnabled = false;
        var identity = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(8, 2, 4, 10) };
        identity.Children.Add(brandImage);
        identity.Children.Add(brandName);
        brand = identity;
        navigation.PaneHeader = brand;
        foreach (var key in new[] { "NewBatch", "History", "Presets", "Settings" })
        {
            var icon = key switch { "NewBatch" => Symbol.Add, "History" => Symbol.Clock, "Presets" => Symbol.List, _ => Symbol.Setting };
            navigation.MenuItems.Add(new NavigationViewItem { Content = L(key), Tag = key, Icon = new SymbolIcon(icon), Foreground = palette.Text });
        }
        navigation.ItemInvoked += (_, args) =>
        {
            if (args.InvokedItemContainer?.Tag is string key && key != section) Show(key);
        };
        root.Children.Add(navigation);
        root.SizeChanged -= OnSizeChanged;
        root.SizeChanged += OnSizeChanged;
        ApplyPaneWidth(root.ActualWidth);
        Show(section);
    }

    private void ApplyTheme()
    {
        root.RequestedTheme = settings.Theme switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default };
        palette.Update(root.ActualTheme);
    }

    private void OnSizeChanged(object sender, SizeChangedEventArgs args) => ApplyPaneWidth(args.NewSize.Width);

    private void ApplyPaneWidth(double width)
    {
        bool compact = width > 0 && width < 840;
        if (brand is not null) brand.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        var mode = compact ? NavigationViewPaneDisplayMode.LeftCompact : NavigationViewPaneDisplayMode.Left;
        if (navigation.PaneDisplayMode == mode) return;
        navigation.PaneDisplayMode = mode;
        navigation.IsPaneOpen = !compact;
    }

    private void Show(string key)
    {
        section = key;
        string selected = key == "PreviewTitle" ? "NewBatch" : key;
        navigation.SelectedItem = navigation.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item => Equals(item.Tag, selected));
        var panel = new Grid { Background = palette.Canvas };
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition());
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var title = Text(L(key));
        title.FontSize = 30;
        title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        title.IsTextSelectionEnabled = false;
        AutomationProperties.SetHeadingLevel(title, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        windowSubtitle = QuietText(string.Empty);
        windowSubtitle.Visibility = Visibility.Collapsed;
        var header = Rows(title, windowSubtitle);
        header.Spacing = 4;
        header.Margin = new Thickness(PageInset, 20, PageInset, 15);
        panel.Children.Add(header);
        feedback = new InfoBar { IsClosable = true, Margin = new Thickness(PageInset, 0, PageInset, 10) };
        Grid.SetRow(feedback, 1);
        panel.Children.Add(feedback);
        page = new StackPanel { Spacing = GroupGap, Padding = new Thickness(PageInset, 2, PageInset, PageInset),
            MaxWidth = 1440, HorizontalAlignment = HorizontalAlignment.Stretch };
        var scroll = new ScrollViewer { Content = page, HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        contentArea = new Grid();
        contentArea.Children.Add(scroll);
        Grid.SetRow(contentArea, 2);
        panel.Children.Add(contentArea);
        pageFooter = new Border { Background = palette.Surface, BorderBrush = palette.Border, BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(PageInset, 10, PageInset, 10), Visibility = Visibility.Collapsed };
        Grid.SetRow(pageFooter, 3);
        panel.Children.Add(pageFooter);
        navigation.Content = panel;
        switch (key)
        {
            case "NewBatch": BuildNewBatch(); break;
            case "PreviewTitle": BuildPreview(); break;
            case "History": BuildHistory(); break;
            case "Presets": BuildPresets(); break;
            case "Settings": BuildSettings(); break;
        }
        if (queueFault is { } error) Report(error);
    }

    private void OnQueueChanged() => root.DispatcherQueue.TryEnqueue(() =>
    {
        if (closing || section != "History" || refreshScheduled) return;
        refreshScheduled = true;
        _ = RefreshAfterDelayAsync();
    });

    private async Task RefreshAfterDelayAsync()
    {
        await Task.Delay(140);
        refreshScheduled = false;
        if (!closing && section == "History") await RunAsync(() => RefreshHistoryAsync(reset: false));
    }

    private void OnQueueFaulted(Exception error) => root.DispatcherQueue.TryEnqueue(() =>
    {
        queueFault = error;
        if (!closing) Report(error);
    });

    private async Task CloseAsync()
    {
        closing = true;
        navigation.IsEnabled = false;
        try
        {
            await queue.ShutdownAsync();
            await Task.Run(store.Checkpoint);
        }
        catch (Exception error)
        {
            Report(error);
            await ConfirmAsync("Close", error.Message, "Close", allowDuringClose: true);
        }
        finally
        {
            queue.Changed -= OnQueueChanged;
            queue.Faulted -= OnQueueFaulted;
            allowClose = true;
            window.Close();
        }
    }

    private async Task RunAsync(Func<Task> action)
    {
        if (closing) return;
        try { await action(); }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!closing) Report(error); }
    }

    private void Report(Exception error) => Notify(ErrorText(error), InfoBarSeverity.Error);

    private void Notify(string message, InfoBarSeverity severity = InfoBarSeverity.Success)
    {
        feedback.Message = message;
        feedback.Severity = severity;
        feedback.IsOpen = true;
    }

    private string L(string key) => strings[key];
    private string F(string key, params object[] args) => string.Format(CultureInfo.CurrentCulture, L(key), args);
    private TextBlock Text(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Foreground = palette.Text };
    private TextBlock Heading(string key) => new() { Text = L(key), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, FontSize = 16,
        TextWrapping = TextWrapping.Wrap, Foreground = palette.Text };
    private static T Identify<T>(T item, string id) where T : DependencyObject { AutomationProperties.SetAutomationId(item, id); return item; }

    private Button ActionButton(string key, Func<Task> action, string? id = null, bool primary = false)
    {
        var button = Identify(new Button { Content = new TextBlock { Text = L(key), TextWrapping = TextWrapping.Wrap }, MinHeight = 34 }, id ?? key);
        AutomationProperties.SetName(button, L(key));
        if (primary)
        {
            if (Microsoft.UI.Xaml.Application.Current.Resources.TryGetValue("AccentButtonStyle", out var style)) button.Style = (Style)style;
            button.Background = palette.Accent;
            button.Foreground = palette.AccentText;
        }
        button.Click += async (_, _) =>
        {
            button.IsEnabled = false;
            try { await RunAsync(action); }
            finally { button.IsEnabled = !closing; }
        };
        return button;
    }

    private TextBox Field(string key, string value = "", bool multiline = false) => Identify(new TextBox
    {
        Header = L(key), Text = value, AcceptsReturn = multiline, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
        MinHeight = multiline ? 100 : 0, MaxHeight = multiline ? 240 : double.PositiveInfinity
    }, key);

    private ComboBox Choice(string key, IEnumerable<string> values, int selected = 0)
    {
        var item = Identify(new ComboBox { Header = L(key), HorizontalAlignment = HorizontalAlignment.Stretch }, key);
        foreach (string value in values) item.Items.Add(value);
        item.SelectedIndex = selected >= 0 && selected < item.Items.Count ? selected : (item.Items.Count > 0 ? 0 : -1);
        return item;
    }

    private static StackPanel Rows(params UIElement[] items)
    {
        var panel = new StackPanel { Spacing = 8 };
        foreach (var item in items) panel.Children.Add(item);
        return panel;
    }

    private static Grid Columns(params FrameworkElement[] items)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        for (int i = 0; i < items.Length; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition());
            Grid.SetColumn(items[i], i);
            grid.Children.Add(items[i]);
        }
        return grid;
    }

    private async Task<bool> ConfirmAsync(string key, string message, string primary = "Confirm", bool allowDuringClose = false)
    {
        if (dialogOpen || (closing && !allowDuringClose)) return false;
        dialogOpen = true;
        try
        {
            var dialog = new ContentDialog
            {
                Title = L(key), Content = new ScrollViewer { MaxHeight = 320, Content = Text(message) },
                PrimaryButtonText = L(primary), CloseButtonText = L("Cancel"),
                DefaultButton = ContentDialogButton.Close, XamlRoot = root.XamlRoot
            };
            return await dialog.ShowAsync() == ContentDialogResult.Primary;
        }
        finally { dialogOpen = false; }
    }

    private async Task<string?> PromptNameAsync(string title)
    {
        if (dialogOpen || closing) return null;
        dialogOpen = true;
        try
        {
            var name = Field("PresetName");
            var dialog = new ContentDialog { Title = L(title), XamlRoot = root.XamlRoot, Content = name, PrimaryButtonText = L("Confirm"),
                CloseButtonText = L("Cancel"), DefaultButton = ContentDialogButton.Primary };
            dialog.PrimaryButtonClick += (_, args) => args.Cancel = string.IsNullOrWhiteSpace(name.Text);
            return await dialog.ShowAsync() == ContentDialogResult.Primary ? name.Text : null;
        }
        finally { dialogOpen = false; }
    }

    private sealed class Strings(string language)
    {
        private static readonly Dictionary<string, string> English = Load("en");
        private readonly Dictionary<string, string> localized = language == "zh-Hans" ? Load(language) : English;
        public string this[string key] => localized.GetValueOrDefault(key) ?? English.GetValueOrDefault(key) ?? key;

        private static Dictionary<string, string> Load(string lang)
        {
            using var stream = typeof(Strings).Assembly.GetManifestResourceStream("Strings." + lang)!;
            return XDocument.Load(stream).Root!.Elements("data").ToDictionary(item => (string)item.Attribute("name")!, item => item.Element("value")!.Value);
        }
    }
}

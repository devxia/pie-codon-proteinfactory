using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace CodonProteinFactory.Windows;

internal sealed class WorkspacePalette
{
    public SolidColorBrush Canvas { get; } = new();
    public SolidColorBrush Sidebar { get; } = new();
    public SolidColorBrush Surface { get; } = new();
    public SolidColorBrush Inset { get; } = new();
    public SolidColorBrush Border { get; } = new();
    public SolidColorBrush Text { get; } = new();
    public SolidColorBrush Muted { get; } = new();
    public SolidColorBrush Accent { get; } = new();
    public SolidColorBrush AccentText { get; } = new();
    public SolidColorBrush AccentSurface { get; } = new();
    public SolidColorBrush Attention { get; } = new();

    public void Update(ElementTheme theme)
    {
        bool dark = theme == ElementTheme.Dark;
        if (new AccessibilitySettings().HighContrast)
        {
            var system = new UISettings();
            Canvas.Color = Sidebar.Color = Surface.Color = Inset.Color = system.UIElementColor(UIElementType.Window);
            Border.Color = Text.Color = Muted.Color = Attention.Color = system.UIElementColor(UIElementType.WindowText);
            Accent.Color = AccentSurface.Color = system.UIElementColor(UIElementType.Highlight);
            AccentText.Color = system.UIElementColor(UIElementType.HighlightText);
            return;
        }
        Canvas.Color = ColorFrom(dark ? 0x171D1A : 0xF4F5F0);
        Sidebar.Color = ColorFrom(dark ? 0x1C2521 : 0xE9EDE6);
        Surface.Color = ColorFrom(dark ? 0x222B26 : 0xFFFEFA);
        Inset.Color = ColorFrom(dark ? 0x1B231F : 0xF3F5EF);
        Border.Color = ColorFrom(dark ? 0x3C4941 : 0xD8E1D8);
        Text.Color = ColorFrom(dark ? 0xE9F1EB : 0x182B23);
        Muted.Color = ColorFrom(dark ? 0xAABCB1 : 0x52645A);
        Accent.Color = ColorFrom(dark ? 0x83D3BE : 0x126356);
        AccentText.Color = ColorFrom(dark ? 0x112A23 : 0xFFFFFF);
        AccentSurface.Color = ColorFrom(dark ? 0x2D463B : 0xE0F0E8);
        Attention.Color = ColorFrom(dark ? 0xFFB4A7 : 0x963729);
    }

    private static Color ColorFrom(int rgb) => Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
}

internal sealed class ActionGroup : Panel
{
    private const double Gap = 8;
    protected override Size MeasureOverride(Size availableSize) => Layout(availableSize.Width, arrange: false);
    protected override Size ArrangeOverride(Size finalSize)
    {
        Layout(finalSize.Width, arrange: true);
        return finalSize;
    }

    private Size Layout(double availableWidth, bool arrange)
    {
        double x = 0;
        double y = 0;
        double rowHeight = 0;
        double width = 0;
        foreach (var child in Children)
        {
            if (child.Visibility == Visibility.Collapsed) continue;
            if (!arrange) child.Measure(new Size(availableWidth, double.PositiveInfinity));
            var size = child.DesiredSize;
            if (x > 0 && x + Gap + size.Width > availableWidth)
            {
                x = 0;
                y += rowHeight + Gap;
                rowHeight = 0;
            }
            if (x > 0) x += Gap;
            if (arrange) child.Arrange(new Rect(x, y, size.Width, size.Height));
            x += size.Width;
            rowHeight = Math.Max(rowHeight, size.Height);
            width = Math.Max(width, x);
        }
        return new Size(width, y + rowHeight);
    }
}

internal sealed partial class WorkspaceView
{
    private const double PageInset = 24;
    private const double GroupGap = 16;
    private const double SectionInset = 17;
    private readonly WorkspacePalette palette = new();

    private TextBlock QuietText(string value)
    {
        var text = Text(value);
        text.Foreground = palette.Muted;
        return text;
    }

    private static StackPanel SectionRows(params UIElement[] items)
    {
        var stack = new StackPanel { Spacing = 12 };
        foreach (var item in items) stack.Children.Add(item);
        return stack;
    }

    private FrameworkElement Section(string title, Symbol icon, params UIElement[] items)
    {
        var emblem = new SymbolIcon(icon) { Foreground = palette.Accent, Width = 18, Height = 18 };
        AutomationProperties.SetAccessibilityView(emblem, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var marker = new Border { Child = emblem, Background = palette.AccentSurface, CornerRadius = new CornerRadius(7), Padding = new Thickness(6) };
        var heading = Heading(title);
        heading.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetHeadingLevel(heading, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 9 };
        header.Children.Add(marker);
        header.Children.Add(heading);
        return PanelSurface(SectionRows(new UIElement[] { header }.Concat(items).ToArray()));
    }

    private Border PanelSurface(FrameworkElement content) => new()
    {
        Child = content, Background = palette.Surface, BorderBrush = palette.Border, BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(12), Padding = new Thickness(SectionInset), VerticalAlignment = VerticalAlignment.Top
    };

    private Grid InlineChoice(string key, ComboBox choice, double labelWidth)
    {
        choice.Header = null;
        AutomationProperties.SetName(choice, L(key));
        void ShowSelectedValue() => ToolTipService.SetToolTip(choice, choice.SelectedItem as string);
        choice.SelectionChanged += (_, _) => ShowSelectedValue();
        ShowSelectedValue();
        var label = Text(L(key));
        label.IsTextSelectionEnabled = false;
        label.VerticalAlignment = VerticalAlignment.Center;
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(labelWidth) });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.Children.Add(label);
        Grid.SetColumn(choice, 1);
        row.Children.Add(choice);
        return row;
    }

    private static ActionGroup Actions(params UIElement[] items)
    {
        var group = new ActionGroup();
        foreach (var item in items) group.Children.Add(item);
        return group;
    }

    private static Grid AdaptiveColumns(FrameworkElement first, FrameworkElement second, double breakpoint,
        double sidebarWidth)
    {
        var grid = new Grid();
        var column = new ColumnDefinition();
        var otherColumn = new ColumnDefinition { Width = new GridLength(0) };
        var nextRow = new RowDefinition { Height = GridLength.Auto };
        grid.ColumnDefinitions.Add(column);
        grid.ColumnDefinitions.Add(otherColumn);
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(nextRow);
        grid.RowSpacing = GroupGap;
        grid.Children.Add(first);
        grid.Children.Add(second);
        Grid.SetRow(second, 1);
        grid.SizeChanged += (_, args) =>
        {
            bool split = args.NewSize.Width >= breakpoint;
            otherColumn.Width = new GridLength(split ? sidebarWidth : 0);
            nextRow.Height = split ? new GridLength(0) : GridLength.Auto;
            grid.ColumnSpacing = split ? GroupGap : 0;
            grid.RowSpacing = split ? 0 : GroupGap;
            Grid.SetColumn(second, split ? 1 : 0);
            Grid.SetRow(second, split ? 0 : 1);
        };
        return grid;
    }

    private void SetActionBar(params UIElement[] items)
    {
        var layout = new Grid { ColumnSpacing = 16 };
        layout.ColumnDefinitions.Add(new ColumnDefinition());
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var hint = QuietText(L("LocalUntilConfirmed"));
        hint.VerticalAlignment = VerticalAlignment.Center;
        hint.Visibility = Visibility.Collapsed;
        layout.Children.Add(hint);
        var actions = Actions(items);
        actions.MaxWidth = 490;
        actions.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(actions, 1);
        layout.Children.Add(actions);
        var footer = pageFooter;
        footer.SizeChanged += (_, args) =>
        {
            actions.MaxWidth = Math.Max(1, Math.Min(490, args.NewSize.Width - 2 * PageInset - layout.ColumnSpacing));
            hint.Visibility = args.NewSize.Width >= 760 ? Visibility.Visible : Visibility.Collapsed;
        };
        footer.Child = layout;
        footer.Visibility = Visibility.Visible;
    }

    private void SetHistoryPanes(FrameworkElement browse, FrameworkElement detail)
    {
        var host = contentArea;
        host.Children.Clear();
        var (browserScroll, detailScroll) = (BodyScroll(), BodyScroll());
        var wide = new Grid { ColumnSpacing = GroupGap, Margin = new Thickness(PageInset, 2, PageInset, 0) };
        wide.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(294) });
        wide.ColumnDefinitions.Add(new ColumnDefinition());
        wide.Children.Add(browserScroll);
        Grid.SetColumn(detailScroll, 1);
        wide.Children.Add(detailScroll);
        var stacked = new StackPanel { Spacing = GroupGap, Padding = new Thickness(PageInset, 2, PageInset, PageInset) };
        var narrow = BodyScroll();
        narrow.Content = stacked;
        bool? split = null;
        void Arrange(double width)
        {
            bool useColumns = width >= 768;
            if (useColumns == split) return;
            split = useColumns;
            host.Children.Clear();
            if (useColumns)
            {
                stacked.Children.Clear();
                browserScroll.Content = browse;
                detailScroll.Content = detail;
                host.Children.Add(wide);
            }
            else
            {
                browserScroll.Content = null;
                detailScroll.Content = null;
                stacked.Children.Add(browse);
                stacked.Children.Add(detail);
                host.Children.Add(narrow);
            }
        }
        host.SizeChanged += (_, args) => Arrange(args.NewSize.Width);
        Arrange(host.ActualWidth);
    }

    private static ScrollViewer BodyScroll() => new()
    {
        HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        Padding = new Thickness(0, 0, 0, PageInset)
    };
}

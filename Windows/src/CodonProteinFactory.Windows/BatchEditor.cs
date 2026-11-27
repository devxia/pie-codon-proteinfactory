using CodonProteinFactory.Application;
using CodonProteinFactory.Domain;
using CodonProteinFactory.Persistence;
using CodonProteinFactory.SequenceIO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace CodonProteinFactory.Windows;

internal sealed partial class WorkspaceView
{
    private string draftName = string.Empty;
    private string pastedText = string.Empty;
    private string pastedName = string.Empty;
    private string customMotifs = string.Empty;
    private Species species;
    private StartCodonPolicy startPolicy;
    private StopPolicy stopPolicy = StopPolicy.Add;
    private readonly HashSet<RestrictionEnzyme> enzymes = [];
    private enum InputMode { Paste, Fasta, Spreadsheet }
    private InputMode inputMode;
    private string? importedFile;
    private IReadOnlyList<Sheet>? workbook;
    private IReadOnlyList<ImportRow>? fasta;
    private ColumnMapping mapping = new(0, true, 0, 1);
    private Batch? preview;
    private ImportPreview? validation;
    private int importGeneration;
    private StackPanel importPanel = null!;
    private TextBlock inputSummary = null!;
    private TextBlock inputIssue = null!;
    private StackPanel inputExamples = null!;
    private bool previewBusy;

    private void BuildNewBatch()
    {
        var name = Field("BatchName", draftName);
        name.MaxLength = DomainLimits.MaxBatchNameLength;
        name.TextChanged += (_, _) => draftName = name.Text;
        inputSummary = QuietText(L("InputEmpty"));
        inputIssue = Text(string.Empty);
        inputIssue.Foreground = palette.Attention;
        inputIssue.Visibility = Visibility.Collapsed;
        AutomationProperties.SetLiveSetting(inputIssue, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        inputExamples = Rows();
        var modes = new SelectorBar();
        AutomationProperties.SetName(modes, L("InputMode"));
        foreach (string key in new[] { "PasteMode", "FastaMode", "TableMode" })
            modes.Items.Add(new SelectorBarItem { Text = L(key) });
        modes.SelectedItem = modes.Items[(int)inputMode];
        modes.SelectionChanged += (_, _) =>
        {
            int selected = modes.Items.IndexOf(modes.SelectedItem);
            if (selected < 0 || selected == (int)inputMode) return;
            inputMode = (InputMode)selected;
            importGeneration++;
            importedFile = null;
            workbook = null;
            fasta = null;
            BuildImportPanel();
        };
        importPanel = new StackPanel { Spacing = 10 };
        var input = Section("SequenceInput", Symbol.Edit, name, modes, importPanel);
        input.AllowDrop = true;
        input.DragOver += (_, args) =>
        {
            if (args.DataView.Contains(StandardDataFormats.StorageItems)) args.AcceptedOperation = DataPackageOperation.Copy;
        };
        input.Drop += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                await RunAsync(async () =>
                {
                    if (args.DataView.Contains(StandardDataFormats.StorageItems) && (await args.DataView.GetStorageItemsAsync()).FirstOrDefault() is StorageFile file)
                        await ImportFileAsync(file.Path);
                });
            }
            finally { deferral.Complete(); }
        };
        BuildImportPanel();
        var left = new StackPanel { Spacing = GroupGap };
        left.Children.Add(input);
        left.Children.Add(Section("Validation", Symbol.Accept, inputSummary, inputExamples));
        windowSubtitle.Text = L("EditorSubtitle");
        windowSubtitle.Visibility = Visibility.Visible;
        page.Children.Add(AdaptiveColumns(left, BuildParameterSection(), 692, 310));
        SetActionBar(ActionButton("Reset", ResetDraftAsync), ActionButton("Preview", PreparePreviewAsync, primary: true));
        UpdateInputSummary();
    }

    private FrameworkElement BuildParameterSection()
    {
        var hosts = Enum.GetValues<Species>();
        var host = Choice("Host", hosts.Select(value => value.DisplayName()), Array.IndexOf(hosts, species));
        host.SelectionChanged += (_, _) => { if (host.SelectedIndex >= 0) species = hosts[host.SelectedIndex]; };
        var starts = Enum.GetValues<StartCodonPolicy>();
        var start = Choice("Start", starts.Select(value => L(value.ToString())), Array.IndexOf(starts, startPolicy));
        start.SelectionChanged += (_, _) => { if (start.SelectedIndex >= 0) startPolicy = starts[start.SelectedIndex]; };
        var stops = Enum.GetValues<StopPolicy>();
        var stop = Choice("StopPolicy", stops.Select(value => L(value.ToString())), Array.IndexOf(stops, stopPolicy));
        stop.SelectionChanged += (_, _) => { if (stop.SelectedIndex >= 0) stopPolicy = stops[stop.SelectedIndex]; UpdateInputSummary(); };
        var motif = Field("Motifs", customMotifs);
        motif.MaxLength = AvoidMotifs.MaximumCustomLength;
        motif.PlaceholderText = "GAATTC, GGT(A/T)ACC";
        motif.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
        var final = QuietText(string.Empty);
        void UpdateFinalMotifs()
        {
            try
            {
                var selected = Parameters().Avoid.Motifs;
                final.Text = selected.Count == 0 ? L("NoMotifs") : string.Join(", ", selected);
                final.Foreground = palette.Muted;
            }
            catch (DomainException error)
            {
                final.Text = ErrorText(error);
                final.Foreground = palette.Attention;
            }
        }
        motif.TextChanged += (_, _) => { customMotifs = motif.Text; UpdateFinalMotifs(); };
        var choices = Enum.GetValues<RestrictionEnzyme>().Select(value =>
        {
            var item = new CheckBox { Content = value.ToString(), IsChecked = enzymes.Contains(value), MinWidth = 0, MinHeight = 28 };
            ToolTipService.SetToolTip(item, value.Motif());
            item.Checked += (_, _) => { enzymes.Add(value); UpdateFinalMotifs(); };
            item.Unchecked += (_, _) => { enzymes.Remove(value); UpdateFinalMotifs(); };
            return item;
        }).ToArray();
        var enzymeBox = new StackPanel { Spacing = 2 };
        foreach (var row in choices.Chunk(2)) enzymeBox.Children.Add(Columns(row));
        UpdateFinalMotifs();
        const double labelWidth = 87;
        var policies = Rows(InlineChoice("Host", host, labelWidth), InlineChoice("Start", start, labelWidth), InlineChoice("StopPolicy", stop, labelWidth));
        return Section("Parameters", Symbol.Filter, policies, Rows(Heading("Enzymes"), enzymeBox), motif,
            Rows(QuietText(L("FinalMotifs")), final), ActionButton("SaveParameterPreset", SaveParameterPresetAsync));
    }

    private void BuildImportPanel()
    {
        importPanel.Children.Clear();
        if (inputMode == InputMode.Paste)
        {
            var gene = Field("Gene", pastedName);
            gene.MaxLength = DomainLimits.MaxRecordNameLength;
            gene.TextChanged += (_, _) => { pastedName = gene.Text; UpdateInputSummary(); };
            var paste = Field("Paste", pastedText, multiline: true);
            paste.MinHeight = 148;
            paste.Header = null;
            AutomationProperties.SetName(paste, L("Paste"));
            paste.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
            paste.PlaceholderText = L("PasteHint");
            paste.TextChanged += (_, _) => { pastedText = paste.Text; UpdateInputSummary(); };
            importPanel.Children.Add(paste);
            importPanel.Children.Add(gene);
        }
        else
        {
            importPanel.Children.Add(Actions(ActionButton("ImportFile", PickImportAsync)));
            importPanel.Children.Add(QuietText(importedFile is null ? L("Drop") : Path.GetFileName(importedFile)));
            if (workbook is not null) BuildMapping();
        }
        importPanel.Children.Add(inputIssue);
        UpdateInputSummary();
    }

    private void BuildMapping()
    {
        var sheets = workbook!;
        var worksheet = Choice("Worksheet", sheets.Select((sheet, index) => sheet.Name ?? (index + 1).ToString()), mapping.WorksheetIndex);
        var header = new CheckBox { Content = L("Header"), IsChecked = mapping.FirstRowIsHeader };
        var columns = new StackPanel { Spacing = 8 };
        void BuildColumns()
        {
            if (worksheet.SelectedIndex < 0) return;
            var sheet = sheets[worksheet.SelectedIndex];
            string[] labels = Enumerable.Range(0, sheet.ColumnCount).Select(index =>
            {
                string label = sheet.Rows.FirstOrDefault()?.ElementAtOrDefault(index) ?? string.Empty;
                if (label.Length > 48) label = label[..48] + "…";
                return header.IsChecked == true && label.Length > 0 ? $"{index + 1} · {label}" : (index + 1).ToString();
            }).ToArray();
            var name = Choice("NameColumn", labels, mapping.NameColumn);
            var sequence = Choice("SequenceColumn", labels, mapping.SequenceColumn);
            void Update()
            {
                mapping = new ColumnMapping(worksheet.SelectedIndex, header.IsChecked == true, name.SelectedIndex, sequence.SelectedIndex);
                UpdateInputSummary();
            }
            name.SelectionChanged += (_, _) => Update();
            sequence.SelectionChanged += (_, _) => Update();
            columns.Children.Clear();
            if (sheet.ContainsFormulas) columns.Children.Add(Text(L("Formulas")));
            columns.Children.Add(Columns(name, sequence));
            Update();
        }
        worksheet.SelectionChanged += (_, _) => BuildColumns();
        header.Checked += (_, _) => BuildColumns();
        header.Unchecked += (_, _) => BuildColumns();
        importPanel.Children.Add(worksheet);
        importPanel.Children.Add(header);
        importPanel.Children.Add(columns);
        importPanel.Children.Add(ActionButton("SaveImportPreset", SaveImportPresetAsync));
        BuildColumns();
    }

    private async Task ResetDraftAsync()
    {
        if (!await ConfirmAsync("Reset", L("ResetConfirm")) || closing) return;
        importGeneration++;
        summaryGeneration++;
        draftName = pastedText = pastedName = customMotifs = string.Empty;
        species = Species.DefaultD2P;
        startPolicy = StartCodonPolicy.None;
        stopPolicy = StopPolicy.Add;
        enzymes.Clear();
        inputMode = InputMode.Paste;
        importedFile = null;
        fasta = null;
        workbook = null;
        mapping = new ColumnMapping(0, true, 0, 1);
        preview = null;
        validation = null;
        Show("NewBatch");
    }

    private async Task PickImportAsync()
    {
        if (smoke && Environment.GetEnvironmentVariable("CODON_FACTORY_UI_IMPORT") is { } fixture)
        {
            await ImportFileAsync(fixture);
            return;
        }
        var picker = new FileOpenPicker();
        string[] extensions = inputMode == InputMode.Fasta ? [".fa", ".faa", ".fas", ".fasta", ".txt"] : [".csv", ".tsv", ".xlsx"];
        foreach (var extension in extensions) picker.FileTypeFilter.Add(extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
        if (await picker.PickSingleFileAsync() is { } file) await ImportFileAsync(file.Path);
    }

    private async Task ImportFileAsync(string path)
    {
        int generation = ++importGeneration;
        var format = SequenceImport.DetectFormat(path);
        byte[] bytes = await SequenceImport.ReadFileAsync(path);
        var result = await Task.Run(() => format == ImportFormat.Fasta
            ? (SequenceImport.ReadFasta(bytes, Path.GetFileNameWithoutExtension(path)), (IReadOnlyList<Sheet>?)null)
            : ((IReadOnlyList<ImportRow>?)null, SequenceImport.ReadSpreadsheet(bytes, format)));
        if (closing || generation != importGeneration || section != "NewBatch") return;
        importedFile = path;
        inputMode = format == ImportFormat.Fasta ? InputMode.Fasta : InputMode.Spreadsheet;
        fasta = result.Item1;
        workbook = result.Item2;
        if (workbook is not null) mapping = new ColumnMapping(0, true, 0, 1);
        if (draftName.Length == 0) draftName = Path.GetFileNameWithoutExtension(path);
        Show("NewBatch");
    }

    private OptimizationParameters Parameters() => new()
    {
        Species = species, StartPolicy = startPolicy, StopPolicy = stopPolicy,
        Avoid = AvoidMotifs.Parse(customMotifs, Enum.GetValues<RestrictionEnzyme>().Where(enzymes.Contains))
    };

    private void UpdateInputSummary()
    {
        if (inputSummary is null) return;
        int revision = ++summaryGeneration;
        if (importedFile is null && (inputMode != InputMode.Paste || string.IsNullOrWhiteSpace(pastedText)))
        {
            inputSummary.Text = L("InputEmpty");
            inputSummary.Foreground = palette.Muted;
            inputIssue.Visibility = Visibility.Collapsed;
            inputExamples.Children.Clear();
            return;
        }
        // Revalidate off the UI thread and discard obsolete results while typing or remapping.
        string text = pastedText;
        string name = pastedName;
        var book = workbook;
        var file = fasta;
        var selection = mapping;
        var policy = stopPolicy;
        _ = SummarizeAsync(revision, text, name, book, file, selection, policy);
    }

    private int summaryGeneration;

    private async Task SummarizeAsync(int revision, string text, string name, IReadOnlyList<Sheet>? book,
        IReadOnlyList<ImportRow>? file, ColumnMapping selection, StopPolicy policy)
    {
        string message;
        IReadOnlyList<RowValidation> examples = [];
        bool failed = false;
        try
        {
            await Task.Delay(180);
            if (revision != summaryGeneration || section != "NewBatch" || closing) return;
            var result = await Task.Run(() => SequenceImport.Validate(book is not null ? SequenceImport.MapColumns(book, selection)
                : file ?? SequenceImport.ReadFasta(text, name), policy));
            int valid = result.Rows.Count(row => row.Issues.Count == 0);
            message = F("Validated", valid, result.Rows.Count - valid);
            examples = result.Rows.OrderByDescending(row => row.Issues.Count > 0).Take(3).ToArray();
        }
        catch (Exception error) { message = ErrorText(error); failed = true; }
        if (revision != summaryGeneration || section != "NewBatch" || closing) return;
        inputSummary.Text = message;
        inputSummary.Foreground = failed ? palette.Attention : palette.Muted;
        var invalid = examples.FirstOrDefault(row => row.Issues.Count > 0);
        string? firstIssue = failed ? message : null;
        if (invalid is not null) firstIssue = F("SourceLine", invalid.Input.SourceRow) + " · " + invalid.Issues[0];
        inputIssue.Text = firstIssue ?? string.Empty;
        inputIssue.Visibility = firstIssue is null ? Visibility.Collapsed : Visibility.Visible;
        inputExamples.Children.Clear();
        foreach (var row in examples) inputExamples.Children.Add(ValidationRow(row));
    }

    private async Task PreparePreviewAsync()
    {
        if (inputMode != InputMode.Paste && importedFile is null)
            throw new DomainException(DomainErrorCode.EmptySequence, L("InputEmpty"));
        string name = draftName;
        string text = pastedText;
        string label = pastedName;
        var file = fasta;
        var book = workbook;
        var selection = mapping;
        var parameters = Parameters();
        var result = await Task.Run(() => SequenceImport.Validate(book is not null ? SequenceImport.MapColumns(book, selection)
            : file ?? SequenceImport.ReadFasta(text, label), parameters.StopPolicy));
        if (closing || section != "NewBatch") return;
        validation = result;
        preview = null;
        if (result.ValidRecords.Count != 0)
            preview = await Task.Run(() => BatchPreparation.Prepare(name, result.ValidRecords, parameters));
        if (!closing && section == "NewBatch") Show("PreviewTitle");
    }

    private void BuildPreview()
    {
        var batch = preview;
        var result = validation!;
        int valid = result.Rows.Count(row => row.Issues.Count == 0);
        var stats = QuietText(F("Validated", valid, result.Rows.Count - valid));
        var back = ActionButton("Back", () => { if (!previewBusy) Show("NewBatch"); return Task.CompletedTask; });
        var records = Section("Records", Symbol.List, stats, PreviewRows(result.Rows));
        if (batch is null)
        {
            page.Children.Add(records);
            page.Children.Add(Text(L("NoValid")));
            SetActionBar(back);
            return;
        }
        windowSubtitle.Text = batch.Name;
        windowSubtitle.Visibility = Visibility.Visible;
        var figures = Columns(Figure("Records", batch.Records.Count), Figure("OriginalLength", batch.OriginalSequenceLength),
            Figure("SubmittedLength", batch.SubmittedSequenceLength));
        page.Children.Add(figures);
        var parameters = SectionRows(ParameterValue("Host", batch.Parameters.Species.DisplayName()),
            ParameterValue("Start", L(batch.Parameters.StartPolicy.ToString())),
            ParameterValue("StopPolicy", L(batch.Parameters.StopPolicy.ToString())),
            ParameterValue("Motifs", batch.Parameters.Avoid.WireValue.Length == 0 ? L("NoMotifs") : batch.Parameters.Avoid.WireValue),
            ParameterValue("Endpoint", batch.Endpoint.OriginalString));
        page.Children.Add(PanelSurface(new Expander { Header = L("PreviewDetails"), Content = parameters,
            HorizontalAlignment = HorizontalAlignment.Stretch }));
        page.Children.Add(records);
        SetActionBar(back, ActionButton("SaveDraft", () => CommitPreviewAsync(batch, false)),
            ActionButton("Send", () => CommitPreviewAsync(batch, true), primary: true));
    }

    private Border Figure(string key, int count)
    {
        var value = Text(count.ToString("N0"));
        value.FontSize = 26;
        value.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        return PanelSurface(Rows(value, QuietText(L(key))));
    }

    private StackPanel ParameterValue(string key, string value) => Rows(QuietText(L(key)), Text(value));

    private ListView PreviewRows(IReadOnlyList<RowValidation> rows)
    {
        var list = Identify(new ListView { MaxHeight = 440, SelectionMode = ListViewSelectionMode.Single }, "ValidationRows");
        foreach (var row in rows) list.Items.Add(ValidationRow(row, showBothSequences: true));
        return list;
    }

    private FrameworkElement ValidationRow(RowValidation row, bool showBothSequences = false)
    {
        bool valid = row.Issues.Count == 0;
        var name = Text(row.Input.Name is { Length: > 0 } value ? value : F("SourceLine", row.Input.SourceRow));
        name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        var status = QuietText(L(valid ? "Valid" : "Invalid") + " · " + F("SourceLine", row.Input.SourceRow));
        status.Foreground = valid ? palette.Accent : palette.Attention;
        var detail = QuietText(valid ? Abbreviate(row.Submitted!.Value) : string.Join(" / ", row.Issues));
        if (valid) detail.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas");
        FrameworkElement content;
        if (valid && showBothSequences)
        {
            var original = QuietText(Abbreviate(row.Original!.Value));
            original.FontFamily = detail.FontFamily;
            content = Rows(name, status, Columns(Rows(QuietText(L("Original")), original), Rows(QuietText(L("Submitted")), detail)));
        }
        else
        {
            var lines = Rows(name, status, detail);
            lines.Spacing = 2;
            content = lines;
        }
        return new Border { Child = content, BorderBrush = palette.Border, BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(0, 8, 0, 2), Margin = new Thickness(0, 2, 0, 1) };
    }

    private static string Abbreviate(string value) => value.Length > 72 ? value[..72] + "…" : value;

    private async Task CommitPreviewAsync(Batch draft, bool send)
    {
        if (previewBusy) return;
        previewBusy = true;
        navigation.IsPaneToggleButtonVisible = false;
        foreach (var item in navigation.MenuItems.OfType<NavigationViewItem>()) item.IsEnabled = false;
        try
        {
            if (send && !await ConfirmAsync("Send", L("SendConfirm"))) return;
            if (closing) return;
            if (send) await queue.SubmitAsync(draft); else await queue.SaveDraftAsync(draft);
            selectedBatchId = draft.Id;
            Show("History");
            Notify(L(send ? "Queued" : "Saved"));
        }
        finally
        {
            previewBusy = false;
            navigation.IsPaneToggleButtonVisible = true;
            foreach (var item in navigation.MenuItems.OfType<NavigationViewItem>()) item.IsEnabled = true;
        }
    }

    private async Task SaveImportPresetAsync()
    {
        if (workbook is null) return;
        SequenceImport.MapColumns(workbook, mapping);
        if (await PromptNameAsync("SaveImportPreset") is { } name)
        {
            var preset = new ImportPreset(Guid.NewGuid(), name, mapping);
            await Task.Run(() => store.Save(preset));
            Notify(L("Saved"));
        }
    }

    private async Task SaveParameterPresetAsync()
    {
        var parameters = Parameters();
        if (await PromptNameAsync("SaveParameterPreset") is { } name)
        {
            var preset = new ParameterPreset(Guid.NewGuid(), name, parameters);
            await Task.Run(() => store.Save(preset));
            Notify(L("Saved"));
        }
    }
}

using System.Globalization;
using System.Text;
using CodonProteinFactory.Application;
using CodonProteinFactory.Domain;
using CodonProteinFactory.Persistence;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;

namespace CodonProteinFactory.Windows;

internal sealed partial class WorkspaceView
{
    private Guid? selectedBatchId;
    private Guid? selectedRecordId;
    private ListView historyList = null!;
    private Button moreHistory = null!;
    private StackPanel batchDetails = null!;
    private HistoryQuery historyFilter = new();
    private int historyLimit = 25;
    private int historyGeneration;
    private int detailGeneration;
    private long displayedRevision = -1;
    private Guid? displayedBatchId;
    private bool historySelecting;
    private readonly List<BatchHistoryRow> historyRows = [];
    private DateTimeOffset? historyFrom;
    private DateTimeOffset? historyUntil;

    private void BuildHistory()
    {
        var query = Field("Search", historyFilter.Search);
        var statuses = Enum.GetValues<BatchStatus>();
        var status = Choice("Status", new[] { L("All") }.Concat(statuses.Select(x => L(x.ToString()))),
            historyFilter.Status is { } selected ? Array.IndexOf(statuses, selected) + 1 : 0);
        var sorts = Enum.GetValues<HistorySort>();
        var sort = Choice("Sort", sorts.Select(x => L(x.ToString())), Array.IndexOf(sorts, historyFilter.Sort));
        var from = Identify(new CalendarDatePicker { Header = L("From"), Date = historyFrom, HorizontalAlignment = HorizontalAlignment.Stretch }, "From");
        var until = Identify(new CalendarDatePicker { Header = L("Until"), Date = historyUntil, HorizontalAlignment = HorizontalAlignment.Stretch }, "Until");
        async Task FilterAsync()
        {
            historyFrom = from.Date;
            historyUntil = until.Date;
            DateTimeOffset? before = until.Date?.AddDays(1);
            historyFilter = new HistoryQuery(query.Text, status.SelectedIndex <= 0 ? null : statuses[status.SelectedIndex - 1],
                from.Date, before, sorts[Math.Max(0, sort.SelectedIndex)], Limit: historyLimit);
            await RefreshHistoryAsync(reset: true);
        }
        query.KeyDown += async (_, args) =>
        {
            if (args.Key == global::Windows.System.VirtualKey.Enter) { args.Handled = true; await RunAsync(FilterAsync); }
        };
        var filters = Rows(sort, from, until);
        var advanced = new Expander { Header = L("Filters"), Content = filters, HorizontalAlignment = HorizontalAlignment.Stretch };
        historyList = Identify(new ListView { MaxHeight = 430, SelectionMode = ListViewSelectionMode.Single }, "HistoryList");
        AutomationProperties.SetName(historyList, L("History"));
        historyList.SelectionChanged += async (_, _) =>
        {
            if (historySelecting || historyList.SelectedItem is not ListViewItem { Tag: Guid id }) return;
            if (selectedBatchId != id) selectedRecordId = null;
            selectedBatchId = id;
            await RunAsync(() => LoadDetailAsync(id, force: true));
        };
        moreHistory = ActionButton("More", async () =>
        {
            historyLimit += 25;
            await RefreshHistoryAsync(reset: false);
        });
        moreHistory.Visibility = Visibility.Collapsed;
        var searchTools = Rows(query, InlineChoice("Status", status, 58), advanced,
            Actions(ActionButton("Filter", FilterAsync), ActionButton("Refresh", () => RefreshHistoryAsync(reset: false))));
        var browse = Section("Batches", Symbol.List, searchTools, historyList, moreHistory);
        batchDetails = new StackPanel { Spacing = 13 };
        var detail = Section("BatchDetails", Symbol.Document, batchDetails);
        SetHistoryPanes(browse, detail);
        historyRows.Clear();
        displayedRevision = -1;
        displayedBatchId = null;
        _ = RunAsync(() => RefreshHistoryAsync(reset: false));
    }

    private async Task RefreshHistoryAsync(bool reset)
    {
        if (section != "History" || closing) return;
        int generation = ++historyGeneration;
        var filter = historyFilter;
        if (reset) historyLimit = 25;
        int limit = historyLimit;
        int requested = limit + 1;
        var result = await Task.Run(() =>
        {
            var rows = new List<BatchHistoryRow>();
            for (int offset = 0; offset < requested; offset += 200)
            {
                int size = Math.Min(200, requested - offset);
                var part = store.History(filter with { Offset = offset, Limit = size });
                rows.AddRange(part);
                if (part.Count < size) break;
            }
            return rows;
        });
        if (closing || section != "History" || historyGeneration != generation) return;
        bool hasMore = result.Count > limit;
        if (hasMore) result.RemoveAt(limit);
        moreHistory.Visibility = hasMore ? Visibility.Visible : Visibility.Collapsed;
        if (!historyRows.SequenceEqual(result))
        {
            historyRows.Clear();
            historyRows.AddRange(result);
            historySelecting = true;
            try
            {
                historyList.Items.Clear();
                foreach (var item in result)
                {
                    var name = Text(item.Name);
                    name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
                    name.IsTextSelectionEnabled = false;
                    name.MaxLines = 2;
                    name.TextTrimming = TextTrimming.CharacterEllipsis;
                    var metadata = QuietText(L(item.Status.ToString()) + " · " + item.RecordCount + " · " + item.UpdatedAt.ToLocalTime().ToString("g"));
                    metadata.IsTextSelectionEnabled = false;
                    var text = Rows(name, metadata);
                    text.Spacing = 4;
                    var row = new ListViewItem { Content = text, Tag = item.Id, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                        Padding = new Thickness(9, 8, 9, 8) };
                    ToolTipService.SetToolTip(row, item.Name);
                    AutomationProperties.SetName(row, item.Name);
                    historyList.Items.Add(row);
                    if (item.Id == selectedBatchId) historyList.SelectedItem = row;
                }
            }
            finally { historySelecting = false; }
        }
        if (selectedBatchId is not { } selected || (reset && !result.Any(item => item.Id == selected)))
        {
            selectedBatchId = result.FirstOrDefault()?.Id;
            selectedRecordId = null;
        }
        if (selectedBatchId is { } id)
        {
            historySelecting = true;
            historyList.SelectedItem = historyList.Items.OfType<ListViewItem>().FirstOrDefault(item => Equals(item.Tag, id));
            historySelecting = false;
            await LoadDetailAsync(id, force: false);
        }
        else
        {
            batchDetails.Children.Clear();
            batchDetails.Children.Add(Text(L("NoBatches")));
        }
    }

    private async Task LoadDetailAsync(Guid id, bool force)
    {
        int generation = ++detailGeneration;
        var snapshot = await Task.Run(() => store.Load(id));
        if (closing || section != "History" || selectedBatchId != id || generation != detailGeneration) return;
        if (snapshot is null)
        {
            selectedBatchId = null;
            await RefreshHistoryAsync(reset: false);
            return;
        }
        if (!force && (dialogOpen || (displayedBatchId == id && displayedRevision == snapshot.Revision))) return;
        displayedBatchId = id;
        displayedRevision = snapshot.Revision;
        var batch = snapshot.Batch;
        batchDetails.Children.Clear();
        var name = Text(batch.Name);
        name.FontSize = 22;
        name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        batchDetails.Children.Add(name);
        var summary = BatchSummary.Count(batch.Records);
        var status = Identify(QuietText($"{L(batch.Status.ToString())} · {summary.Done}/{summary.Total}"), "BatchStatus");
        status.Foreground = batch.Status is BatchStatus.Unknown or BatchStatus.Failed ? palette.Attention : palette.Accent;
        batchDetails.Children.Add(status);
        if (batch.Status is BatchStatus.Running or BatchStatus.Queued)
            batchDetails.Children.Add(new ProgressBar { Maximum = Math.Max(1, summary.Total), Value = summary.Done, Foreground = palette.Accent });
        if (batch.Message.Length > 0) batchDetails.Children.Add(QuietText(L(batch.Message)));
        var actions = Actions();
        if (batch.Status == BatchStatus.Prepared)
            actions.Children.Add(ActionButton("Send", async () =>
            {
                if (!await ConfirmAsync("Send", L("SendConfirm")) || closing) return;
                await queue.SubmitAsync(batch);
                await RefreshHistoryAsync(reset: false);
            }, "SendSaved", primary: true));
        if (batch.Status is BatchStatus.Queued or BatchStatus.Running)
            actions.Children.Add(ActionButton("Stop", async () =>
            {
                if (await ConfirmAsync("Stop", L("StopConfirm"))) await queue.StopAsync(batch.Id);
            }));
        if (batch.Status is BatchStatus.Stopped or BatchStatus.Partial or BatchStatus.Failed or BatchStatus.Unknown)
            actions.Children.Add(ActionButton("Retry", () => RetryAsync(batch)));
        actions.Children.Add(ActionButton("Fasta", () => ExportAsync(batch, ExportFormat.Fasta), "ExportFasta"));
        if (summary.Completed > 0) actions.Children.Add(ActionButton("Csv", () => ExportAsync(batch, ExportFormat.ResultsCsv), "ExportCsv"));
        actions.Children.Add(ActionButton("Zip", () => ExportAsync(batch, ExportFormat.AuditZip), "ExportZip"));
        if (batch.Status is not (BatchStatus.Running or BatchStatus.Queued))
            actions.Children.Add(ActionButton("Delete", async () =>
            {
                if (!await ConfirmAsync("Delete", L("DeleteConfirm"))) return;
                if (!await Task.Run(() => store.Delete(batch.Id))) throw new WorkspaceConflictException();
                selectedBatchId = null;
                selectedRecordId = null;
                await RefreshHistoryAsync(reset: false);
            }, "DeleteBatch"));
        batchDetails.Children.Add(actions);
        batchDetails.Children.Add(Heading("Records"));
        var records = Identify(new ListView { MaxHeight = 176, SelectionMode = ListViewSelectionMode.Single }, "RecordsList");
        AutomationProperties.SetName(records, L("Records"));
        var recordDetails = new StackPanel { Spacing = 8 };
        foreach (var record in batch.Records)
        {
            var item = new ListViewItem { Content = Text($"{record.Position} · {record.Name} · {L(record.Status.ToString())}"), Tag = record };
            AutomationProperties.SetName(item, record.Name);
            records.Items.Add(item);
        }
        records.SelectionChanged += (_, _) =>
        {
            if (records.SelectedItem is ListViewItem { Tag: SequenceRecord record })
            {
                selectedRecordId = record.Id;
                BuildRecordDetail(recordDetails, record, batch.Parameters);
            }
        };
        records.SelectedItem = records.Items.OfType<ListViewItem>().FirstOrDefault(item => item.Tag is SequenceRecord record && record.Id == selectedRecordId)
            ?? records.Items.OfType<ListViewItem>().FirstOrDefault();
        batchDetails.Children.Add(records);
        batchDetails.Children.Add(recordDetails);
    }

    private async Task RetryAsync(Batch batch)
    {
        var unknown = batch.Records.Where(record => record.Status == RecordStatus.Unknown).ToArray();
        if (unknown.Length == 0)
        {
            if (await ConfirmAsync("Retry", L("RetryConfirm"))) await queue.RetryAsync(batch.Id);
            return;
        }
        var confirmation = new ConfirmedUnknownRetry(batch);
        string records = string.Join("\n", unknown.Select(record => $"{record.Position} · {record.Name} · " +
            string.Join(", ", record.Attempts.Select(attempt => $"#{attempt.Number}"))));
        if (await ConfirmAsync("Retry", L("UnknownConfirm") + "\n\n" + records)) await queue.RetryAsync(batch.Id, confirmation);
    }

    private void BuildRecordDetail(StackPanel panel, SequenceRecord record, OptimizationParameters parameters)
    {
        panel.Children.Clear();
        panel.Children.Add(Text($"{L("Original")} · {record.OriginalSequence.Value.Length}"));
        panel.Children.Add(SequenceBlock(record.OriginalSequence.Value));
        if (record.OriginalSequence != record.Sequence)
        {
            panel.Children.Add(Text(L("Submitted")));
            panel.Children.Add(SequenceBlock(record.Sequence.Value));
        }
        if (record.Error is { } error) panel.Children.Add(Text(L(error)));
        if (record.Dna is { } dna)
        {
            panel.Children.Add(Heading("Result"));
            var displayed = SequenceBlock(dna);
            Identify(displayed, "DnaText");
            panel.Children.Add(displayed);
            if (record.Checks is { } checks) panel.Children.Add(Text($"{checks.BasePairCount} bp · {checks.AminoAcidCount} aa · GC {checks.GcPercent:0.0}%"));
            panel.Children.Add(ActionButton("Copy", () =>
            {
                var result = DnaValidation.Reverify(record, parameters);
                var content = new DataPackage();
                content.SetText(result.Dna);
                Clipboard.SetContent(content);
                Notify(L("Copied"));
                return Task.CompletedTask;
            }));
        }
        if (record.Attempts.Count == 0) return;
        panel.Children.Add(Heading("Attempts"));
        foreach (var attempt in record.Attempts.Reverse())
        {
            var content = Rows(Text(attempt.StartedAt.ToLocalTime().ToString("G")), Text(attempt.PayloadSha256));
            if (attempt.HttpStatus is { } code) content.Children.Add(Text($"HTTP {code} · {attempt.ElapsedMilliseconds} ms"));
            if (attempt.Error is { } message) content.Children.Add(Text(L(message)));
            content.Children.Add(ActionButton("ShowResponse", () => ViewResponseAsync(record.Id, attempt.Id), $"ShowResponse{attempt.Number}"));
            var expander = Identify(new Expander { Header = $"#{attempt.Number} · {L(attempt.Status.ToString())}", Content = content,
                HorizontalAlignment = HorizontalAlignment.Stretch }, $"Attempt{attempt.Number}");
            panel.Children.Add(expander);
        }
    }

    private ScrollViewer SequenceBlock(string sequence) => new()
    {
        MaxHeight = 170, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled,
        Background = palette.Inset, Padding = new Thickness(10, 7, 10, 7),
        Content = new TextBlock { Text = sequence, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"), Foreground = palette.Text }
    };

    private async Task ViewResponseAsync(Guid recordId, Guid attemptId)
    {
        if (dialogOpen) return;
        var response = await Task.Run(() => store.ReadResponse(recordId, attemptId));
        if (closing || section != "History") return;
        if (!response.Exists || response.Body is null || response.Body.Length == 0)
        {
            Notify(L(!response.Exists ? "MissingAttempt" : response.Body is null ? "NoResponse" : "EmptyResponse"), InfoBarSeverity.Informational);
            return;
        }
        if (dialogOpen) return;
        dialogOpen = true;
        try
        {
            string value = Encoding.UTF8.GetString(response.Body);
            const int pageSize = 4096;
            int current = 0;
            int pages = (value.Length + pageSize - 1) / pageSize;
            var body = Identify(Field("ShowResponse", multiline: true), "ResponseBody");
            body.IsReadOnly = true;
            body.MinHeight = 170;
            var marker = Identify(Text(string.Empty), "ResponsePage");
            var previous = Identify(new Button { Content = L("Previous") }, "PreviousPage");
            var next = Identify(new Button { Content = L("Next") }, "NextPage");
            void Render()
            {
                int start = current * pageSize;
                int end = Math.Min((current + 1) * pageSize, value.Length);
                if (start > 0 && char.IsLowSurrogate(value[start])) start++;
                if (end < value.Length && char.IsLowSurrogate(value[end])) end++;
                body.Text = value[start..end];
                marker.Text = F("Page", current + 1, pages);
                previous.IsEnabled = current > 0;
                next.IsEnabled = current + 1 < pages;
            }
            previous.Click += (_, _) => { current--; Render(); };
            next.Click += (_, _) => { current++; Render(); };
            Render();
            var dialog = new ContentDialog { Title = L("ShowResponse"), CloseButtonText = L("Close"), XamlRoot = root.XamlRoot,
                Content = Rows(body, marker, Columns(previous, next)) };
            await dialog.ShowAsync();
        }
        finally { dialogOpen = false; }
    }

    private async Task ExportAsync(Batch batch, ExportFormat format)
    {
        string key = format switch { ExportFormat.Fasta => "Fasta", ExportFormat.ResultsCsv => "Csv", _ => "Zip" };
        string extension = format switch { ExportFormat.Fasta => ".fasta", ExportFormat.ResultsCsv => ".csv", _ => ".zip" };
        byte[] data = await Task.Run(() => LocalBatchExport.Encode(batch, format));
        string? path;
        if (smoke)
        {
            path = Path.Combine(store.DirectoryPath, "smoke-export" + extension);
        }
        else
        {
            var picker = new FileSavePicker { SuggestedFileName = CleanName(batch.Name) + " - " + L(key) };
            picker.FileTypeChoices.Add(L(key), [extension]);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
            path = (await picker.PickSaveFileAsync())?.Path;
        }
        if (path is null || closing) return;
        await LocalBatchExport.WriteAsync(path, data);
        Notify(L("Exported"));
    }

    private static string CleanName(string name)
    {
        var illegal = Path.GetInvalidFileNameChars().ToHashSet();
        string result = new(name.Take(90).Select(c => illegal.Contains(c) ? '_' : c).ToArray());
        return result.Trim().TrimEnd('.');
    }
}

using System.Diagnostics;
using CodonProteinFactory.Application;
using CodonProteinFactory.Domain;
using CodonProteinFactory.Persistence;
using CodonProteinFactory.SequenceIO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CodonProteinFactory.Windows;

internal sealed partial class WorkspaceView
{
    private void BuildSettings()
    {
        var themes = new[] { "system", "light", "dark" };
        var appearance = Choice("Theme", new[] { L("System"), L("Light"), L("Dark") }, Array.IndexOf(themes, settings.Theme));
        var languages = new[] { "en", "zh-Hans" };
        var language = Choice("Language", new[] { "English", "简体中文" }, Array.IndexOf(languages, settings.Language));
        appearance.SelectionChanged += async (_, _) => await RunAsync(async () =>
        {
            if (appearance.SelectedIndex < 0) return;
            settings = settings with { Theme = themes[appearance.SelectedIndex] };
            ApplyTheme();
            await SaveSettingsAsync();
        });
        language.SelectionChanged += async (_, _) => await RunAsync(async () =>
        {
            if (language.SelectedIndex < 0) return;
            settings = settings with { Language = languages[language.SelectedIndex] };
            strings = new Strings(settings.Language);
            BuildShell();
            await SaveSettingsAsync();
        });
        var preferences = Section("AppearanceOptions", Symbol.Setting, appearance, language,
            QuietText(F("Version", typeof(WorkspaceView).Assembly.GetName().Version?.ToString(3) ?? "0.1.0")));
        var data = Section("LocalWorkspace", Symbol.Folder, QuietText(L("DataExplanation")), Text(store.DirectoryPath), ActionButton("OpenData", () =>
        {
            Process.Start(new ProcessStartInfo(store.DirectoryPath) { UseShellExecute = true });
            return Task.CompletedTask;
        }));
        var settingsSections = SectionRows(preferences, data);
        settingsSections.MaxWidth = 680;
        settingsSections.HorizontalAlignment = HorizontalAlignment.Left;
        page.Children.Add(settingsSections);
    }

    private readonly SemaphoreSlim settingsWrites = new(1, 1);

    private async Task SaveSettingsAsync()
    {
        await settingsWrites.WaitAsync();
        try { await settings.SaveAsync(store.DirectoryPath); }
        finally { settingsWrites.Release(); }
    }

    private void BuildPresets()
    {
        var pane = new StackPanel { Spacing = 12 };
        page.Children.Add(pane);
        _ = RunAsync(async () =>
        {
            var presets = await Task.Run(() => (store.ImportPresets(), store.ParameterPresets()));
            if (closing || section != "Presets" || !page.Children.Contains(pane)) return;
            var parameters = new StackPanel { Spacing = 10 };
            var imports = new StackPanel { Spacing = 10 };
            AddPresets(parameters, presets.Item2, preset => (preset.Id, preset.Name), preset =>
            {
                species = preset.Parameters.Species;
                startPolicy = preset.Parameters.StartPolicy;
                stopPolicy = preset.Parameters.StopPolicy;
                customMotifs = preset.Parameters.Avoid.WireValue;
                enzymes.Clear();
                Show("NewBatch");
            });
            AddPresets(imports, presets.Item1, preset => (preset.Id, preset.Name), preset =>
            {
                if (workbook is null) throw new ImportException(ImportErrorCode.InvalidMapping, L("ImportFile"));
                SequenceImport.MapColumns(workbook, preset.Mapping);
                mapping = preset.Mapping;
                Show("NewBatch");
            });
            pane.Children.Add(Section("ParameterPresets", Symbol.Filter, parameters));
            pane.Children.Add(Section("ImportPresets", Symbol.Folder, imports));
        });
    }

    private void AddPresets<T>(StackPanel pane, IReadOnlyList<T> presets, Func<T, (Guid Id, string Name)> describe, Action<T> apply)
    {
        if (presets.Count == 0) pane.Children.Add(Text(L("NoPreset")));
        foreach (var item in presets)
        {
            var (id, name) = describe(item);
            pane.Children.Add(Rows(Text(name), Actions(ActionButton("Apply", () => { apply(item); return Task.CompletedTask; }),
                ActionButton("Delete", async () =>
                {
                    if (!await ConfirmAsync("Delete", L("DeleteConfirm"))) return;
                    await Task.Run(() => store.DeletePreset(id));
                    Show("Presets");
                }))));
        }
    }

    private string ErrorText(Exception error)
    {
        string key = error switch { DomainException domain => domain.Code.ToString(), ImportException import => import.Code.ToString(),
            QueueException queued => queued.Code.ToString(), _ => string.Empty };
        string translated = L(key);
        return translated.Length > 0 && translated != key ? translated : error.Message;
    }
}

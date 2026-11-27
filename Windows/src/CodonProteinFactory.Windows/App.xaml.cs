using System.Text.Json;
using CodonProteinFactory.Application;
using CodonProteinFactory.Domain;
using CodonProteinFactory.Persistence;
using CodonProteinFactory.Service;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CodonProteinFactory.Windows;

public partial class App : Microsoft.UI.Xaml.Application
{
    private Window? window;
    private FileStream? instanceLock;
    private IDisposable? disposableService;

    public App()
    {
        UnhandledException += (_, args) =>
        {
            if (Environment.GetCommandLineArgs().Contains("--ui-smoke", StringComparer.Ordinal))
            {
                try { File.WriteAllText(Path.Combine(SmokeDirectory(), "ui-error.log"), args.Exception?.ToString() ?? args.Message); }
                catch (Exception error) when (error is IOException or InvalidOperationException or UnauthorizedAccessException) { }
            }
        };
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new Window { Title = "Codon ProteinFactory" };
        bool smoke = Environment.GetCommandLineArgs().Contains("--ui-smoke", StringComparer.Ordinal);
        try
        {
            string directory = smoke ? SmokeDirectory() : WorkspaceStore.DefaultDirectory;
            Directory.CreateDirectory(directory);
            instanceLock = new FileStream(Path.Combine(directory, ".workspace.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            var store = new WorkspaceStore(directory);
            QueueRecovery.Recover(store, TimeProvider.System);
            ISubmissionService service = smoke ? new SmokeService() : new ProteinServiceClient();
            disposableService = service as IDisposable;
            var queue = new QueueCoordinator(store, service);
            var settings = UserSettings.Read(directory);
            var workspace = new WorkspaceView(window, store, queue, settings, smoke);
            window.Content = workspace.View;
            window.Closed += (_, _) =>
            {
                disposableService?.Dispose();
                instanceLock?.Dispose();
            };
        }
        catch (Exception error)
        {
            window.Content = new ScrollViewer { Content = new TextBlock
            {
                Text = "无法打开工作区 / Unable to open workspace\n" + error.Message,
                TextWrapping = TextWrapping.Wrap, Margin = new Thickness(24)
            } };
        }
        window.Activate();
    }

    private static string SmokeDirectory()
    {
        string? name = Environment.GetEnvironmentVariable("CODON_FACTORY_UI_SMOKE_ID");
        if (!Guid.TryParseExact(name, "N", out var id)) throw new InvalidOperationException("UI smoke requires an isolated workspace ID.");
        return Path.Combine(Path.GetTempPath(), "CodonFactoryUiSmoke-" + id.ToString("N"));
    }

    private sealed class SmokeService : ISubmissionService
    {
        public Task<ServiceReceipt> SubmitAsync(ServiceRequest request, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            byte[] body = JsonSerializer.SerializeToUtf8Bytes(new { success = 1, seq = "ATGTAA", context = new string('x', 9_000) });
            return Task.FromResult(ResponseClassifier.Classify(200, body, request));
        }
    }
}

internal sealed record UserSettings(string Language, string Theme)
{
    public static UserSettings Read(string directory)
    {
        string path = Path.Combine(directory, "settings.json");
        if (File.Exists(path)) return JsonSerializer.Deserialize<UserSettings>(File.ReadAllText(path)) ?? Defaults();
        return Defaults();
    }

    public Task SaveAsync(string directory) => LocalBatchExport.WriteAsync(Path.Combine(directory, "settings.json"), JsonSerializer.SerializeToUtf8Bytes(this));

    private static UserSettings Defaults() => new(System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "zh" ? "zh-Hans" : "en", "system");
}

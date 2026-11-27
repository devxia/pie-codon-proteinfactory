using Microsoft.Data.Sqlite;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CodonProteinFactory.InstallerProbe;

public partial class App : Microsoft.UI.Xaml.Application
{
    private Window? window;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var version = typeof(App).Assembly.GetName().Version!.ToString(3);
        using var sqlite = new SqliteConnection("Data Source=:memory:");
        sqlite.Open();
        using var command = sqlite.CreateCommand();
        command.CommandText = "SELECT sqlite_version()";
        var sqliteVersion = (string)command.ExecuteScalar()!;
        var title = $"Codon Protein Factory Installer Probe {version}";
        var dataDirectory = Environment.GetEnvironmentVariable("CODON_FACTORY_PROBE_DATA");
        if (string.IsNullOrWhiteSpace(dataDirectory))
        {
            dataDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Codon ProteinFactory Installer Probe");
        }

        Directory.CreateDirectory(dataDirectory);
        var markerPath = Path.Combine(dataDirectory, "installation-id.txt");
        if (!File.Exists(markerPath))
        {
            File.WriteAllText(markerPath, Guid.NewGuid().ToString("D"));
        }

        window = new Window
        {
            Title = title,
            Content = new TextBlock
            {
                Text = $"{title} · SQLite {sqliteVersion}",
                Margin = new Thickness(24),
                TextWrapping = TextWrapping.Wrap
            }
        };
        window.Activate();
        File.WriteAllText(Path.Combine(dataDirectory, "last-launch.txt"), version);
    }
}

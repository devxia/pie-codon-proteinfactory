[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')] [string] $FirstVersion = '0.1.0',
    [ValidatePattern('^\d+\.\d+\.\d+$')] [string] $UpgradeVersion = '0.1.1',
    [switch] $DirectOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$artifacts = Join-Path $repoRoot 'dist/windows/w0'
$appName = 'Codon Protein Factory Installer Probe'
$installDirectory = Join-Path $env:ProgramFiles $appName
$installedExe = Join-Path $installDirectory 'InstallerProbe.exe'
$uninstaller = Join-Path $installDirectory 'unins000.exe'
$startMenuLink = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) "$appName.lnk"
$testRoot = Join-Path $env:TEMP "CodonFactoryProbe-$([guid]::NewGuid())"
$logs = Join-Path $artifacts (Split-Path $testRoot -Leaf)
$oldDataPath = $env:CODON_FACTORY_PROBE_DATA
$controlFiles = @($installedExe, $uninstaller, $startMenuLink)

function Invoke-Setup([string] $Executable, [string] $LogName) {
    $logPath = Join-Path $logs $LogName
    $process = Start-Process -FilePath $Executable -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=`"$logPath`"" -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Setup failed ($($process.ExitCode)). See '$logPath'." }
}

function Test-ProbeLaunch([string] $Executable, [string] $ExpectedVersion, [string] $DataPath) {
    $env:CODON_FACTORY_PROBE_DATA = $DataPath
    $process = Start-Process -FilePath $Executable -PassThru
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        $versionFile = Join-Path $DataPath 'last-launch.txt'
        $expectedTitle = "$appName $ExpectedVersion"
        do {
            Start-Sleep -Milliseconds 150
            $process.Refresh()
            if ($process.HasExited) { throw "Probe exited at startup ($($process.ExitCode)): '$Executable'." }
            if ($process.MainWindowTitle -eq $expectedTitle -and
                (Test-Path -LiteralPath $versionFile) -and
                (Get-Content -LiteralPath $versionFile -Raw) -eq $ExpectedVersion) {
                Write-Host "Started $expectedTitle from '$Executable'."
                return
            }
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "Probe window did not appear: '$Executable'."
    } finally {
        if (-not $process.HasExited) {
            $null = $process.CloseMainWindow()
            if (-not $process.WaitForExit(5000)) {
                $process.Kill()
                throw 'Probe failed to close its window.'
            }
        }
        $process.Dispose()
    }
}

$publishedExe = (Get-Item -LiteralPath (Join-Path $artifacts "publish/$FirstVersion/InstallerProbe.exe")).FullName
try {
    Test-ProbeLaunch $publishedExe $FirstVersion (Join-Path $testRoot 'direct')
    if ($DirectOnly) { return }

    if ([version]$UpgradeVersion -le [version]$FirstVersion) { throw 'Upgrade version must increase.' }
    foreach ($path in @($installDirectory, $startMenuLink)) {
        if (Test-Path -LiteralPath $path) { throw "A probe installation already exists at '$path'." }
    }
    $firstInstaller = (Get-Item -LiteralPath (Join-Path $artifacts "installers/InstallerProbe-$FirstVersion-win-x64.exe")).FullName
    $upgradeInstaller = (Get-Item -LiteralPath (Join-Path $artifacts "installers/InstallerProbe-$UpgradeVersion-win-x64.exe")).FullName
    $null = New-Item -ItemType Directory -Path $logs
    $installedData = Join-Path $testRoot 'installed'
    Invoke-Setup $firstInstaller '01-install.log'
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($startMenuLink)
    if ($shortcut.TargetPath -ne $installedExe) { throw 'Start menu shortcut points to the wrong executable.' }
    Test-ProbeLaunch $installedExe $FirstVersion $installedData
    $marker = Join-Path $installedData 'installation-id.txt'
    $installationId = Get-Content -LiteralPath $marker -Raw

    Invoke-Setup $upgradeInstaller '02-upgrade.log'
    Test-ProbeLaunch $installedExe $UpgradeVersion $installedData
    if ((Get-Content -LiteralPath $marker -Raw) -ne $installationId) { throw 'Upgrade changed probe data.' }

    Invoke-Setup $uninstaller '03-uninstall.log'
    foreach ($file in $controlFiles) {
        if (Test-Path -LiteralPath $file) { throw "Uninstall left '$file' behind." }
    }
    if ((Get-Content -LiteralPath $marker -Raw) -ne $installationId) { throw 'Uninstall changed probe data.' }
    Write-Host "Probe launch, install, upgrade and uninstall passed. Logs: '$logs'."
} finally {
    $env:CODON_FACTORY_PROBE_DATA = $oldDataPath
    if (Test-Path -LiteralPath $testRoot) {
        Write-Host "Isolated probe data: '$testRoot'."
    }
}

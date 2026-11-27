[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Installer,
    [Parameter(Mandatory)] [string] $UpgradeInstaller
)

$ErrorActionPreference = 'Stop'
$initial = Get-Item -LiteralPath $Installer
$upgrade = Get-Item -LiteralPath $UpgradeInstaller
if ([version]$upgrade.VersionInfo.ProductVersion -le [version]$initial.VersionInfo.ProductVersion) { throw 'Upgrade version must increase.' }
$installFolder = Join-Path $env:ProgramFiles 'Codon Protein Factory'
$exe = Join-Path $installFolder 'CodonProteinFactory.exe'
$uninstall = Join-Path $installFolder 'unins000.exe'
$shortcut = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Codon ProteinFactory.lnk'
foreach ($path in $installFolder, $shortcut) {
    if (Test-Path -LiteralPath $path) { throw "An existing installation occupies '$path'." }
}
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$logs = Join-Path $root "dist/windows/verification/installed-$([DateTime]::Now.ToString('yyyyMMdd-HHmmss'))"
$null = New-Item -ItemType Directory -Force -Path $logs
$uiSmoke = Join-Path $PSScriptRoot 'smoke-app.ps1'
$workspace = $null

function Invoke-Setup([string] $Path, [string] $LogName) {
    $logFile = Join-Path $logs $LogName
    $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="' + $logFile + '"'
    $setup = Start-Process -FilePath $Path -ArgumentList $arguments -PassThru -Wait
    if ($setup.ExitCode -ne 0) { throw "Setup returned $($setup.ExitCode). See '$logFile'." }
}

function Assert-Installation([string] $Version) {
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    if ($link.TargetPath -ne $exe) { throw 'The start menu shortcut points to the wrong executable.' }
    if ((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -notmatch ('^' + [regex]::Escape($Version))) {
        throw "The installed application is not version $Version."
    }
    foreach ($name in 'e_sqlite3.dll','coreclr.dll','CodonProteinFactory.pri','App.xbf') {
        if (!(Test-Path -LiteralPath (Join-Path $installFolder $name))) { throw "Missing installed file $name." }
    }
}

Invoke-Setup $initial.FullName '01-install.log'
Assert-Installation ([version]$initial.VersionInfo.ProductVersion).ToString(3)
$evidence = Join-Path $logs 'ui'
$uiResult = & $uiSmoke -AppPath $exe -EvidenceDirectory $evidence
$uiResult | Tee-Object (Join-Path $logs 'ui-initial.log')
$resultLine = $uiResult | Where-Object { $_ -like 'Isolated workspace: *' } | Select-Object -Last 1
if ($resultLine -notmatch 'CodonFactoryUiSmoke-([0-9a-f]{32})$') { throw 'The WinUI smoke process did not report its workspace.' }
$workspace = $Matches[1]
$database = Join-Path $env:TEMP "CodonFactoryUiSmoke-$workspace/Workspace.sqlite"
$before = (Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash

Invoke-Setup $upgrade.FullName '02-upgrade.log'
Assert-Installation ([version]$upgrade.VersionInfo.ProductVersion).ToString(3)
if ((Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash -ne $before) { throw 'Upgrade changed the workspace before launch.' }
& $uiSmoke -AppPath $exe -ExistingWorkspaceId $workspace | Tee-Object (Join-Path $logs 'ui-upgraded.log')

$before = (Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash
Invoke-Setup $uninstall '03-uninstall.log'
foreach ($path in $exe, $uninstall, $shortcut) {
    if (Test-Path -LiteralPath $path) { throw "Uninstall left '$path'." }
}
if ((Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash -ne $before) { throw 'Uninstall changed the workspace database.' }

Invoke-Setup $initial.FullName '04-reinstall.log'
Assert-Installation ([version]$initial.VersionInfo.ProductVersion).ToString(3)
& $uiSmoke -AppPath $exe -ExistingWorkspaceId $workspace | Tee-Object (Join-Path $logs 'ui-reinstalled.log')
Write-Output "Install, upgrade, uninstall and reinstall passed. Evidence: $logs"

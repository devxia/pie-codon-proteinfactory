[CmdletBinding()]
param(
    [ValidateSet('Release')] [string] $Configuration = 'Release',
    [ValidatePattern('^\d+\.\d+\.\d+$')] [string] $Version,
    [string] $InnoCompiler = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe'),
    [string] $InstallerDirectory,
    [ValidatePattern('^[a-zA-Z0-9_-]*$')] [string] $SignToolName
)

$ErrorActionPreference = 'Stop'
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (!$Version) {
    [xml] $buildProperties = Get-Content -LiteralPath (Join-Path $windowsRoot 'Directory.Build.props') -Raw
    $Version = $buildProperties.SelectSingleNode('/Project/PropertyGroup/Version').InnerText
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Directory.Build.props must define a three-part Windows version.' }
}
$repoRoot = Split-Path $windowsRoot -Parent
if (!$InstallerDirectory) { $InstallerDirectory = Join-Path $repoRoot 'dist' }
$InstallerDirectory = [System.IO.Path]::GetFullPath($InstallerDirectory)
$null = New-Item -ItemType Directory -Force -Path $InstallerDirectory
$buildDirectory = Join-Path $windowsRoot '.build/installer'
$prerequisites = Join-Path $buildDirectory 'prerequisites'
$publishDirectory = Join-Path $buildDirectory "publish/$Version"
$project = 'src/CodonProteinFactory.Windows/CodonProteinFactory.Windows.csproj'
$compiler = (Get-Item -LiteralPath $InnoCompiler).FullName
$actualInno = & $compiler --version
if ($LASTEXITCODE -ne 0 -or $actualInno -ne '7.1.1') { throw "Inno Setup 7.1.1 is required. Found '$actualInno'." }

Push-Location $windowsRoot
try {
    $expected = (Get-Content -LiteralPath 'global.json' -Raw | ConvertFrom-Json).sdk.version
    $actual = & dotnet --version
    if ($LASTEXITCODE -ne 0 -or $actual -ne $expected) { throw "Expected .NET SDK $expected. Found '$actual'." }
    & dotnet restore $project --locked-mode
    if ($LASTEXITCODE -ne 0) { throw "Locked restore failed ($LASTEXITCODE)." }
    & dotnet publish $project -c $Configuration --no-restore -p:Version=$Version -o $publishDirectory
    if ($LASTEXITCODE -ne 0) { throw "Publish failed ($LASTEXITCODE)." }
} finally { Pop-Location }

foreach ($file in 'CodonProteinFactory.exe','coreclr.dll','e_sqlite3.dll','CodonProteinFactory.pri','App.xbf') {
    if (!(Test-Path -LiteralPath (Join-Path $publishDirectory $file) -PathType Leaf)) { throw "Publish output is missing '$file'." }
}
& (Join-Path $PSScriptRoot 'Get-VerifiedPrerequisites.ps1') -Destination $prerequisites
$defines = @("/DAppVersion=$Version", "/DOutputDirectory=$InstallerDirectory", "/DPublishDir=$publishDirectory", "/DPrerequisiteDir=$prerequisites")
if ($SignToolName) { $defines += "/DInstallerSignTool=$SignToolName" }
& $compiler --quiet-progress @defines (Join-Path $windowsRoot 'Installer/CodonProteinFactory.iss')
if ($LASTEXITCODE -ne 0) { throw "Installer compile failed ($LASTEXITCODE)." }

$artifact = Get-Item -LiteralPath (Join-Path $InstallerDirectory "Pie-Codon-ProteinFactory-$Version-win-x64.exe")
$hash = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$($artifact.FullName).sha256", "$hash  $($artifact.Name)" + [char]10, [System.Text.Encoding]::ASCII)
Write-Output "$hash  $($artifact.FullName)"

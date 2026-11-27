[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')] [string] $Version = '0.1.0',
    [string] $InnoCompiler = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe')
)

$ErrorActionPreference = 'Stop'
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = Split-Path $windowsRoot -Parent
$artifactDirectory = Join-Path $repoRoot 'dist/windows/w0'
$publishDirectory = Join-Path $artifactDirectory "publish/$Version"
$installerDirectory = Join-Path $artifactDirectory 'installers'
$prerequisiteDirectory = Join-Path $artifactDirectory 'prerequisites'
$project = 'Spikes/InstallerProbe/InstallerProbe.csproj'

$compiler = Get-Item -LiteralPath $InnoCompiler
$innoVersion = & $compiler.FullName --version
if ($LASTEXITCODE -ne 0 -or $innoVersion -ne '7.1.1') {
    throw "Inno Setup 7.1.1 is required. Found '$innoVersion'."
}

Push-Location $windowsRoot
try {
    $expectedSdk = (Get-Content -LiteralPath 'global.json' -Raw | ConvertFrom-Json).sdk.version
    $actualSdk = & dotnet --version
    if ($LASTEXITCODE -ne 0 -or $actualSdk -ne $expectedSdk) {
        throw "Expected .NET SDK $expectedSdk. Found '$actualSdk'."
    }
    & dotnet restore $project --locked-mode
    if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed ($LASTEXITCODE)." }
    & dotnet publish $project -c Release --no-restore -p:Version=$Version -o $publishDirectory
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)." }
} finally {
    Pop-Location
}

& (Join-Path $PSScriptRoot 'Get-VerifiedPrerequisites.ps1') -Destination $prerequisiteDirectory
$installerScript = Join-Path $windowsRoot 'Installer/InstallerProbe.iss'
& $compiler.FullName "/DProbeVersion=$Version" "/DOutputDirectory=$installerDirectory" "/DPublishDir=$publishDirectory" "/DPrerequisiteDir=$prerequisiteDirectory" $installerScript
if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)." }

Get-Item -LiteralPath (Join-Path $installerDirectory "InstallerProbe-$Version-win-x64.exe")

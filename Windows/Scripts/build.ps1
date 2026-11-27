[CmdletBinding()]
param([ValidateSet('Debug','Release')] [string] $Configuration = 'Release')

$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    $expected = (Get-Content -LiteralPath 'global.json' -Raw | ConvertFrom-Json).sdk.version
    $actual = & dotnet --version
    if ($LASTEXITCODE -ne 0 -or $actual -ne $expected) { throw "Expected .NET SDK $expected. Found '$actual'." }
    & dotnet restore CodonProteinFactory.Windows.sln --locked-mode
    if ($LASTEXITCODE -ne 0) { throw "Locked restore failed ($LASTEXITCODE)." }
    & dotnet build CodonProteinFactory.Windows.sln -c $Configuration -p:Platform=x64 --no-restore
    if ($LASTEXITCODE -ne 0) { throw "Build failed ($LASTEXITCODE)." }
} finally { Pop-Location }

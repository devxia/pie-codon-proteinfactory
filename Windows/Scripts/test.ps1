[CmdletBinding()]
param([ValidateSet('Debug','Release')] [string] $Configuration = 'Release')

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'build.ps1') -Configuration $Configuration
Push-Location (Join-Path $PSScriptRoot '..')
try {
    & dotnet test CodonProteinFactory.Windows.sln -c $Configuration -p:Platform=x64 --no-build --no-restore
    if ($LASTEXITCODE -ne 0) { throw "Tests failed ($LASTEXITCODE)." }
} finally { Pop-Location }

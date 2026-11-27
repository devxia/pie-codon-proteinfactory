[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Destination
)

$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $PSScriptRoot '../Installer/Prerequisites/win-x64.json'
$prerequisites = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$null = New-Item -ItemType Directory -Path $Destination -Force

foreach ($prerequisite in $prerequisites) {
    $file = Join-Path $Destination $prerequisite.file
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $download = "$file.$([guid]::NewGuid()).download"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $prerequisite.url -OutFile $download
            if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $prerequisite.sha256) {
                throw "SHA-256 mismatch for $($prerequisite.name) $($prerequisite.version)."
            }
            Move-Item -LiteralPath $download -Destination $file
        } finally {
            if (Test-Path -LiteralPath $download) {
                Remove-Item -LiteralPath $download
            }
        }
    }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $prerequisite.sha256) {
        throw "SHA-256 mismatch for '$file'."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $file
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '\bO=Microsoft Corporation(,|$)') {
        throw "Invalid Microsoft Authenticode signature on '$file'."
    }
    Write-Host "Verified $($prerequisite.name) $($prerequisite.version)."
}

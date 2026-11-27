[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AppPath,
    [string] $EvidenceDirectory,
    [ValidatePattern('^[0-9a-f]{32}$')] [string] $ExistingWorkspaceId,
    [switch] $VerifyDesktopControls
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
if (-not ('CodonFactoryDisplay' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodonFactoryDisplay {
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
}
'@
}
$app = (Get-Item -LiteralPath $AppPath).FullName
$workspaceId = if ($ExistingWorkspaceId) { $ExistingWorkspaceId } else { [guid]::NewGuid().ToString('N') }
$originalWorkspaceId = $env:CODON_FACTORY_UI_SMOKE_ID
$testDirectory = Join-Path $env:TEMP "CodonFactoryUiSmoke-$workspaceId"
$env:CODON_FACTORY_UI_SMOKE_ID = $workspaceId
$process = $null
$window = $null

function Find-Element([string] $Value, [switch] $ByName) {
    $property = [System.Windows.Automation.AutomationElement]::AutomationIdProperty
    if ($ByName) { $property = [System.Windows.Automation.AutomationElement]::NameProperty }
    $condition = New-Object System.Windows.Automation.PropertyCondition($property, $Value)
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "The app exited ($($process.ExitCode)) while looking for '$Value'." }
        try {
            $element = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if ($element) { return $element }
        } catch [System.Windows.Automation.ElementNotAvailableException] { }
        Start-Sleep -Milliseconds 120
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Missing UI element '$Value'."
}

function Wait-File([string] $Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "File not created: '$Path'."
}

function Start-App {
    $script:process = Start-Process -FilePath $app -ArgumentList '--ui-smoke' -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "App startup failed ($($process.ExitCode))." }
        if ($process.MainWindowHandle -ne 0) {
            $script:window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
            Write-Host "Window DPI: $([CodonFactoryDisplay]::GetDpiForWindow($process.MainWindowHandle))"
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'WinUI window did not appear.'
}

function Invoke-Control([string] $Value, [switch] $ByName) {
    $element = Find-Element $Value -ByName:$ByName
    $pattern = $null
    if ($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
    } elseif ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
        $pattern.Select()
    } else {
        throw "No action pattern for '$Value'."
    }
}

function Set-Field([string] $Id, [string] $Text) {
    $element = Find-Element $Id
    $pattern = $element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $pattern.SetValue($Text)
}

function Close-App {
    if ($process.HasExited) { throw 'App already exited.' }
    if (!$process.CloseMainWindow() -or !$process.WaitForExit(10000)) { throw 'App failed to drain and close.' }
    if ($process.ExitCode -ne 0) { throw "App exited with $($process.ExitCode)." }
}

try {
    Start-App
    if ($ExistingWorkspaceId) {
        Invoke-Control 'History' -ByName
        $null = Find-Element 'ExportCsv'
        $null = Find-Element 'Windows UI smoke' -ByName
        Close-App
        Write-Output 'Verified persisted history through WinUI.'
        return
    }
    if ($VerifyDesktopControls) {
        Add-Type -AssemblyName System.Windows.Forms
        (Find-Element 'BatchName').SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($focused.Current.ProcessId -ne $process.Id -or $focused.Current.AutomationId -eq 'BatchName') {
            throw 'Tab did not move focus to another control in the workspace.'
        }
        Invoke-Control 'Settings' -ByName
        $language = Find-Element 'Language'
        $language.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        $chinese = -join ([char]0x7b80, [char]0x4f53, [char]0x4e2d, [char]0x6587)
        Invoke-Control $chinese -ByName
        $chineseSettings = -join ([char]0x8bbe, [char]0x7f6e)
        $null = Find-Element $chineseSettings -ByName
        $language = Find-Element 'Language'
        $language.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        Invoke-Control 'English' -ByName
        $theme = Find-Element 'Theme'
        $theme.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        Invoke-Control 'Dark' -ByName
        $settingsFile = Join-Path $testDirectory 'settings.json'
        Wait-File $settingsFile
        $deadline = [DateTime]::UtcNow.AddSeconds(6)
        do {
            Start-Sleep -Milliseconds 100
            $settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        } while (($settings.Language -ne 'en' -or $settings.Theme -ne 'dark') -and [DateTime]::UtcNow -lt $deadline)
        if ($settings.Language -ne 'en' -or $settings.Theme -ne 'dark') { throw 'The desktop settings did not persist.' }
        Invoke-Control 'New batch' -ByName
        Write-Output 'Checked keyboard focus, simplified Chinese, English and persisted dark theme.'
    }
    Set-Field 'BatchName' 'Windows UI smoke'
    Set-Field 'Gene' 'synthetic-smoke'
    Set-Field 'Paste' 'M'
    $null = Find-Element ('1 valid ' + [char]0x00b7 + ' 0 rejected') -ByName
    Invoke-Control 'Preview'
    Invoke-Control 'SaveDraft'
    $null = Find-Element 'SendSaved'
    Write-Output 'Saved local draft through WinUI.'
    Invoke-Control 'SendSaved'
    Invoke-Control 'Confirm' -ByName
    $null = Find-Element 'ExportCsv'
    Write-Output 'Confirmed simulated submission and observed verified result.'

    $attempt = Find-Element 'Attempt1'
    $expand = $attempt.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expand.Expand()
    Invoke-Control 'ShowResponse1'
    $page = Find-Element 'ResponsePage'
    if ($page.Current.Name -notlike '*1 of 3*') { throw "Unexpected first response page: $($page.Current.Name)" }
    Invoke-Control 'NextPage'
    Start-Sleep -Milliseconds 300
    if ((Find-Element 'ResponsePage').Current.Name -notlike '*2 of 3*') { throw 'Response did not advance to page 2.' }
    Invoke-Control 'Close' -ByName
    Write-Output 'Loaded response on demand and advanced to page 2.'

    foreach ($pair in @(@('ExportFasta','.fasta'), @('ExportCsv','.csv'), @('ExportZip','.zip'))) {
        Invoke-Control $pair[0]
        Wait-File (Join-Path $testDirectory ('smoke-export' + $pair[1]))
    }
    $csv = Get-Content -LiteralPath (Join-Path $testDirectory 'smoke-export.csv') -Raw
    if ($csv -notmatch '1,synthetic-smoke,M,ATGTAA') { throw 'The CSV does not include the verified mock result.' }
    Write-Output 'Saved FASTA, CSV and audit ZIP.'
    Close-App
    Start-App
    Invoke-Control 'History' -ByName
    $null = Find-Element 'ExportCsv'
    $null = Find-Element 'Windows UI smoke' -ByName
    Write-Output 'Restarted the application and verified persisted history.'
    Close-App
    if ($EvidenceDirectory) {
        $null = New-Item -ItemType Directory -Force -Path $EvidenceDirectory
        Copy-Item -LiteralPath (Join-Path $testDirectory 'Workspace.sqlite') -Destination $EvidenceDirectory
        Get-ChildItem -Path $testDirectory -Filter 'smoke-export.*' | Copy-Item -Destination $EvidenceDirectory
    }
} catch {
    if ($window -and $process -and !$process.HasExited) {
        $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
            Select-Object -First 70 | ForEach-Object { Write-Output "UI $($_.Current.AutomationId) $($_.Current.Name)" }
    }
    throw
} finally {
    if ($process -and !$process.HasExited) { $null = $process.CloseMainWindow() }
    $env:CODON_FACTORY_UI_SMOKE_ID = $originalWorkspaceId
    Write-Output "Isolated workspace: $testDirectory"
}

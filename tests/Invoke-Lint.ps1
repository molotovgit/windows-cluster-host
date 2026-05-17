<#
.SYNOPSIS
    Run PSScriptAnalyzer against the windows-cluster-host PowerShell sources.

.DESCRIPTION
    Wraps Invoke-ScriptAnalyzer with the project's settings file so every
    contributor runs the same rule set. Exits non-zero on any Error/Warning
    finding (severity threshold configurable via -MinSeverity).

    Targets by default:
        src/             -- all .ps1/.psm1/.psd1
        scripts/         -- operator helpers (Test-Prerequisites, Uninstall, …)
        tests/           -- our own test infrastructure
        install.ps1      -- top-level bootstrap (PR 17)

    Pre-flight: auto-installs PSScriptAnalyzer into CurrentUser scope if it
    is not already on the module path. This keeps the sandbox harness
    self-bootstrapping for new contributors.

.PARAMETER Paths
    Files / directories to scan. Defaults derived from the repo layout.

.PARAMETER MinSeverity
    Warning | Error. Default Warning. Findings at or above this level
    cause a non-zero exit.

.PARAMETER SettingsPath
    PSScriptAnalyzer settings file. Defaults to
    tests/PSScriptAnalyzerSettings.psd1 next to this script.

.PARAMETER Fix
    Pass through to Invoke-ScriptAnalyzer -Fix where the rule supports
    auto-fixing. Use with care -- inspect the diff after.

.OUTPUTS
    System.Int32 exit code (0 = clean, 1 = findings).
#>

[CmdletBinding()]
param(
    [string[]]$Paths,
    [ValidateSet('Warning','Error')]
    [string]$MinSeverity = 'Warning',
    [string]$SettingsPath,
    [switch]$Fix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- locate ---
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
if (-not $SettingsPath) {
    $SettingsPath = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
}
if (-not $Paths -or $Paths.Count -eq 0) {
    $Paths = @(
        (Join-Path $repoRoot 'src'),
        (Join-Path $repoRoot 'tests'),
        (Join-Path $repoRoot 'scripts'),
        (Join-Path $repoRoot 'install.ps1')
    ) | Where-Object { Test-Path -LiteralPath $_ }
}

# --- bootstrap PSScriptAnalyzer if missing ---
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host 'PSScriptAnalyzer not installed. Installing into CurrentUser scope...' -ForegroundColor Yellow
    try {
        Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -ErrorAction Stop -SkipPublisherCheck
    } catch {
        Write-Error "Cannot install PSScriptAnalyzer automatically. Install it manually with 'Install-Module PSScriptAnalyzer -Scope CurrentUser' and retry. Underlying error: $($_.Exception.Message)"
        exit 2
    }
}
Import-Module PSScriptAnalyzer -Force

# --- scan ---
Write-Host "Lint targets:" -ForegroundColor Cyan
$Paths | ForEach-Object { Write-Host "  $_" }
Write-Host "Settings: $SettingsPath" -ForegroundColor Cyan

$severityArg = if ($MinSeverity -eq 'Error') { @('Error') } else { @('Warning','Error') }

$findings = New-Object System.Collections.Generic.List[object]
foreach ($p in $Paths) {
    $params = @{
        Path        = $p
        Recurse     = $true
        Severity    = $severityArg
        ErrorAction = 'Continue'
    }
    if (Test-Path -LiteralPath $SettingsPath) { $params['Settings'] = $SettingsPath }
    if ($Fix) { $params['Fix'] = $true }
    $r = Invoke-ScriptAnalyzer @params
    if ($r) { $findings.AddRange([object[]]$r) }
}

if ($findings.Count -eq 0) {
    Write-Host "`nLint: clean ($($Paths.Count) target(s))." -ForegroundColor Green
    exit 0
}

Write-Host "`nLint findings ($($findings.Count)):" -ForegroundColor Red
$findings |
    Sort-Object @{Expression='Severity';Descending=$true}, ScriptPath, Line |
    Format-Table -AutoSize -Wrap RuleName, Severity, ScriptPath, Line, Message

exit 1

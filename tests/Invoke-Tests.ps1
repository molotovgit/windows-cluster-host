<#
.SYNOPSIS
    Run the Pester test suite for windows-cluster-host.

.DESCRIPTION
    Wraps Invoke-Pester with the project's preferred configuration:
      - Pester 5+ syntax (Discovery / It / Should -Be).
      - tests/unit/         unit tests with module-level mocks.
      - tests/integration/  end-to-end dry-runs (mocked Hyper-V / cmdlets).
    Auto-installs Pester 5 into CurrentUser scope if missing.

.PARAMETER Tags
    Optional Pester tags to filter. Default: all tags.

.PARAMETER Unit
    Run only tests/unit/.

.PARAMETER Integration
    Run only tests/integration/.

.PARAMETER Verbosity
    None | Minimal | Normal | Detailed | Diagnostic. Default Normal.

.OUTPUTS
    System.Int32 exit code (0 = all green, 1 = any failure).
#>

[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [string[]]$Tags,

    [Parameter(ParameterSetName = 'Unit')]
    [switch]$Unit,

    [Parameter(ParameterSetName = 'Integration')]
    [switch]$Integration,

    [ValidateSet('None','Minimal','Normal','Detailed','Diagnostic')]
    [string]$Verbosity = 'Normal',

    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$unitDir  = Join-Path $repoRoot 'tests\unit'
$intDir   = Join-Path $repoRoot 'tests\integration'

$rawPaths = switch ($PSCmdlet.ParameterSetName) {
    'Unit'        { @($unitDir) }
    'Integration' { @($intDir)  }
    default       { @($unitDir, $intDir) }
}
$paths = @($rawPaths | Where-Object { Test-Path -LiteralPath $_ })
if ($paths.Count -eq 0) {
    Write-Host "(no test directories exist yet under $repoRoot\tests; nothing to run)" -ForegroundColor DarkGray
    exit 0
}

# --- bootstrap Pester 5 if missing ---
$pesterAvail = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0.0' }
if (-not $pesterAvail) {
    if ($SkipInstall) {
        Write-Error "Pester 5+ is not installed and -SkipInstall was specified. Run: Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0.0 -SkipPublisherCheck"
        exit 2
    }
    Write-Host 'Pester 5+ not installed. Installing into CurrentUser scope (-SkipInstall to refuse)...' -ForegroundColor Yellow
    try {
        Install-Module -Name Pester -Scope CurrentUser -Force -ErrorAction Stop -SkipPublisherCheck -MinimumVersion 5.0.0
    } catch {
        Write-Error "Cannot install Pester 5 automatically. Install it manually with 'Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0.0 -SkipPublisherCheck' and retry. Underlying error: $($_.Exception.Message)"
        exit 2
    }
}
Import-Module Pester -MinimumVersion 5.0.0 -Force

# --- run ---
$cfg = New-PesterConfiguration
$cfg.Run.Path     = $paths
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = $Verbosity
if ($Tags) {
    $cfg.Filter.Tag = $Tags
}

Write-Host "Pester targets:" -ForegroundColor Cyan
$paths | ForEach-Object { Write-Host "  $_" }
if ($Tags) { Write-Host "  Tags: $($Tags -join ', ')" }

$r = Invoke-Pester -Configuration $cfg
"`nResult: Passed=$($r.PassedCount) Failed=$($r.FailedCount) Skipped=$($r.SkippedCount) Duration=$([math]::Round($r.Duration.TotalSeconds,2))s" | Write-Host -ForegroundColor Cyan

if ($r.FailedCount -gt 0) { exit 1 } else { exit 0 }

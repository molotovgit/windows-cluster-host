<#
.SYNOPSIS
    Run the full pre-peer-review sandbox: lint -> tests -> manifest check.

.DESCRIPTION
    A contributor / agent invokes this between writing code and submitting
    a PR for review. Order matches the project's REVIEW_PROCESS.md:

      1. PSScriptAnalyzer (severity Warning+Error)            -- tests/Invoke-Lint.ps1
      2. Pester unit suite                                   -- tests/Invoke-Tests.ps1 -Unit
      3. Pester integration suite (if any)                   -- tests/Invoke-Tests.ps1 -Integration
      4. Test-ModuleManifest for every src/lib/*.psd1        -- inline below

    Exits 0 only when every stage passes.

.PARAMETER SkipIntegration
    Skip stage 3 (useful while integration tests don't exist yet).

.PARAMETER StopOnFirstFailure
    Abort the harness after the first non-zero stage. Default is to run
    every stage even after a failure so contributors get the full picture
    in a single pass.

.PARAMETER SkipInstall
    Forwarded to Invoke-Lint / Invoke-Tests. Refuses to auto-install
    PSScriptAnalyzer / Pester when missing; emits an error with the manual
    install command instead.
#>

[CmdletBinding()]
param(
    [switch]$SkipIntegration,
    [switch]$StopOnFirstFailure,
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$stages = @()

$script:abort = $false
function Invoke-Stage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Block
    )
    if ($script:abort) { return }
    Write-Host "`n===== $Name =====" -ForegroundColor Yellow
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = 0
    try {
        & $Block
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } catch {
        $code = 99
        Write-Host "${Name}: THREW -- $($_.Exception.Message)" -ForegroundColor Red
    }
    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    $script:stages += [pscustomobject]@{ Name = $Name; ExitCode = $code; Seconds = $secs }
    if ($code -ne 0) { Write-Host "${Name}: FAIL ($code) in ${secs}s" -ForegroundColor Red }
    else             { Write-Host "${Name}: OK in ${secs}s" -ForegroundColor Green }
    if ($code -ne 0 -and $StopOnFirstFailure) {
        Write-Host "Stop-on-first-failure: aborting after $Name." -ForegroundColor Red
        $script:abort = $true
    }
}

$lintScript  = Join-Path $PSScriptRoot 'Invoke-Lint.ps1'
$testsScript = Join-Path $PSScriptRoot 'Invoke-Tests.ps1'

Invoke-Stage -Name 'Lint' -Block {
    if ($SkipInstall) { & $lintScript -SkipInstall } else { & $lintScript }
}

Invoke-Stage -Name 'Pester unit' -Block {
    if ($SkipInstall) { & $testsScript -Unit -Verbosity Minimal -SkipInstall }
    else              { & $testsScript -Unit -Verbosity Minimal }
}

if (-not $SkipIntegration -and (Test-Path -LiteralPath (Join-Path $repoRoot 'tests\integration'))) {
    $hasFiles = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests\integration') -Filter '*.Tests.ps1' -Recurse -ErrorAction SilentlyContinue
    if ($hasFiles) {
        Invoke-Stage -Name 'Pester integration' -Block {
            if ($SkipInstall) { & $testsScript -Integration -Verbosity Minimal -SkipInstall }
            else              { & $testsScript -Integration -Verbosity Minimal }
        }
    } else {
        Write-Host "`n(no integration tests yet)" -ForegroundColor DarkGray
    }
}

# Manifests stage: do NOT exit from inside the scriptblock -- the parent
# script must run the summary table even on failure. Use $global:LASTEXITCODE
# so the caller's $LASTEXITCODE capture on the next line picks it up.
Invoke-Stage -Name 'Manifests' -Block {
    $manifests = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src\lib') -Filter '*.psd1' -Recurse -ErrorAction SilentlyContinue
    if (-not $manifests) { Write-Host '(no manifests to verify)' -ForegroundColor DarkGray; return }
    $failed = 0
    foreach ($m in $manifests) {
        try {
            $mf = Test-ModuleManifest -Path $m.FullName -ErrorAction Stop
            Write-Host ("  OK  {0}  v{1}  ({2} exports)" -f $m.Name, $mf.Version, $mf.ExportedFunctions.Count)
        } catch {
            Write-Host ("  FAIL {0}: {1}" -f $m.Name, $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    }
    $global:LASTEXITCODE = if ($failed -gt 0) { 1 } else { 0 }
}

# Summary
Write-Host "`n===== Sandbox summary =====" -ForegroundColor Yellow
$stages | Format-Table -AutoSize Name, ExitCode, Seconds

$bad = @($stages | Where-Object { $_.ExitCode -ne 0 })
if ($bad.Count -gt 0) {
    Write-Host "Sandbox FAILED ($($bad.Count) stage(s)):" -ForegroundColor Red
    $bad | ForEach-Object { Write-Host "  - $($_.Name) (exit $($_.ExitCode))" -ForegroundColor Red }
    exit 1
}
Write-Host "Sandbox OK." -ForegroundColor Green
exit 0

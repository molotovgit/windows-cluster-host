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
#>

[CmdletBinding()]
param(
    [switch]$SkipIntegration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$stages = @()

function Invoke-Stage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Block
    )
    Write-Host "`n===== $Name =====" -ForegroundColor Yellow
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Block
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        $sw.Stop()
        $script:stages += [pscustomobject]@{ Name = $Name; ExitCode = $code; Seconds = [math]::Round($sw.Elapsed.TotalSeconds,2) }
        if ($code -ne 0) { Write-Host "${Name}: FAIL ($code) in $($sw.Elapsed.TotalSeconds)s" -ForegroundColor Red }
        else             { Write-Host "${Name}: OK in $($sw.Elapsed.TotalSeconds)s" -ForegroundColor Green }
    } catch {
        $sw.Stop()
        $script:stages += [pscustomobject]@{ Name = $Name; ExitCode = 99; Seconds = [math]::Round($sw.Elapsed.TotalSeconds,2) }
        Write-Host "${Name}: THREW -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

Invoke-Stage -Name 'Lint' -Block {
    & (Join-Path $PSScriptRoot 'Invoke-Lint.ps1')
}

Invoke-Stage -Name 'Pester unit' -Block {
    & (Join-Path $PSScriptRoot 'Invoke-Tests.ps1') -Unit -Verbosity Minimal
}

if (-not $SkipIntegration -and (Test-Path -LiteralPath (Join-Path $repoRoot 'tests\integration'))) {
    $hasFiles = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests\integration') -Filter '*.Tests.ps1' -Recurse -ErrorAction SilentlyContinue
    if ($hasFiles) {
        Invoke-Stage -Name 'Pester integration' -Block {
            & (Join-Path $PSScriptRoot 'Invoke-Tests.ps1') -Integration -Verbosity Minimal
        }
    } else {
        Write-Host "`n(no integration tests yet)" -ForegroundColor DarkGray
    }
}

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
    if ($failed -gt 0) { $script:LASTEXITCODE = 1; exit 1 }
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

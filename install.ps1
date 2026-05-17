<#
.SYNOPSIS
    One-liner bootstrap for the windows-cluster-host setup.

.DESCRIPTION
    Operator copy-paste at an elevated PowerShell prompt:

        $env:CLUSTERHOST_CONTROLLER = '10.0.0.7'   # optional: pin the controller
        iwr -useb https://10.0.0.7/install.ps1 | iex

    Or, with the repo already on disk:

        .\install.ps1 -ControllerAddress 10.0.0.7

    Steps the bootstrap performs:
      1. Check PowerShell version (>= 7); refuse to run under Windows PowerShell 5.1
         and print the upgrade pointer.
      2. Check admin rights; refuse to run unelevated.
      3. Resolve / create the staging directory under -StagingRoot
         (default %ProgramData%\ClusterHost\src).
      4. Source the repo:
           - If -SourceZip is supplied, expand it.
           - Else if the script is already running from inside the repo
             (cluster-host root sibling files visible), copy the repo
             tree to the staging directory.
           - Else download a zipball from -ControllerAddress
             (https://<addr>/cluster-host.zip by default) and expand it.
      5. Optionally write a starter cluster-config.json in
         <StagingRoot>\config\ when -WriteConfig is set.
      6. Invoke <StagingRoot>\src\Invoke-ClusterHostSetup.ps1 with any
         orchestrator-bound parameters forwarded (-Resume, -DryRun, etc.).

    Exit codes are forwarded from the orchestrator: 0 / 1 / 2 / 3.
#>

[CmdletBinding()]
param(
    [string]$ControllerAddress,
    [string]$SourceZip,
    [string]$ZipUrl,
    [string]$StagingRoot = (Join-Path $env:ProgramData 'ClusterHost\src'),
    [string]$ConfigPath,
    [switch]$WriteConfig,
    [switch]$Resume,
    [switch]$DryRun,
    [switch]$NoRestart,
    [switch]$SkipDownload,
    [switch]$AllowSelfSignedController,
    [string]$LogDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = [System.Security.Principal.WindowsPrincipal]::new($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)
    } catch { return $false }
}

function Assert-Prerequisite {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$FailureMessage,[int]$ExitCode = 10)
    if (-not $Condition) {
        Write-Host $FailureMessage -ForegroundColor Red
        exit $ExitCode
    }
}

function Resolve-ZipUrl {
    param([string]$Address,[string]$Override)
    if ($Override) { return $Override }
    if (-not $Address) { return $null }
    return "https://$Address/cluster-host.zip"
}

function Confirm-StagingRootSafe {
    # Guard against an operator passing a -StagingRoot like 'C:\' or a
    # populated unrelated directory: only wipe a path that either does not
    # exist OR contains a previous staging marker.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $marker = Join-Path $Path '.clusterhost-staging'
    $hasContent = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -gt 0
    if ($hasContent -and -not (Test-Path -LiteralPath $marker)) {
        throw "Refusing to wipe '$Path' -- it is non-empty and does not contain the .clusterhost-staging marker file. Pass an empty -StagingRoot or remove it manually."
    }
}

function Copy-RepoTree {
    # When install.ps1 lives inside a checked-out repo, copy that tree to
    # the staging directory (one-shot install from a USB stick or local
    # share). Returns the resolved repo root or $null.
    param([Parameter(Mandatory)][string]$ScriptRoot,[Parameter(Mandatory)][string]$Destination)
    $expected = @('src','config','REVIEW_PROMPT.md')
    $missing  = @($expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ScriptRoot $_)) })
    if ($missing.Count -gt 0) { return $null }   # not inside a repo
    Confirm-StagingRootSafe -Path $Destination
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    # Drop the staging-dir marker so re-runs can safely wipe.
    Set-Content -LiteralPath (Join-Path $Destination '.clusterhost-staging') -Value 'managed-by-install.ps1' -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $ScriptRoot 'src')    -Destination $Destination -Recurse -Force -ErrorAction Stop
    if (Test-Path (Join-Path $ScriptRoot 'config'))  { Copy-Item -LiteralPath (Join-Path $ScriptRoot 'config')  -Destination $Destination -Recurse -Force }
    if (Test-Path (Join-Path $ScriptRoot 'scripts')) { Copy-Item -LiteralPath (Join-Path $ScriptRoot 'scripts') -Destination $Destination -Recurse -Force }
    return $Destination
}

function Expand-RepoZip {
    param([Parameter(Mandatory)][string]$Zip,[Parameter(Mandatory)][string]$Destination)
    Confirm-StagingRootSafe -Path $Destination
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Destination '.clusterhost-staging') -Value 'managed-by-install.ps1' -Encoding utf8
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force -ErrorAction Stop
    # The zip is expected to contain a top-level folder. Flatten if needed
    # so $Destination\src exists rather than $Destination\<top>\src.
    $top = @(Get-ChildItem -LiteralPath $Destination -Directory)
    if ($top.Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $Destination 'src'))) {
        Get-ChildItem -LiteralPath $top[0].FullName -Force | Move-Item -Destination $Destination -Force
        Remove-Item -LiteralPath $top[0].FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $Destination
}

function Invoke-WithRetryWebRequest {
    # Tiny built-in retry. We avoid importing lib/Retry.psm1 because the
    # bootstrap runs BEFORE the repo is on disk.
    # SkipCertificateCheck is opt-IN because the project's LAN model
    # commonly uses self-signed certs; the caller must explicitly state
    # so it appears in the operator's transcript.
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$Attempts = 3,
        [switch]$AllowSelfSigned
    )
    if ($AllowSelfSigned) {
        Write-Warning "TLS certificate validation DISABLED for $Url (operator opted in via -AllowSelfSignedController)."
    }
    $delay = 500
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            if ($AllowSelfSigned) {
                Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -SkipCertificateCheck -ErrorAction Stop
            } else {
                Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            }
            return
        } catch {
            if ($i -eq $Attempts) { throw }
            Start-Sleep -Milliseconds $delay
            $delay = $delay * 2
        }
    }
}

function Write-StarterConfig {
    param([Parameter(Mandatory)][string]$Path,[string]$Controller)
    $cfg = [ordered]@{
        controller = [ordered]@{
            address  = if ($Controller) { $Controller } else { $null }
            port     = 443
            protocol = 'https'
        }
        network = [ordered]@{
            nat_switch_name = 'ClusterNATSwitch'
            nat_candidate_subnets = @('192.168.100.0/24','192.168.150.0/24','172.20.50.0/24','10.50.0.0/24')
        }
        vms = [ordered]@{
            count               = 2
            name_prefix         = 'vm-'
            min_disk_gb_per_vm  = 60
            memory_startup_gb   = 4
            memory_min_gb       = 2
            memory_max_gb       = 6
            vcpu_count          = 2
            stagger_seconds     = 30
            secure_boot_template = 'MicrosoftWindows'
        }
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $json = $cfg | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

# ---------- main ----------

# Tests dot-source install.ps1 with CLUSTERHOST_NOAUTORUN=1 to pull the
# helpers into scope without running the main body. Production paths
# leave the env var unset.
if ($env:CLUSTERHOST_NOAUTORUN -eq '1') { return }

Write-Host '== windows-cluster-host bootstrap ==' -ForegroundColor Cyan
Write-Host "PowerShell : $($PSVersionTable.PSVersion)"
Write-Host "User       : $env:USERDOMAIN\$env:USERNAME"
Write-Host "StagingRoot: $StagingRoot"
Write-Host ""

if ($PSVersionTable.PSVersion -lt [version]'7.0') {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Write-Host 'Detected Windows PowerShell 5.1 (Desktop edition). The cluster setup requires PowerShell 7+.' -ForegroundColor Red
        Write-Host 'Install PowerShell 7 via:'  -ForegroundColor Yellow
        Write-Host '  winget install --id Microsoft.PowerShell -e'   -ForegroundColor Yellow
        Write-Host 'Then re-open as Administrator and re-run under pwsh.exe (NOT powershell.exe):' -ForegroundColor Yellow
        Write-Host '  pwsh -File .\install.ps1' -ForegroundColor Yellow
    } else {
        Write-Host 'This script requires PowerShell 7+. Install from https://aka.ms/PowerShell and re-run under pwsh.' -ForegroundColor Red
    }
    exit 11
}
Assert-Prerequisite -Condition (Test-IsAdministrator) `
                     -FailureMessage 'This script requires Administrator rights. Right-click PowerShell and Run as Administrator.' `
                     -ExitCode 12

# Optional: pin a log directory before the orchestrator initialises Logging.
if ($LogDir) { $env:CLUSTERHOST_LOG_DIR = $LogDir }

# 1. Source the repo.
$resolvedRoot = $null
if (-not $SkipDownload) {
    if ($SourceZip) {
        Assert-Prerequisite -Condition (Test-Path -LiteralPath $SourceZip) `
                             -FailureMessage "Source zip not found at $SourceZip." -ExitCode 13
        Write-Host "Expanding $SourceZip -> $StagingRoot" -ForegroundColor Yellow
        $resolvedRoot = Expand-RepoZip -Zip $SourceZip -Destination $StagingRoot
    } else {
        # If install.ps1 lives next to src/ + config/, copy the repo locally.
        $local = Copy-RepoTree -ScriptRoot $PSScriptRoot -Destination $StagingRoot
        if ($local) {
            Write-Host "Copied repo from $PSScriptRoot -> $StagingRoot" -ForegroundColor Yellow
            $resolvedRoot = $local
        } else {
            $url = Resolve-ZipUrl -Address $ControllerAddress -Override $ZipUrl
            Assert-Prerequisite -Condition ([bool]$url) `
                                 -FailureMessage 'No -SourceZip, no local repo, and no -ControllerAddress / -ZipUrl given. Cannot source the repo.' `
                                 -ExitCode 14
            $tmpZip = Join-Path $env:TEMP ("cluster-host-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.zip')
            Write-Host "Downloading $url -> $tmpZip" -ForegroundColor Yellow
            try {
                Invoke-WithRetryWebRequest -Url $url -OutFile $tmpZip -Attempts 3 -AllowSelfSigned:$AllowSelfSignedController
                $resolvedRoot = Expand-RepoZip -Zip $tmpZip -Destination $StagingRoot
            } finally {
                Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
            }
        }
    }
} else {
    Write-Host '-SkipDownload set; using existing staging root.' -ForegroundColor Yellow
    $resolvedRoot = $StagingRoot
}

Assert-Prerequisite -Condition (Test-Path -LiteralPath (Join-Path $resolvedRoot 'src\Invoke-ClusterHostSetup.ps1')) `
                     -FailureMessage "Staged repo at $resolvedRoot is missing src\Invoke-ClusterHostSetup.ps1." `
                     -ExitCode 15

# 2. Optional starter config.
if (-not $ConfigPath) { $ConfigPath = Join-Path $resolvedRoot 'config\cluster-config.json' }
if ($WriteConfig -and -not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "Writing starter cluster-config.json -> $ConfigPath" -ForegroundColor Yellow
    Write-StarterConfig -Path $ConfigPath -Controller $ControllerAddress
}

# 3. Invoke the orchestrator.
$orch = Join-Path $resolvedRoot 'src\Invoke-ClusterHostSetup.ps1'
$orchArgs = @()
$orchArgs += @('-ConfigPath', $ConfigPath)
if ($Resume)     { $orchArgs += '-Resume' }
if ($DryRun)     { $orchArgs += '-DryRun' }
if ($NoRestart)  { $orchArgs += '-NoRestart' }

Write-Host ""
Write-Host "== Launching orchestrator ==" -ForegroundColor Cyan
Write-Host "  & $orch $($orchArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

try {
    & $orch @orchArgs
    $exit = $LASTEXITCODE
    if ($null -eq $exit) { $exit = 0 }
} catch {
    Write-Host "Orchestrator threw: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    $exit = 3
}
exit $exit

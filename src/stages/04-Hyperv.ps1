<#
.SYNOPSIS
    Stage 4 -- Hyper-V. Enable the Hyper-V Windows feature and signal a
    reboot when required so the orchestrator can resume after restart.

.DESCRIPTION
    Probes Hyper-V state, then enables it with three fallback methods:

      1. Enable-WindowsOptionalFeature -Online -NoRestart (primary)
      2. dism.exe /online /enable-feature ... /norestart  (fallback 1)
      3. Add-WindowsCapability -Online                    (fallback 2)

    Feature name: Microsoft-Hyper-V-All.

    The stage NEVER calls Restart-Computer itself. Instead, it returns
    Overall='RebootRequired' when a reboot is needed; the orchestrator
    (PR 16) is responsible for:
      - Save-StageMarker (already on the right stage number)
      - Register-ResumeTask
      - Restart-Computer
    On the post-reboot resume, the orchestrator re-enters this stage and
    the probe finds Hyper-V already enabled -> Overall='Pass'.

    -DryRun reports what would change without enabling anything.

    Returns: pscustomobject @{
        Overall = 'Pass' | 'RebootRequired' | 'Fail';
        Method  = 'AlreadyEnabled' | 'WindowsOptionalFeature' | 'DISM' |
                  'WindowsCapability' | 'DryRun' | 'None';
        State; RebootRequired; Detail; Remediation
    }

.NOTES
    Test seam: $script:HypervInvokers maps the eight cmdlets/helpers used
    to closures. Set-HypervInvoker / Reset-HypervInvoker gated by
    CLUSTERHOST_ALLOW_TEST_SEAMS.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Soft-load sibling lib modules.
$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Retry') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

$script:HypervFeatureName = 'Microsoft-Hyper-V-All'

# ---------- invoker seam ----------

function Get-DefaultHypervInvoker {
    @{
        # Returns @{ State; RestartNeeded } for the Hyper-V feature. State is
        # one of 'Enabled' | 'Disabled' | 'EnablePending' | 'Unknown'.
        GetFeatureState = {
            try {
                $f = Get-WindowsOptionalFeature -Online -FeatureName $script:HypervFeatureName -ErrorAction Stop
                return @{
                    State          = "$($f.State)"
                    RestartNeeded  = ("$($f.RestartNeeded)" -eq 'Required')
                }
            } catch {
                $null = $_
                return @{ State = 'Unknown'; RestartNeeded = $false }
            }
        }
        EnableViaCmdlet = {
            try {
                $r = Enable-WindowsOptionalFeature -Online -FeatureName $script:HypervFeatureName `
                                                   -NoRestart -All -ErrorAction Stop
                return @{
                    Ok            = $true
                    RestartNeeded = ("$($r.RestartNeeded)" -eq 'Required')
                    Detail        = "Enable-WindowsOptionalFeature succeeded; RestartNeeded=$($r.RestartNeeded)."
                }
            } catch {
                return @{ Ok = $false; RestartNeeded = $false; Detail = "Enable-WindowsOptionalFeature failed: $($_.Exception.Message)" }
            }
        }
        EnableViaDism = {
            try {
                $args = @('/online','/enable-feature',"/featurename:$script:HypervFeatureName",'/all','/norestart','/quiet')
                $out  = & dism.exe @args 2>&1
                $code = $LASTEXITCODE
                # DISM exit 0 = success+no-restart, 3010 = success+restart-required.
                $ok            = ($code -eq 0 -or $code -eq 3010)
                $restartNeeded = ($code -eq 3010)
                return @{
                    Ok            = $ok
                    RestartNeeded = $restartNeeded
                    Detail        = "DISM exit=$code RestartNeeded=$restartNeeded. Output: $($out -join ' | ')"
                }
            } catch {
                return @{ Ok = $false; RestartNeeded = $false; Detail = "DISM threw: $($_.Exception.Message)" }
            }
        }
        EnableViaCapability = {
            try {
                # Add-WindowsCapability covers some Hyper-V management surface
                # but the platform feature itself isn't a capability on Win11.
                # We still try it as a last resort; if the capability name is
                # not recognized this returns Ok=false with a clear message.
                $r = Add-WindowsCapability -Online -Name 'Hyper-V~~~~' -ErrorAction Stop
                return @{
                    Ok            = $true
                    RestartNeeded = ("$($r.RestartNeeded)" -eq 'Required')
                    Detail        = "Add-WindowsCapability succeeded; RestartNeeded=$($r.RestartNeeded)."
                }
            } catch {
                return @{ Ok = $false; RestartNeeded = $false; Detail = "Add-WindowsCapability failed: $($_.Exception.Message)" }
            }
        }
    }
}

$script:HypervInvokers = Get-DefaultHypervInvoker

function Confirm-TestSeamAllowed {
    if (-not $env:CLUSTERHOST_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERHOST_ALLOW_TEST_SEAMS=1 to enable Set-HypervInvoker / Reset-HypervInvoker."
    }
}

function Set-HypervInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-TestSeamAllowed
    if (-not $script:HypervInvokers.ContainsKey($Name)) {
        throw "Set-HypervInvoker: unknown invoker '$Name'. Known: $(($script:HypervInvokers.Keys | Sort-Object) -join ', ')"
    }
    $script:HypervInvokers[$Name] = $ScriptBlock
}

function Reset-HypervInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-TestSeamAllowed
    $script:HypervInvokers = Get-DefaultHypervInvoker
}

# ---------- public ----------

function Invoke-HypervStage {
    <#
    .SYNOPSIS Probe + enable the Hyper-V feature with primary + 2 fallbacks.

    .OUTPUTS
        pscustomobject @{ Overall; Method; State; RebootRequired; Detail; Remediation }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Stage entry point; enables a documented Windows optional feature. -DryRun honored.')]
    [CmdletBinding()]
    param(
        [switch]$DryRun
    )

    # ---------- probe ----------
    $probe = & $script:HypervInvokers.GetFeatureState
    $state = "$($probe.State)"
    $stateRebootNeeded = [bool]$probe.RestartNeeded

    if ($state -eq 'Enabled' -and -not $stateRebootNeeded) {
        $result = [pscustomobject]@{
            Overall        = 'Pass'
            Method         = 'AlreadyEnabled'
            State          = $state
            RebootRequired = $false
            Detail         = 'Hyper-V (Microsoft-Hyper-V-All) is already Enabled and not pending a restart.'
            Remediation    = $null
        }
        Write-HypervLog $result
        return $result
    }

    if ($state -eq 'Enabled' -and $stateRebootNeeded) {
        # Feature is Enabled but a restart is still pending. Tell the
        # orchestrator to reboot+resume.
        $result = [pscustomobject]@{
            Overall        = 'RebootRequired'
            Method         = 'AlreadyEnabled'
            State          = $state
            RebootRequired = $true
            Detail         = 'Hyper-V is Enabled but a restart is required to finish activation.'
            Remediation    = 'Orchestrator: register the resume task and restart the host.'
        }
        Write-HypervLog $result
        return $result
    }

    if ($DryRun) {
        $result = [pscustomobject]@{
            Overall        = 'Pass'
            Method         = 'DryRun'
            State          = $state
            RebootRequired = $false
            Detail         = "DryRun: would enable $script:HypervFeatureName (current state: $state)."
            Remediation    = $null
        }
        Write-HypervLog $result
        return $result
    }

    # ---------- enable: primary + fallbacks ----------
    $attempts = @()

    $a1 = & $script:HypervInvokers.EnableViaCmdlet
    $attempts += @{ Method = 'WindowsOptionalFeature'; Ok = $a1.Ok; RestartNeeded = $a1.RestartNeeded; Detail = $a1.Detail }
    if ($a1.Ok) { return New-HypervResult -State $state -Attempts $attempts -Winner 'WindowsOptionalFeature' }

    $a2 = & $script:HypervInvokers.EnableViaDism
    $attempts += @{ Method = 'DISM'; Ok = $a2.Ok; RestartNeeded = $a2.RestartNeeded; Detail = $a2.Detail }
    if ($a2.Ok) { return New-HypervResult -State $state -Attempts $attempts -Winner 'DISM' }

    $a3 = & $script:HypervInvokers.EnableViaCapability
    $attempts += @{ Method = 'WindowsCapability'; Ok = $a3.Ok; RestartNeeded = $a3.RestartNeeded; Detail = $a3.Detail }
    if ($a3.Ok) { return New-HypervResult -State $state -Attempts $attempts -Winner 'WindowsCapability' }

    # All three failed.
    $result = [pscustomobject]@{
        Overall        = 'Fail'
        Method         = 'None'
        State          = $state
        RebootRequired = $false
        Detail         = "Every enable strategy failed: " + (($attempts | ForEach-Object { "[$($_.Method): $($_.Detail)]" }) -join ' / ')
        Remediation    = @(
            'Three enable strategies failed. Manual recovery options:'
            '  1. Verify the host is Windows 11 Pro/Enterprise/Education (Preflight passes this gate).'
            '  2. As Administrator: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All'
            '  3. As Administrator: dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart'
            '  4. Confirm Windows Update has applied recent CU; some Hyper-V packages ship via Servicing.'
        ) -join "`n"
    }
    Write-HypervLog $result
    return $result
}

function New-HypervResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Pure helper: builds a result pscustomobject.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][object[]]$Attempts,
        [Parameter(Mandatory)][string]$Winner
    )
    $winnerRec = $Attempts | Where-Object { $_.Method -eq $Winner } | Select-Object -First 1
    $rebootNeeded = [bool]$winnerRec.RestartNeeded
    $overall      = if ($rebootNeeded) { 'RebootRequired' } else { 'Pass' }
    $remed        = if ($rebootNeeded) { 'Orchestrator: register the resume task and restart the host.' } else { $null }
    $result = [pscustomobject]@{
        Overall        = $overall
        Method         = $Winner
        State          = $State
        RebootRequired = $rebootNeeded
        Detail         = "Hyper-V enabled via $Winner. $($winnerRec.Detail)"
        Remediation    = $remed
    }
    Write-HypervLog $result
    return $result
}

function Write-HypervLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result)
    if (-not (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue)) { return }
    $lvl = switch ($Result.Overall) {
        'Pass'           { 'Info' }
        'RebootRequired' { 'Warn' }
        'Fail'           { 'Error' }
        default          { 'Info' }
    }
    Write-ClusterLog -Level $lvl -Stage 'hyperv' -Message "Hyper-V stage: $($Result.Overall) via $($Result.Method)" -Data @{
        state          = $Result.State
        rebootRequired = $Result.RebootRequired
    }
}

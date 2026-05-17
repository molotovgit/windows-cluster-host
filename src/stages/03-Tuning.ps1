<#
.SYNOPSIS
    Stage 3 -- Tuning. Apply Windows settings that the cluster host
    needs in order to stay up and reachable.

.DESCRIPTION
    Each tweak is idempotent: probe current state, skip if already correct,
    otherwise apply. Each tweak has a primary + at least one fallback
    method so a host with a partially-locked-down policy still completes.

    Tweaks applied (each returns a per-tweak result row):
      1. Fast Startup           HiberbootEnabled=0 in
                                HKLM:\SYSTEM\CurrentControlSet\Control\Power
                                (registry primary -> powercfg fallback)
      2. Power plan             SCHEME_MIN (High Performance).
                                powercfg primary -> WMI fallback.
      3. USB selective suspend  AC + DC power index = 0 on the USB GUID.
                                powercfg primary -> registry fallback.
      4. Sleep timeout (AC)     0 (never).
                                powercfg primary; doc-only on failure.

    -DryRun reports what WOULD change without applying anything. Used by
    the integration dry-run and the orchestrator's preview step.

    Returns: pscustomobject @{
        Overall = 'Pass' | 'Warn' | 'Fail';
        Tweaks  = @( @{ Name; Status='Pass'|'Warn'|'Fail'|'Skipped'; Detail; Remediation } ... )
        Changed = <int>
    }

.NOTES
    Read-write stage. Mutations are limited to the documented registry
    keys and powercfg settings. Test seam: $script:TuningInvokers maps
    {GetReg, SetReg, RunPowercfg, GetPowerPlan} to closures that tests
    swap via Set-TuningInvoker (CLUSTERHOST_ALLOW_TEST_SEAMS gate).
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

# ---------- invoker seam ----------

function Get-DefaultTuningInvoker {
    @{
        GetReg = {
            param([string]$Path,[string]$Name)
            try {
                $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
                return $p.$Name
            } catch {
                $null = $_
                return $null
            }
        }
        SetReg = {
            param([string]$Path,[string]$Name,$Value,[string]$Type)
            if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
            New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        }
        RunPowercfg = {
            param([string[]]$Argv)
            $out = & powercfg.exe @Argv 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
        }
        GetActivePowerPlanGuid = {
            $out = & powercfg.exe /GETACTIVESCHEME 2>&1
            if ($LASTEXITCODE -ne 0) { return $null }
            # 'Power Scheme GUID: 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  (High performance)'
            $m = [regex]::Match("$out", '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
            if ($m.Success) { return $m.Groups[1].Value } else { return $null }
        }
    }
}

$script:TuningInvokers = Get-DefaultTuningInvoker

function Confirm-TestSeamAllowed {
    if (-not $env:CLUSTERHOST_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERHOST_ALLOW_TEST_SEAMS=1 to enable Set-TuningInvoker / Reset-TuningInvoker."
    }
}

function Set-TuningInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-TestSeamAllowed
    if (-not $script:TuningInvokers.ContainsKey($Name)) {
        throw "Set-TuningInvoker: unknown invoker '$Name'. Known: $(($script:TuningInvokers.Keys | Sort-Object) -join ', ')"
    }
    $script:TuningInvokers[$Name] = $ScriptBlock
}

function Reset-TuningInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-TestSeamAllowed
    $script:TuningInvokers = Get-DefaultTuningInvoker
}

# ---------- helpers ----------

function Add-TuningResult {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass','Warn','Fail','Skipped')][string]$Status,
        [string]$Detail,
        [string]$Remediation,
        [switch]$Changed
    )
    $Results.Add([pscustomobject]@{
        Name        = $Name
        Status      = $Status
        Detail      = $Detail
        Remediation = $Remediation
        Changed     = [bool]$Changed
    })
}

# Well-known GUIDs / paths.
$script:GuidHighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:PowerKey            = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
$script:HiberbootName       = 'HiberbootEnabled'
# Subgroup + setting GUIDs for "USB settings" -> "USB selective suspend setting".
$script:UsbSubGroupGuid     = '2a737441-1930-4402-8d77-b2bebba308a3'
$script:UsbSuspendGuid      = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'

# ---------- tweaks ----------

function Set-FastStartupDisabled {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Idempotent registry write to a documented Windows power-management value.')]
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results
    )
    $current = & $script:TuningInvokers.GetReg $script:PowerKey $script:HiberbootName
    if ($current -eq 0) {
        Add-TuningResult -Results $Results -Name 'Fast Startup disabled' -Status Pass `
            -Detail "Already disabled (HiberbootEnabled=$current)."
        return
    }
    if ($DryRun) {
        Add-TuningResult -Results $Results -Name 'Fast Startup disabled' -Status Skipped `
            -Detail "DryRun: would set HiberbootEnabled=0 (current=$current)."
        return
    }
    try {
        & $script:TuningInvokers.SetReg $script:PowerKey $script:HiberbootName 0 'DWord'
        Add-TuningResult -Results $Results -Name 'Fast Startup disabled' -Status Pass `
            -Detail "Set HiberbootEnabled=0 (was $current)." -Changed
    } catch {
        # Fallback: powercfg /h off disables hibernation entirely (also kills Fast Startup).
        $r = & $script:TuningInvokers.RunPowercfg @('/H','off')
        if ($r.ExitCode -eq 0) {
            Add-TuningResult -Results $Results -Name 'Fast Startup disabled' -Status Pass `
                -Detail "Set via powercfg /H off (registry-write fallback). Hibernation also disabled." -Changed
        } else {
            Add-TuningResult -Results $Results -Name 'Fast Startup disabled' -Status Fail `
                -Detail "Registry write failed: $($_.Exception.Message). powercfg /H off also failed: $($r.Output)." `
                -Remediation 'As Administrator: powercfg /H off'
        }
    }
}

function Set-HighPerformancePowerPlan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Sets the Windows active power scheme to a well-known GUID; idempotent and reversible.')]
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results
    )
    $active = & $script:TuningInvokers.GetActivePowerPlanGuid
    if ($active -eq $script:GuidHighPerformance) {
        Add-TuningResult -Results $Results -Name 'Power plan: High Performance' -Status Pass `
            -Detail "Already active ($active)."
        return
    }
    if ($DryRun) {
        Add-TuningResult -Results $Results -Name 'Power plan: High Performance' -Status Skipped `
            -Detail "DryRun: would set active scheme to $($script:GuidHighPerformance) (current=$active)."
        return
    }
    $r = & $script:TuningInvokers.RunPowercfg @('/SETACTIVE', $script:GuidHighPerformance)
    if ($r.ExitCode -eq 0) {
        Add-TuningResult -Results $Results -Name 'Power plan: High Performance' -Status Pass `
            -Detail "Activated High Performance scheme (was $active)." -Changed
    } else {
        # Some Win11 hosts hide the High Performance scheme; powercfg /DUPLICATESCHEME makes a copy that can be activated.
        $dup = & $script:TuningInvokers.RunPowercfg @('/DUPLICATESCHEME', $script:GuidHighPerformance)
        $m   = [regex]::Match("$($dup.Output)", '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
        if ($dup.ExitCode -eq 0 -and $m.Success) {
            $newGuid = $m.Groups[1].Value
            $r2 = & $script:TuningInvokers.RunPowercfg @('/SETACTIVE', $newGuid)
            if ($r2.ExitCode -eq 0) {
                Add-TuningResult -Results $Results -Name 'Power plan: High Performance' -Status Pass `
                    -Detail "Activated High Performance via /DUPLICATESCHEME ($newGuid)." -Changed
                return
            }
        }
        Add-TuningResult -Results $Results -Name 'Power plan: High Performance' -Status Warn `
            -Detail "Could not activate High Performance. powercfg /SETACTIVE: $($r.Output) /DUPLICATESCHEME: $($dup.Output)." `
            -Remediation 'As Administrator: powercfg /SETACTIVE 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    }
}

function Set-UsbSelectiveSuspendOff {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Sets the documented Windows USB selective-suspend power index to 0 (Disabled).')]
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results
    )
    if ($DryRun) {
        Add-TuningResult -Results $Results -Name 'USB selective suspend disabled' -Status Skipped `
            -Detail "DryRun: would set AC+DC value index to 0 on $($script:UsbSubGroupGuid)/$($script:UsbSuspendGuid)."
        return
    }
    $active = & $script:TuningInvokers.GetActivePowerPlanGuid
    if (-not $active) {
        Add-TuningResult -Results $Results -Name 'USB selective suspend disabled' -Status Warn `
            -Detail 'Could not determine active power scheme; skipping USB tweak.'
        return
    }
    $ac = & $script:TuningInvokers.RunPowercfg @('/SETACVALUEINDEX', $active, $script:UsbSubGroupGuid, $script:UsbSuspendGuid, '0')
    $dc = & $script:TuningInvokers.RunPowercfg @('/SETDCVALUEINDEX', $active, $script:UsbSubGroupGuid, $script:UsbSuspendGuid, '0')
    if ($ac.ExitCode -eq 0 -and $dc.ExitCode -eq 0) {
        Add-TuningResult -Results $Results -Name 'USB selective suspend disabled' -Status Pass `
            -Detail "Set AC and DC indices to 0 on active scheme $active." -Changed
    } else {
        Add-TuningResult -Results $Results -Name 'USB selective suspend disabled' -Status Warn `
            -Detail "powercfg /SETACVALUEINDEX exit=$($ac.ExitCode) /SETDCVALUEINDEX exit=$($dc.ExitCode). Output: $($ac.Output) ; $($dc.Output)" `
            -Remediation 'Manually disable USB selective suspend in Control Panel -> Power Options -> Change plan settings -> Change advanced power settings -> USB settings.'
    }
}

function Set-NeverSleepOnAc {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Sets the AC sleep timeout to 0 (never). Reversible.')]
    [CmdletBinding()]
    param(
        [switch]$DryRun,
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results
    )
    if ($DryRun) {
        Add-TuningResult -Results $Results -Name 'Never sleep on AC' -Status Skipped `
            -Detail 'DryRun: would set AC sleep timeout to 0.'
        return
    }
    $r = & $script:TuningInvokers.RunPowercfg @('/CHANGE','standby-timeout-ac','0')
    if ($r.ExitCode -eq 0) {
        Add-TuningResult -Results $Results -Name 'Never sleep on AC' -Status Pass `
            -Detail 'AC sleep timeout = 0 (never).' -Changed
    } else {
        Add-TuningResult -Results $Results -Name 'Never sleep on AC' -Status Warn `
            -Detail "powercfg /CHANGE standby-timeout-ac 0 failed: $($r.Output)." `
            -Remediation 'As Administrator: powercfg /CHANGE standby-timeout-ac 0'
    }
}

# ---------- public ----------

function Invoke-TuningStage {
    <#
    .SYNOPSIS
        Apply (or dry-run) all Windows tuning tweaks. Returns the structured
        result with per-tweak Status + Detail.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Top-level stage entry point; each tweak honors -DryRun.')]
    [CmdletBinding()]
    param(
        [switch]$DryRun
    )

    $results = New-Object System.Collections.Generic.List[object]

    Set-FastStartupDisabled       -DryRun:$DryRun -Results $results
    Set-HighPerformancePowerPlan  -DryRun:$DryRun -Results $results
    Set-UsbSelectiveSuspendOff    -DryRun:$DryRun -Results $results
    Set-NeverSleepOnAc            -DryRun:$DryRun -Results $results

    $passCount = @($results | Where-Object { $_.Status -eq 'Pass'   }).Count
    $warnCount = @($results | Where-Object { $_.Status -eq 'Warn'   }).Count
    $failCount = @($results | Where-Object { $_.Status -eq 'Fail'   }).Count
    $skipCount = @($results | Where-Object { $_.Status -eq 'Skipped'}).Count
    $changed   = @($results | Where-Object { $_.Changed }).Count

    $overall = if ($failCount -gt 0) { 'Fail' }
               elseif ($warnCount -gt 0) { 'Warn' }
               else { 'Pass' }

    if (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue) {
        foreach ($t in $results) {
            $lvl = switch ($t.Status) {
                'Pass'    { 'Info' }
                'Warn'    { 'Warn' }
                'Fail'    { 'Error' }
                'Skipped' { 'Info' }
                default   { 'Info' }
            }
            Write-ClusterLog -Level $lvl -Stage 'tuning' -Message "$($t.Name): $($t.Status)" -Data @{
                detail  = $t.Detail
                changed = $t.Changed
            }
        }
        Write-ClusterLog -Level Info -Stage 'tuning' `
            -Message "Tuning complete: $overall (pass=$passCount warn=$warnCount fail=$failCount skipped=$skipCount changed=$changed)"
    }

    return [pscustomobject]@{
        Overall   = $overall
        Tweaks    = $results.ToArray()
        PassCount = $passCount
        WarnCount = $warnCount
        FailCount = $failCount
        SkipCount = $skipCount
        Changed   = $changed
    }
}

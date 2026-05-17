<#
.SYNOPSIS
    Stage 1 -- Preflight. Verify the host can run the rest of the script.

.DESCRIPTION
    Dot-source this file and call Invoke-PreflightStage to run all
    preflight checks. Returns a structured result:

        @{
            Overall  = 'Pass' | 'Warn' | 'Fail'
            Checks   = @(
                @{ Name; Status = 'Pass'|'Warn'|'Fail'; Detail; Remediation }
                ...
            )
            FailCount; WarnCount; PassCount
        }

    The orchestrator decides how to react to Warn vs Fail. By default Fail
    aborts the run; Warn is logged and allowed. -IgnoreFailures lets a
    caller dry-run all stages without halting.

    Checks performed:
      1. Administrator                  must be elevated
      2. Windows SKU                    Pro / Enterprise / Education (Home not supported)
      3. RAM                            >= -MinRamGb (default 16 GB)
      4. VM storage free space          >= vms.count * vms.min_disk_gb_per_vm
      5. Virtualization (VT)            enabled in BIOS/UEFI
      6. SLAT support                   required for Hyper-V
      7. Network adapter up             at least one Up adapter
      8. Task Scheduler service         must be Running (for resume task)
      9. Execution policy               not Restricted in CurrentUser/LocalMachine
     10. PowerShell version             7.0+

.NOTES
    No state is changed by this stage. Read-only. Hardware detection is
    delegated to lib/HardwareDetect.psm1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Soft-load sibling lib modules.
$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
# When dot-sourced from outside the repo (e.g. when this is staged into
# C:\ProgramData\ClusterHost\src), $libDir may resolve unexpectedly. The
# orchestrator must import the libs first; this fallback is defense-in-depth.
foreach ($mod in 'Logging','HardwareDetect') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

function Add-PreflightCheck {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Checks,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass','Warn','Fail')][string]$Status,
        [string]$Detail,
        [string]$Remediation
    )
    $Checks.Add([pscustomobject]@{
        Name        = $Name
        Status      = $Status
        Detail      = $Detail
        Remediation = $Remediation
    })
}

function Test-IsAdministrator {
    # Avoid throwing on non-Windows hosts (CI etc.).
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = [System.Security.Principal.WindowsPrincipal]::new($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)
    } catch {
        $null = $_
        return $false
    }
}

function Get-PreflightRamGb {
    # Best signal: Get-CimInstance Win32_ComputerSystem.TotalPhysicalMemory.
    # Fallback: Win32_PhysicalMemory sum.
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.TotalPhysicalMemory) {
            return [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 1)
        }
    } catch { $null = $_ }
    try {
        $sum = (Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop |
            Measure-Object -Property Capacity -Sum).Sum
        if ($sum) { return [math]::Round([double]$sum / 1GB, 1) }
    } catch { $null = $_ }
    return $null
}

function Test-AnyNetworkAdapterUp {
    try {
        $up = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
        return [bool]$up
    } catch {
        $null = $_
        return $false
    }
}

function Get-TaskSchedulerStatus {
    try { (Get-Service -Name 'Schedule' -ErrorAction Stop).Status } catch { $null = $_; 'Missing' }
}

function Get-EffectiveExecutionPolicy {
    try {
        $best = $null
        foreach ($s in 'MachinePolicy','UserPolicy','CurrentUser','LocalMachine','Process') {
            $p = Get-ExecutionPolicy -Scope $s -ErrorAction SilentlyContinue
            if ($p -and $p -ne 'Undefined') { $best = $p; break }
        }
        return $best
    } catch {
        $null = $_
        return $null
    }
}

function Invoke-PreflightStage {
    <#
    .SYNOPSIS
        Run all preflight checks and return the structured report.

    .PARAMETER Config
        The parsed cluster-config.json object. Used for vms.count and
        vms.min_disk_gb_per_vm. Optional -- defaults applied when missing.

    .PARAMETER MinRamGb
        Minimum required RAM in GB. Default 16.

    .PARAMETER MinPwshVersion
        Minimum PowerShell version. Default 7.0.

    .PARAMETER IgnoreFailures
        When set, Fail results don't raise the Overall to Fail. Useful for
        dry-run mode and for the integration test that wants to inspect
        every check's result.

    .OUTPUTS
        pscustomobject @{ Overall; Checks; PassCount; WarnCount; FailCount }
    #>
    [CmdletBinding()]
    param(
        $Config,
        [int]$MinRamGb = 16,
        [version]$MinPwshVersion = '7.0',
        [switch]$IgnoreFailures
    )

    $checks = New-Object System.Collections.Generic.List[object]

    # ---------- 1. Administrator ----------
    if (Test-IsAdministrator) {
        Add-PreflightCheck -Checks $checks -Name 'Administrator' -Status Pass -Detail 'Running elevated.'
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Administrator' -Status Fail `
            -Detail 'Not running as Administrator.' `
            -Remediation 'Right-click PowerShell and Run as Administrator, then re-run the setup script.'
    }

    # ---------- 2. Windows SKU ----------
    $sku = Get-WindowsSku
    if ($sku.Sku -in 'Pro','Enterprise','Education') {
        Add-PreflightCheck -Checks $checks -Name 'Windows SKU' -Status Pass -Detail "$($sku.Sku) (source: $($sku.Source))"
    } elseif ($sku.Sku -eq 'Home') {
        Add-PreflightCheck -Checks $checks -Name 'Windows SKU' -Status Fail `
            -Detail "Windows Home -- Hyper-V is not available on this SKU." `
            -Remediation 'Upgrade to Windows 11 Pro/Enterprise/Education via Settings -> System -> Activation.'
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Windows SKU' -Status Warn `
            -Detail "Could not determine SKU. Raw: '$($sku.Raw)' source: $($sku.Source)" `
            -Remediation 'Set $env:CLUSTERHOST_ALLOW_UNKNOWN_SKU=1 to override after manual verification.'
    }

    # ---------- 3. RAM ----------
    $ram = Get-PreflightRamGb
    if ($null -eq $ram) {
        Add-PreflightCheck -Checks $checks -Name 'RAM' -Status Warn `
            -Detail 'Could not query physical memory.' `
            -Remediation 'Verify Get-CimInstance Win32_ComputerSystem works.'
    } elseif ($ram -ge $MinRamGb) {
        Add-PreflightCheck -Checks $checks -Name 'RAM' -Status Pass -Detail "${ram} GB (>= ${MinRamGb} GB)"
    } else {
        Add-PreflightCheck -Checks $checks -Name 'RAM' -Status Fail `
            -Detail "Only ${ram} GB installed; need >= ${MinRamGb} GB." `
            -Remediation 'Install more RAM or reduce vms.count / memory_min_gb in cluster-config.json.'
    }

    # ---------- 4. VM storage ----------
    $count    = if ($Config -and $Config.PSObject.Properties['vms']) { [int]$Config.vms.count } else { 2 }
    $perVmGb  = if ($Config -and $Config.PSObject.Properties['vms'] -and $Config.vms.PSObject.Properties['min_disk_gb_per_vm']) {
                    [int]$Config.vms.min_disk_gb_per_vm
                } else { 60 }
    $minFree  = $count * $perVmGb
    $drive    = Get-PhysicalDriveBest -MinFreeGb $minFree
    if ($drive) {
        Add-PreflightCheck -Checks $checks -Name 'VM storage' -Status Pass `
            -Detail "$($drive.DriveLetter): drive selected ($($drive.FreeGb) GB free of $($drive.SizeGb), source: $($drive.Source))"
    } else {
        Add-PreflightCheck -Checks $checks -Name 'VM storage' -Status Fail `
            -Detail "No drive has >= $minFree GB free ($count VMs x $perVmGb GB each)." `
            -Remediation 'Free disk space, attach a larger drive, or reduce vms.count / vms.min_disk_gb_per_vm.'
    }

    # ---------- 5+6. Virtualization (VT + SLAT) ----------
    $virt = Get-VirtualizationSupport
    if ($virt.VtSupported) {
        Add-PreflightCheck -Checks $checks -Name 'Virtualization (VT)' -Status Pass `
            -Detail "VT enabled (source: $($virt.Reasons['VtSource']))."
    } elseif ($virt.Reasons['VtSource'] -eq 'unknown') {
        Add-PreflightCheck -Checks $checks -Name 'Virtualization (VT)' -Status Warn `
            -Detail 'Could not determine VT support from Get-ComputerInfo or Win32_Processor.' `
            -Remediation 'Boot into firmware (UEFI/BIOS) and verify Intel VT-x / AMD-V is Enabled.'
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Virtualization (VT)' -Status Fail `
            -Detail 'CPU virtualization is disabled in firmware.' `
            -Remediation 'Reboot, enter UEFI/BIOS, enable Intel VT-x or AMD-V (and IOMMU if available), save, return to Windows, re-run setup.'
    }

    if ($virt.SlatSupported) {
        Add-PreflightCheck -Checks $checks -Name 'SLAT' -Status Pass -Detail 'Second-level address translation supported.'
    } elseif ($virt.Reasons['SlatSource'] -eq 'unknown') {
        Add-PreflightCheck -Checks $checks -Name 'SLAT' -Status Warn `
            -Detail 'Could not determine SLAT support.' `
            -Remediation 'Check Get-ComputerInfo HyperVRequirementSecondLevelAddressTranslation manually.'
    } else {
        Add-PreflightCheck -Checks $checks -Name 'SLAT' -Status Fail `
            -Detail 'CPU does not support SLAT (Hyper-V requires it).' `
            -Remediation 'Hyper-V is not supported on this CPU. Replace the CPU or move the workload to a different host.'
    }

    # ---------- 7. Network adapter up ----------
    if (Test-AnyNetworkAdapterUp) {
        Add-PreflightCheck -Checks $checks -Name 'Network adapter' -Status Pass -Detail 'At least one adapter is Up.'
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Network adapter' -Status Fail `
            -Detail 'No network adapter is in Up state.' `
            -Remediation 'Connect to the cluster WiFi (or wired) network and verify ipconfig shows a usable address.'
    }

    # ---------- 8. Task Scheduler service ----------
    $svc = Get-TaskSchedulerStatus
    if ($svc -eq 'Running') {
        Add-PreflightCheck -Checks $checks -Name 'Task Scheduler service' -Status Pass -Detail 'Schedule service is Running.'
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Task Scheduler service' -Status Fail `
            -Detail "Schedule service is '$svc'." `
            -Remediation "Run: Set-Service Schedule -StartupType Automatic; Start-Service Schedule"
    }

    # ---------- 9. Execution policy ----------
    $ep = Get-EffectiveExecutionPolicy
    if (-not $ep) {
        Add-PreflightCheck -Checks $checks -Name 'Execution policy' -Status Warn `
            -Detail 'Could not read the execution policy.' `
            -Remediation 'Verify Get-ExecutionPolicy works as Administrator.'
    } elseif ($ep -in 'Bypass','Unrestricted','RemoteSigned','AllSigned') {
        Add-PreflightCheck -Checks $checks -Name 'Execution policy' -Status Pass -Detail "Effective policy: $ep"
    } else {
        Add-PreflightCheck -Checks $checks -Name 'Execution policy' -Status Fail `
            -Detail "Effective policy '$ep' blocks script execution." `
            -Remediation 'Run as Admin: Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force'
    }

    # ---------- 10. PowerShell version ----------
    $ver = $PSVersionTable.PSVersion
    if ($ver -ge $MinPwshVersion) {
        Add-PreflightCheck -Checks $checks -Name 'PowerShell version' -Status Pass -Detail "PowerShell $ver (>= $MinPwshVersion)"
    } else {
        Add-PreflightCheck -Checks $checks -Name 'PowerShell version' -Status Fail `
            -Detail "PowerShell $ver is below the required $MinPwshVersion." `
            -Remediation 'Install PowerShell 7 from https://aka.ms/PowerShell and re-run setup under pwsh.'
    }

    # ---------- summary ----------
    $passCount = @($checks | Where-Object { $_.Status -eq 'Pass' }).Count
    $warnCount = @($checks | Where-Object { $_.Status -eq 'Warn' }).Count
    $failCount = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count

    $overall = if ($failCount -gt 0 -and -not $IgnoreFailures) { 'Fail' }
               elseif ($warnCount -gt 0) { 'Warn' }
               else { 'Pass' }

    # Log a one-line summary plus per-check entries.
    if (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue) {
        foreach ($c in $checks) {
            $lvl = switch ($c.Status) { 'Pass' { 'Info' } 'Warn' { 'Warn' } 'Fail' { 'Error' } }
            Write-ClusterLog -Level $lvl -Stage 'preflight' `
                -Message "$($c.Name): $($c.Status)" -Data @{ detail = $c.Detail }
        }
        Write-ClusterLog -Level Info -Stage 'preflight' `
            -Message "Preflight complete: $overall (pass=$passCount warn=$warnCount fail=$failCount)"
    }

    return [pscustomobject]@{
        Overall    = $overall
        Checks     = $checks.ToArray()
        PassCount  = $passCount
        WarnCount  = $warnCount
        FailCount  = $failCount
    }
}

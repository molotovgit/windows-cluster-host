<#
.SYNOPSIS
    Stage 8 -- Verify. Confirm everything the previous stages installed
    is actually running, and write an operator-readable summary report.

.DESCRIPTION
    Checks performed:
      1. Mesh Agent service running on the host
      2. sshd service running on the host
      3. Every expected VM exists (Get-VM)
      4. Every expected VM is Running (or starts within a short window)
      5. Each VM's NetworkAdapter[0].SwitchName matches the expected
         NAT switch
      6. Reachability probe: TCP-test each VM's IPAddress (if known) on
         the SSH port; soft check, Warn on miss because VMs may take
         time to DHCP

    Writes a structured summary text file:
      %ProgramData%\\ClusterHost\\setup-summary.txt
    or wherever -SummaryPath points.

    Returns: pscustomobject @{ Overall; Checks[]; Summary; SummaryPath }
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Retry') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultVerifyInvoker {
    @{
        GetService = {
            param([string]$Name)
            try {
                $s = Get-Service -Name $Name -ErrorAction Stop
                return [pscustomobject]@{ Found = $true; Status = "$($s.Status)"; StartType = "$($s.StartType)" }
            } catch {
                $null = $_
                return [pscustomobject]@{ Found = $false; Status = 'NotInstalled'; StartType = $null }
            }
        }
        GetVm = {
            param([string]$Name)
            try {
                $vm  = Get-VM -Name $Name -ErrorAction Stop
                $nic = $vm.NetworkAdapters | Select-Object -First 1
                $ip  = if ($nic) { @($nic.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) | Select-Object -First 1 } else { $null }
                return [pscustomobject]@{
                    Found      = $true
                    State      = "$($vm.State)"
                    SwitchName = if ($nic) { "$($nic.SwitchName)" } else { $null }
                    IpAddress  = $ip
                }
            } catch {
                $null = $_
                return [pscustomobject]@{ Found = $false; State = 'NotPresent'; SwitchName = $null; IpAddress = $null }
            }
        }
        StartVm = {
            param([string]$Name)
            try { Start-VM -Name $Name -ErrorAction Stop; return @{ Ok = $true } }
            catch { return @{ Ok = $false; Detail = "$($_.Exception.Message)" } }
        }
        TestTcp = {
            param([string]$Address,[int]$Port,[int]$TimeoutMs)
            if (-not $Address) { return $false }
            $client = $null
            try {
                $client = [System.Net.Sockets.TcpClient]::new()
                $iar    = $client.BeginConnect($Address, $Port, $null, $null)
                $ok     = $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
                if (-not $ok) { return $false }
                $client.EndConnect($iar)
                return $true
            } catch { return $false }
            finally {
                if ($client) { try { $client.Close() } catch { Write-Debug "$_" } }
            }
        }
        WriteSummary = {
            param([string]$Path,[string]$Body)
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($Path, $Body, [System.Text.UTF8Encoding]::new($false))
        }
    }
}

$script:VerifyInvokers = Get-DefaultVerifyInvoker

function Confirm-TestSeamAllowed {
    if (-not $env:CLUSTERHOST_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERHOST_ALLOW_TEST_SEAMS=1 to enable Set-VerifyInvoker / Reset-VerifyInvoker."
    }
}

function Set-VerifyInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][scriptblock]$ScriptBlock)
    Confirm-TestSeamAllowed
    if (-not $script:VerifyInvokers.ContainsKey($Name)) {
        throw "Set-VerifyInvoker: unknown invoker '$Name'. Known: $(($script:VerifyInvokers.Keys | Sort-Object) -join ', ')"
    }
    $script:VerifyInvokers[$Name] = $ScriptBlock
}

function Reset-VerifyInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-TestSeamAllowed
    $script:VerifyInvokers = Get-DefaultVerifyInvoker
}

function Add-VerifyCheck {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Checks,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass','Warn','Fail')][string]$Status,
        [string]$Detail
    )
    $Checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

function Format-VerifySummary {
    param(
        [pscustomobject[]]$Checks,
        [string]$Overall,
        [string]$SwitchName,
        [string[]]$VmNames,
        [hashtable]$VmInfo,
        [hashtable]$Meta
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Cluster host setup summary")
    [void]$sb.AppendLine("==========================")
    [void]$sb.AppendLine("Generated: $([datetime]::UtcNow.ToString('o'))")
    [void]$sb.AppendLine("Overall  : $Overall")
    [void]$sb.AppendLine("")
    if ($Meta) {
        [void]$sb.AppendLine("Run metadata:")
        foreach ($k in $Meta.Keys | Sort-Object) {
            [void]$sb.AppendLine(("  {0,-22} {1}" -f $k, $Meta[$k]))
        }
        [void]$sb.AppendLine("")
    }
    [void]$sb.AppendLine("VMs (switch: $SwitchName):")
    foreach ($n in $VmNames) {
        $info = $VmInfo[$n]
        if ($info) {
            [void]$sb.AppendLine(("  {0,-12} state={1,-10} switch={2,-22} ip={3}" -f $n, $info.State, $info.SwitchName, ($info.IpAddress ?? '<none>')))
        } else {
            [void]$sb.AppendLine("  $n  (not found)")
        }
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Checks:")
    foreach ($c in $Checks) {
        [void]$sb.AppendLine(("  [{0,-4}] {1}: {2}" -f $c.Status, $c.Name, $c.Detail))
    }
    return $sb.ToString()
}

# ---------- public ----------

function Invoke-VerifyStage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Stage entry point; read-only except for the optional Start-VM and summary file write.')]
    [CmdletBinding()]
    param(
        $Config,
        [string[]]$VmNames,
        [string]$SwitchName,
        [string]$SummaryPath = (Join-Path $env:ProgramData 'ClusterHost\setup-summary.txt'),
        [hashtable]$Meta,
        [int]$StartWaitSeconds = 30,
        [int]$TcpProbePort = 22,
        [switch]$StartStoppedVMs,
        [switch]$DryRun
    )

    if (-not $SwitchName -and $Config -and $Config.PSObject.Properties['network'] -and $Config.network -and `
        $Config.network.PSObject.Properties['nat_switch_name']) {
        $SwitchName = "$($Config.network.nat_switch_name)"
    }
    if (-not $SwitchName) { $SwitchName = 'ClusterNATSwitch' }

    if (-not $VmNames -or $VmNames.Count -eq 0) {
        # Derive names from -Config.vms (count / name_prefix / name_suffixes).
        $vmsCfg  = if ($Config -and $Config.PSObject.Properties['vms']) { $Config.vms } else { $null }
        $count   = if ($vmsCfg -and $vmsCfg.PSObject.Properties['count'])         { [int]$vmsCfg.count } else { 2 }
        $prefix  = if ($vmsCfg -and $vmsCfg.PSObject.Properties['name_prefix'])   { "$($vmsCfg.name_prefix)" } else { 'vm-' }
        $suffixesCfg = if ($vmsCfg -and $vmsCfg.PSObject.Properties['name_suffixes'] -and $vmsCfg.name_suffixes) { @($vmsCfg.name_suffixes) } else { $null }
        if ($suffixesCfg) {
            $VmNames = $suffixesCfg | ForEach-Object { "$prefix$_" }
        } elseif ($count -le 26) {
            $VmNames = 0..($count - 1) | ForEach-Object { "$prefix$([char](97 + $_))" }
        } else {
            $VmNames = 1..$count | ForEach-Object { "$prefix$($_.ToString('D2'))" }
        }
    }
    $VmNames = @($VmNames)

    $checks = New-Object System.Collections.Generic.List[object]
    $vmInfo = @{}

    # ---------- 1. Mesh Agent service ----------
    $meshSvc = & $script:VerifyInvokers.GetService 'Mesh Agent'
    if ($meshSvc.Found -and $meshSvc.Status -eq 'Running') {
        Add-VerifyCheck $checks 'Mesh Agent service' 'Pass' "Running ($($meshSvc.StartType))."
    } elseif ($meshSvc.Found) {
        Add-VerifyCheck $checks 'Mesh Agent service' 'Fail' "Mesh Agent service is $($meshSvc.Status)."
    } else {
        Add-VerifyCheck $checks 'Mesh Agent service' 'Fail' 'Mesh Agent service not installed -- Stage 6 (Agents) did not complete.'
    }

    # ---------- 2. sshd service ----------
    $sshSvc = & $script:VerifyInvokers.GetService 'sshd'
    if ($sshSvc.Found -and $sshSvc.Status -eq 'Running') {
        Add-VerifyCheck $checks 'sshd service' 'Pass' "Running ($($sshSvc.StartType))."
    } elseif ($sshSvc.Found) {
        Add-VerifyCheck $checks 'sshd service' 'Fail' "sshd is $($sshSvc.Status)."
    } else {
        Add-VerifyCheck $checks 'sshd service' 'Fail' 'sshd not installed -- Stage 6 (Agents) did not complete.'
    }

    # ---------- 3+4+5. Per-VM existence / state / switch ----------
    foreach ($name in $VmNames) {
        $vm = & $script:VerifyInvokers.GetVm $name
        $vmInfo[$name] = $vm
        if (-not $vm.Found) {
            Add-VerifyCheck $checks "VM '$name' present" 'Fail' "Get-VM returned NotPresent -- Stage 7 (VMs) did not complete."
            continue
        }
        Add-VerifyCheck $checks "VM '$name' present" 'Pass' "state=$($vm.State), switch=$($vm.SwitchName), ip=$($vm.IpAddress ?? '<none>')"

        if ($vm.State -ne 'Running') {
            if ($StartStoppedVMs -and -not $DryRun) {
                $s = & $script:VerifyInvokers.StartVm $name
                if ($s.Ok) {
                    Add-VerifyCheck $checks "VM '$name' running" 'Warn' "Was $($vm.State); Start-VM issued. Waiting up to ${StartWaitSeconds}s for it to boot."
                    Start-Sleep -Seconds ([math]::Min($StartWaitSeconds, 5))
                    $vm = & $script:VerifyInvokers.GetVm $name
                    $vmInfo[$name] = $vm
                } else {
                    Add-VerifyCheck $checks "VM '$name' running" 'Fail' "Start-VM failed: $($s.Detail)"
                }
            } else {
                Add-VerifyCheck $checks "VM '$name' running" 'Warn' "state=$($vm.State). Pass -StartStoppedVMs to start automatically, or boot via Hyper-V Manager."
            }
        } else {
            Add-VerifyCheck $checks "VM '$name' running" 'Pass' "Running."
        }

        if ($vm.SwitchName -and $vm.SwitchName -ne $SwitchName) {
            Add-VerifyCheck $checks "VM '$name' switch" 'Warn' "attached to '$($vm.SwitchName)' but expected '$SwitchName'."
        }
    }

    # ---------- 6. TCP probe (soft) ----------
    foreach ($name in $VmNames) {
        $info = $vmInfo[$name]
        if (-not $info -or -not $info.IpAddress) { continue }
        $reachable = & $script:VerifyInvokers.TestTcp $info.IpAddress $TcpProbePort 750
        if ($reachable) {
            Add-VerifyCheck $checks "VM '$name' tcp:$TcpProbePort" 'Pass' "Reachable at $($info.IpAddress):$TcpProbePort."
        } else {
            Add-VerifyCheck $checks "VM '$name' tcp:$TcpProbePort" 'Warn' "TCP $($info.IpAddress):$TcpProbePort did not respond. VM may still be booting; re-check in a minute."
        }
    }

    # ---------- summary ----------
    $passCount = @($checks | Where-Object { $_.Status -eq 'Pass' }).Count
    $warnCount = @($checks | Where-Object { $_.Status -eq 'Warn' }).Count
    $failCount = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count
    $overall = if ($failCount -gt 0) { 'Fail' } elseif ($warnCount -gt 0) { 'Warn' } else { 'Pass' }

    $summaryText = Format-VerifySummary -Checks $checks.ToArray() -Overall $overall `
                                         -SwitchName $SwitchName -VmNames $VmNames -VmInfo $vmInfo -Meta $Meta

    if (-not $DryRun) {
        try {
            & $script:VerifyInvokers.WriteSummary $SummaryPath $summaryText
            Add-VerifyCheck $checks 'Summary file' 'Pass' "Wrote $SummaryPath."
        } catch {
            Add-VerifyCheck $checks 'Summary file' 'Warn' "Summary write failed: $($_.Exception.Message)"
        }
    }

    if (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue) {
        foreach ($c in $checks) {
            $lvl = switch ($c.Status) { 'Pass' {'Info'} 'Warn' {'Warn'} 'Fail' {'Error'} }
            Write-ClusterLog -Level $lvl -Stage 'verify' -Message "$($c.Name): $($c.Status)" -Data @{ detail = $c.Detail }
        }
        Write-ClusterLog -Level Info -Stage 'verify' `
            -Message "Verify complete: $overall (pass=$passCount warn=$warnCount fail=$failCount)" `
            -Data @{ summaryPath = $SummaryPath }
    }

    return [pscustomobject]@{
        Overall     = $overall
        Checks      = $checks.ToArray()
        Summary     = $summaryText
        SummaryPath = $SummaryPath
        VmInfo      = $vmInfo
        PassCount   = $passCount
        WarnCount   = $warnCount
        FailCount   = $failCount
    }
}

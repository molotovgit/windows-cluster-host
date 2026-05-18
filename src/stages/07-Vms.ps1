<#
.SYNOPSIS
    Stage 7 -- VMs. Pull the golden VHDX, clone per vms.count, create
    Gen2 VMs attached to the NAT vSwitch, autostart enabled.

.DESCRIPTION
    Sub-steps (each idempotent + per-step Status):
      1. Pick a VM storage drive (Get-PhysicalDriveBest)
      2. Source the golden VHDX. Three sources, tried in order:
           - -LocalGoldenPath (operator pre-stage)
           - SMB \\<controller>\<share>\<subdir>\<filename>
             defaults: share='ClusterShare', subdir='vhdx',
             filename='golden.vhdx' -- matches the layout
             windows-cluster-controller's Stage 11 publishes.
           - HTTPS <addr>/golden.vhdx (operator-served; not published by
             default by windows-cluster-controller, kept as fallback for
             custom deploys).
         All four pieces (share, subdir, filename, https_url) are
         overridable via Config.golden_vhdx.{smb_share, smb_subdir,
         filename, https_url} OR via -GoldenSmbPath / -GoldenHttpsUrl.
         Verify SHA256 when -GoldenSha256 supplied.
      3. For each VM: clone golden -> <prefix><suffix>.vhdx if missing
      4. For each VM: New-VM (Gen2) attached to -SwitchName, dynamic mem
      5. For each VM: AutomaticStartAction=Start with staggered delays

    Returns: pscustomobject @{ Overall; Steps[]; VmStorageDrive; VmNames }
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Retry','HardwareDetect') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

# ---------- invoker seam ----------

function Get-DefaultVmInvoker {
    @{
        SourceGoldenVhdx = {
            param([string]$SmbPath,[string]$HttpsUrl,[string]$LocalPath,[string]$Destination)
            # Accumulate per-source failures so the final Detail explains each
            # path the stage tried (helps the operator diagnose without a re-run).
            $errs = New-Object System.Collections.Generic.List[string]
            if ($LocalPath -and (Test-Path -LiteralPath $LocalPath)) {
                try {
                    Copy-Item -LiteralPath $LocalPath -Destination $Destination -Force -ErrorAction Stop
                    return @{ Ok = $true; Source = 'local'; Detail = "Copied from $LocalPath." }
                } catch { $errs.Add("local-copy: $($_.Exception.Message)") }
            } elseif ($LocalPath) {
                $errs.Add("local: path '$LocalPath' does not exist")
            }
            if ($SmbPath -and (Test-Path -LiteralPath $SmbPath)) {
                try {
                    Copy-Item -LiteralPath $SmbPath -Destination $Destination -Force -ErrorAction Stop
                    return @{ Ok = $true; Source = 'smb'; Detail = "Copied from $SmbPath." }
                } catch { $errs.Add("smb-copy: $($_.Exception.Message)") }
            } elseif ($SmbPath) {
                $errs.Add("smb: path '$SmbPath' not reachable")
            }
            if ($HttpsUrl) {
                try {
                    Invoke-WebRequest -Uri $HttpsUrl -OutFile $Destination -UseBasicParsing -SkipCertificateCheck -ErrorAction Stop
                    return @{ Ok = $true; Source = 'https'; Detail = "Downloaded from $HttpsUrl." }
                } catch { $errs.Add("https: $($_.Exception.Message)") }
            }
            $reason = if ($errs.Count -gt 0) { $errs -join ' | ' } else { 'no -LocalGoldenPath/-SmbPath/-HttpsUrl supplied' }
            return @{ Ok = $false; Source = 'none'; Detail = "Golden source failed. Tried: $reason" }
        }
        VerifyVhdxHash = {
            param([string]$Path,[string]$ExpectedSha256)
            if (-not $ExpectedSha256) { return @{ Ok = $true; Skipped = $true; Detail = 'No -GoldenSha256 provided; integrity check skipped.' } }
            try {
                $h = (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash
                $ok = ($h.ToLowerInvariant() -eq $ExpectedSha256.ToLowerInvariant())
                return @{ Ok = $ok; Skipped = $false; Hash = $h
                          Detail = if ($ok) { 'SHA256 verified.' } else { "SHA256 mismatch: actual=$h expected=$ExpectedSha256" } }
            } catch { return @{ Ok = $false; Skipped = $false; Detail = "Get-FileHash threw: $($_.Exception.Message)" } }
        }
        CloneVhdx = {
            param([string]$Source,[string]$Destination)
            try {
                if (Test-Path -LiteralPath $Destination) { return @{ Ok = $true; AlreadyPresent = $true; Detail = "$Destination already exists." } }
                Copy-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
                return @{ Ok = $true; AlreadyPresent = $false; Detail = "Cloned $Source -> $Destination." }
            } catch { return @{ Ok = $false; AlreadyPresent = $false; Detail = "Clone failed: $($_.Exception.Message)" } }
        }
        GetVm = {
            param([string]$Name)
            try {
                $vm = Get-VM -Name $Name -ErrorAction Stop
                $nic = $vm.NetworkAdapters | Select-Object -First 1
                $hd  = $vm.HardDrives     | Select-Object -First 1
                return [pscustomobject]@{
                    Found                = $true
                    State                = "$($vm.State)"
                    AutomaticStartAction = "$($vm.AutomaticStartAction)"
                    SwitchName           = if ($nic) { "$($nic.SwitchName)" } else { $null }
                    HardDrivePath        = if ($hd)  { "$($hd.Path)"  } else { $null }
                    MemoryStartupGb      = if ($vm.MemoryStartup) { [int][math]::Round($vm.MemoryStartup / 1GB) } else { 0 }
                    ProcessorCount       = [int]$vm.ProcessorCount
                }
            } catch {
                $null = $_
                return [pscustomobject]@{ Found = $false; State = 'NotPresent'; AutomaticStartAction = $null;
                                          SwitchName = $null; HardDrivePath = $null; MemoryStartupGb = 0; ProcessorCount = 0 }
            }
        }
        CreateVm = {
            param(
                [string]$Name,[string]$VhdxPath,[string]$SwitchName,
                [long]$MemStartupBytes,[long]$MemMinBytes,[long]$MemMaxBytes,
                [int]$VcpuCount,[string]$SecureBootTemplate
            )
            try {
                New-VM -Name $Name -MemoryStartupBytes $MemStartupBytes -VHDPath $VhdxPath `
                       -SwitchName $SwitchName -Generation 2 -ErrorAction Stop | Out-Null
                Set-VMProcessor -VMName $Name -Count $VcpuCount -ErrorAction Stop
                Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true `
                             -StartupBytes $MemStartupBytes `
                             -MinimumBytes $MemMinBytes `
                             -MaximumBytes $MemMaxBytes -ErrorAction Stop
                # Secure Boot template: 'MicrosoftWindows', 'MicrosoftUEFICertificateAuthority' (Linux),
                # or 'Off' to disable. Project default is MicrosoftWindows.
                if ($SecureBootTemplate -eq 'Off') {
                    Set-VMFirmware -VMName $Name -EnableSecureBoot Off -ErrorAction Stop
                } else {
                    Set-VMFirmware -VMName $Name -EnableSecureBoot On `
                                   -SecureBootTemplate $SecureBootTemplate -ErrorAction Stop
                }
                return @{ Ok = $true; Detail = "Created Gen2 VM $Name (vCPU=$VcpuCount, mem=$([math]::Round($MemStartupBytes / 1GB,1)) GB startup, $([math]::Round($MemMinBytes/1GB,1))-$([math]::Round($MemMaxBytes/1GB,1)) GB dynamic, SecureBoot=$SecureBootTemplate, switch=$SwitchName)." }
            } catch { return @{ Ok = $false; Detail = "New-VM / Set-VMProcessor / Set-VMMemory / Set-VMFirmware failed: $($_.Exception.Message)" } }
        }
        ConfigureAutostart = {
            param([string]$Name,[int]$DelaySeconds)
            try {
                Set-VM -Name $Name -AutomaticStartAction Start -AutomaticStartDelay $DelaySeconds -ErrorAction Stop
                return @{ Ok = $true; Detail = "Autostart=Start, Delay=$DelaySeconds s." }
            } catch { return @{ Ok = $false; Detail = "Set-VM autostart failed: $($_.Exception.Message)" } }
        }
        # Mount the controller's SMB share with explicit credentials. Required
        # in workgroup deploys where the host's local user does not exist on
        # the controller; the implicit-creds Copy-Item would otherwise be
        # rejected by the share's "Authenticated Users" ACL.
        OpenSmbAuth = {
            param([string]$UncPath,[string]$User,[string]$Password)
            if (-not $UncPath -or -not $User -or -not $Password) {
                return @{ Ok = $false; SharePath = $null; Detail = 'no smb credentials supplied; using implicit auth' }
            }
            # Extract '\\server\share' root from a longer UNC path.
            if ($UncPath -notmatch '^(\\\\[^\\]+\\[^\\]+)') {
                return @{ Ok = $false; SharePath = $null; Detail = "'$UncPath' is not a UNC share path" }
            }
            $share = $Matches[1]
            try {
                # Idempotent: remove any stale mapping first so a prior-run
                # cached credential doesn't conflict with the explicit one.
                $existing = Get-SmbMapping -RemotePath $share -ErrorAction SilentlyContinue
                if ($existing) {
                    Remove-SmbMapping -RemotePath $share -Force -UpdateProfile -ErrorAction SilentlyContinue
                }
                New-SmbMapping -RemotePath $share -UserName $User -Password $Password -ErrorAction Stop | Out-Null
                return @{ Ok = $true; SharePath = $share; Detail = "Mounted $share as $User." }
            } catch {
                return @{ Ok = $false; SharePath = $share; Detail = "New-SmbMapping failed: $($_.Exception.Message)" }
            }
        }
        CloseSmbAuth = {
            param([string]$SharePath)
            if (-not $SharePath) { return }
            try { Remove-SmbMapping -RemotePath $SharePath -Force -UpdateProfile -ErrorAction SilentlyContinue }
            catch { $null = $_ }
        }
    }
}

$script:VmInvokers = Get-DefaultVmInvoker

function Confirm-TestSeamAllowed {
    if (-not $env:CLUSTERHOST_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERHOST_ALLOW_TEST_SEAMS=1 to enable Set-VmInvoker / Reset-VmInvoker."
    }
}

function Set-VmInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][scriptblock]$ScriptBlock)
    Confirm-TestSeamAllowed
    if (-not $script:VmInvokers.ContainsKey($Name)) {
        throw "Set-VmInvoker: unknown invoker '$Name'. Known: $(($script:VmInvokers.Keys | Sort-Object) -join ', ')"
    }
    $script:VmInvokers[$Name] = $ScriptBlock
}

function Reset-VmInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-TestSeamAllowed
    $script:VmInvokers = Get-DefaultVmInvoker
}

function Add-VmStep {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Steps,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass','Warn','Fail','Skipped')][string]$Status,
        [string]$Detail,
        [string]$Remediation
    )
    $Steps.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Remediation = $Remediation })
}

function Get-VmNameList {
    param(
        [int]$Count,
        [string]$Prefix = 'vm-',
        [string[]]$Suffixes
    )
    if ($Suffixes -and $Suffixes.Count -gt 0) {
        return $Suffixes | ForEach-Object { "$Prefix$_" }
    }
    # Default: lowercase letters (a, b, c, ...). For count > 26, fall back to a01, a02, ...
    if ($Count -le 26) {
        $names = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $Count; $i++) {
            $letter = [char](97 + $i)   # 'a'..'z'
            [void]$names.Add("$Prefix$letter")
        }
        return $names.ToArray()
    }
    return @(1..$Count | ForEach-Object { "$Prefix$($_.ToString('D2'))" })
}

# ---------- public ----------

function Invoke-VmsStage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Stage entry point; sub-steps honor -DryRun.')]
    [CmdletBinding()]
    param(
        $Config,
        [string]$SwitchName,
        [string]$VmStorageDrive,
        [string]$GoldenSmbPath,
        [string]$GoldenHttpsUrl,
        [string]$LocalGoldenPath,
        [string]$GoldenSha256,
        [string]$ControllerSmbUser,
        [string]$ControllerSmbPassword,
        [int]$Count,
        [string]$Prefix,
        [string[]]$Suffixes,
        [int]$MemStartupGb,
        [int]$MemMinGb,
        [int]$MemMaxGb,
        [int]$VcpuCount,
        [int]$StaggerSeconds,
        [string]$SecureBootTemplate,
        [switch]$DryRun
    )

    # ---------- resolve config-driven defaults ----------
    if (-not $SwitchName -and $Config -and $Config.PSObject.Properties['network'] -and $Config.network `
        -and $Config.network.PSObject.Properties['nat_switch_name']) {
        $SwitchName = "$($Config.network.nat_switch_name)"
    }
    if (-not $SwitchName) { $SwitchName = 'ClusterNATSwitch' }

    $vmsCfg = if ($Config -and $Config.PSObject.Properties['vms']) { $Config.vms } else { $null }
    if (-not $PSBoundParameters.ContainsKey('Count')          -and $vmsCfg -and $vmsCfg.PSObject.Properties['count'])             { $Count          = [int]$vmsCfg.count }
    if (-not $PSBoundParameters.ContainsKey('Prefix')         -and $vmsCfg -and $vmsCfg.PSObject.Properties['name_prefix'])       { $Prefix         = "$($vmsCfg.name_prefix)" }
    if (-not $PSBoundParameters.ContainsKey('Suffixes')       -and $vmsCfg -and $vmsCfg.PSObject.Properties['name_suffixes'] -and $vmsCfg.name_suffixes) { $Suffixes = @($vmsCfg.name_suffixes) }
    if (-not $PSBoundParameters.ContainsKey('MemStartupGb')   -and $vmsCfg -and $vmsCfg.PSObject.Properties['memory_startup_gb']) { $MemStartupGb   = [int]$vmsCfg.memory_startup_gb }
    if (-not $PSBoundParameters.ContainsKey('MemMinGb')       -and $vmsCfg -and $vmsCfg.PSObject.Properties['memory_min_gb'])     { $MemMinGb       = [int]$vmsCfg.memory_min_gb }
    if (-not $PSBoundParameters.ContainsKey('MemMaxGb')       -and $vmsCfg -and $vmsCfg.PSObject.Properties['memory_max_gb'])     { $MemMaxGb       = [int]$vmsCfg.memory_max_gb }
    if (-not $PSBoundParameters.ContainsKey('VcpuCount')      -and $vmsCfg -and $vmsCfg.PSObject.Properties['vcpu_count'])        { $VcpuCount      = [int]$vmsCfg.vcpu_count }
    if (-not $PSBoundParameters.ContainsKey('StaggerSeconds') -and $vmsCfg -and $vmsCfg.PSObject.Properties['stagger_seconds'])   { $StaggerSeconds = [int]$vmsCfg.stagger_seconds }
    if (-not $PSBoundParameters.ContainsKey('SecureBootTemplate') -and $vmsCfg -and $vmsCfg.PSObject.Properties['secure_boot_template']) { $SecureBootTemplate = "$($vmsCfg.secure_boot_template)" }
    if (-not $Count)          { $Count          = 2 }
    if (-not $Prefix)         { $Prefix         = 'vm-' }
    if (-not $MemStartupGb)   { $MemStartupGb   = 4 }
    if (-not $MemMinGb)       { $MemMinGb       = [math]::Max(2, [int]($MemStartupGb / 2)) }
    if (-not $MemMaxGb)       { $MemMaxGb       = [math]::Max($MemStartupGb, $MemStartupGb * 2) }
    if (-not $VcpuCount)      { $VcpuCount      = 2 }
    if (-not $StaggerSeconds) { $StaggerSeconds = 30 }
    if (-not $SecureBootTemplate) { $SecureBootTemplate = 'MicrosoftWindows' }

    if ((-not $GoldenSmbPath -or -not $GoldenHttpsUrl) -and $Config -and `
        $Config.PSObject.Properties['controller'] -and $Config.controller -and `
        $Config.controller.PSObject.Properties['address'] -and $Config.controller.address) {
        $addr = "$($Config.controller.address)"
        # Resolve share / subdir / filename / https_url with override
        # precedence: explicit -GoldenSmbPath/-GoldenHttpsUrl > Config.golden_vhdx > defaults.
        # Defaults match windows-cluster-controller's Stage 11 (Share)
        # layout: share name 'ClusterShare', VHDX subdir 'vhdx',
        # filename 'golden.vhdx' -> '\\<addr>\ClusterShare\vhdx\golden.vhdx'.
        $gvCfg = if ($Config.PSObject.Properties['golden_vhdx']) { $Config.golden_vhdx } else { $null }
        $smbShare = if ($gvCfg -and $gvCfg.PSObject.Properties['smb_share']  -and $gvCfg.smb_share)  { "$($gvCfg.smb_share)"  } else { 'ClusterShare' }
        $smbSubdir = if ($gvCfg -and $gvCfg.PSObject.Properties['smb_subdir'] -and $gvCfg.smb_subdir) { "$($gvCfg.smb_subdir)" } else { 'vhdx' }
        $vhdxFile  = if ($gvCfg -and $gvCfg.PSObject.Properties['filename']   -and $gvCfg.filename)   { "$($gvCfg.filename)"   } else { 'golden.vhdx' }
        $httpsOverride = if ($gvCfg -and $gvCfg.PSObject.Properties['https_url'] -and $gvCfg.https_url) { "$($gvCfg.https_url)" } else { $null }
        if (-not $GoldenSmbPath) {
            $segments = @($smbShare, $smbSubdir, $vhdxFile) | Where-Object { $_ } | ForEach-Object { $_.Trim('\') }
            $GoldenSmbPath = "\\$addr\" + ($segments -join '\')
        }
        if (-not $GoldenHttpsUrl) {
            $GoldenHttpsUrl = if ($httpsOverride) { $httpsOverride } else { "https://$addr/$vhdxFile" }
        }
    }

    # Resolve SMB credentials. Required in workgroup deploys (host's local
    # user does not exist on the controller). Precedence: explicit params
    # > Config.controller.smb_username/smb_password > none (implicit auth).
    if (-not $ControllerSmbUser -and $Config -and `
        $Config.PSObject.Properties['controller'] -and $Config.controller -and `
        $Config.controller.PSObject.Properties['smb_username'] -and $Config.controller.smb_username) {
        $ControllerSmbUser = "$($Config.controller.smb_username)"
    }
    if (-not $ControllerSmbPassword -and $Config -and `
        $Config.PSObject.Properties['controller'] -and $Config.controller -and `
        $Config.controller.PSObject.Properties['smb_password'] -and $Config.controller.smb_password) {
        $ControllerSmbPassword = "$($Config.controller.smb_password)"
    }

    $steps = New-Object System.Collections.Generic.List[object]
    $names = Get-VmNameList -Count $Count -Prefix $Prefix -Suffixes $Suffixes

    # ---------- 1. Pick storage drive ----------
    if (-not $VmStorageDrive) {
        $minPerVm = if ($vmsCfg -and $vmsCfg.PSObject.Properties['min_disk_gb_per_vm']) { [int]$vmsCfg.min_disk_gb_per_vm } else { 60 }
        # Include the golden VHDX itself (Copy-Item makes full copies, not
        # differencing) -- so we need Count clones PLUS the golden.
        $minFree  = ($Count + 1) * $minPerVm
        $drive    = Get-PhysicalDriveBest -MinFreeGb $minFree
        if ($drive) {
            $VmStorageDrive = $drive.DriveLetter
            Add-VmStep $steps 'VM storage drive' 'Pass' "Selected $($drive.DriveLetter): ($($drive.FreeGb) GB free, source: $($drive.Source))."
        } else {
            Add-VmStep $steps 'VM storage drive' 'Fail' "No drive has >= $minFree GB free (count=$Count x $minPerVm GB)." 'Free disk space or attach a larger drive.'
            return New-VmStageResult -Steps $steps -VmStorageDrive $null -VmNames $names
        }
    } else {
        Add-VmStep $steps 'VM storage drive' 'Pass' "Using explicit -VmStorageDrive '$VmStorageDrive'."
    }

    $vmRoot   = "${VmStorageDrive}:\VMs"
    $goldenPath = Join-Path $vmRoot 'golden.vhdx'

    # ---------- 2. Source golden VHDX ----------
    if ($DryRun) {
        Add-VmStep $steps 'Golden VHDX source' 'Skipped' "DryRun: would source from $LocalGoldenPath, $GoldenSmbPath, or $GoldenHttpsUrl to $goldenPath."
    } elseif (Test-Path -LiteralPath $goldenPath) {
        Add-VmStep $steps 'Golden VHDX source' 'Pass' "Golden VHDX already present at $goldenPath; not re-downloading."
    } else {
        if (-not (Test-Path -LiteralPath $vmRoot)) { New-Item -Path $vmRoot -ItemType Directory -Force | Out-Null }

        # Mount the controller's SMB share with explicit creds if supplied
        # (workgroup deploys need this; domain-joined deploys can rely on
        # implicit auth). The mapping is cleaned up in the finally block.
        $smbAuthState = $null
        if ($GoldenSmbPath -and $ControllerSmbUser -and $ControllerSmbPassword) {
            $smbAuthState = & $script:VmInvokers.OpenSmbAuth $GoldenSmbPath $ControllerSmbUser $ControllerSmbPassword
            if ($smbAuthState.Ok) {
                Add-VmStep $steps 'SMB auth to controller' 'Pass' $smbAuthState.Detail
            } else {
                Add-VmStep $steps 'SMB auth to controller' 'Warn' $smbAuthState.Detail 'Continuing with implicit credentials; SMB Copy-Item may fail.'
            }
        }
        try {
            $s = & $script:VmInvokers.SourceGoldenVhdx $GoldenSmbPath $GoldenHttpsUrl $LocalGoldenPath $goldenPath
        } finally {
            if ($smbAuthState -and $smbAuthState.Ok -and $smbAuthState.SharePath) {
                & $script:VmInvokers.CloseSmbAuth $smbAuthState.SharePath
            }
        }
        if (-not $s.Ok) {
            Add-VmStep $steps 'Golden VHDX source' 'Fail' $s.Detail "Drop a golden VHDX at $GoldenSmbPath on the controller (windows-cluster-controller publishes \\<addr>\ClusterShare\vhdx\ by default), or pass -LocalGoldenPath to install.ps1. If the share auth is rejecting the host, set controller.smb_username/smb_password in cluster-config.json."
            return New-VmStageResult -Steps $steps -VmStorageDrive $VmStorageDrive -VmNames $names
        }
        Add-VmStep $steps 'Golden VHDX source' 'Pass' "Sourced via $($s.Source). $($s.Detail)"

        $v = & $script:VmInvokers.VerifyVhdxHash $goldenPath $GoldenSha256
        if ($v.Skipped) {
            Add-VmStep $steps 'Golden VHDX SHA256' 'Warn' $v.Detail 'Pass -GoldenSha256 to enable integrity verification.'
        } elseif ($v.Ok) {
            Add-VmStep $steps 'Golden VHDX SHA256' 'Pass' $v.Detail
        } else {
            Add-VmStep $steps 'Golden VHDX SHA256' 'Fail' $v.Detail 'Delete the bad VHDX and re-source from a trusted controller.'
            return New-VmStageResult -Steps $steps -VmStorageDrive $VmStorageDrive -VmNames $names
        }
    }

    # ---------- 3+4+5. Per-VM: clone, create, autostart ----------
    $i = 0
    foreach ($name in $names) {
        $vhdx    = Join-Path $vmRoot ("$name.vhdx")
        $delay   = $i * $StaggerSeconds
        $i++

        if ($DryRun) {
            Add-VmStep $steps "VM '$name'" 'Skipped' "DryRun: would clone $goldenPath -> $vhdx, create Gen2 VM with $MemStartupGb GB / $VcpuCount vCPU attached to '$SwitchName', autostart with $delay s delay."
            continue
        }

        $c = & $script:VmInvokers.CloneVhdx $goldenPath $vhdx
        if (-not $c.Ok) {
            Add-VmStep $steps "VM '$name' clone" 'Fail' $c.Detail "Manual: Copy-Item '$goldenPath' '$vhdx'"
            continue
        }
        $existing = & $script:VmInvokers.GetVm $name
        if ($existing.Found) {
            $a = & $script:VmInvokers.ConfigureAutostart $name $delay
            # Config-drift detection: warn when the existing VM doesn't match
            # what this run would have created. The GetVm closure returns the
            # observable fields; mismatch surfaces in Detail without auto-
            # repairing (operator must Remove-VM and re-run to fix).
            $drift = New-Object System.Collections.Generic.List[string]
            if ($existing.PSObject.Properties['SwitchName']      -and $existing.SwitchName      -and $existing.SwitchName      -ne $SwitchName)             { $drift.Add("switch='$($existing.SwitchName)' (expected '$SwitchName')") }
            if ($existing.PSObject.Properties['MemoryStartupGb'] -and $existing.MemoryStartupGb -and $existing.MemoryStartupGb -ne $MemStartupGb)           { $drift.Add("memStartupGb=$($existing.MemoryStartupGb) (expected $MemStartupGb)") }
            if ($existing.PSObject.Properties['ProcessorCount']  -and $existing.ProcessorCount  -and $existing.ProcessorCount  -ne $VcpuCount)              { $drift.Add("vcpu=$($existing.ProcessorCount) (expected $VcpuCount)") }
            $status = if (-not $a.Ok)           { 'Warn' }
                      elseif ($drift.Count -gt 0) { 'Warn' }
                      else                        { 'Pass' }
            $driftMsg = if ($drift.Count -gt 0) { " Config drift: $($drift -join '; ')." } else { '' }
            $remed    = if ($drift.Count -gt 0) { "Remove the stale VM and re-run: Stop-VM $name -TurnOff -Force; Remove-VM $name -Force" } else { $null }
            Add-VmStep $steps "VM '$name'" $status "Already present (state: $($existing.State)). Autostart re-applied: $($a.Detail).$driftMsg" $remed
            continue
        }
        $memStartupBytes = [long]$MemStartupGb * 1GB
        $memMinBytes     = [long]$MemMinGb     * 1GB
        $memMaxBytes     = [long]$MemMaxGb     * 1GB
        $n = & $script:VmInvokers.CreateVm $name $vhdx $SwitchName $memStartupBytes $memMinBytes $memMaxBytes $VcpuCount $SecureBootTemplate
        if (-not $n.Ok) {
            Add-VmStep $steps "VM '$name' create" 'Fail' $n.Detail "Manual: New-VM -Name $name -MemoryStartupBytes $memStartupBytes -VHDPath $vhdx -SwitchName $SwitchName -Generation 2"
            continue
        }
        $a = & $script:VmInvokers.ConfigureAutostart $name $delay
        if (-not $a.Ok) {
            Add-VmStep $steps "VM '$name' autostart" 'Warn' $a.Detail "Manual: Set-VM -Name $name -AutomaticStartAction Start -AutomaticStartDelay $delay"
        } else {
            Add-VmStep $steps "VM '$name'" 'Pass' "$($n.Detail) $($a.Detail)"
        }
    }

    return New-VmStageResult -Steps $steps -VmStorageDrive $VmStorageDrive -VmNames $names
}

function New-VmStageResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Pure helper; builds a result pscustomobject.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Steps,
        [string]$VmStorageDrive,
        [string[]]$VmNames
    )
    $passCount = @($Steps | Where-Object { $_.Status -eq 'Pass'    }).Count
    $warnCount = @($Steps | Where-Object { $_.Status -eq 'Warn'    }).Count
    $failCount = @($Steps | Where-Object { $_.Status -eq 'Fail'    }).Count
    $skipCount = @($Steps | Where-Object { $_.Status -eq 'Skipped' }).Count
    $overall = if ($failCount -gt 0) { 'Fail' } elseif ($warnCount -gt 0) { 'Warn' } else { 'Pass' }

    if (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue) {
        foreach ($s in $Steps) {
            $lvl = switch ($s.Status) { 'Pass' {'Info'} 'Warn' {'Warn'} 'Fail' {'Error'} 'Skipped' {'Info'} }
            Write-ClusterLog -Level $lvl -Stage 'vms' -Message "$($s.Name): $($s.Status)" -Data @{ detail = $s.Detail }
        }
        Write-ClusterLog -Level Info -Stage 'vms' `
            -Message "VMs complete: $overall (pass=$passCount warn=$warnCount fail=$failCount skipped=$skipCount)" `
            -Data @{ vmStorageDrive = $VmStorageDrive; vmNames = ($VmNames -join ',') }
    }

    return [pscustomobject]@{
        Overall         = $overall
        Steps           = $Steps.ToArray()
        VmStorageDrive  = $VmStorageDrive
        VmNames         = $VmNames
        PassCount       = $passCount
        WarnCount       = $warnCount
        FailCount       = $failCount
        SkipCount       = $skipCount
    }
}

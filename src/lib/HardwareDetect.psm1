<#
.SYNOPSIS
    Hardware and OS-edition detection for the windows-cluster-host setup
    script. Every function tries multiple strategies and returns the first
    one that yields a useful answer.

.DESCRIPTION
    The host's hardware varies per PC (drive layout, NICs, RAM, CPU virt
    features) and the script must adapt at runtime. This module wraps the
    detection helpers each downstream stage will use:

      Get-WindowsSku            Home | Pro | Enterprise | Education (or
                                'Unknown'). 4-way fallback: Get-WindowsEdition
                                -> registry EditionID -> WMI Caption ->
                                Get-ComputerInfo OsName.

      Get-PhysicalDriveBest     Drive letter with the largest free space
                                that also meets a min-free-GB threshold,
                                excluding the system drive when -ExcludeSystem.
                                Returns $null if no drive qualifies.

      Get-ActiveWifiAdapter     The first NetAdapter whose MediaType is
                                'Native 802.11' and status is 'Up'. Falls
                                back to MediaType 'Wireless LAN' and to
                                Get-WmiObject Win32_NetworkAdapter.

      Get-VirtualizationSupport Returns a pscustomobject with HyperVisorPresent,
                                VtSupported (CPU virt enabled in BIOS),
                                SlatSupported (SLAT for Hyper-V), and the
                                reasons each was reported.

    All detections soft-call Logging.psm1 to record the strategy that won.

.NOTES
    No detection function ever throws on a single-strategy failure -- the
    primitive is "try, log, fall back". The function only throws if EVERY
    strategy fails, in which case the caller (typically the Preflight stage)
    decides what to do.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Soft-dependency on Logging.psm1, same pattern as State.psm1 / Retry.psm1.
# Lookup result is cached so repeated detector calls don't re-probe.
$script:LoggingLookupTried = $false
$script:LoggingCmd         = $null
function Write-ClusterLogIfAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [string]$Stage = 'hardware',
        [hashtable]$Data
    )
    if (-not $script:LoggingLookupTried) {
        $script:LoggingCmd = Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue
        if (-not $script:LoggingCmd) {
            $sibling = Join-Path $PSScriptRoot 'Logging.psm1'
            if (Test-Path -LiteralPath $sibling) {
                Import-Module -Name $sibling -Force -ErrorAction SilentlyContinue
                $script:LoggingCmd = Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue
            }
        }
        $script:LoggingLookupTried = $true
    }
    if (-not $script:LoggingCmd) { return }
    if ($Data) { & $script:LoggingCmd -Level $Level -Message $Message -Stage $Stage -Data $Data }
    else       { & $script:LoggingCmd -Level $Level -Message $Message -Stage $Stage }
}

# Detector seam. Production calls the real Windows cmdlets; unit tests can
# swap any subset of these closures to return canned values without needing
# admin rights or actual hardware. Gated by CLUSTERHOST_ALLOW_TEST_SEAMS.
function Get-DefaultDetector {
    @{
        # Windows edition
        WindowsEditionCmdlet   = { try { (Get-WindowsEdition -Online -ErrorAction Stop).Edition } catch { $null } }
        RegistryEditionID      = { try { (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID' -ErrorAction Stop).EditionID } catch { $null } }
        WmiOsCaption           = { try { (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $null } }
        ComputerInfoOsName     = { try { (Get-ComputerInfo -Property 'OsName' -ErrorAction Stop).OsName } catch { $null } }

        # Drives
        VolumeList             = { try { Get-Volume -ErrorAction Stop } catch { @() } }
        WmiLogicalDiskList     = { try { Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop } catch { @() } }
        SystemDriveLetter      = { ($env:SystemDrive -replace ':','') }

        # Network adapters
        NetAdapterList         = { try { Get-NetAdapter -ErrorAction Stop } catch { @() } }
        WmiNetAdapterList      = { try { Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop } catch { @() } }

        # Virtualization
        ComputerInfoVirt       = { try { Get-ComputerInfo -Property 'HyperVRequirementVirtualizationFirmwareEnabled','HyperVRequirementSecondLevelAddressTranslation','HyperVisorPresent' -ErrorAction Stop } catch { $null } }
        WmiProcessorVirtFlag   = { try { (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0].VirtualizationFirmwareEnabled } catch { $null } }
    }
}

$script:Detector = Get-DefaultDetector

function Confirm-TestSeamAllowed {
    if (-not $env:CLUSTERHOST_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERHOST_ALLOW_TEST_SEAMS=1 to enable Set-HardwareDetector / Reset-HardwareDetector."
    }
}

function Set-HardwareDetector {
    <#
    .SYNOPSIS
        Test-only: override one of the detector closures. Gated by
        CLUSTERHOST_ALLOW_TEST_SEAMS.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test seam gated by env var; mutates only in-process script-scope state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-TestSeamAllowed
    if (-not $script:Detector.ContainsKey($Name)) {
        throw "Set-HardwareDetector: unknown detector '$Name'. Known: $(($script:Detector.Keys | Sort-Object) -join ', ')"
    }
    $script:Detector[$Name] = $ScriptBlock
}

function Reset-HardwareDetector {
    <#
    .SYNOPSIS Test-only: restore the production detector closures.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test seam gated by env var; restores in-process script-scope state.')]
    [CmdletBinding()]
    param()
    Confirm-TestSeamAllowed
    $script:Detector = Get-DefaultDetector
}

# ---------- Windows SKU ----------

function ConvertTo-CanonicalSku {
    <#
    .SYNOPSIS
        Map a raw Windows edition string to one of Home | Pro | Enterprise |
        Education | Unknown.

    .NOTES
        Pro derivatives (Pro Education, Pro for Workstations, Pro
        SingleLanguage) collapse to 'Pro' -- they all support Hyper-V and
        are equivalent for the downstream Preflight gate. Pro Education
        specifically does NOT collapse to 'Education' even though Microsoft
        labels it as such; for the purposes of this script it's a Pro SKU.

        LTSC variants (EnterpriseS, EnterpriseG, IoTEnterpriseLTSC) collapse
        to 'Enterprise' via the substring match.
    #>
    param([string]$Raw)
    if (-not $Raw) { return 'Unknown' }
    $t = $Raw.ToLowerInvariant()
    switch -Regex ($t) {
        # Pro derivatives MUST be checked before 'education' / 'enterprise' so
        # 'ProEducation' / 'Pro Education' classify as Pro, not Education.
        'pro\s*education'      { return 'Pro' }
        'pro\s*single\s*language' { return 'Pro' }
        'pro\s*for\s*workstations' { return 'Pro' }
        'enterprise'           { return 'Enterprise' }
        'education'            { return 'Education' }
        'professional'         { return 'Pro' }
        '\bpro(\b|fessional)'  { return 'Pro' }
        '^pro'                 { return 'Pro' }    # bare 'Pro', 'ProN', 'ProSingleLanguage'
        '\bhome\b'             { return 'Home' }
        '\bcore'               { return 'Home' }   # 'Core', 'CoreSingleLanguage', etc. are Home flavors
        default                { return 'Unknown' }
    }
}

function Get-WindowsSku {
    <#
    .SYNOPSIS
        Detect the Windows edition (SKU). Returns one of
        Home | Pro | Enterprise | Education | Unknown, plus the strategy
        name that produced the answer.

    .OUTPUTS
        pscustomobject @{ Sku; Source; Raw }
    #>
    [CmdletBinding()]
    param()

    $strategies = @(
        @{ Name = 'Get-WindowsEdition'; Key = 'WindowsEditionCmdlet' }
        @{ Name = 'Registry.EditionID'; Key = 'RegistryEditionID'    }
        @{ Name = 'WMI.Caption';        Key = 'WmiOsCaption'         }
        @{ Name = 'Get-ComputerInfo';   Key = 'ComputerInfoOsName'   }
    )

    foreach ($s in $strategies) {
        $raw = & $script:Detector[$s.Key]
        if ($raw) {
            $sku = ConvertTo-CanonicalSku -Raw $raw
            Write-ClusterLogIfAvailable -Level Info -Message "SKU detected" -Data @{
                strategy = $s.Name; sku = $sku; raw = $raw
            }
            if ($sku -ne 'Unknown') {
                return [pscustomobject]@{ Sku = $sku; Source = $s.Name; Raw = "$raw" }
            }
        }
    }

    Write-ClusterLogIfAvailable -Level Warn -Message "SKU detection: all 4 strategies failed; returning Unknown"
    return [pscustomobject]@{ Sku = 'Unknown'; Source = 'none'; Raw = $null }
}

# ---------- Physical drive ----------

function Get-PhysicalDriveBest {
    <#
    .SYNOPSIS
        Pick the drive letter best suited for VM storage. Largest free
        capacity wins, subject to a minimum free-GB threshold.

    .PARAMETER MinFreeGb
        Lower bound on free space the drive must have. Default 120 GB
        assumes 2 VMs x 60 GB. Callers that change the VM count or VHDX
        size MUST pass an explicit value (Preflight stage computes it
        from cluster-config.json: vms.count * vms.min_disk_gb_per_vm).

    .PARAMETER ExcludeSystem
        When set, exclude the OS drive (C: or whatever $env:SystemDrive is)
        from consideration. Default: $false (system drive is eligible if it
        has enough free space).

    .OUTPUTS
        pscustomobject @{ DriveLetter; FreeGb; SizeGb; Source } or $null
        when no drive qualifies.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 8192)]
        [int]$MinFreeGb = 120,
        [switch]$ExcludeSystem
    )

    $sysLetter = & $script:Detector['SystemDriveLetter']

    $candidates = New-Object System.Collections.Generic.List[pscustomobject]
    $source = $null

    $vols = & $script:Detector['VolumeList']
    $volumesReturned = [bool]$vols
    if ($vols) {
        foreach ($v in $vols) {
            if (-not $v.DriveLetter) { continue }
            if (-not $v.SizeRemaining -or -not $v.Size) { continue }
            $letter = "$($v.DriveLetter)".TrimEnd(':').ToUpperInvariant()
            if ($ExcludeSystem -and $letter -eq $sysLetter) { continue }
            $freeGb = [math]::Floor($v.SizeRemaining / 1GB)
            $sizeGb = [math]::Floor($v.Size          / 1GB)
            if ($freeGb -lt $MinFreeGb) { continue }
            $candidates.Add([pscustomobject]@{ DriveLetter = $letter; FreeGb = [int]$freeGb; SizeGb = [int]$sizeGb })
        }
        if ($candidates.Count -gt 0) { $source = 'Get-Volume' }
    }

    if ($candidates.Count -eq 0 -and -not $volumesReturned) {
        # Get-Volume returned nothing AT ALL -- fall back to WMI Win32_LogicalDisk.
        # We do NOT fall back when Get-Volume returned data but no drive
        # qualified; the answer is "no drive qualifies", not "try WMI too".
        $disks = & $script:Detector['WmiLogicalDiskList']
        foreach ($d in $disks) {
            if (-not $d.DeviceID) { continue }
            $letter = ($d.DeviceID -replace ':','').ToUpperInvariant()
            if ($ExcludeSystem -and $letter -eq $sysLetter) { continue }
            if (-not $d.FreeSpace -or -not $d.Size) { continue }
            $freeGb = [math]::Floor([double]$d.FreeSpace / 1GB)
            $sizeGb = [math]::Floor([double]$d.Size      / 1GB)
            if ($freeGb -lt $MinFreeGb) { continue }
            $candidates.Add([pscustomobject]@{ DriveLetter = $letter; FreeGb = [int]$freeGb; SizeGb = [int]$sizeGb })
        }
        if ($candidates.Count -gt 0) { $source = 'Win32_LogicalDisk' }
    }

    if ($candidates.Count -eq 0) {
        Write-ClusterLogIfAvailable -Level Warn -Message "Get-PhysicalDriveBest: no drive meets minimum free-GB threshold" -Data @{ minFreeGb = $MinFreeGb; excludeSystem = [bool]$ExcludeSystem }
        return $null
    }

    $best = $candidates | Sort-Object -Property FreeGb -Descending | Select-Object -First 1
    $obj  = [pscustomobject]@{
        DriveLetter = $best.DriveLetter
        FreeGb      = $best.FreeGb
        SizeGb      = $best.SizeGb
        Source      = $source
    }
    Write-ClusterLogIfAvailable -Level Info -Message "Drive selected for VM storage" -Data @{
        drive  = $obj.DriveLetter
        freeGb = $obj.FreeGb
        sizeGb = $obj.SizeGb
        source = $obj.Source
    }
    return $obj
}

# ---------- WiFi adapter ----------

function Get-ActiveWifiAdapter {
    <#
    .SYNOPSIS
        Return the first Up wireless NetAdapter, or $null if none exist.

    .OUTPUTS
        pscustomobject @{ Name; InterfaceIndex; MediaType; Status; Source }
        or $null.
    #>
    [CmdletBinding()]
    param()

    # Primary: Get-NetAdapter where MediaType matches wireless and Status=Up.
    # Excludes Hyper-V virtual adapters (Virtual=$true) so a re-run after PR 11
    # enables Hyper-V doesn't pick a vSwitch-attached pseudo-NIC.
    $nics = & $script:Detector['NetAdapterList']
    if ($nics) {
        $w = $nics | Where-Object {
            ($_.MediaType -match 'Native 802\.11' -or $_.MediaType -match 'Wireless') -and
            $_.Status -eq 'Up' -and
            -not ($_.PSObject.Properties['Virtual'] -and $_.Virtual)
        } | Select-Object -First 1
        if ($w) {
            Write-ClusterLogIfAvailable -Level Info -Message "WiFi adapter detected" -Data @{
                strategy = 'Get-NetAdapter'; name = $w.Name; mediaType = $w.MediaType
            }
            return [pscustomobject]@{
                Name           = $w.Name
                InterfaceIndex = $w.InterfaceIndex
                MediaType      = $w.MediaType
                Status         = $w.Status
                Source         = 'Get-NetAdapter'
            }
        }
    }

    # Fallback: WMI.
    $wmiNics = & $script:Detector['WmiNetAdapterList']
    foreach ($w in $wmiNics) {
        # NetConnectionStatus 2 = Connected. AdapterType strings vary by locale, so
        # accept anything with 'wireless' in it.
        if ($w.AdapterType -and ($w.AdapterType -match 'wireless') -and $w.NetConnectionStatus -eq 2) {
            Write-ClusterLogIfAvailable -Level Info -Message "WiFi adapter detected" -Data @{
                strategy = 'Win32_NetworkAdapter'; name = $w.Name
            }
            return [pscustomobject]@{
                Name           = $w.Name
                InterfaceIndex = $w.InterfaceIndex
                MediaType      = $w.AdapterType
                Status         = 'Up'
                Source         = 'Win32_NetworkAdapter'
            }
        }
    }

    Write-ClusterLogIfAvailable -Level Warn -Message "No active WiFi adapter detected via any strategy"
    return $null
}

# ---------- Virtualization support ----------

function Get-VirtualizationSupport {
    <#
    .SYNOPSIS
        Detect CPU + firmware virtualization support and Hyper-V presence.

    .OUTPUTS
        pscustomobject @{
            HyperVisorPresent     bool
            VtSupported           bool  -- virtualization enabled in BIOS/UEFI
            SlatSupported         bool  -- SLAT for Hyper-V
            CanRunHyperV          bool  -- summary: SLAT + VT + not-in-VM-blocking
            Reasons               hashtable of source -> value for each field
        }
    #>
    [CmdletBinding()]
    param()

    $reasons = @{}
    $info = & $script:Detector['ComputerInfoVirt']

    # Track which properties Get-ComputerInfo actually answered so we can
    # distinguish "confirmed false" from "could not be determined" downstream.
    $hvInfoOk   = $false
    $vtInfoOk   = $false
    $slatInfoOk = $false
    if ($info) {
        if ($null -ne $info.HyperVisorPresent) {
            $reasons['HyperVisorPresent']       = [bool]$info.HyperVisorPresent
            $reasons['HyperVisorPresentSource'] = 'Get-ComputerInfo'
            $hvInfoOk = $true
        }
        if ($null -ne $info.HyperVRequirementVirtualizationFirmwareEnabled) {
            $reasons['VtSupported'] = [bool]$info.HyperVRequirementVirtualizationFirmwareEnabled
            $reasons['VtSource']    = 'Get-ComputerInfo'
            $vtInfoOk = $true
        }
        if ($null -ne $info.HyperVRequirementSecondLevelAddressTranslation) {
            $reasons['SlatSupported'] = [bool]$info.HyperVRequirementSecondLevelAddressTranslation
            $reasons['SlatSource']    = 'Get-ComputerInfo'
            $slatInfoOk = $true
        }
    }

    # Secondary signal for VT: WMI Win32_Processor flag. Useful when the
    # Get-ComputerInfo path can't read the firmware setting (older
    # Windows builds or virtual hosts).
    if (-not $vtInfoOk) {
        $wmiVt = & $script:Detector['WmiProcessorVirtFlag']
        if ($null -ne $wmiVt) {
            $reasons['VtSupported'] = [bool]$wmiVt
            $reasons['VtSource']    = 'Win32_Processor.VirtualizationFirmwareEnabled'
            $vtInfoOk = $true
        }
    }

    if (-not $hvInfoOk)   { $reasons['HyperVisorPresentSource'] = 'unknown' }
    if (-not $vtInfoOk)   { $reasons['VtSource']                = 'unknown' }
    if (-not $slatInfoOk) { $reasons['SlatSource']              = 'unknown' }

    if (-not ($hvInfoOk -and $vtInfoOk -and $slatInfoOk)) {
        Write-ClusterLogIfAvailable -Level Warn -Message "Virtualization-support probe incomplete" -Data @{
            hyperVisorPresentSource = $reasons['HyperVisorPresentSource']
            vtSource                = $reasons['VtSource']
            slatSource              = $reasons['SlatSource']
        }
    }

    $hvPresent = if ($reasons.ContainsKey('HyperVisorPresent')) { [bool]$reasons['HyperVisorPresent'] } else { $false }
    $vt        = if ($reasons.ContainsKey('VtSupported'))       { [bool]$reasons['VtSupported']       } else { $false }
    $slat      = if ($reasons.ContainsKey('SlatSupported'))     { [bool]$reasons['SlatSupported']     } else { $false }
    # CanRunHyperV is conservative: requires BOTH VT and SLAT to be CONFIRMED true.
    # Unknown values are treated as 'not confirmed', so CanRunHyperV stays false.
    $canRun    = $vt -and $slat

    $result = [pscustomobject]@{
        HyperVisorPresent = $hvPresent
        VtSupported       = $vt
        SlatSupported     = $slat
        CanRunHyperV      = $canRun
        Reasons           = $reasons
    }

    Write-ClusterLogIfAvailable -Level Info -Message "Virtualization support probed" -Data @{
        hyperVisorPresent = $hvPresent
        vtSupported       = $vt
        slatSupported     = $slat
        canRunHyperV      = $canRun
    }
    return $result
}

Export-ModuleMember -Function `
    Get-WindowsSku, `
    Get-PhysicalDriveBest, `
    Get-ActiveWifiAdapter, `
    Get-VirtualizationSupport, `
    ConvertTo-CanonicalSku

# Test seams are intentionally NOT exported. Reach them inside the module via:
#   & (Get-Module HardwareDetect) { Set-HardwareDetector -Name X -ScriptBlock {...} }
# After setting $env:CLUSTERHOST_ALLOW_TEST_SEAMS=1.

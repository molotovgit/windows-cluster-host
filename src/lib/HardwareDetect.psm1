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
function Write-ClusterLogIfAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [string]$Stage = 'hardware',
        [hashtable]$Data
    )
    $cmd = Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $sibling = Join-Path $PSScriptRoot 'Logging.psm1'
        if (Test-Path -LiteralPath $sibling) {
            Import-Module -Name $sibling -Force -ErrorAction SilentlyContinue
            $cmd = Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue
        }
    }
    if (-not $cmd) { return }
    if ($Data) { & $cmd -Level $Level -Message $Message -Stage $Stage -Data $Data }
    else       { & $cmd -Level $Level -Message $Message -Stage $Stage }
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
    param([string]$Raw)
    if (-not $Raw) { return 'Unknown' }
    $t = $Raw.ToLowerInvariant()
    switch -Regex ($t) {
        'enterprise'           { return 'Enterprise' }
        'education'            { return 'Education' }
        'professional'         { return 'Pro' }
        '\bpro(\b|fessional)'  { return 'Pro' }
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
        Lower bound on free space the drive must have (default 60 GB per VM
        x default 2 VMs == 120 GB).

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
    $nics = & $script:Detector['NetAdapterList']
    if ($nics) {
        $w = $nics | Where-Object {
            ($_.MediaType -match 'Native 802\.11' -or $_.MediaType -match 'Wireless') -and
            $_.Status -eq 'Up'
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
    if ($info) {
        $reasons['HyperVisorPresent']  = $info.HyperVisorPresent
        $reasons['VtSupported']        = $info.HyperVRequirementVirtualizationFirmwareEnabled
        $reasons['SlatSupported']      = $info.HyperVRequirementSecondLevelAddressTranslation
    }

    # Secondary signal for VT: WMI Win32_Processor flag. Useful when the
    # Get-ComputerInfo path can't read the firmware setting (older
    # Windows builds or virtual hosts).
    $wmiVt = & $script:Detector['WmiProcessorVirtFlag']
    if ($null -eq $reasons['VtSupported'] -and $null -ne $wmiVt) {
        $reasons['VtSupported']  = [bool]$wmiVt
        $reasons['VtSource']     = 'Win32_Processor.VirtualizationFirmwareEnabled'
    } elseif ($info) {
        $reasons['VtSource']     = 'Get-ComputerInfo'
    }

    $hvPresent = [bool]$reasons['HyperVisorPresent']
    $vt        = [bool]$reasons['VtSupported']
    $slat      = [bool]$reasons['SlatSupported']
    $canRun    = $vt -and $slat   # Hyper-V can be ENABLED even if not yet running

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

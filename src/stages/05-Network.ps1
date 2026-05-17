<#
.SYNOPSIS
    Stage 5 -- Network. Create an internal Hyper-V vSwitch + NAT for the
    VMs to share the host's WiFi uplink.

.DESCRIPTION
    Builds a per-host NAT network:
        - Internal vSwitch named per config (default ClusterNATSwitch)
        - Host-side gateway IP at <subnet>.1/24 on that switch
        - NetNat entry mapping the chosen /24 to the WiFi uplink

    Subnet selection: iterates network.nat_candidate_subnets and picks the
    first /24 that does NOT collide with any existing route. This keeps
    each host's VM subnet unique on its physical LAN.

    Idempotent: probes existing switch / IP / NAT and skips writes when
    state already matches.

    Fallback: if NetNat module isn't available (Win10 LTSC etc.), creates
    an internal-only vSwitch with the host IP -- VMs can still talk to
    the host but won't reach the broader LAN. Reports Overall=Warn.

    -DryRun reports what would change without applying.

    Returns: pscustomobject @{
        Overall = 'Pass' | 'Warn' | 'Fail';
        Method  = 'AlreadyConfigured' | 'CreatedWithNat' | 'CreatedInternalOnly' | 'DryRun' | 'None';
        SwitchName; Subnet; GatewayIp; Detail; Remediation
    }
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

function Get-DefaultNetworkInvoker {
    @{
        # Return array of @{ Name; SwitchType; NetAdapterInterfaceDescription } or @().
        GetVMSwitch    = { try { @(Get-VMSwitch -ErrorAction Stop | ForEach-Object {
                                    [pscustomobject]@{ Name = $_.Name; SwitchType = "$($_.SwitchType)"; NetAdapterInterfaceDescription = "$($_.NetAdapterInterfaceDescription)" }
                                  }) } catch { $null = $_; @() } }
        NewVMSwitch    = { param([string]$Name) New-VMSwitch -Name $Name -SwitchType Internal -ErrorAction Stop | Out-Null }
        # Existing NetIPAddresses array.
        GetNetIPv4     = { try { @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object {
                                     [pscustomobject]@{ IPAddress = $_.IPAddress; PrefixLength = $_.PrefixLength; InterfaceAlias = $_.InterfaceAlias }
                                  }) } catch { $null = $_; @() } }
        NewNetIPAddr   = {
            param([string]$Alias, [string]$Ip, [int]$Prefix)
            New-NetIPAddress -InterfaceAlias $Alias -IPAddress $Ip -PrefixLength $Prefix -ErrorAction Stop | Out-Null
        }
        GetNetRoute    = { try { @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object {
                                     [pscustomobject]@{ DestinationPrefix = $_.DestinationPrefix }
                                  }) } catch { $null = $_; @() } }
        GetNetNat      = { try { @(Get-NetNat -ErrorAction Stop | ForEach-Object {
                                     [pscustomobject]@{ Name = $_.Name; InternalIPInterfaceAddressPrefix = "$($_.InternalIPInterfaceAddressPrefix)" }
                                  }) } catch { $null = $_; @() } }
        NewNetNat      = {
            param([string]$Name, [string]$Prefix)
            New-NetNat -Name $Name -InternalIPInterfaceAddressPrefix $Prefix -ErrorAction Stop | Out-Null
        }
        # NetNat module presence check (some Win editions ship without it).
        HasNetNatCmdlet = { [bool](Get-Command -Name New-NetNat -ErrorAction SilentlyContinue) }
    }
}

$script:NetworkInvokers = Get-DefaultNetworkInvoker

function Confirm-TestSeamAllowed {
    if (-not $env:CLUSTERHOST_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERHOST_ALLOW_TEST_SEAMS=1 to enable Set-NetworkInvoker / Reset-NetworkInvoker."
    }
}

function Set-NetworkInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][scriptblock]$ScriptBlock)
    Confirm-TestSeamAllowed
    if (-not $script:NetworkInvokers.ContainsKey($Name)) {
        throw "Set-NetworkInvoker: unknown invoker '$Name'. Known: $(($script:NetworkInvokers.Keys | Sort-Object) -join ', ')"
    }
    $script:NetworkInvokers[$Name] = $ScriptBlock
}

function Reset-NetworkInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test seam gated by env var.')]
    [CmdletBinding()]
    param()
    Confirm-TestSeamAllowed
    $script:NetworkInvokers = Get-DefaultNetworkInvoker
}

# ---------- helpers ----------

function Convert-CidrToPrefix {
    # '192.168.100.0/24' -> @{ Network='192.168.100.0'; Prefix=24; Gateway='192.168.100.1' }
    param([Parameter(Mandatory)][string]$Cidr)
    $parts = $Cidr -split '/'
    if ($parts.Count -ne 2) { throw "Convert-CidrToPrefix: '$Cidr' is not a CIDR." }
    $net    = $parts[0]
    $prefix = [int]$parts[1]
    $octets = $net -split '\.'
    if ($octets.Count -ne 4) { throw "Convert-CidrToPrefix: '$net' is not an IPv4 address." }
    $gw = "$($octets[0]).$($octets[1]).$($octets[2]).1"
    return @{ Network = $net; Prefix = $prefix; Gateway = $gw }
}

function Find-FreeSubnet {
    # Returns the first candidate whose /24 doesn't collide with an existing route.
    param(
        [Parameter(Mandatory)][string[]]$Candidates
    )
    $routes = & $script:NetworkInvokers.GetNetRoute
    $taken  = @($routes | ForEach-Object { "$($_.DestinationPrefix)" } | Where-Object { $_ })
    foreach ($c in $Candidates) {
        if (-not ($taken -contains $c)) {
            return $c
        }
    }
    return $null
}

# ---------- public ----------

function Invoke-NetworkStage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions','',
        Justification='Stage entry point: creates an internal Hyper-V switch + NAT. -DryRun honored.')]
    [CmdletBinding()]
    param(
        $Config,
        [string]$SwitchName,
        [string[]]$CandidateSubnets,
        [switch]$DryRun
    )

    # Resolve config-driven defaults.
    if (-not $SwitchName) {
        if ($Config -and $Config.PSObject.Properties['network'] -and $Config.network -and `
            $Config.network.PSObject.Properties['nat_switch_name']) {
            $SwitchName = "$($Config.network.nat_switch_name)"
        }
    }
    if (-not $SwitchName) { $SwitchName = 'ClusterNATSwitch' }

    if (-not $CandidateSubnets -or $CandidateSubnets.Count -eq 0) {
        if ($Config -and $Config.PSObject.Properties['network'] -and $Config.network -and `
            $Config.network.PSObject.Properties['nat_candidate_subnets']) {
            $CandidateSubnets = @($Config.network.nat_candidate_subnets)
        }
    }
    if (-not $CandidateSubnets -or $CandidateSubnets.Count -eq 0) {
        $CandidateSubnets = @('192.168.100.0/24','192.168.150.0/24','172.20.50.0/24','10.50.0.0/24')
    }

    # ---------- subnet selection ----------
    $chosenCidr = Find-FreeSubnet -Candidates $CandidateSubnets
    if (-not $chosenCidr) {
        $result = [pscustomobject]@{
            Overall = 'Fail'; Method = 'None'; SwitchName = $SwitchName; Subnet = $null; GatewayIp = $null
            Detail  = "All candidate subnets collide with existing host routes. Tried: $($CandidateSubnets -join ', ')."
            Remediation = 'Add more entries to network.nat_candidate_subnets in cluster-config.json or change the host''s upstream network.'
        }
        Write-NetworkLog $result
        return $result
    }
    $parsed  = Convert-CidrToPrefix -Cidr $chosenCidr
    $gateway = $parsed.Gateway
    $prefix  = $parsed.Prefix
    $network = $parsed.Network

    # ---------- vSwitch ----------
    $switches = & $script:NetworkInvokers.GetVMSwitch
    $existingSwitch = $switches | Where-Object { $_.Name -eq $SwitchName } | Select-Object -First 1

    # ---------- NetNat availability ----------
    $hasNat = [bool](& $script:NetworkInvokers.HasNetNatCmdlet)

    # ---------- existing-state pass-through ----------
    if ($existingSwitch -and -not $DryRun) {
        $ips = @(& $script:NetworkInvokers.GetNetIPv4 | Where-Object {
            $_.InterfaceAlias -match [regex]::Escape($SwitchName) -and $_.IPAddress -eq $gateway -and $_.PrefixLength -eq $prefix
        })
        $nats = if ($hasNat) {
            @(& $script:NetworkInvokers.GetNetNat | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $chosenCidr })
        } else { @() }
        if ($ips.Count -gt 0 -and ($nats.Count -gt 0 -or -not $hasNat)) {
            $result = [pscustomobject]@{
                Overall = 'Pass'; Method = 'AlreadyConfigured'; SwitchName = $SwitchName
                Subnet  = $chosenCidr; GatewayIp = $gateway
                Detail  = "Switch '$SwitchName' already configured with gateway $gateway/$prefix and NAT $(if(-not $hasNat){'(NetNat unavailable; internal-only)'}else{$chosenCidr})."
                Remediation = $null
            }
            Write-NetworkLog $result
            return $result
        }
    }

    if ($DryRun) {
        $result = [pscustomobject]@{
            Overall = 'Pass'; Method = 'DryRun'; SwitchName = $SwitchName
            Subnet  = $chosenCidr; GatewayIp = $gateway
            Detail  = "DryRun: would create internal switch '$SwitchName' with gateway $gateway/$prefix$( if($hasNat){' and NetNat for '+$chosenCidr}else{' (NetNat unavailable; internal-only)'} )."
            Remediation = $null
        }
        Write-NetworkLog $result
        return $result
    }

    # ---------- apply ----------
    try {
        if (-not $existingSwitch) {
            & $script:NetworkInvokers.NewVMSwitch -Name $SwitchName
        }
        # Find the alias to bind the IP. Hyper-V exposes 'vEthernet ($SwitchName)'.
        $alias = "vEthernet ($SwitchName)"
        # Idempotent IP: only add when missing.
        $existingIp = @(& $script:NetworkInvokers.GetNetIPv4 | Where-Object {
            $_.InterfaceAlias -eq $alias -and $_.IPAddress -eq $gateway
        })
        if ($existingIp.Count -eq 0) {
            & $script:NetworkInvokers.NewNetIPAddr -Alias $alias -Ip $gateway -Prefix $prefix
        }

        if ($hasNat) {
            $existingNat = @(& $script:NetworkInvokers.GetNetNat | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $chosenCidr })
            if ($existingNat.Count -eq 0) {
                $natName = "$($SwitchName)Nat"
                & $script:NetworkInvokers.NewNetNat -Name $natName -Prefix $chosenCidr
            }
            $result = [pscustomobject]@{
                Overall = 'Pass'; Method = 'CreatedWithNat'; SwitchName = $SwitchName
                Subnet  = $chosenCidr; GatewayIp = $gateway
                Detail  = "Created internal switch '$SwitchName' with gateway $gateway/$prefix and NAT for $chosenCidr."
                Remediation = $null
            }
        } else {
            $result = [pscustomobject]@{
                Overall = 'Warn'; Method = 'CreatedInternalOnly'; SwitchName = $SwitchName
                Subnet  = $chosenCidr; GatewayIp = $gateway
                Detail  = "NetNat module not available; created internal-only switch '$SwitchName' with gateway $gateway/$prefix. VMs can talk to host but won't reach the broader LAN."
                Remediation = 'Install the NetNat capability or manually configure a different NAT path (ICS, third-party, etc.).'
            }
        }
        Write-NetworkLog $result
        return $result
    } catch {
        $result = [pscustomobject]@{
            Overall = 'Fail'; Method = 'None'; SwitchName = $SwitchName; Subnet = $chosenCidr; GatewayIp = $gateway
            Detail  = "Network configuration threw: $($_.Exception.Message)"
            Remediation = "Verify the Hyper-V service is running, the user is elevated, and re-run. Manual: New-VMSwitch -Name $SwitchName -SwitchType Internal; New-NetIPAddress -InterfaceAlias 'vEthernet ($SwitchName)' -IPAddress $gateway -PrefixLength $prefix; New-NetNat -Name $($SwitchName)Nat -InternalIPInterfaceAddressPrefix $chosenCidr"
        }
        Write-NetworkLog $result
        return $result
    }
}

function Write-NetworkLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result)
    if (-not (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue)) { return }
    $lvl = switch ($Result.Overall) { 'Pass' { 'Info' } 'Warn' { 'Warn' } 'Fail' { 'Error' } default { 'Info' } }
    Write-ClusterLog -Level $lvl -Stage 'network' -Message "Network stage: $($Result.Overall) via $($Result.Method)" -Data @{
        switch  = $Result.SwitchName
        subnet  = $Result.Subnet
        gateway = $Result.GatewayIp
    }
}

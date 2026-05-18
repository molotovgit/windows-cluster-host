<#
.SYNOPSIS
    Controller discovery for the windows-cluster-host setup script.

.DESCRIPTION
    Locates the MeshCentral controller PC at runtime using a chain of
    strategies. The first one that yields an address that ALSO responds to
    a probe wins. If no strategy succeeds, Find-Controller returns $null
    with an actionable error in the log -- the orchestrator decides whether
    to halt or escalate (no interactive prompts in unattended mode).

    Strategies tried in order:

      1. Config file        cluster-config.json -> controller.address
      2. mDNS / DNS         Resolve-DnsName on each -CandidateName
                            (default: 'controller.local', 'controller')
      3. Subnet scan        Test-Connection on each .1 / .10 / .100 / .254
                            of every local IPv4 /24
      4. (intentionally no prompt in unattended mode)

    Every candidate that resolves is then probed at -CandidatePorts (default
    443) at -ProbePath (default '/') with a short timeout. The probe
    succeeds on any 2xx/3xx/401 response (MeshCentral's login page is the
    typical 200; some configs return 401 for unauthenticated GETs).

.NOTES
    Uses the same invoker-seam pattern as State.psm1 / HardwareDetect.psm1
    -- production code calls the real Windows cmdlets; tests swap the
    closures via Set-DiscoveryInvoker (CLUSTERHOST_ALLOW_TEST_SEAMS gate).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- soft Logging dependency ----------
$script:LoggingLookupTried = $false
$script:LoggingCmd         = $null
function Write-ClusterLogIfAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [string]$Stage = 'discovery',
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

# ---------- pluggable invokers ----------

function Get-DefaultDiscoveryInvoker {
    @{
        # Resolve a name to an IPv4 address. Returns the first IPv4 string,
        # or $null on failure. Used for both DNS and mDNS (Windows resolves
        # .local via Bonjour-style multicast if mDNS is wired in, otherwise
        # via DNS suffixes).
        Resolve = {
            param([string]$Name)
            try {
                $r = Resolve-DnsName -Name $Name -Type A -ErrorAction Stop -QuickTimeout
                $a = @($r) | Where-Object { $_.QueryType -eq 'A' -and $_.IPAddress } | Select-Object -First 1
                if ($a) { return "$($a.IPAddress)" }
                return $null
            } catch { return $null }
        }

        # Read the IPv4 addresses + prefix-length tuples assigned to local
        # interfaces. Used to seed the subnet-scan strategy.
        LocalIPv4 = {
            try {
                Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                    Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' -and $_.PrefixLength -le 30 } |
                    ForEach-Object {
                        [pscustomobject]@{ IPAddress = $_.IPAddress; PrefixLength = $_.PrefixLength }
                    }
            } catch { @() }
        }

        # Lightweight TCP reachability check. Returns $true if the port
        # accepted the connection within $TimeoutMs, $false otherwise.
        TestTcp = {
            param([string]$Address, [int]$Port, [int]$TimeoutMs)
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
                if ($client) {
                    try { $client.Close() } catch { Write-Debug "TcpClient.Close: $($_.Exception.Message)" }
                }
            }
        }

        # Probe an HTTPS URL with a short timeout. Returns a pscustomobject
        # @{ Status; Body } -- Status int and a short snippet of the body for
        # MeshCentral-marker matching. Returns $null on connection error.
        HttpProbe = {
            param([string]$Url, [int]$TimeoutSec)
            try {
                $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec `
                                       -SkipCertificateCheck -ErrorAction Stop -Method Get
                $body = ''
                try { $body = "$($r.Content)" } catch { $body = '' }
                return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = $body }
            } catch {
                # Under StrictMode, $_.Exception.Response throws when the
                # exception type has no Response property (DNS errors, TLS
                # handshake failures, timeouts, connection-refused all produce
                # HttpRequestException or its inner aggregate, none of which
                # carry a Response). Probe safely via PSObject.Properties.
                $ex = $_.Exception
                $hasResp = $false
                try { $hasResp = $null -ne $ex.PSObject.Properties['Response'] -and $null -ne $ex.Response } catch { $hasResp = $false }
                if ($hasResp) {
                    return [pscustomobject]@{ Status = [int]$ex.Response.StatusCode; Body = '' }
                }
                return $null
            }
        }

        # Read the config file. Returns a hashtable parsed from JSON, or $null.
        ReadConfig = {
            param([string]$Path)
            if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
            try {
                return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            } catch { return $null }
        }

        # Persist the discovered controller back into a config file (separate
        # from the example, so we don't dirty source).
        WriteDiscovered = {
            param([string]$Path, [hashtable]$Record)
            if (-not $Path) { return }
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force | Out-Null
            }
            $json = $Record | ConvertTo-Json -Depth 6
            [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
        }
    }
}

$script:DiscoveryInvokers = Get-DefaultDiscoveryInvoker

function Confirm-TestSeamAllowed {
    if (-not $env:CLUSTERHOST_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERHOST_ALLOW_TEST_SEAMS=1 to enable Set-DiscoveryInvoker / Reset-DiscoveryInvoker."
    }
}

function Set-DiscoveryInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test seam gated by env var; mutates only in-process script-scope state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-TestSeamAllowed
    if (-not $script:DiscoveryInvokers.ContainsKey($Name)) {
        throw "Set-DiscoveryInvoker: unknown invoker '$Name'. Known: $(($script:DiscoveryInvokers.Keys | Sort-Object) -join ', ')"
    }
    $script:DiscoveryInvokers[$Name] = $ScriptBlock
}

function Reset-DiscoveryInvoker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test seam gated by env var; restores in-process script-scope state.')]
    [CmdletBinding()]
    param()
    Confirm-TestSeamAllowed
    $script:DiscoveryInvokers = Get-DefaultDiscoveryInvoker
}

# ---------- internal helpers ----------

function Test-ProbeOk {
    param([int]$Status)
    return ($Status -ge 200 -and $Status -lt 400) -or ($Status -eq 401)
}

function Test-ControllerEndpoint {
    <#
    .SYNOPSIS
        TCP-probe a host:port then HTTPS-probe the path. To distinguish a
        real MeshCentral controller from a captive portal / router admin UI,
        the response body must contain a recognisable marker.

    .PARAMETER MeshCentralMarker
        Regex tested case-insensitively against the response body. Default
        '(?i)meshcentral' -- MeshCentral's default login page includes the
        product name in title, scripts, and copyright notice.

    .OUTPUTS
        pscustomobject @{ Ok; Status; Url; Reason }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [int]$Port = 443,
        [string]$ProbePath = '/',
        [int]$TcpTimeoutMs = 750,
        [int]$HttpTimeoutSec = 4,
        [string]$MeshCentralMarker = '(?i)meshcentral'
    )
    $url = "https://$Address`:$Port$ProbePath"
    $tcpOk = & $script:DiscoveryInvokers.TestTcp $Address $Port $TcpTimeoutMs
    if (-not $tcpOk) {
        return [pscustomobject]@{ Ok = $false; Status = $null; Url = $url; Reason = 'tcp-closed' }
    }
    $resp = & $script:DiscoveryInvokers.HttpProbe $url $HttpTimeoutSec
    if ($null -eq $resp) {
        return [pscustomobject]@{ Ok = $false; Status = $null; Url = $url; Reason = 'no-response' }
    }
    $status = $resp.Status
    $body   = if ($resp.PSObject.Properties['Body']) { "$($resp.Body)" } else { '' }
    if (-not (Test-ProbeOk $status)) {
        return [pscustomobject]@{ Ok = $false; Status = $status; Url = $url; Reason = "http-$status" }
    }
    # 2xx/3xx/401 alone is not enough -- require the MeshCentral marker so a
    # captive portal or router admin UI on the LAN doesn't false-positive.
    if ($body -and ($body -match $MeshCentralMarker)) {
        return [pscustomobject]@{ Ok = $true; Status = $status; Url = $url; Reason = 'ok' }
    }
    # 401 with no body is allowed -- MeshCentral sometimes returns 401 with
    # an empty body before redirecting; downstream stages will surface the
    # real verification (login attempt) anyway.
    if ($status -eq 401 -and -not $body) {
        return [pscustomobject]@{ Ok = $true; Status = $status; Url = $url; Reason = 'ok-401-empty' }
    }
    return [pscustomobject]@{ Ok = $false; Status = $status; Url = $url; Reason = "marker-missing" }
}

function Get-SubnetScanTarget {
    <#
    .SYNOPSIS
        For each local IPv4 interface with a usable prefix length, return a
        small set of probable controller addresses to scan.
    #>
    [CmdletBinding()]
    param([int[]]$LastOctets = @(1, 10, 100, 254))

    $interfaces = & $script:DiscoveryInvokers.LocalIPv4
    if (-not $interfaces) { return @() }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($iface in $interfaces) {
        # Only scan typical /24-sized home / lab subnets to keep the probe cheap.
        if ($iface.PrefixLength -lt 22 -or $iface.PrefixLength -gt 30) { continue }
        $parts = $iface.IPAddress -split '\.'
        if ($parts.Count -ne 4) { continue }
        $prefix = "$($parts[0]).$($parts[1]).$($parts[2])"
        foreach ($oct in $LastOctets) {
            $cand = "$prefix.$oct"
            if ($cand -ne $iface.IPAddress) {
                [void]$out.Add($cand)
            }
        }
    }
    return @($out | Select-Object -Unique)
}

# ---------- public ----------

function Find-Controller {
    <#
    .SYNOPSIS
        Locate the MeshCentral controller. Returns
        @{ Address; Source; Url; Port; Status } on success, or $null.

    .PARAMETER ConfigPath
        Path to cluster-config.json. If the file exists and has
        controller.address set, that's the first thing tried.

    .PARAMETER CandidateNames
        Names to resolve via DNS / mDNS. Default 'controller.local','controller'.

    .PARAMETER CandidatePorts
        Ports to probe on each candidate address. Default 443.

    .PARAMETER ProbePath
        URL path to GET. Default '/'.

    .PARAMETER PersistPath
        If supplied AND a controller is found AND the source is not 'config',
        write the discovered address back to this file (so subsequent runs
        skip discovery). Default $null.

    .PARAMETER MaxSubnetScans
        Upper bound on subnet probe-targets to try. Default 16. The
        Get-SubnetScanTarget helper already returns a small set; this is a
        safety cap.

    .PARAMETER LastOctetsForScan
        Octets to try when constructing subnet-scan candidates.
        Default 1, 10, 100, 254.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', 'ProbePath',
        Justification = 'ProbePath is captured by the nested Confirm-Candidate function and passed to Test-ControllerEndpoint; the analyzer does not see through the inner function.')]
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string[]]$CandidateNames = @('controller.local','controller'),
        [int[]]$CandidatePorts    = @(443),
        [string]$ProbePath        = '/',
        [string]$PersistPath,
        [int]$MaxSubnetScans      = 16,
        [int[]]$LastOctetsForScan = @(1, 10, 100, 254)
    )

    # Helper -- given an Address candidate and the strategy label, probe and
    # build the success record if it answers.
    function Confirm-Candidate {
        param([string]$Address, [string]$Source)
        foreach ($port in $CandidatePorts) {
            $probe = Test-ControllerEndpoint -Address $Address -Port $port -ProbePath $ProbePath
            if ($probe.Ok) {
                $rec = [pscustomobject]@{
                    Address = $Address
                    Source  = $Source
                    Url     = $probe.Url
                    Port    = $port
                    Status  = $probe.Status
                }
                Write-ClusterLogIfAvailable -Level Info -Message "Controller discovered" -Data @{
                    source = $Source; address = $Address; port = $port; status = $probe.Status
                }
                return $rec
            } else {
                Write-ClusterLogIfAvailable -Level Debug -Message "Probe miss" -Data @{
                    source = $Source; address = $Address; port = $port; reason = $probe.Reason
                }
            }
        }
        return $null
    }

    # ----- Strategy 1: config file -----
    if ($ConfigPath) {
        $cfg = & $script:DiscoveryInvokers.ReadConfig $ConfigPath
        if ($cfg) {
            $addr = $null
            if ($cfg.PSObject.Properties['controller'] -and $cfg.controller `
                -and $cfg.controller.PSObject.Properties['address']) {
                $addr = "$($cfg.controller.address)"
            }
            if ($addr) {
                $found = Confirm-Candidate -Address $addr -Source 'config'
                if ($found) { return $found }
                Write-ClusterLogIfAvailable -Level Warn -Message "Config-listed controller did not respond; trying other strategies" -Data @{ address = $addr }
            }
        }
    }

    # ----- Strategy 2: DNS / mDNS -----
    foreach ($name in $CandidateNames) {
        $ip = & $script:DiscoveryInvokers.Resolve $name
        if ($ip) {
            $found = Confirm-Candidate -Address $ip -Source "dns:$name"
            if ($found) {
                if ($PersistPath) { & $script:DiscoveryInvokers.WriteDiscovered $PersistPath @{ address = $found.Address; source = $found.Source; discovered_at = ([datetime]::UtcNow.ToString('o')) } }
                return $found
            }
        }
    }

    # ----- Strategy 3: subnet scan -----
    $targets = @(Get-SubnetScanTarget -LastOctets $LastOctetsForScan) | Select-Object -First $MaxSubnetScans
    foreach ($cand in $targets) {
        $found = Confirm-Candidate -Address $cand -Source 'subnet-scan'
        if ($found) {
            if ($PersistPath) { & $script:DiscoveryInvokers.WriteDiscovered $PersistPath @{ address = $found.Address; source = $found.Source; discovered_at = ([datetime]::UtcNow.ToString('o')) } }
            return $found
        }
    }

    Write-ClusterLogIfAvailable -Level Error `
        -Message "Find-Controller: every strategy failed (config / dns / subnet-scan). Set controller.address in cluster-config.json or place the controller on the same WiFi SSID and retry." `
        -Data @{
            candidateNames = ($CandidateNames -join ',')
            candidatePorts = ($CandidatePorts -join ',')
            subnetTargets  = ($targets         -join ',')
        }
    return $null
}

Export-ModuleMember -Function `
    Find-Controller, `
    Test-ControllerEndpoint, `
    Get-SubnetScanTarget

# Test seams (Set-DiscoveryInvoker, Reset-DiscoveryInvoker) are intentionally
# NOT exported. Reach them via '& (Get-Module Discovery) { ... }' after setting
# $env:CLUSTERHOST_ALLOW_TEST_SEAMS=1.

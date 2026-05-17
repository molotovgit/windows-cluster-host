<#
.SYNOPSIS
    Stage 2 -- Discover. Locate the MeshCentral controller and persist the
    answer to the local state directory.

.DESCRIPTION
    Thin wrapper around lib/Discovery.psm1's Find-Controller. Returns:

        @{
            Overall  = 'Pass' | 'Fail'
            Address; Source; Url; Port; Status
            ConfigPath; PersistPath
        }

    On failure in unattended mode the function returns Overall='Fail' with
    a clear remediation message; it never prompts. The orchestrator decides
    whether to halt or continue.

    The discovered address is persisted to
    %ProgramData%\ClusterHost\state\controller.json (override with
    -PersistPath) so subsequent runs can skip the network probe.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Soft-load sibling lib modules.
$libDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\lib'
foreach ($mod in 'Logging','Discovery') {
    if (-not (Get-Module -Name $mod)) {
        $candidate = Join-Path $libDir "$mod.psm1"
        if (Test-Path -LiteralPath $candidate) { Import-Module -Name $candidate -Force }
    }
}

function Get-DefaultPersistPath {
    if ($env:CLUSTERHOST_STATE_DIR) {
        return (Join-Path $env:CLUSTERHOST_STATE_DIR 'controller.json')
    }
    return (Join-Path $env:ProgramData 'ClusterHost\state\controller.json')
}

function Confirm-PersistPathWritable {
    # Make sure the persist directory exists and is writable before delegating
    # to Find-Controller (whose WriteDiscovered would otherwise throw an
    # access-denied exception that escapes the stage's structured Fail
    # contract). On failure, fall back to LOCALAPPDATA as a last resort.
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not $dir) { return $Path }

    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $dir ('.write-probe-' + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $probe -Value 'ok' -Encoding utf8 -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $Path
    } catch {
        $null = $_
        $fallbackDir = Join-Path $env:LOCALAPPDATA 'ClusterHost\state'
        try { New-Item -Path $fallbackDir -ItemType Directory -Force -ErrorAction Stop | Out-Null } catch { $null = $_ }
        return (Join-Path $fallbackDir (Split-Path -Leaf $Path))
    }
}

function Invoke-DiscoverStage {
    <#
    .SYNOPSIS
        Run controller discovery and return a structured result.

    .PARAMETER ConfigPath
        Path to cluster-config.json (the operator-edited copy).

    .PARAMETER Config
        Pre-parsed config object. Used to pull candidate.names / port /
        protocol if the caller has already loaded the config.

    .PARAMETER PersistPath
        Where to write the discovered controller record. Default
        %ProgramData%\ClusterHost\state\controller.json (or
        $env:CLUSTERHOST_STATE_DIR\controller.json).

    .PARAMETER CandidateNames
        Names to try for DNS/mDNS resolution. Default 'controller.local',
        'controller'.

    .PARAMETER CandidatePorts
        Ports to probe. Default 443 (or controller.port from config).

    .OUTPUTS
        pscustomobject @{
            Overall; Address; Source; Url; Port; Status;
            ConfigPath; PersistPath; Detail; Remediation
        }
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        $Config,
        [string]$PersistPath,
        [string[]]$CandidateNames,
        [int[]]$CandidatePorts
    )

    if (-not $PersistPath) { $PersistPath = Get-DefaultPersistPath }
    $PersistPath = Confirm-PersistPathWritable -Path $PersistPath

    $portsExplicit = $PSBoundParameters.ContainsKey('CandidatePorts')
    if (-not $CandidateNames -or $CandidateNames.Count -eq 0) { $CandidateNames = @('controller.local','controller') }
    if (-not $CandidatePorts -or $CandidatePorts.Count -eq 0) { $CandidatePorts = @(443) }

    # Optional config override of port. The explicit -CandidatePorts parameter
    # (when supplied) WINS over -Config.controller.port so a caller that knows
    # the port can override the config file.
    if (-not $portsExplicit -and `
        $Config -and $Config.PSObject.Properties['controller'] -and $Config.controller -and `
        $Config.controller.PSObject.Properties['port'] -and $Config.controller.port) {
        $CandidatePorts = @([int]$Config.controller.port)
    }

    # If -Config is supplied with a controller.address but no -ConfigPath,
    # the underlying Find-Controller would skip the config-file branch.
    # Emit a warning so the caller knows -Config alone is advisory for the
    # port override and does NOT seed the address strategy.
    if ($Config -and -not $ConfigPath -and `
        $Config.PSObject.Properties['controller'] -and $Config.controller -and `
        $Config.controller.PSObject.Properties['address'] -and $Config.controller.address) {
        if (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue) {
            Write-ClusterLog -Level Warn -Stage 'discover' `
                -Message "-Config.controller.address is ignored without -ConfigPath; pass -ConfigPath so Find-Controller can use the config-file strategy." `
                -Data @{ address = "$($Config.controller.address)" }
        }
    }

    try {
        $found = Find-Controller -ConfigPath $ConfigPath `
                                 -CandidateNames $CandidateNames `
                                 -CandidatePorts $CandidatePorts `
                                 -PersistPath $PersistPath
    } catch {
        $exMsg = $_.Exception.Message
        if (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue) {
            Write-ClusterLog -Level Error -Stage 'discover' `
                -Message "Find-Controller threw -- treating as discovery failure." `
                -ErrorRecord $_
        }
        return [pscustomobject]@{
            Overall     = 'Fail'
            Address     = $null
            Source      = $null
            Url         = $null
            Port        = $null
            Status      = $null
            ConfigPath  = $ConfigPath
            PersistPath = $PersistPath
            Detail      = "Find-Controller threw: $exMsg"
            Remediation = "Discovery threw an unhandled exception ($exMsg). Investigate the log file (lib/Logging.psm1 default path) and re-run."
        }
    }

    if ($found) {
        if (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue) {
            Write-ClusterLog -Level Info -Stage 'discover' `
                -Message "Discover stage complete" -Data @{
                    address    = $found.Address
                    source     = $found.Source
                    url        = $found.Url
                    persistAt  = $PersistPath
                }
        }
        return [pscustomobject]@{
            Overall     = 'Pass'
            Address     = $found.Address
            Source      = $found.Source
            Url         = $found.Url
            Port        = $found.Port
            Status      = $found.Status
            ConfigPath  = $ConfigPath
            PersistPath = $PersistPath
            Detail      = "Controller found via $($found.Source) at $($found.Address):$($found.Port)"
            Remediation = $null
        }
    }

    $remediation = @(
        'Discovery exhausted every strategy:',
        '  1. cluster-config.json controller.address',
        "  2. DNS / mDNS for $($CandidateNames -join ', ')",
        '  3. subnet scan of the local /22-/30 interfaces (.1 / .10 / .100 / .254)',
        'Fix one of:',
        '  - Make sure the controller PC is on the same WiFi SSID and reachable',
        "  - Set controller.address in cluster-config.json explicitly: $ConfigPath",
        '  - Verify the MeshCentral service is running on the controller (https://<controller>/ returns its login page)'
    ) -join "`n"

    if (Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue) {
        Write-ClusterLog -Level Error -Stage 'discover' `
            -Message "Discover stage failed -- no controller found." -Data @{
                candidateNames = ($CandidateNames -join ',')
                candidatePorts = ($CandidatePorts -join ',')
                configPath     = $ConfigPath
            }
    }

    return [pscustomobject]@{
        Overall     = 'Fail'
        Address     = $null
        Source      = $null
        Url         = $null
        Port        = $null
        Status      = $null
        ConfigPath  = $ConfigPath
        PersistPath = $PersistPath
        Detail      = 'No controller responded to any discovery strategy.'
        Remediation = $remediation
    }
}

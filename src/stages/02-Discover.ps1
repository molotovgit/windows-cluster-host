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
    if (-not $CandidateNames -or $CandidateNames.Count -eq 0) { $CandidateNames = @('controller.local','controller') }
    if (-not $CandidatePorts -or $CandidatePorts.Count -eq 0) { $CandidatePorts = @(443) }

    # Optional config override of port / extra candidate names.
    if ($Config -and $Config.PSObject.Properties['controller'] -and $Config.controller) {
        if ($Config.controller.PSObject.Properties['port'] -and $Config.controller.port) {
            $CandidatePorts = @([int]$Config.controller.port)
        }
    }

    $found = Find-Controller -ConfigPath $ConfigPath `
                             -CandidateNames $CandidateNames `
                             -CandidatePorts $CandidatePorts `
                             -PersistPath $PersistPath

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

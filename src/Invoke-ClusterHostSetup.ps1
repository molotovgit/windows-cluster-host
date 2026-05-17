<#
.SYNOPSIS
    Top-level orchestrator for the windows-cluster-host setup.

.DESCRIPTION
    Imports all lib modules and stage scripts, then runs the 8 stages in
    order:
       1. Preflight     (read-only)
       2. Discover      (locates the MeshCentral controller)
       3. Tuning        (Fast Startup off, High Performance, USB, sleep)
       4. Hyper-V       (enable feature, REBOOT, resume)
       5. Network       (NAT vSwitch + subnet pick)
       6. Agents        (OpenSSH + MeshAgent + SSH key + ACL)
       7. VMs           (golden VHDX + clones + New-VM)
       8. Verify        (services Running, VMs healthy, summary)

    Reboot handling: Stage 4 returns Overall='RebootRequired' when a
    reboot is needed. The orchestrator then:
        - Save-StageMarker so we know where to resume
        - Register-ResumeTask (PR 3 helpers) for unattended resume
        - Set-ClusterRunStatus 'InProgress'
        - Restart-Computer (unless -NoRestart for dry-run / testing)

    On post-reboot resume (-Resume): read the stage marker, jump to the
    next stage, continue. Stage 4 will see Hyper-V already Enabled and
    short-circuit to Pass.

    On final success: Complete-ClusterRun clears the stage marker, sets
    Status=Completed, and unregisters the resume task.

    On Fail: Set-ClusterRunStatus Failed + LastError, log the
    Remediation, and exit non-zero. The resume task is NOT
    unregistered (the operator may fix the issue and re-run).

.PARAMETER ConfigPath
    Path to cluster-config.json. Default: <repo>\config\cluster-config.json.

.PARAMETER Resume
    Skip stages already completed (per stage marker), continue from the next.

.PARAMETER StartFromStage
    Force start at this stage number, ignoring any prior marker. Useful
    for re-running specific stages during development. Conflicts with
    -Resume.

.PARAMETER DryRun
    Pass -DryRun to each stage. No system mutations.

.PARAMETER NoRestart
    Treat a Stage 4 'RebootRequired' result as a hard halt (return
    Overall='RebootRequired') instead of triggering Restart-Computer.
    Used by the dry-run integration tests and by operators who want to
    schedule the reboot themselves.

.PARAMETER RegBase
    Override the registry root used for State module markers. Default
    HKLM:\Software\ClusterHost.

.OUTPUTS
    pscustomobject @{
        Overall = 'Pass' | 'RebootRequired' | 'Fail';
        Stages = @( @{ Number; Name; Overall; Detail } ... );
        StartedAt; FinishedAt; ElapsedSeconds; RunId
    }
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [string]$ConfigPath,
    [Parameter(ParameterSetName = 'Resume')][switch]$Resume,
    [Parameter(ParameterSetName = 'StartFrom')]
    [ValidateRange(1,8)][int]$StartFromStage,
    [switch]$DryRun,
    [switch]$NoRestart,
    [string]$RegBase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- bootstrap ----------

$repoRoot     = Split-Path -Parent $PSScriptRoot
$libDir       = Join-Path $PSScriptRoot 'lib'
$stagesDir    = Join-Path $PSScriptRoot 'stages'
$orchVersion  = '0.1.0'

# Default config path: repo's config/cluster-config.json, or example if absent.
if (-not $ConfigPath) {
    $candidates = @(
        (Join-Path $repoRoot 'config\cluster-config.json'),
        (Join-Path $repoRoot 'config\cluster-config.example.json')
    )
    $ConfigPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

# Import every lib module BEFORE dot-sourcing stages so each stage can
# rely on the cmdlets being available.
foreach ($mod in 'Logging','State','Retry','HardwareDetect','Discovery') {
    $p = Join-Path $libDir "$mod.psm1"
    if (Test-Path -LiteralPath $p) {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module -Name $p -Force
    }
}

Initialize-ClusterLog -ConsoleLevel Info | Out-Null

# Dot-source every stage script. Order matters only inasmuch as each
# stage defines a single top-level Invoke-*Stage function.
$stageScripts = @(
    Join-Path $stagesDir '01-Preflight.ps1'
    Join-Path $stagesDir '02-Discover.ps1'
    Join-Path $stagesDir '03-Tuning.ps1'
    Join-Path $stagesDir '04-Hyperv.ps1'
    Join-Path $stagesDir '05-Network.ps1'
    Join-Path $stagesDir '06-Agents.ps1'
    Join-Path $stagesDir '07-Vms.ps1'
    Join-Path $stagesDir '08-Verify.ps1'
)
foreach ($s in $stageScripts) {
    if (-not (Test-Path -LiteralPath $s)) { throw "Orchestrator: stage script '$s' not found." }
    . $s
}

# ---------- helpers ----------

function Read-ClusterConfig {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch {
        Write-ClusterLog -Level Warn -Stage 'orchestrator' `
            -Message "Could not parse $Path as JSON: $($_.Exception.Message). Proceeding with defaults." -ErrorRecord $_
        return $null
    }
}

function Get-Plan {
    # Returns an array of @{ Number; Name; FunctionName; Splat }. The
    # orchestrator looks up each function by name via Get-Command at call
    # time -- closures over function references don't survive cross-scope
    # invocation cleanly in Pester / dot-source contexts.
    param([pscustomobject]$Config,[string]$ConfigPath,[string]$OrchVersion,[switch]$DryRun,[string]$RegBase)

    $runId = $null
    try { $s = Get-ClusterRunStatus -RegBase $RegBase; if ($s) { $runId = $s.RunId } } catch { $null = $_ }

    @(
        @{ Number = 1; Name = 'Preflight';
           FunctionName = 'Invoke-PreflightStage'
           Splat = @{ Config = $Config; IgnoreFailures = [bool]$DryRun } }
        @{ Number = 2; Name = 'Discover';
           FunctionName = 'Invoke-DiscoverStage'
           Splat = @{ Config = $Config; ConfigPath = $ConfigPath } }
        @{ Number = 3; Name = 'Tuning';
           FunctionName = 'Invoke-TuningStage'
           Splat = @{ DryRun = [bool]$DryRun } }
        @{ Number = 4; Name = 'Hyperv';
           FunctionName = 'Invoke-HypervStage'
           Splat = @{ DryRun = [bool]$DryRun } }
        @{ Number = 5; Name = 'Network';
           FunctionName = 'Invoke-NetworkStage'
           Splat = @{ Config = $Config; DryRun = [bool]$DryRun } }
        @{ Number = 6; Name = 'Agents';
           FunctionName = 'Invoke-AgentsStage'
           Splat = @{ Config = $Config; DryRun = [bool]$DryRun } }
        @{ Number = 7; Name = 'Vms';
           FunctionName = 'Invoke-VmsStage'
           Splat = @{ Config = $Config; DryRun = [bool]$DryRun } }
        @{ Number = 8; Name = 'Verify';
           FunctionName = 'Invoke-VerifyStage'
           Splat = @{
               Config = $Config; DryRun = [bool]$DryRun
               Meta   = @{ runId = $runId; version = $OrchVersion; configPath = "$ConfigPath" }
           } }
    )
}

# ---------- main ----------

function Invoke-ClusterHostSetup {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [switch]$Resume,
        [int]$StartFromStage,
        [switch]$DryRun,
        [switch]$NoRestart,
        [string]$RegBase
    )

    Start-StageLog -Name 'orchestrator'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stageResults = New-Object System.Collections.Generic.List[pscustomobject]

    try {
        if (-not $RegBase) { $RegBase = $env:CLUSTERHOST_REG_BASE }
        $cfg = Read-ClusterConfig -Path $ConfigPath

        # Decide starting stage.
        $startAt = 1
        if ($Resume) {
            $marker = Get-StageMarker -RegBase $RegBase
            if ($marker) {
                # Stage 4 is special: if a reboot was just done, Stage 4 itself needs
                # to re-run so it detects the Enabled state and reports Pass.
                $startAt = if ($marker -eq 4) { 4 } else { $marker + 1 }
                Write-ClusterLog -Level Info -Stage 'orchestrator' `
                    -Message "Resume: prior marker=$marker, starting from stage $startAt." -Data @{ resume = $true }
            } else {
                Write-ClusterLog -Level Info -Stage 'orchestrator' `
                    -Message 'Resume requested but no prior stage marker; starting from stage 1.'
            }
        } elseif ($StartFromStage) {
            $startAt = $StartFromStage
            Write-ClusterLog -Level Info -Stage 'orchestrator' -Message "StartFromStage=$StartFromStage."
        }

        Set-ClusterRunVersion -Version $orchVersion -RegBase $RegBase
        # Pre-create a RunId via Save-StageMarker (it'll seed StartedAt etc.).
        # Save with the first stage we are actually about to run.
        Save-StageMarker -StageNumber $startAt -RegBase $RegBase
        # Build the plan AFTER the marker so Stage 8 Verify gets the real RunId.
        $plan = Get-Plan -Config $cfg -ConfigPath $ConfigPath -OrchVersion $orchVersion -DryRun:$DryRun -RegBase $RegBase

        foreach ($entry in $plan) {
            if ($entry.Number -lt $startAt) {
                Write-ClusterLog -Level Info -Stage 'orchestrator' `
                    -Message ("Stage {0:00} {1}: SKIPPED (already done in previous run)" -f $entry.Number, $entry.Name)
                $stageResults.Add([pscustomobject]@{
                    Number = $entry.Number; Name = $entry.Name; Overall = 'Skipped'; Detail = 'Skipped by resume / StartFromStage.'
                })
                continue
            }
            Save-StageMarker -StageNumber $entry.Number -RegBase $RegBase
            Start-StageLog -Name $entry.Name
            try {
                $cmd      = Get-Command -Name $entry.FunctionName -ErrorAction Stop
                $stageArgs = $entry.Splat
                $r = & $cmd @stageArgs
                $overall = if ($r -and $r.PSObject.Properties['Overall']) { "$($r.Overall)" } else { 'Pass' }
                $detail  = if ($r -and $r.PSObject.Properties['Detail'])  { "$($r.Detail)"  }
                            elseif ($r) { 'see structured result' } else { '' }
                $stageResults.Add([pscustomobject]@{
                    Number = $entry.Number; Name = $entry.Name; Overall = $overall; Detail = $detail
                })
                Write-ClusterLog -Level Info -Stage 'orchestrator' `
                    -Message ("Stage {0:00} {1}: {2}" -f $entry.Number, $entry.Name, $overall)
                Stop-StageLog -Outcome $(if ($overall -eq 'Fail') { 'Failure' } elseif ($overall -eq 'Warn') { 'Warning' } else { 'Success' })

                # ---------- handle Hyper-V reboot trigger ----------
                if ($entry.Number -eq 4 -and $overall -eq 'RebootRequired') {
                    Write-ClusterLog -Level Warn -Stage 'orchestrator' `
                        -Message 'Stage 4 requires a reboot; registering resume task before restart.'
                    if (-not $NoRestart) {
                        $orchPath = $PSCommandPath
                        if (-not $orchPath) { $orchPath = (Join-Path $PSScriptRoot 'Invoke-ClusterHostSetup.ps1') }
                        $extraArgs = @()
                        if ($ConfigPath) { $extraArgs += @('-ConfigPath',"`"$ConfigPath`"") }
                        if ($DryRun)     { $extraArgs += '-DryRun' }
                        if ($RegBase) { $extraArgs += @('-RegBase', $RegBase) }
                        Register-ResumeTask -OrchestratorPath $orchPath -ExtraArgs $extraArgs | Out-Null
                        # Re-affirm InProgress so a previously-Failed run doesn't carry the
                        # stale terminal state across the reboot.
                        Set-ClusterRunStatus -Status InProgress -RegBase $RegBase
                        Write-ClusterLog -Level Warn -Stage 'orchestrator' -Message 'Restarting host now.'
                        # Do NOT call Stop-StageLog here -- the inner 'Hyperv' stage was
                        # already closed at the Stop-StageLog above, and the outer
                        # 'orchestrator' frame is closed by the finally block.
                        Restart-Computer -Force
                        $sw.Stop()
                        return New-OrchResult -Overall 'RebootRequired' -StageResults $stageResults `
                                              -ElapsedSeconds $sw.Elapsed.TotalSeconds -RegBase $RegBase
                    } else {
                        $sw.Stop()
                        Set-ClusterRunStatus -Status InProgress -RegBase $RegBase
                        return New-OrchResult -Overall 'RebootRequired' -StageResults $stageResults `
                                              -ElapsedSeconds $sw.Elapsed.TotalSeconds -RegBase $RegBase
                    }
                }

                # ---------- handle hard fail ----------
                if ($overall -eq 'Fail') {
                    $remed = if ($r -and $r.PSObject.Properties['Remediation']) { "$($r.Remediation)" } else { '' }
                    $msg   = "Stage $($entry.Number) $($entry.Name) failed: $detail $remed"
                    Write-ClusterLog -Level Error -Stage 'orchestrator' -Message $msg
                    Set-ClusterRunStatus -Status Failed -LastError $msg -RegBase $RegBase
                    $sw.Stop()
                    return New-OrchResult -Overall 'Fail' -StageResults $stageResults `
                                          -ElapsedSeconds $sw.Elapsed.TotalSeconds -RegBase $RegBase
                }
            } catch {
                $exMsg = $_.Exception.Message
                Write-ClusterLog -Level Error -Stage 'orchestrator' `
                    -Message ("Stage {0:00} {1} threw: {2}" -f $entry.Number, $entry.Name, $exMsg) -ErrorRecord $_
                Stop-StageLog -Outcome Failure -Detail $exMsg
                $stageResults.Add([pscustomobject]@{
                    Number = $entry.Number; Name = $entry.Name; Overall = 'Fail'; Detail = "Threw: $exMsg"
                })
                Set-ClusterRunStatus -Status Failed -LastError "Stage $($entry.Number) $($entry.Name) threw: $exMsg" -RegBase $RegBase
                $sw.Stop()
                return New-OrchResult -Overall 'Fail' -StageResults $stageResults `
                                      -ElapsedSeconds $sw.Elapsed.TotalSeconds -RegBase $RegBase
            }
        }

        # All stages passed.
        $sw.Stop()
        Complete-ClusterRun -RegBase $RegBase
        Write-ClusterLog -Level Info -Stage 'orchestrator' -Message 'All 8 stages passed. Run complete.'
        return New-OrchResult -Overall 'Pass' -StageResults $stageResults `
                              -ElapsedSeconds $sw.Elapsed.TotalSeconds -RegBase $RegBase
    } finally {
        if (Get-OpenStageName | Where-Object { $_ -eq 'orchestrator' }) { Stop-StageLog -Outcome Success | Out-Null }
    }
}

function New-OrchResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Pure helper.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Overall,
        [Parameter(Mandatory)][System.Collections.Generic.List[pscustomobject]]$StageResults,
        [Parameter(Mandatory)][double]$ElapsedSeconds,
        [string]$RegBase
    )
    $status = Get-ClusterRunStatus -RegBase $RegBase   # already correctly forwarded
    return [pscustomobject]@{
        Overall        = $Overall
        Stages         = $StageResults.ToArray()
        StartedAt      = if ($status) { $status.StartedAt } else { $null }
        FinishedAt     = [datetime]::UtcNow.ToString('o')
        ElapsedSeconds = [math]::Round($ElapsedSeconds,2)
        RunId          = if ($status) { $status.RunId } else { $null }
    }
}

# When invoked as a top-level script (e.g. by install.ps1 or via
# pwsh -File ...), run immediately. Tests dot-source the file and rely on
# CLUSTERHOST_NOAUTORUN=1 to skip the auto-run block. The
# $MyInvocation.InvocationName check ('-ne ''.''') is unreliable across
# dot-source contexts so we use an explicit env var instead.
if ($env:CLUSTERHOST_NOAUTORUN -ne '1') {
    $result = Invoke-ClusterHostSetup `
        -ConfigPath $ConfigPath `
        -Resume:$Resume `
        -StartFromStage $StartFromStage `
        -DryRun:$DryRun `
        -NoRestart:$NoRestart `
        -RegBase $RegBase

    Write-Host ""
    Write-Host "===== Orchestrator result =====" -ForegroundColor Cyan
    Write-Host ("Overall: {0}" -f $result.Overall) -ForegroundColor $(switch ($result.Overall) { 'Pass' {'Green'} 'RebootRequired' {'Yellow'} 'Fail' {'Red'} default {'White'} })
    Write-Host ("RunId  : {0}" -f $result.RunId)
    Write-Host ("Elapsed: {0} s" -f $result.ElapsedSeconds)
    Write-Host ""
    $result.Stages | Format-Table -AutoSize Number, Name, Overall, Detail

    switch ($result.Overall) {
        'Pass'            { exit 0 }
        'RebootRequired'  { exit 2 }
        'Fail'            { exit 1 }
        default           { exit 3 }
    }
}

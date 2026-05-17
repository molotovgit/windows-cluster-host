<#
.SYNOPSIS
    Persistent setup-run state for the windows-cluster-host orchestrator.

.DESCRIPTION
    Stores the current stage marker, top-level status, and run metadata in
    the Windows registry so the orchestrator survives the Hyper-V-forced
    reboot. Also wraps the scheduled-task registration that auto-resumes
    the orchestrator at next logon.

    Registry layout (under HKLM:\Software\ClusterHost\ by default):
        Stage     (DWORD)   1..N -- last stage that began (cleared on Done)
        Status    (string)  InProgress | Completed | Failed
        StartedAt (string)  ISO-8601 UTC of the first stage's begin
        UpdatedAt (string)  ISO-8601 UTC of the last write
        Version   (string)  Script semver, taken from the orchestrator
        LastError (string)  Optional, populated on Status=Failed
        RunId     (string)  GUID assigned at the start of a fresh run

    Tests redirect the base key via $env:CLUSTERHOST_REG_BASE, which must
    name an existing PowerShell-drive-style path (e.g.
    'HKCU:\Software\ClusterHost-test-<guid>'). This avoids needing admin
    rights or polluting the real HKLM hive.

.NOTES
    Scheduled task name defaults to 'ClusterHostResume'. The task runs at
    user logon, AsHighest privilege, executing the orchestrator with the
    -Resume switch. Helpers Register-ResumeTask and Unregister-ResumeTask
    are idempotent.

    Every public function accepts an optional -RegBase override so callers
    (and tests) can point at an alternate registry root without touching
    the environment variable.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Soft dependency on Logging.psm1: imported on first use; never blocks the
# module from loading when the sibling module is absent (so unit tests for
# State don't have to require Logging). The Write-ClusterLogIfAvailable
# helper below quietly no-ops if the Logging module isn't loaded.

function Write-ClusterLogIfAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data
    )
    $cmd = Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue
    if (-not $cmd) {
        # Try to import the sibling Logging module from the same lib/ folder.
        $sibling = Join-Path $PSScriptRoot 'Logging.psm1'
        if (Test-Path -LiteralPath $sibling) {
            Import-Module -Name $sibling -Force -ErrorAction SilentlyContinue
            $cmd = Get-Command -Name 'Write-ClusterLog' -ErrorAction SilentlyContinue
        }
    }
    if (-not $cmd) { return }  # logging unavailable, swallow silently
    if ($Data) {
        & $cmd -Level $Level -Message $Message -Stage 'state' -Data $Data
    } else {
        & $cmd -Level $Level -Message $Message -Stage 'state'
    }
}

# ---------- helpers ----------

function Get-DefaultRegBase {
    if ($env:CLUSTERHOST_REG_BASE) { return $env:CLUSTERHOST_REG_BASE }
    return 'HKLM:\Software\ClusterHost'
}

function Confirm-RegBase {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        try {
            New-Item -Path $Path -Force | Out-Null
        } catch {
            throw "Cluster-host state cannot create registry key '$Path' ($($_.Exception.Message)). Run as Administrator or override with `$env:CLUSTERHOST_REG_BASE."
        }
    }
}

function Get-NowIso {
    [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function Write-RegValue {
    # Internal helper. Named with a non-state-changing verb so PSScriptAnalyzer
    # does not insist on ShouldProcess for what is effectively a private setter.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        $Value,
        [ValidateSet('String','DWord')]
        [string]$Type = 'String'
    )
    Confirm-RegBase -Path $Path
    if ($null -eq $Value) {
        # Get-ItemProperty -Name returns the parent key object even when the
        # property is missing on some PS versions, so we cannot rely on its
        # truthiness. Probe the property collection explicitly.
        $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($item -and ($item.GetValueNames() -contains $Name)) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -Force
        }
        return
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    return $p.$Name
}

# ---------- public: stage marker ----------

function Save-StageMarker {
    <#
    .SYNOPSIS
        Record that the orchestrator has begun stage N. Also stamps UpdatedAt
        and starts a run (Status=InProgress + RunId + StartedAt) on first call.

    .PARAMETER StageNumber
        1..N -- the stage about to run.

    .PARAMETER RegBase
        Optional registry-key root override. Defaults to
        $env:CLUSTERHOST_REG_BASE or HKLM:\Software\ClusterHost.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes to a dedicated cluster-host registry key only; no ShouldProcess prompt is appropriate for an unattended setup script.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 32)]
        [int]$StageNumber,
        [string]$RegBase
    )
    if (-not $RegBase) { $RegBase = Get-DefaultRegBase }
    Confirm-RegBase -Path $RegBase

    # Order matters for crash recovery: write RunId + Status first so the
    # registry is in a consistent state if we die mid-init, and write
    # StartedAt LAST. The presence of StartedAt is the durable signal that
    # the init block completed; a re-run after a crash will re-do the init
    # values (idempotent overwrite for RunId is fine -- diagnostics only).
    if (-not (Get-RegValue -Path $RegBase -Name 'StartedAt')) {
        Write-RegValue -Path $RegBase -Name 'RunId'     -Value ([guid]::NewGuid().ToString())
        Write-RegValue -Path $RegBase -Name 'Status'    -Value 'InProgress'
        Write-RegValue -Path $RegBase -Name 'StartedAt' -Value (Get-NowIso)
        Write-ClusterLogIfAvailable -Level Info -Message "Run started" -Data @{ stage = $StageNumber; regBase = $RegBase }
    }
    Write-RegValue -Path $RegBase -Name 'Stage'     -Value $StageNumber -Type DWord
    Write-RegValue -Path $RegBase -Name 'UpdatedAt' -Value (Get-NowIso)
    Write-ClusterLogIfAvailable -Level Info -Message "Stage marker advanced" -Data @{ stage = $StageNumber }
}

function Get-StageMarker {
    <#
    .SYNOPSIS Return the last-recorded stage number, or $null if none.
    #>
    [CmdletBinding()]
    param([string]$RegBase)
    if (-not $RegBase) { $RegBase = Get-DefaultRegBase }
    $v = Get-RegValue -Path $RegBase -Name 'Stage'
    if ($null -eq $v) { return $null }
    return [int]$v
}

function Clear-StageMarker {
    <#
    .SYNOPSIS
        Remove the stage marker. Use on successful run completion (after
        Set-ClusterRunStatus -Status Completed has set the terminal state).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Operates only on a dedicated cluster-host registry key value.')]
    [CmdletBinding()]
    param([string]$RegBase)
    if (-not $RegBase) { $RegBase = Get-DefaultRegBase }
    if (-not (Test-Path -LiteralPath $RegBase)) { return }
    if (Get-RegValue -Path $RegBase -Name 'Stage') {
        Remove-ItemProperty -LiteralPath $RegBase -Name 'Stage' -Force
    }
}

# ---------- public: run status ----------

function Set-ClusterRunStatus {
    <#
    .SYNOPSIS Update the top-level run Status (and optional LastError).
    .PARAMETER Status   InProgress | Completed | Failed.
    .PARAMETER LastError Free-form remediation hint when Status=Failed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes to a dedicated cluster-host registry key only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('InProgress','Completed','Failed')]
        [string]$Status,
        [string]$LastError,
        [string]$RegBase
    )
    if (-not $RegBase) { $RegBase = Get-DefaultRegBase }
    Confirm-RegBase -Path $RegBase
    Write-RegValue -Path $RegBase -Name 'Status'    -Value $Status
    Write-RegValue -Path $RegBase -Name 'UpdatedAt' -Value (Get-NowIso)
    if ($PSBoundParameters.ContainsKey('LastError')) {
        Write-RegValue -Path $RegBase -Name 'LastError' -Value $LastError
    }
    Write-ClusterLogIfAvailable -Level Info -Message "Run status updated" -Data @{
        status    = $Status
        lastError = if ($PSBoundParameters.ContainsKey('LastError')) { $LastError } else { '<unchanged>' }
    }
}

function Get-ClusterRunStatus {
    <#
    .SYNOPSIS Return the full run record as a pscustomobject (or $null if empty).
    #>
    [CmdletBinding()]
    param([string]$RegBase)
    if (-not $RegBase) { $RegBase = Get-DefaultRegBase }
    if (-not (Test-Path -LiteralPath $RegBase)) { return $null }

    $names = 'Stage','Status','StartedAt','UpdatedAt','Version','LastError','RunId'
    $obj = [ordered]@{}
    $any = $false
    foreach ($n in $names) {
        $v = Get-RegValue -Path $RegBase -Name $n
        if ($null -ne $v) { $any = $true }
        $obj[$n] = $v
    }
    if (-not $any) { return $null }
    return [pscustomobject]$obj
}

function Set-ClusterRunVersion {
    <#
    .SYNOPSIS Stamp the orchestrator version into the run record.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes to a dedicated cluster-host registry key only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$RegBase
    )
    if (-not $RegBase) { $RegBase = Get-DefaultRegBase }
    Write-RegValue -Path $RegBase -Name 'Version' -Value $Version
    Write-ClusterLogIfAvailable -Level Info -Message "Run version stamped" -Data @{ version = $Version }
}

function Reset-ClusterRunState {
    <#
    .SYNOPSIS
        Wipe ALL cluster-host run state from the registry root. Used at the
        very start of a fresh run (orchestrator's -Restart switch) and by
        unit tests. Does NOT touch the scheduled task.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Operates only on the dedicated cluster-host registry key tree.')]
    [CmdletBinding()]
    param([string]$RegBase)
    if (-not $RegBase) { $RegBase = Get-DefaultRegBase }
    if (Test-Path -LiteralPath $RegBase) {
        Remove-Item -LiteralPath $RegBase -Recurse -Force
    }
}

# ---------- public: scheduled resume task ----------

# Resume-task constants. Public read-only via Get-ResumeTaskInfo.
$script:ResumeTaskName    = 'ClusterHostResume'
$script:ResumeTaskFolder  = '\ClusterHost\'   # dedicated folder to avoid name collisions

function Get-DefaultResumeTaskInvoker {
    @{
        Test       = { Get-ScheduledTask -TaskName $script:ResumeTaskName -ErrorAction SilentlyContinue }
        Register   = {
            param($Spec)
            $action  = New-ScheduledTaskAction      -Execute  $Spec.Execute -Argument $Spec.Argument
            $triggers = @()
            if ($Spec.Trigger -in 'AtLogOn','Both')   { $triggers += (New-ScheduledTaskTrigger -AtLogOn -User $Spec.User) }
            if ($Spec.Trigger -in 'AtStartup','Both') { $triggers += (New-ScheduledTaskTrigger -AtStartup) }
            $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                                    -StartWhenAvailable -RestartCount 3 `
                                                    -RestartInterval (New-TimeSpan -Minutes 5)
            # AtStartup requires the task to be able to run without an
            # interactive user logged in; use ServiceAccount (SYSTEM) when
            # any AtStartup trigger is in play, otherwise Interactive.
            $logonType = if ($Spec.Trigger -in 'AtStartup','Both') { 'ServiceAccount' } else { 'Interactive' }
            $userId    = if ($logonType -eq 'ServiceAccount') { 'NT AUTHORITY\SYSTEM' } else { $Spec.User }
            $princ   = New-ScheduledTaskPrincipal   -UserId $userId -LogonType $logonType -RunLevel Highest
            Register-ScheduledTask -TaskName $Spec.TaskName -TaskPath $Spec.TaskPath `
                                   -Action $action -Trigger $triggers -Settings $set -Principal $princ | Out-Null
        }
        Unregister = { Unregister-ScheduledTask -TaskName $script:ResumeTaskName -Confirm:$false }
    }
}

# Pluggable invokers for the scheduled-task surface. Defaults call the real
# Windows cmdlets in production; unit tests swap them with closures via
# Set-ResumeTaskInvoker, which is gated by CLUSTERHOST_ALLOW_TEST_SEAMS.
$script:ResumeTaskInvokers = Get-DefaultResumeTaskInvoker

function Confirm-TestSeamAllowed {
    if (-not $env:CLUSTERHOST_ALLOW_TEST_SEAMS) {
        throw "Test seams are disabled in production. Set `$env:CLUSTERHOST_ALLOW_TEST_SEAMS=1 to enable Set-ResumeTaskInvoker / Reset-ResumeTaskInvoker."
    }
}

function Set-ResumeTaskInvoker {
    <#
    .SYNOPSIS
        Test-only: override one of the scheduled-task invocation closures so
        unit tests can stub the cmdlets without triggering Windows' strict
        CimInstance parameter binding. Gated by CLUSTERHOST_ALLOW_TEST_SEAMS.

    .PARAMETER Operation
        Test | Register | Unregister
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test seam gated by env var; mutates only an in-process script-scope hashtable.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Test','Register','Unregister')]
        [string]$Operation,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    Confirm-TestSeamAllowed
    $script:ResumeTaskInvokers[$Operation] = $ScriptBlock
}

function Reset-ResumeTaskInvoker {
    <#
    .SYNOPSIS Test-only: restore the real-cmdlet invokers. Gated by CLUSTERHOST_ALLOW_TEST_SEAMS.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test seam gated by env var; restores in-process script-scope hashtable.')]
    [CmdletBinding()]
    param()
    Confirm-TestSeamAllowed
    $script:ResumeTaskInvokers = Get-DefaultResumeTaskInvoker
}

function New-ResumeTaskSpec {
    <#
    .SYNOPSIS
        Pure function: build the spec for the resume scheduled task. Returns
        a hashtable with TaskName, TaskPath, Execute, Argument, User, Trigger.

    .PARAMETER Trigger
        AtLogOn  -- fires when the configured user logs on. Requires either
                    auto-logon or human at the keyboard.
        AtStartup -- fires when Windows boots, before any user logs on.
                     Runs as NT AUTHORITY\SYSTEM. Safe for unattended hosts.
        Both     -- registers both triggers (default). Whichever happens
                     first re-launches the orchestrator with -Resume.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure function: builds and returns a hashtable describing the spec. No side effects, no system-level state changes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrchestratorPath,
        [string]$PwshPath,
        [string]$User,
        [string[]]$ExtraArgs = @(),

        [ValidateSet('AtLogOn','AtStartup','Both')]
        [string]$Trigger = 'Both'
    )

    if (-not (Test-Path -LiteralPath $OrchestratorPath)) {
        throw "New-ResumeTaskSpec: orchestrator script '$OrchestratorPath' not found."
    }
    $resolved = (Resolve-Path -LiteralPath $OrchestratorPath).Path

    if (-not $PwshPath) {
        $PwshPath = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh.exe' } else { 'powershell.exe' }
    }
    if (-not $User) {
        $User = "$env:USERDOMAIN\$env:USERNAME"
    }

    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$resolved`"",'-Resume') + $ExtraArgs

    return @{
        TaskName = $script:ResumeTaskName
        TaskPath = $script:ResumeTaskFolder
        Execute  = $PwshPath
        Argument = ($argList -join ' ')
        User     = $User
        Trigger  = $Trigger
    }
}

function Get-ResumeTaskInfo {
    <#
    .SYNOPSIS Diagnostic: return the task name + folder this module uses.
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        TaskName   = $script:ResumeTaskName
        TaskPath   = $script:ResumeTaskFolder
    }
}

function Test-ResumeTask {
    <#
    .SYNOPSIS Return $true if the resume scheduled task exists.
    #>
    [CmdletBinding()]
    param()
    return [bool](& $script:ResumeTaskInvokers.Test)
}

function Confirm-TaskSchedulerAvailable {
    # The Schedule service must be Running for Register-ScheduledTask to succeed.
    # Skip the check when test seams are active so unit tests don't have to
    # mock the service surface.
    if ($env:CLUSTERHOST_ALLOW_TEST_SEAMS) { return }
    $svc = Get-Service -Name 'Schedule' -ErrorAction SilentlyContinue
    if (-not $svc) {
        throw "Register-ResumeTask: Task Scheduler service ('Schedule') is not installed -- this host is not a supported Windows SKU."
    }
    if ($svc.Status -ne 'Running') {
        throw "Register-ResumeTask: Task Scheduler service is '$($svc.Status)'. Run 'Set-Service Schedule -StartupType Automatic; Start-Service Schedule' and retry."
    }
}

function Register-ResumeTask {
    <#
    .SYNOPSIS
        Register (or replace) a scheduled task that runs the orchestrator
        with -Resume after the next reboot.

    .PARAMETER OrchestratorPath
        Absolute path to Invoke-ClusterHostSetup.ps1 (PR 16).

    .PARAMETER PwshPath
        pwsh.exe path. Defaults to 'pwsh.exe' on PS7 or 'powershell.exe' on PS5.1.

    .PARAMETER User
        Logon user the task runs as when the AtLogOn trigger fires. Defaults
        to the current user. Ignored if -Trigger is AtStartup only (task
        runs as NT AUTHORITY\SYSTEM in that case).

    .PARAMETER ExtraArgs
        Additional arguments appended after -Resume.

    .PARAMETER Trigger
        AtLogOn | AtStartup | Both (default Both). AtStartup is the safe
        choice for unattended setups -- it fires before any user logs on
        and runs as SYSTEM. Pair it with AtLogOn for belt-and-braces.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Registers a dedicated, idempotent scheduled task ClusterHostResume only; ShouldProcess prompts would break unattended setup.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrchestratorPath,
        [string]$PwshPath,
        [string]$User,
        [string[]]$ExtraArgs = @(),

        [ValidateSet('AtLogOn','AtStartup','Both')]
        [string]$Trigger = 'Both'
    )

    Confirm-TaskSchedulerAvailable

    $spec = New-ResumeTaskSpec -OrchestratorPath $OrchestratorPath -PwshPath $PwshPath -User $User `
                               -ExtraArgs $ExtraArgs -Trigger $Trigger

    if (Test-ResumeTask) { & $script:ResumeTaskInvokers.Unregister }
    & $script:ResumeTaskInvokers.Register $spec
    Write-ClusterLogIfAvailable -Level Info -Message "Resume task registered" -Data @{
        taskName = $spec.TaskName
        trigger  = $spec.Trigger
        argument = $spec.Argument
    }
    return $spec
}

function Unregister-ResumeTask {
    <#
    .SYNOPSIS Remove the resume scheduled task. Idempotent.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Removes a dedicated scheduled task; ShouldProcess prompts would break unattended teardown.')]
    [CmdletBinding()]
    param()
    if (Test-ResumeTask) {
        & $script:ResumeTaskInvokers.Unregister
        Write-ClusterLogIfAvailable -Level Info -Message "Resume task unregistered"
    }
}

function Complete-ClusterRun {
    <#
    .SYNOPSIS
        Mark the run as Completed AND clean up reboot-resume scaffolding.
        Call this from the orchestrator after the final stage succeeds.

        Specifically:
          1. Sets Status=Completed (records UpdatedAt).
          2. Clears the stage marker so a future fresh run starts at Stage 1.
          3. Unregisters the ClusterHostResume scheduled task so it cannot
             accidentally fire on the next reboot and re-execute the
             orchestrator on an already-configured host.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Finalises the run by writing Completed status, clearing the stage marker, and unregistering the resume task. Intended to run unattended.')]
    [CmdletBinding()]
    param([string]$RegBase)
    if (-not $RegBase) { $RegBase = Get-DefaultRegBase }
    Set-ClusterRunStatus -Status Completed -RegBase $RegBase
    Clear-StageMarker -RegBase $RegBase
    Unregister-ResumeTask
    Write-ClusterLogIfAvailable -Level Info -Message "Cluster run completed and resume task removed"
}

Export-ModuleMember -Function `
    Save-StageMarker, Get-StageMarker, Clear-StageMarker, `
    Set-ClusterRunStatus, Get-ClusterRunStatus, Set-ClusterRunVersion, Reset-ClusterRunState, `
    Complete-ClusterRun, `
    Get-ResumeTaskInfo, Test-ResumeTask, Register-ResumeTask, Unregister-ResumeTask, `
    New-ResumeTaskSpec

# Test seams are intentionally NOT exported. Unit tests reach them via:
#   & (Get-Module State) { Set-ResumeTaskInvoker -Operation X -ScriptBlock {...} }
# AND must set $env:CLUSTERHOST_ALLOW_TEST_SEAMS=1 before the call.

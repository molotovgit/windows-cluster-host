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
        if (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue) {
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

    if (-not (Get-RegValue -Path $RegBase -Name 'StartedAt')) {
        Write-RegValue -Path $RegBase -Name 'RunId'     -Value ([guid]::NewGuid().ToString())
        Write-RegValue -Path $RegBase -Name 'StartedAt' -Value (Get-NowIso)
        Write-RegValue -Path $RegBase -Name 'Status'    -Value 'InProgress'
    }
    Write-RegValue -Path $RegBase -Name 'Stage'     -Value $StageNumber -Type DWord
    Write-RegValue -Path $RegBase -Name 'UpdatedAt' -Value (Get-NowIso)
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
$script:ResumeTaskFolder  = '\'        # root task folder

# Pluggable invokers for the scheduled-task surface. Defaults call the real
# Windows cmdlets in production; unit tests swap them with closures that
# record calls without performing them. This is the simplest mock seam that
# also bypasses the real cmdlets' strict CimInstance parameter binding.
$script:ResumeTaskInvokers = @{
    Test       = { Get-ScheduledTask -TaskName $script:ResumeTaskName -ErrorAction SilentlyContinue }
    Register   = {
        param($Spec)
        $action  = New-ScheduledTaskAction      -Execute  $Spec.Execute  -Argument $Spec.Argument
        $trigger = New-ScheduledTaskTrigger     -AtLogOn  -User    $Spec.User
        $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                                -StartWhenAvailable -RestartCount 3 `
                                                -RestartInterval (New-TimeSpan -Minutes 5)
        $princ   = New-ScheduledTaskPrincipal   -UserId   $Spec.User -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $Spec.TaskName -TaskPath $Spec.TaskPath `
                               -Action $action -Trigger $trigger -Settings $set -Principal $princ | Out-Null
    }
    Unregister = { Unregister-ScheduledTask -TaskName $script:ResumeTaskName -Confirm:$false }
}

function Set-ResumeTaskInvoker {
    <#
    .SYNOPSIS
        Test-only: override one of the scheduled-task invocation closures so
        unit tests can stub the cmdlets without triggering Windows' strict
        CimInstance parameter binding.

    .PARAMETER Operation
        Test | Register | Unregister
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test seam; mutates only an in-process script-scope hashtable.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Test','Register','Unregister')]
        [string]$Operation,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    $script:ResumeTaskInvokers[$Operation] = $ScriptBlock
}

function Reset-ResumeTaskInvoker {
    <#
    .SYNOPSIS Test-only: restore the real-cmdlet invokers.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test seam; restores in-process script-scope hashtable.')]
    [CmdletBinding()]
    param()
    $script:ResumeTaskInvokers = @{
        Test       = { Get-ScheduledTask -TaskName $script:ResumeTaskName -ErrorAction SilentlyContinue }
        Register   = {
            param($Spec)
            $action  = New-ScheduledTaskAction      -Execute  $Spec.Execute  -Argument $Spec.Argument
            $trigger = New-ScheduledTaskTrigger     -AtLogOn  -User    $Spec.User
            $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                                    -StartWhenAvailable -RestartCount 3 `
                                                    -RestartInterval (New-TimeSpan -Minutes 5)
            $princ   = New-ScheduledTaskPrincipal   -UserId   $Spec.User -LogonType Interactive -RunLevel Highest
            Register-ScheduledTask -TaskName $Spec.TaskName -TaskPath $Spec.TaskPath `
                                   -Action $action -Trigger $trigger -Settings $set -Principal $princ | Out-Null
        }
        Unregister = { Unregister-ScheduledTask -TaskName $script:ResumeTaskName -Confirm:$false }
    }
}

function New-ResumeTaskSpec {
    <#
    .SYNOPSIS
        Pure function: build the spec for the resume scheduled task. Returns
        a hashtable with TaskName, TaskPath, Execute, Argument, User. Easily
        unit-testable.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure function: builds and returns a hashtable describing the spec. No side effects, no system-level state changes.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrchestratorPath,
        [string]$PwshPath,
        [string]$User,
        [string[]]$ExtraArgs = @()
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

function Register-ResumeTask {
    <#
    .SYNOPSIS
        Register (or replace) a scheduled task that runs the orchestrator at
        next user logon with the -Resume switch.

    .PARAMETER OrchestratorPath
        Absolute path to Invoke-ClusterHostSetup.ps1 (PR 16).

    .PARAMETER PwshPath
        pwsh.exe path. Defaults to 'pwsh.exe' on PS7 or 'powershell.exe' on PS5.1.

    .PARAMETER User
        Logon user the task runs as. Defaults to the current user.

    .PARAMETER ExtraArgs
        Additional arguments appended after -Resume.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Registers a dedicated, idempotent scheduled task ClusterHostResume only; ShouldProcess prompts would break unattended setup.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OrchestratorPath,
        [string]$PwshPath,
        [string]$User,
        [string[]]$ExtraArgs = @()
    )

    $spec = New-ResumeTaskSpec -OrchestratorPath $OrchestratorPath -PwshPath $PwshPath -User $User -ExtraArgs $ExtraArgs

    # Idempotent: remove any prior copy first so we always end with the new spec.
    if (Test-ResumeTask) { & $script:ResumeTaskInvokers.Unregister }
    & $script:ResumeTaskInvokers.Register $spec
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
    if (Test-ResumeTask) { & $script:ResumeTaskInvokers.Unregister }
}

Export-ModuleMember -Function `
    Save-StageMarker, Get-StageMarker, Clear-StageMarker, `
    Set-ClusterRunStatus, Get-ClusterRunStatus, Set-ClusterRunVersion, Reset-ClusterRunState, `
    Get-ResumeTaskInfo, Test-ResumeTask, Register-ResumeTask, Unregister-ResumeTask, `
    New-ResumeTaskSpec, Set-ResumeTaskInvoker, Reset-ResumeTaskInvoker

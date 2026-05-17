<#
.SYNOPSIS
    Structured logging for the windows-cluster-host setup script.

.DESCRIPTION
    Provides Write-ClusterLog, Start-StageLog, Stop-StageLog. One log file is
    opened on the first call and reused for the rest of the process. The path
    is C:\ProgramData\ClusterHost\logs\setup-YYYYMMDD-HHmmssZ.log by default
    but can be overridden via the CLUSTERHOST_LOG_PATH environment variable
    or by passing -LogPath to Initialize-ClusterLog explicitly.

    All output is UTF-8 and uses ISO-8601 UTC timestamps so log lines sort
    correctly regardless of host timezone or DST transitions.

    The module is intentionally PowerShell-only with no external dependencies
    so it can be loaded before any installer / network stage runs.

.NOTES
    Levels: Debug (0), Info (1), Warn (2), Error (3). Console output is
    suppressed for levels below the active threshold (default Info). File
    output is never filtered -- the log is the audit trail.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- module-private state ----------
$script:ClusterLogState = [pscustomobject]@{
    LogPath        = $null
    ConsoleLevel   = 'Info'
    StageStack     = New-Object System.Collections.Generic.Stack[pscustomobject]
    Initialized    = $false
}

$script:LevelRank = @{
    Debug = 0
    Info  = 1
    Warn  = 2
    Error = 3
}

$script:LevelColor = @{
    Debug = 'DarkGray'
    Info  = 'Gray'
    Warn  = 'Yellow'
    Error = 'Red'
}

# ---------- helpers ----------
function Get-IsoTimestamp {
    [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function Resolve-DefaultLogPath {
    $dir = if ($env:CLUSTERHOST_LOG_DIR) {
        $env:CLUSTERHOST_LOG_DIR
    } else {
        Join-Path $env:ProgramData 'ClusterHost\logs'
    }
    $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmssZ')
    Join-Path $dir "setup-$stamp.log"
}

# ---------- public ----------
function Initialize-ClusterLog {
    <#
    .SYNOPSIS
        Opens the log file for this process. Idempotent -- repeat calls are a no-op
        unless -Force is passed, which rotates to a fresh file.

    .PARAMETER LogPath
        Explicit log file path. If omitted, defaults to
        C:\ProgramData\ClusterHost\logs\setup-<UTC-stamp>.log (or the directory
        named by $env:CLUSTERHOST_LOG_DIR).

    .PARAMETER ConsoleLevel
        Minimum severity printed to the console (file always records all). One
        of Debug, Info, Warn, Error.

    .PARAMETER Force
        Rotate to a new file even if already initialized.
    #>
    [CmdletBinding()]
    param(
        [string]$LogPath,
        [ValidateSet('Debug','Info','Warn','Error')]
        [string]$ConsoleLevel = 'Info',
        [switch]$Force
    )

    if ($script:ClusterLogState.Initialized -and -not $Force) {
        return $script:ClusterLogState.LogPath
    }

    if (-not $LogPath) { $LogPath = Resolve-DefaultLogPath }

    $dir = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    # Touch the file so later append-writes don't race with the first call.
    if (-not (Test-Path -LiteralPath $LogPath)) {
        New-Item -Path $LogPath -ItemType File -Force | Out-Null
    }

    $script:ClusterLogState.LogPath      = $LogPath
    $script:ClusterLogState.ConsoleLevel = $ConsoleLevel
    $script:ClusterLogState.Initialized  = $true

    $header = "{0} [INFO ] [bootstrap] cluster-host log opened at {1}" -f (Get-IsoTimestamp), $LogPath
    Add-Content -LiteralPath $LogPath -Value $header -Encoding utf8
    return $LogPath
}

function Get-ClusterLogPath {
    <#
    .SYNOPSIS Returns the currently-active log file path, or $null if uninitialized.
    #>
    [CmdletBinding()]
    param()
    $script:ClusterLogState.LogPath
}

function Write-ClusterLog {
    <#
    .SYNOPSIS
        Append one structured line to the log file and (optionally) the console.

    .PARAMETER Level
        Severity. Debug | Info | Warn | Error.

    .PARAMETER Stage
        Short label for the current stage / function. Auto-derived from the
        Stage stack if -Stage is omitted and a stage is currently open.

    .PARAMETER Message
        The human-readable message. Multi-line messages have each line
        prefixed with the timestamp so log scrapers stay sane.

    .PARAMETER Data
        Optional hashtable of structured fields appended as KEY=VALUE pairs.
        Useful for tagging discovered values (IP, drive, subnet, etc.).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingWriteHost', '',
        Justification = 'Color-coded console output is the intentional UX for operator-facing setup logs; the file log remains the machine-readable audit trail.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug','Info','Warn','Error')]
        [string]$Level,

        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [string]$Stage,

        [hashtable]$Data
    )

    if (-not $script:ClusterLogState.Initialized) { Initialize-ClusterLog | Out-Null }

    if (-not $Stage) {
        if ($script:ClusterLogState.StageStack.Count -gt 0) {
            $Stage = $script:ClusterLogState.StageStack.Peek().Name
        } else {
            $Stage = 'main'
        }
    }

    $kv = ''
    if ($Data -and $Data.Count -gt 0) {
        $parts = foreach ($k in $Data.Keys) {
            $v = $Data[$k]
            if ($null -eq $v) { $v = '<null>' }
            $vStr = ($v -replace '[\r\n]+',' ')
            "$k=$vStr"
        }
        $kv = ' { ' + ($parts -join ' ') + ' }'
    }

    $ts = Get-IsoTimestamp
    $lvlTag = $Level.ToUpperInvariant().PadRight(5)

    # Split multi-line messages so each gets its own timestamp prefix.
    $lines = if ($Message) { $Message -split "`r?`n" } else { @('') }
    foreach ($ln in $lines) {
        $record = "$ts [$lvlTag] [$Stage] $ln$kv"
        Add-Content -LiteralPath $script:ClusterLogState.LogPath -Value $record -Encoding utf8

        if ($script:LevelRank[$Level] -ge $script:LevelRank[$script:ClusterLogState.ConsoleLevel]) {
            Write-Host $record -ForegroundColor $script:LevelColor[$Level]
        }
    }
}

function Start-StageLog {
    <#
    .SYNOPSIS Mark the beginning of a stage and start a timer.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates only in-process module state (a stage-name stack); no system-level state is changed, so ShouldProcess prompts would be misleading.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    if (-not $script:ClusterLogState.Initialized) { Initialize-ClusterLog | Out-Null }

    $frame = [pscustomobject]@{
        Name      = $Name
        StartUtc  = [datetime]::UtcNow
        Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
    $script:ClusterLogState.StageStack.Push($frame)
    Write-ClusterLog -Level Info -Stage $Name -Message ">>> begin $Name"
}

function Stop-StageLog {
    <#
    .SYNOPSIS
        Mark the end of the most-recently-started stage. Logs elapsed seconds.

    .PARAMETER Outcome
        Success | Warning | Failure. Drives the log line level.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pops in-process module state only; no system-level changes.')]
    [CmdletBinding()]
    param(
        [ValidateSet('Success','Warning','Failure')]
        [string]$Outcome = 'Success',

        [string]$Detail
    )

    if ($script:ClusterLogState.StageStack.Count -eq 0) {
        Write-ClusterLog -Level Warn -Stage 'main' `
            -Message 'Stop-StageLog called with no open stage -- check stage bracketing.'
        return
    }

    $frame = $script:ClusterLogState.StageStack.Pop()
    $frame.Stopwatch.Stop()
    $elapsed = [math]::Round($frame.Stopwatch.Elapsed.TotalSeconds, 2)

    $level = switch ($Outcome) {
        'Success' { 'Info' }
        'Warning' { 'Warn' }
        'Failure' { 'Error' }
    }

    $msg = "<<< end $($frame.Name) outcome=$Outcome elapsed_s=$elapsed"
    if ($Detail) { $msg += " detail=`"$Detail`"" }

    Write-ClusterLog -Level $level -Stage $frame.Name -Message $msg
}

function Get-OpenStageName {
    <#
    .SYNOPSIS
        Diagnostic: return open stage names. Stack<T> enumerates LIFO, so the
        result is innermost-first; reverse if you want outermost-first.
    #>
    [CmdletBinding()]
    param()
    if ($script:ClusterLogState.StageStack.Count -eq 0) { return @() }
    return @($script:ClusterLogState.StageStack.ToArray() | ForEach-Object { $_.Name })
}

function Reset-ClusterLogState {
    <#
    .SYNOPSIS Test-only -- wipe module state. Pester tests call this between cases.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Resets in-process module state for unit tests; no system-level changes.')]
    [CmdletBinding()]
    param()
    $script:ClusterLogState.LogPath      = $null
    $script:ClusterLogState.ConsoleLevel = 'Info'
    $script:ClusterLogState.StageStack   = New-Object System.Collections.Generic.Stack[pscustomobject]
    $script:ClusterLogState.Initialized  = $false
}

Export-ModuleMember -Function `
    Initialize-ClusterLog, `
    Get-ClusterLogPath, `
    Write-ClusterLog, `
    Start-StageLog, `
    Stop-StageLog, `
    Get-OpenStageName, `
    Reset-ClusterLogState

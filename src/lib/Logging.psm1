<#
.SYNOPSIS
    Structured logging for the windows-cluster-host setup script.

.DESCRIPTION
    Provides Write-ClusterLog, Start-StageLog, Stop-StageLog. The module opens
    one append-mode log file per *setup run* and reuses it even after the
    Hyper-V-forced reboot (see "Reboot continuity" below). All output is
    BOM-less UTF-8 with ISO-8601 UTC timestamps so log lines sort correctly
    regardless of host timezone or DST transitions.

    Levels: Debug (0), Info (1), Warn (2), Error (3). Console output is
    suppressed for levels below the active threshold (default Info); the file
    is the complete audit trail.

.NOTES
    Reboot continuity:
        Initialize-ClusterLog writes a pointer file at
        <state-dir>\current-log.txt containing the active log path. On a
        subsequent process start (e.g. the post-Hyper-V resume task), reading
        that pointer lets the new process APPEND to the same log file rather
        than start a fresh one, so a single setup run produces one log file.
        The pointer is considered stale after 24h and triggers a fresh file.

    Secret redaction:
        Write-ClusterLog -Data values are redacted automatically when the key
        name matches the active redaction regex (default covers
        password/secret/token/apikey/credential/bearer/authorization). Extend
        via Set-ClusterLogRedaction.

    Writes are BOM-less UTF-8 (System.IO.File.AppendAllText) so the log is
    byte-identical between PowerShell 5.1 and 7. Each line is written with a
    short retry loop to ride out transient I/O contention (AV scan,
    background indexer).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- module-private state ----------
$script:ClusterLogState = [pscustomobject]@{
    LogPath      = $null
    ConsoleLevel = 'Info'
    StageStack   = New-Object System.Collections.Generic.Stack[pscustomobject]
    Initialized  = $false
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

# Default redaction: case-insensitive match against -Data hashtable KEY names.
# Callers extend via Set-ClusterLogRedaction.
$script:RedactKeyPattern = '(?i)^(pass(word)?|secret|token|api[_-]?key|cred(ential)?s?|bearer|authorization)$'

# How long a pointer file is honored before we start a fresh log.
$script:PointerStaleAfter = [timespan]::FromHours(24)

# Append retry policy for transient AV / indexer locks.
$script:AppendRetryCount = 3
$script:AppendRetryDelayMs = 50

# Truncation guard so a misbehaving installer can't write a 10 MB single "line".
$script:MaxLineBytes = 8192

# BOM-less UTF-8 encoding shared across all writes.
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# ---------- helpers (not exported) ----------
function Get-IsoTimestamp {
    [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function Get-LogDir {
    if ($env:CLUSTERHOST_LOG_DIR) { return $env:CLUSTERHOST_LOG_DIR }
    return (Join-Path $env:ProgramData 'ClusterHost\logs')
}

function Get-StateDir {
    if ($env:CLUSTERHOST_STATE_DIR) { return $env:CLUSTERHOST_STATE_DIR }
    return (Join-Path $env:ProgramData 'ClusterHost\state')
}

function Get-PointerPath {
    Join-Path (Get-StateDir) 'current-log.txt'
}

function Get-NextLogFileName {
    # millisecond precision so two opens within the same second don't collide
    $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss.fffZ')
    Join-Path (Get-LogDir) "setup-$stamp.log"
}

function Read-LogPointer {
    $p = Get-PointerPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $line = (Get-Content -LiteralPath $p -TotalCount 1 -ErrorAction Stop).Trim()
    } catch { return $null }
    if (-not $line) { return $null }
    if (-not (Test-Path -LiteralPath $line)) { return $null }

    $age = [datetime]::UtcNow - (Get-Item -LiteralPath $line -ErrorAction SilentlyContinue).LastWriteTimeUtc
    if ($age -gt $script:PointerStaleAfter) { return $null }
    return $line
}

function Write-LogPointer {
    param([Parameter(Mandatory)][string]$Path)
    $stateDir = Get-StateDir
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText((Get-PointerPath), $Path, $script:Utf8NoBom)
}

function Confirm-WritableDirectory {
    # Validate the path is writable; throw an actionable message if not.
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $Path ('.write-probe-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'ok', $script:Utf8NoBom)
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch {
        $envHint = if ($Path -like (Join-Path $env:ProgramData 'ClusterHost*')) {
            'Set $env:CLUSTERHOST_LOG_DIR (and optionally $env:CLUSTERHOST_STATE_DIR) to a writable path and retry.'
        } else {
            "Choose a writable -LogPath or unset CLUSTERHOST_LOG_DIR. ($($_.Exception.Message))"
        }
        throw "Cluster-host logging cannot write to '$Path'. $envHint"
    }
}

function Invoke-AppendLine {
    # BOM-less UTF-8 append with transient-IOException retry.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Line
    )

    $payload = $Line + [Environment]::NewLine
    for ($attempt = 1; $attempt -le $script:AppendRetryCount; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($Path, $payload, $script:Utf8NoBom)
            return
        } catch [System.IO.IOException] {
            if ($attempt -eq $script:AppendRetryCount) { throw }
            Start-Sleep -Milliseconds $script:AppendRetryDelayMs
        }
    }
}

function Format-RedactedValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        $Value
    )
    if ($null -eq $Value) { return '<null>' }
    if ($Key -match $script:RedactKeyPattern) { return '<redacted>' }
    $s = "$Value" -replace '[\r\n]+',' '
    $s = $s -replace '"','\"'    # keep KV format parseable
    return $s
}

function Format-KVBlock {
    param([hashtable]$Data)
    if (-not $Data -or $Data.Count -eq 0) { return '' }
    $parts = foreach ($k in $Data.Keys) {
        $v = Format-RedactedValue -Key "$k" -Value $Data[$k]
        "$k=$v"
    }
    ' { ' + ($parts -join ' ') + ' }'
}

function Limit-LineByte {
    param([Parameter(Mandatory)][string]$Line)
    $bytes = [System.Text.Encoding]::UTF8.GetByteCount($Line)
    if ($bytes -le $script:MaxLineBytes) { return $Line }
    # truncate to MaxLineBytes - tag-room, then annotate
    $tag = "...[truncated $bytes B to $script:MaxLineBytes B]"
    $room = $script:MaxLineBytes - [System.Text.Encoding]::UTF8.GetByteCount($tag)
    $chars = $Line.ToCharArray()
    $kept = New-Object System.Text.StringBuilder
    $acc = 0
    foreach ($c in $chars) {
        $b = [System.Text.Encoding]::UTF8.GetByteCount([string]$c)
        if (($acc + $b) -gt $room) { break }
        $acc += $b
        [void]$kept.Append($c)
    }
    return ($kept.ToString() + $tag)
}

# ---------- public ----------

function Initialize-ClusterLog {
    <#
    .SYNOPSIS
        Open the log file for this process. Idempotent. Re-attaches to the
        previous run's file when a recent current-log.txt pointer exists.

    .PARAMETER LogPath
        Explicit log file path. If omitted, behaviour is:
          1. Read $stateDir\current-log.txt; if that pointer is fresh (< 24h)
             and the file still exists, append to it.
          2. Otherwise create a new file named setup-<UTC>.log under the
             effective log directory and write the pointer.

    .PARAMETER ConsoleLevel
        Minimum severity printed to the console (file always records all).

    .PARAMETER Force
        Always rotate to a fresh file (ignore the pointer).
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

    $reused = $false
    if (-not $LogPath) {
        if (-not $Force) {
            $existing = Read-LogPointer
            if ($existing) { $LogPath = $existing; $reused = $true }
        }
        if (-not $LogPath) { $LogPath = Get-NextLogFileName }
    }

    Confirm-WritableDirectory -Path (Split-Path -Parent $LogPath)

    if (-not (Test-Path -LiteralPath $LogPath)) {
        # Touch via BOM-less write so the very first byte is not a BOM.
        [System.IO.File]::WriteAllText($LogPath, '', $script:Utf8NoBom)
    }

    Write-LogPointer -Path $LogPath

    $script:ClusterLogState.LogPath      = $LogPath
    $script:ClusterLogState.ConsoleLevel = $ConsoleLevel
    $script:ClusterLogState.Initialized  = $true

    $verb = if ($reused) { 'resumed' } else { 'opened' }
    $header = "{0} [INFO ] [bootstrap] cluster-host log {1} at {2}" -f (Get-IsoTimestamp), $verb, $LogPath
    Invoke-AppendLine -Path $LogPath -Line $header
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

function Set-ClusterLogRedaction {
    <#
    .SYNOPSIS
        Replace the regex used to redact -Data values by key name.

    .PARAMETER KeyPattern
        A regex (case-insensitivity recommended via inline (?i)) tested against
        each hashtable key. Matched keys log as <redacted>.

    .PARAMETER AddKeyPattern
        Append this regex (OR-merged) to the existing pattern instead of
        replacing it. Useful when extending the default denylist.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates only in-process module state (a regex string); no system-level state is changed.')]
    [CmdletBinding(DefaultParameterSetName = 'Replace')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Replace')]
        [string]$KeyPattern,

        [Parameter(Mandatory, ParameterSetName = 'Add')]
        [string]$AddKeyPattern
    )
    if ($PSCmdlet.ParameterSetName -eq 'Replace') {
        $script:RedactKeyPattern = $KeyPattern
    } else {
        $script:RedactKeyPattern = "($script:RedactKeyPattern)|($AddKeyPattern)"
    }
}

function Get-ClusterLogRedaction {
    <#
    .SYNOPSIS Return the active redaction regex.
    #>
    [CmdletBinding()]
    param()
    $script:RedactKeyPattern
}

function Write-ClusterLog {
    <#
    .SYNOPSIS
        Append one structured line to the log file and (optionally) the console.

    .PARAMETER Level
        Severity. Debug | Info | Warn | Error.

    .PARAMETER Stage
        Short label for the current stage / function. Auto-derived from the
        Stage stack if omitted.

    .PARAMETER Message
        The human-readable message. Multi-line messages have each line
        prefixed with the timestamp.

    .PARAMETER Data
        Optional hashtable of structured fields appended as KEY=VALUE pairs.
        Values whose KEY matches the active redaction pattern (see
        Set-ClusterLogRedaction) are emitted as <redacted>.

    .PARAMETER ErrorRecord
        Convenience for catch blocks: emit type, message, position, and the
        first 20 stack frames on consecutive log lines.
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

        [hashtable]$Data,

        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if (-not $script:ClusterLogState.Initialized) { Initialize-ClusterLog | Out-Null }

    if (-not $Stage) {
        if ($script:ClusterLogState.StageStack.Count -gt 0) {
            $Stage = $script:ClusterLogState.StageStack.Peek().Name
        } else {
            $Stage = 'main'
        }
    }

    $kv = Format-KVBlock -Data $Data
    $ts = Get-IsoTimestamp
    $lvlTag = $Level.ToUpperInvariant().PadRight(5)

    $bodyLines = if ($Message) { $Message -split "`r?`n" } else { @('') }

    if ($ErrorRecord) {
        $bodyLines = @($bodyLines)
        $bodyLines += "exception_type=$($ErrorRecord.Exception.GetType().FullName)"
        $bodyLines += "exception_message=$($ErrorRecord.Exception.Message)"
        if ($ErrorRecord.InvocationInfo) {
            $bodyLines += "exception_at=$($ErrorRecord.InvocationInfo.PositionMessage -replace "`r?`n",' | ')"
        }
        $stackText = $ErrorRecord.ScriptStackTrace
        if ($stackText) {
            $stackText -split "`r?`n" |
                Select-Object -First 20 |
                ForEach-Object { $bodyLines += "stack: $_" }
        }
    }

    foreach ($ln in $bodyLines) {
        $record = "$ts [$lvlTag] [$Stage] $ln$kv"
        $record = Limit-LineByte -Line $record
        Invoke-AppendLine -Path $script:ClusterLogState.LogPath -Line $record

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
        Justification = 'Mutates only in-process module state (a stage-name stack); no system-level changes.')]
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
    if ($Detail) {
        $safe = $Detail -replace '"','\"'
        $msg += " detail=`"$safe`""
    }

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
    .SYNOPSIS
        Test-only -- wipe module state and pointer. Pester tests call this
        between cases to keep runs hermetic.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Resets in-process module state for unit tests; no system-level changes.')]
    [CmdletBinding()]
    param([switch]$KeepPointer)
    $script:ClusterLogState.LogPath      = $null
    $script:ClusterLogState.ConsoleLevel = 'Info'
    $script:ClusterLogState.StageStack   = New-Object System.Collections.Generic.Stack[pscustomobject]
    $script:ClusterLogState.Initialized  = $false
    $script:RedactKeyPattern             = '(?i)^(pass(word)?|secret|token|api[_-]?key|cred(ential)?s?|bearer|authorization)$'

    if (-not $KeepPointer) {
        $p = Get-PointerPath
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
}

Export-ModuleMember -Function `
    Initialize-ClusterLog, `
    Get-ClusterLogPath, `
    Write-ClusterLog, `
    Start-StageLog, `
    Stop-StageLog, `
    Get-OpenStageName, `
    Set-ClusterLogRedaction, `
    Get-ClusterLogRedaction, `
    Reset-ClusterLogState

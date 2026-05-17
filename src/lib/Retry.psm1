<#
.SYNOPSIS
    Retry-with-backoff and fallback-chain primitives for the windows-cluster-host
    setup script.

.DESCRIPTION
    Two related primitives:

    Invoke-WithRetry
        Try one operation up to N times with exponential backoff and optional
        jitter. Supports a -RetryableException filter (only retry if the
        thrown exception's type matches one of the listed type names) and a
        -ShouldRetry predicate (caller-supplied decision for ambiguous cases,
        e.g. inspecting the exception message or the captured output).

    Invoke-WithFallback
        Try a sequence of strategies (each is a named script block) in order.
        On failure, call -ShouldFallback to decide whether to move on to the
        next strategy. The first strategy that succeeds wins; if all fail,
        the function throws an aggregate AggregateException-style record
        listing every attempt's outcome.

    Both emit Info-level log lines via the optional Logging.psm1 sibling
    module so each retry/fallback decision shows up in the audit trail.

.NOTES
    Designed for use by every later stage that touches a flaky surface --
    network downloads, registry/WMI calls, scheduled-task registration,
    Hyper-V cmdlets, DISM. Caller decides retry vs fallback:

      - "this might be transient" -> Invoke-WithRetry on a single block
      - "this might fundamentally not work; try a different approach" ->
        Invoke-WithFallback with a sequence of strategies
      - "both" -> wrap each fallback strategy in Invoke-WithRetry

    See tests/unit/Retry.Tests.ps1 for end-to-end usage examples.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Soft dependency on Logging.psm1, same pattern as State.psm1.
function Write-ClusterLogIfAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [string]$Stage = 'retry',
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
    if ($Data) {
        & $cmd -Level $Level -Message $Message -Stage $Stage -Data $Data
    } else {
        & $cmd -Level $Level -Message $Message -Stage $Stage
    }
}

function Get-MillisecondsClamped {
    # Cap a millisecond value at $MaxDelayMs and add optional uniform jitter.
    # MaxDelayMs is a HARD cap -- jitter is re-clamped against it so the
    # returned value can never exceed the documented ceiling.
    param(
        [Parameter(Mandatory)][double]$Ms,
        [Parameter(Mandatory)][int]$MaxDelayMs,
        [switch]$Jitter
    )
    $bound = [math]::Min($Ms, [double]$MaxDelayMs)
    if ($Jitter) {
        # +-25% jitter to spread thundering-herd retries across hosts.
        $delta = $bound * 0.25 * (Get-Random -Minimum -1.0 -Maximum 1.0)
        $bound = [math]::Max(0.0, [math]::Min([double]$MaxDelayMs, $bound + $delta))
    }
    return [int][math]::Round($bound)
}

function Test-ExceptionMatchesType {
    param(
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string[]]$RetryableException
    )
    if (-not $RetryableException -or $RetryableException.Count -eq 0) { return $true }
    # Walk the exception chain (current + InnerException + ...).
    $ex = $ErrorRecord.Exception
    while ($ex) {
        $t = $ex.GetType().FullName
        foreach ($name in $RetryableException) {
            if ($t -eq $name -or $t.EndsWith(".$name")) { return $true }
        }
        $ex = $ex.InnerException
    }
    return $false
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Run a script block, retrying on failure with exponential backoff.

    .PARAMETER ScriptBlock
        The operation to attempt. Its return value is passed through on success.

    .PARAMETER Name
        Short label for log lines (e.g. 'download-meshagent', 'enable-hyperv').

    .PARAMETER MaxAttempts
        Total attempts including the first call. 3 = first + 2 retries.

    .PARAMETER InitialDelayMs
        Delay before the first retry (i.e. between attempt 1 and 2).

    .PARAMETER BackoffFactor
        Multiplier applied to the previous delay for each subsequent retry.
        Default 2.0 (classic exponential).

    .PARAMETER MaxDelayMs
        Cap on any single delay. Default 30 s.

    .PARAMETER Jitter
        Add +-25% uniform jitter to each delay so a fleet of 30 hosts doesn't
        thundering-herd a shared resource.

    .PARAMETER RetryableException
        Optional list of exception type names (full or short). If supplied,
        ONLY these exception types trigger a retry; anything else throws
        immediately. Matching walks the InnerException chain and is by
        SIMPLE NAME -- it does NOT match subclasses. e.g. supplying
        'IOException' will NOT match FileNotFoundException even though the
        latter derives from the former. List each concrete type you want
        to retry.

    .PARAMETER ShouldRetry
        Optional predicate { param($ErrorRecord, $AttemptNumber) ... } that
        returns $true to retry, $false to give up. Runs AFTER the type filter.
        Useful for "retry on HTTP 5xx but not 4xx" decisions.

    .OUTPUTS
        The successful ScriptBlock's return value. Throws on final failure.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Runs the supplied script block; this is a control-flow helper, not a state-changing cmdlet.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$Name = 'op',
        [ValidateRange(1, 100)]
        [int]$MaxAttempts = 3,
        [ValidateRange(0, 600000)]
        [int]$InitialDelayMs = 250,
        [ValidateRange(1.0, 10.0)]
        [double]$BackoffFactor = 2.0,
        [ValidateRange(1, 600000)]
        [int]$MaxDelayMs = 30000,
        [switch]$Jitter,
        [string[]]$RetryableException,
        [scriptblock]$ShouldRetry
    )

    $delay = [double]$InitialDelayMs
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $result = & $ScriptBlock
            if ($attempt -gt 1) {
                Write-ClusterLogIfAvailable -Level Info -Message "Retry succeeded" -Data @{
                    op       = $Name
                    attempt  = $attempt
                }
            }
            return $result
        } catch {
            $err = $_
            $isLast = ($attempt -eq $MaxAttempts)
            $typeOk = Test-ExceptionMatchesType -ErrorRecord $err -RetryableException $RetryableException
            $predOk = $true
            if ($ShouldRetry) {
                try {
                    $predOk = [bool](& $ShouldRetry $err $attempt)
                } catch {
                    Write-ClusterLogIfAvailable -Level Warn -Message "ShouldRetry predicate threw -- treating as 'do not retry'" -Data @{
                        op = $Name; attempt = $attempt; predicate_error = $_.Exception.Message
                    }
                    $predOk = $false
                }
            }

            $willRetry = -not $isLast -and $typeOk -and $predOk
            $lvl  = $(if ($willRetry) { 'Warn' } else { 'Error' })
            $tail = $(if ($willRetry) { ' -- will retry' } else { '' })
            Write-ClusterLogIfAvailable -Level $lvl `
                -Message ("Attempt {0}/{1} failed{2}" -f $attempt, $MaxAttempts, $tail) `
                -Data @{
                    op             = $Name
                    attempt        = $attempt
                    will_retry     = $willRetry
                    exception_type = $err.Exception.GetType().FullName
                    exception_msg  = $err.Exception.Message
                }

            if (-not $willRetry) { throw $err }

            $sleepMs = Get-MillisecondsClamped -Ms $delay -MaxDelayMs $MaxDelayMs -Jitter:$Jitter
            Start-Sleep -Milliseconds $sleepMs
            $delay = $delay * $BackoffFactor
        }
    }
}

function Invoke-WithFallback {
    <#
    .SYNOPSIS
        Try a sequence of strategies in order. First success wins.

    .PARAMETER Strategy
        An array of strategies. Each strategy is a hashtable with:
          Name  -- short label
          Block -- the script block to execute
        Strategies are tried in array order.

    .PARAMETER ShouldFallback
        Optional predicate { param($ErrorRecord, $StrategyName, $StrategyIndex) ... }
        Decides whether to move on to the next strategy after a failure. If
        omitted, the next strategy is always tried.

    .PARAMETER OnAttempt
        Optional callback fired before each strategy is tried:
        { param($StrategyName, $StrategyIndex) ... }

    .OUTPUTS
        A pscustomobject with fields:
          Winner   -- the strategy Name that succeeded
          Index    -- its 0-based index
          Result   -- whatever its Block returned
          Attempts -- ordered list of { Name; Error }; successful attempt's Error is $null

        Throws an aggregate error if every strategy failed (or ShouldFallback
        bailed early), with the same Attempts list attached for triage.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Runs the supplied strategy script blocks; this is a control-flow helper.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [hashtable[]]$Strategy,
        [scriptblock]$ShouldFallback,
        [scriptblock]$OnAttempt
    )

    if ($Strategy.Count -eq 0) {
        throw "Invoke-WithFallback: -Strategy must contain at least one strategy."
    }

    $attempts = New-Object System.Collections.Generic.List[pscustomobject]
    for ($i = 0; $i -lt $Strategy.Count; $i++) {
        $s = $Strategy[$i]
        if (-not $s.ContainsKey('Name')  -or -not $s.Name)  { throw "Invoke-WithFallback: strategy at index $i missing 'Name'." }
        if (-not $s.ContainsKey('Block') -or -not $s.Block) { throw "Invoke-WithFallback: strategy '$($s.Name)' missing 'Block'." }

        if ($OnAttempt) {
            try { & $OnAttempt $s.Name $i | Out-Null }
            catch {
                Write-ClusterLogIfAvailable -Level Warn -Message "OnAttempt callback threw -- continuing with the strategy" -Data @{
                    strategy = $s.Name; index = $i; callback_error = $_.Exception.Message
                }
            }
        }
        Write-ClusterLogIfAvailable -Level Info -Message "Trying strategy" -Data @{
            strategy = $s.Name; index = $i; total = $Strategy.Count
        }

        try {
            $r = & $s.Block
            $attempts.Add([pscustomobject]@{ Name = $s.Name; Error = $null })
            Write-ClusterLogIfAvailable -Level Info -Message "Strategy succeeded" -Data @{
                strategy = $s.Name; index = $i
            }
            return [pscustomobject]@{
                Winner   = $s.Name
                Index    = $i
                Result   = $r
                Attempts = $attempts.ToArray()
            }
        } catch {
            $err = $_
            $attempts.Add([pscustomobject]@{ Name = $s.Name; Error = $err })
            $isLast = ($i -eq ($Strategy.Count - 1))

            $continue = $true
            if ($ShouldFallback) {
                try { $continue = [bool](& $ShouldFallback $err $s.Name $i) }
                catch {
                    Write-ClusterLogIfAvailable -Level Warn -Message "ShouldFallback predicate threw -- treating as 'do not continue'" -Data @{
                        strategy = $s.Name; index = $i; predicate_error = $_.Exception.Message
                    }
                    $continue = $false
                }
            }

            $lvl = $(if ($isLast -or -not $continue) { 'Error' } else { 'Warn' })
            Write-ClusterLogIfAvailable -Level $lvl `
                -Message "Strategy failed" -Data @{
                    strategy       = $s.Name
                    index          = $i
                    will_fallback  = ($continue -and -not $isLast)
                    exception_type = $err.Exception.GetType().FullName
                    exception_msg  = $err.Exception.Message
                }

            if ($isLast -or -not $continue) {
                $names = ($attempts | ForEach-Object { $_.Name }) -join ' -> '
                $agg = [System.AggregateException]::new(
                    "Invoke-WithFallback: all strategies exhausted ($names).",
                    @($attempts | ForEach-Object { $_.Error.Exception } | Where-Object { $_ })
                )
                # Attach the attempts list AND the first exception to the
                # exception's Data dictionary so callers can inspect per-strategy
                # outcomes and grab the primary failure mode in one property access.
                $agg.Data['Attempts'] = $attempts.ToArray()
                $first = $attempts | Where-Object { $_.Error } | Select-Object -First 1
                if ($first) { $agg.Data['First'] = $first.Error }
                throw $agg
            }
        }
    }
}

Export-ModuleMember -Function Invoke-WithRetry, Invoke-WithFallback

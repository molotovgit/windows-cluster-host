#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Retry.psm1'

    Get-Module Retry | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force
}

AfterAll {
    Get-Module Retry | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-WithRetry' {

    It 'returns the script-block result on first success without retrying' {
        $script:calls = 0
        $r = Invoke-WithRetry -Name 'happy' -ScriptBlock { $script:calls++; 'ok' } 6>$null
        $r | Should -Be 'ok'
        $script:calls | Should -Be 1
    }

    It 'retries up to -MaxAttempts and returns success when an attempt finally works' {
        $script:calls = 0
        $r = Invoke-WithRetry -Name 'flaky' -MaxAttempts 3 -InitialDelayMs 1 -ScriptBlock {
            $script:calls++
            if ($script:calls -lt 3) { throw "transient $script:calls" }
            'ok'
        } 6>$null
        $r | Should -Be 'ok'
        $script:calls | Should -Be 3
    }

    It 'throws the last error after exhausting -MaxAttempts' {
        $script:calls = 0
        $thrown = $null
        try {
            Invoke-WithRetry -Name 'broken' -MaxAttempts 2 -InitialDelayMs 1 -ScriptBlock {
                $script:calls++
                throw "still bad $script:calls"
            } 6>$null
        } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        $script:calls | Should -Be 2
        "$thrown" | Should -Match 'still bad'
    }

    It '-RetryableException filter: matching short name retries' {
        $script:calls = 0
        try {
            Invoke-WithRetry -Name 'ioonly' -MaxAttempts 3 -InitialDelayMs 1 `
                -RetryableException @('IOException') `
                -ScriptBlock { $script:calls++; throw [System.IO.IOException]::new('disk') } 6>$null
        } catch { $null = $_ }
        $script:calls | Should -Be 3
    }

    It '-RetryableException filter: non-matching throws immediately' {
        $script:calls = 0
        try {
            Invoke-WithRetry -Name 'wrongtype' -MaxAttempts 5 -InitialDelayMs 1 `
                -RetryableException @('IOException') `
                -ScriptBlock { $script:calls++; throw [System.UnauthorizedAccessException]::new('denied') } 6>$null
        } catch { $null = $_ }
        $script:calls | Should -Be 1
    }

    It '-ShouldRetry predicate: returning $false stops retry early' {
        $script:calls = 0
        try {
            Invoke-WithRetry -Name 'predicate-stop' -MaxAttempts 5 -InitialDelayMs 1 `
                -ShouldRetry { param($err, $attempt) $false } `
                -ScriptBlock { $script:calls++; throw 'nope' } 6>$null
        } catch { $null = $_ }
        $script:calls | Should -Be 1
    }

    It '-ShouldRetry predicate that throws is treated as "do not retry"' {
        $script:calls = 0
        try {
            Invoke-WithRetry -Name 'predicate-throws' -MaxAttempts 5 -InitialDelayMs 1 `
                -ShouldRetry { throw 'predicate exploded' } `
                -ScriptBlock { $script:calls++; throw 'underlying failure' } 6>$null
        } catch { $null = $_ }
        $script:calls | Should -Be 1
    }

    It 'rejects MaxAttempts outside the validated range' {
        { Invoke-WithRetry -ScriptBlock { } -MaxAttempts 0 6>$null }   | Should -Throw
        { Invoke-WithRetry -ScriptBlock { } -MaxAttempts 200 6>$null } | Should -Throw
    }

    It 'applies exponential backoff (between attempts the delay grows)' {
        $sleeps = New-Object System.Collections.Generic.List[int]
        InModuleScope Retry -Parameters @{ caps = $sleeps } {
            param($caps)
            Mock Start-Sleep -ModuleName Retry { param($Milliseconds) $caps.Add($Milliseconds) | Out-Null }.GetNewClosure()
            try {
                Invoke-WithRetry -Name 'backoff' -MaxAttempts 4 -InitialDelayMs 100 -BackoffFactor 2.0 `
                    -ScriptBlock { throw 'fail' } 6>$null
            } catch { $null = $_ }
        }
        $sleeps.Count | Should -Be 3
        $sleeps[1]    | Should -BeGreaterThan $sleeps[0]
        $sleeps[2]    | Should -BeGreaterThan $sleeps[1]
    }

    It 'respects -MaxDelayMs as a hard cap' {
        $sleeps = New-Object System.Collections.Generic.List[int]
        InModuleScope Retry -Parameters @{ caps = $sleeps } {
            param($caps)
            Mock Start-Sleep -ModuleName Retry { param($Milliseconds) $caps.Add($Milliseconds) | Out-Null }.GetNewClosure()
            try {
                Invoke-WithRetry -Name 'cap' -MaxAttempts 6 -InitialDelayMs 1000 -BackoffFactor 10.0 -MaxDelayMs 5000 `
                    -ScriptBlock { throw 'fail' } 6>$null
            } catch { $null = $_ }
        }
        ($sleeps | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 5000
    }

    It 'respects -MaxDelayMs as a hard cap even WITH -Jitter applied' {
        $sleeps = New-Object System.Collections.Generic.List[int]
        InModuleScope Retry -Parameters @{ caps = $sleeps } {
            param($caps)
            Mock Start-Sleep -ModuleName Retry { param($Milliseconds) $caps.Add($Milliseconds) | Out-Null }.GetNewClosure()
            try {
                # Many attempts so the dataset is statistically meaningful and
                # the +-25% jitter has ample opportunity to overshoot if the
                # math is wrong.
                Invoke-WithRetry -Name 'cap-jitter' -MaxAttempts 12 -InitialDelayMs 1000 `
                    -BackoffFactor 10.0 -MaxDelayMs 2000 -Jitter `
                    -ScriptBlock { throw 'fail' } 6>$null
            } catch { $null = $_ }
        }
        $sleeps.Count | Should -BeGreaterThan 5
        foreach ($s in $sleeps) { $s | Should -BeLessOrEqual 2000 }
    }

    It '-RetryableException matches against a deep InnerException chain' {
        $script:calls = 0
        try {
            Invoke-WithRetry -Name 'inner' -MaxAttempts 3 -InitialDelayMs 1 `
                -RetryableException @('IOException') `
                -ScriptBlock {
                    $script:calls++
                    $inner   = [System.IO.IOException]::new('disk-fault')
                    $wrapper = [System.InvalidOperationException]::new('wrapped', $inner)
                    throw $wrapper
                } 6>$null
        } catch { $null = $_ }
        $script:calls | Should -Be 3
    }
}

Describe 'Invoke-WithFallback' {

    It 'returns the first strategy result and does not run later strategies' {
        $script:run = @{}
        $caps = $script:run
        $r = Invoke-WithFallback -Strategy @(
            @{ Name = 'A'; Block = { $caps.A = $true; 'first' } }
            @{ Name = 'B'; Block = { $caps.B = $true; 'second' } }
        ) 6>$null
        $r.Winner | Should -Be 'A'
        $r.Index  | Should -Be 0
        $r.Result | Should -Be 'first'
        $script:run.ContainsKey('B') | Should -BeFalse
    }

    It 'falls back to the next strategy when the first throws' {
        $r = Invoke-WithFallback -Strategy @(
            @{ Name = 'primary';   Block = { throw 'primary down' } }
            @{ Name = 'secondary'; Block = { 'b-ok' } }
        ) 6>$null
        $r.Winner | Should -Be 'secondary'
        $r.Index  | Should -Be 1
        $r.Result | Should -Be 'b-ok'
        $r.Attempts.Count | Should -Be 2
        $r.Attempts[0].Error | Should -Not -BeNullOrEmpty
        $r.Attempts[1].Error | Should -BeNullOrEmpty
    }

    It '-ShouldFallback returning $false aborts the chain even if more strategies remain' {
        $script:tries = 0
        $caps = [pscustomobject]@{ count = 0 }
        $thrown = $null
        try {
            Invoke-WithFallback -Strategy @(
                @{ Name = 'a'; Block = { $caps.count++; throw 'fatal' } }
                @{ Name = 'b'; Block = { $caps.count++; 'should never run' } }
            ) -ShouldFallback { param($err, $name, $idx) $false } 6>$null
        } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        $caps.count | Should -Be 1
    }

    It 'throws an AggregateException with Attempts attached when all strategies fail' {
        $thrown = $null
        try {
            Invoke-WithFallback -Strategy @(
                @{ Name = 'one';   Block = { throw [System.IO.IOException]::new('disk') } }
                @{ Name = 'two';   Block = { throw [System.Net.WebException]::new('net') } }
                @{ Name = 'three'; Block = { throw [System.InvalidOperationException]::new('logic') } }
            ) 6>$null
        } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        $ex = $thrown.Exception
        $ex | Should -BeOfType ([System.AggregateException])
        $ex.InnerExceptions.Count | Should -Be 3
        $attempts = $ex.Data['Attempts']
        $attempts.Count   | Should -Be 3
        $attempts[0].Name | Should -Be 'one'
        $attempts[1].Name | Should -Be 'two'
        $attempts[2].Name | Should -Be 'three'
    }

    It '-OnAttempt fires before each strategy and receives Name+Index' {
        $script:seen = New-Object System.Collections.Generic.List[string]
        $caps = $script:seen
        Invoke-WithFallback -Strategy @(
            @{ Name = 'first';  Block = { throw 'x' } }
            @{ Name = 'second'; Block = { 'ok' } }
        ) -OnAttempt { param($name, $idx) $caps.Add("${idx}:$name") } 6>$null | Out-Null
        $script:seen.Count    | Should -Be 2
        $script:seen[0]       | Should -Be '0:first'
        $script:seen[1]       | Should -Be '1:second'
    }

    It 'AggregateException.Data[''First''] points at the primary failure mode' {
        $thrown = $null
        try {
            Invoke-WithFallback -Strategy @(
                @{ Name = 'primary';  Block = { throw [System.Net.WebException]::new('net-down') } }
                @{ Name = 'fallback'; Block = { throw [System.IO.IOException]::new('disk-fault') } }
            ) 6>$null
        } catch { $thrown = $_ }
        $thrown.Exception.Data['First']           | Should -Not -BeNullOrEmpty
        $thrown.Exception.Data['First'].Exception | Should -BeOfType ([System.Net.WebException])
    }

    It '-OnAttempt that throws does NOT abort the fallback chain' {
        $r = Invoke-WithFallback -Strategy @(
            @{ Name = 'first';  Block = { throw 'x' } }
            @{ Name = 'second'; Block = { 'ok' } }
        ) -OnAttempt { param($name, $idx) throw "callback boom for $name" } 6>$null
        $r.Winner | Should -Be 'second'
        $r.Result | Should -Be 'ok'
    }

    It 'rejects an empty strategy list' {
        { Invoke-WithFallback -Strategy @() 6>$null } | Should -Throw -ExpectedMessage '*at least one strategy*'
    }

    It 'rejects a strategy missing Name or Block' {
        { Invoke-WithFallback -Strategy @(@{ Block = { 'x' } }) 6>$null }                 | Should -Throw -ExpectedMessage "*missing 'Name'*"
        { Invoke-WithFallback -Strategy @(@{ Name = 'x'; Block = $null }) 6>$null }      | Should -Throw -ExpectedMessage "*missing 'Block'*"
    }
}

Describe 'Composition: Invoke-WithRetry inside Invoke-WithFallback' {

    It 'retries within each fallback strategy independently' {
        $script:counts = @{ smb = 0; https = 0 }
        $caps = $script:counts
        $r = Invoke-WithFallback -Strategy @(
            @{
                Name  = 'smb'
                Block = {
                    Invoke-WithRetry -Name 'smb' -MaxAttempts 2 -InitialDelayMs 1 -ScriptBlock {
                        $caps.smb++
                        throw 'smb-unreachable'
                    } 6>$null
                }
            }
            @{
                Name  = 'https'
                Block = {
                    Invoke-WithRetry -Name 'https' -MaxAttempts 3 -InitialDelayMs 1 -ScriptBlock {
                        $caps.https++
                        if ($caps.https -lt 3) { throw 'https-flaky' }
                        'got-it'
                    } 6>$null
                }
            }
        ) 6>$null
        $r.Winner       | Should -Be 'https'
        $r.Result       | Should -Be 'got-it'
        $script:counts.smb   | Should -Be 2
        $script:counts.https | Should -Be 3
    }
}

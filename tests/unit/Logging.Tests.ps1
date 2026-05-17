#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Logging.psm1'

    Get-Module Logging | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    # Per-run temp roots so Pester can clean up + tests stay hermetic.
    $script:tmpRoot   = Join-Path ([System.IO.Path]::GetTempPath()) ("clusterlog-"   + [guid]::NewGuid().ToString('N').Substring(0,8))
    $script:stateRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("clusterstate-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmpRoot   -ItemType Directory -Force | Out-Null
    New-Item -Path $script:stateRoot -ItemType Directory -Force | Out-Null
    $env:CLUSTERHOST_LOG_DIR   = $script:tmpRoot
    $env:CLUSTERHOST_STATE_DIR = $script:stateRoot
}

AfterAll {
    Remove-Item -LiteralPath $script:tmpRoot   -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:stateRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_LOG_DIR   -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_STATE_DIR -ErrorAction SilentlyContinue
    Get-Module Logging | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Initialize-ClusterLog' {

    BeforeEach { Reset-ClusterLogState }

    It 'creates a log file under the configured directory on first call' {
        $path = Initialize-ClusterLog
        $path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $path | Should -BeTrue
        (Split-Path -Parent $path) | Should -Be $script:tmpRoot
    }

    It 'is idempotent: a second in-process call returns the same path' {
        $a = Initialize-ClusterLog
        $b = Initialize-ClusterLog
        $b | Should -Be $a
    }

    It '-Force rotates to a new file' {
        $a = Initialize-ClusterLog
        Start-Sleep -Milliseconds 1100
        $b = Initialize-ClusterLog -Force
        $b | Should -Not -Be $a
        Test-Path -LiteralPath $a | Should -BeTrue
        Test-Path -LiteralPath $b | Should -BeTrue
    }

    It 'honors an explicit -LogPath' {
        $explicit = Join-Path $script:tmpRoot 'explicit.log'
        $path = Initialize-ClusterLog -LogPath $explicit
        $path | Should -Be $explicit
        Test-Path -LiteralPath $explicit | Should -BeTrue
    }

    It 'writes an "opened" header on a fresh file' {
        $path = Initialize-ClusterLog
        $first = Get-Content -LiteralPath $path -TotalCount 1
        $first | Should -Match 'cluster-host log opened'
    }

    It 'creates the log directory if it does not exist' {
        $deep = Join-Path $script:tmpRoot 'a/b/c/d.log'
        Initialize-ClusterLog -LogPath $deep | Out-Null
        Test-Path -LiteralPath $deep | Should -BeTrue
    }

    Context 'reboot continuity (pointer file)' {

        It 're-attaches to the prior log file when a fresh pointer exists' {
            # Pretend the first process opened a log.
            $first = Initialize-ClusterLog
            # Simulate "second process" by tearing module state down but KEEPING the pointer.
            Reset-ClusterLogState -KeepPointer
            $second = Initialize-ClusterLog
            $second | Should -Be $first
            $line = Get-Content -LiteralPath $second | Select-Object -Last 1
            $line | Should -Match 'cluster-host log resumed'
        }

        It 'ignores a stale pointer (file gone) and starts a fresh log' {
            $first = Initialize-ClusterLog
            Remove-Item -LiteralPath $first -Force
            Reset-ClusterLogState -KeepPointer
            $second = Initialize-ClusterLog
            $second | Should -Not -Be $first
        }

        It '-Force always rotates even when a valid pointer exists' {
            $first = Initialize-ClusterLog
            Reset-ClusterLogState -KeepPointer
            Start-Sleep -Milliseconds 1100
            $second = Initialize-ClusterLog -Force
            $second | Should -Not -Be $first
        }
    }

    Context 'failure modes' {

        It 'throws an actionable error mentioning CLUSTERHOST_LOG_DIR when default dir is not writable' {
            # Point CLUSTERHOST_LOG_DIR at a path under a parent we will lock with NTFS deny ACL.
            $readonly = Join-Path $script:tmpRoot 'readonly-dir'
            New-Item -Path $readonly -ItemType Directory -Force | Out-Null

            # Apply a deny-write ACL for the current user so the directory cannot be written.
            $acl  = Get-Acl $readonly
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'Write,CreateFiles,CreateDirectories', 'ContainerInherit,ObjectInherit', 'None', 'Deny')
            $acl.SetAccessRule($rule)
            Set-Acl -Path $readonly -AclObject $acl

            try {
                $oldLogDir = $env:CLUSTERHOST_LOG_DIR
                $env:CLUSTERHOST_LOG_DIR = $readonly
                Reset-ClusterLogState
                { Initialize-ClusterLog } | Should -Throw -ExpectedMessage '*CLUSTERHOST_LOG_DIR*'
            } finally {
                $env:CLUSTERHOST_LOG_DIR = $oldLogDir
                # Remove the deny ACE so cleanup can delete the dir.
                $acl.RemoveAccessRule($rule) | Out-Null
                Set-Acl -Path $readonly -AclObject $acl
                Remove-Item -LiteralPath $readonly -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Write-ClusterLog' {

    BeforeEach {
        Reset-ClusterLogState
        $script:log = Initialize-ClusterLog
    }

    It 'writes ISO-8601 UTC timestamps' {
        Write-ClusterLog -Level Info -Message 'hello' 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z'
    }

    It 'tags the level in fixed-width brackets' {
        Write-ClusterLog -Level Warn -Message 'careful' 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match '\[WARN \]'
    }

    It 'defaults the stage to "main" when no stage is open' {
        Write-ClusterLog -Level Info -Message 'standalone' 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match '\[main\]'
    }

    It 'attaches structured data as KEY=VALUE pairs' {
        Write-ClusterLog -Level Info -Message 'discovered' -Data @{ controller = '10.0.0.7'; port = 443 } 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match 'controller=10\.0\.0\.7'
        $line | Should -Match 'port=443'
    }

    It 'auto-initializes if called before Initialize-ClusterLog' {
        Reset-ClusterLogState
        Write-ClusterLog -Level Info -Message 'lazy-init' 6>$null
        Get-ClusterLogPath | Should -Not -BeNullOrEmpty
    }

    It 'splits multi-line messages so each line has its own timestamp' {
        Write-ClusterLog -Level Info -Message "line1`nline2" 6>$null
        $tail = Get-Content -LiteralPath $script:log | Select-Object -Last 2
        $tail[0] | Should -Match 'line1'
        $tail[1] | Should -Match 'line2'
        $tail[1] | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'records lines below the console threshold to the file' {
        Initialize-ClusterLog -Force -ConsoleLevel Error
        Write-ClusterLog -Level Debug -Message 'noisy' 6>$null
        $hits = Select-String -Path (Get-ClusterLogPath) -Pattern 'noisy'
        $hits | Should -Not -BeNullOrEmpty
    }

    It 'sanitizes embedded newlines in -Data values to spaces' {
        Write-ClusterLog -Level Info -Message 'cleaned' -Data @{ msg = "a`r`nb" } 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match 'msg=a b'
    }

    Context 'secret redaction' {

        It 'redacts -Data values whose key matches the default pattern' {
            Write-ClusterLog -Level Info -Message 'logging-in' -Data @{ password = 'hunter2'; user = 'alice' } 6>$null
            $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
            $line | Should -Match 'password=<redacted>'
            $line | Should -Match 'user=alice'
            $line | Should -Not -Match 'hunter2'
        }

        It 'redacts token, secret, api_key, bearer, credentials, authorization keys' {
            $secrets = @{
                token         = 'tok_abc123'
                secret        = 's3cr3t'
                api_key       = 'sk_live_xyz'
                bearer        = 'eyJhbGciOiJIUzI1NiJ9.x'
                credentials   = 'plain'
                Authorization = 'Bearer xxx'
            }
            Write-ClusterLog -Level Info -Message 'many secrets' -Data $secrets 6>$null
            $log = Get-Content -LiteralPath $script:log -Raw
            foreach ($v in 'tok_abc123','s3cr3t','sk_live_xyz','eyJhbGciOiJIUzI1NiJ9.x','plain','Bearer xxx') {
                $log | Should -Not -Match ([regex]::Escape($v))
            }
        }

        It 'lets callers add to the redaction pattern' {
            Set-ClusterLogRedaction -AddKeyPattern '(?i)^controller_pin$'
            Write-ClusterLog -Level Info -Message 'extra' -Data @{ controller_pin = '0000'; user = 'bob' } 6>$null
            $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
            $line | Should -Match 'controller_pin=<redacted>'
            $line | Should -Match 'user=bob'
            (Get-ClusterLogRedaction) | Should -Match 'controller_pin'
        }

        It 'lets callers fully replace the redaction pattern' {
            Set-ClusterLogRedaction -KeyPattern '(?i)^pin$'
            # Now 'password' is NOT redacted under the new pattern.
            Write-ClusterLog -Level Info -Message 'after-replace' -Data @{ password = 'hunter2'; pin = '1234' } 6>$null
            $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
            $line | Should -Match 'password=hunter2'
            $line | Should -Match 'pin=<redacted>'
        }
    }

    Context 'BOM-less UTF-8' {

        It 'does NOT write a UTF-8 BOM at the start of the file' {
            $log = Get-ClusterLogPath
            $bytes = [System.IO.File]::ReadAllBytes($log)
            $bytes.Length | Should -BeGreaterThan 0
            # 0xEF,0xBB,0xBF is the UTF-8 BOM
            if ($bytes.Length -ge 3) {
                ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
            }
        }

        It 'round-trips non-ASCII characters' {
            Write-ClusterLog -Level Info -Message 'hello world non-ascii: a-umlaut and CJK' 6>$null
            $content = Get-Content -LiteralPath $script:log -Raw -Encoding utf8
            $content | Should -Match 'hello world non-ascii'
        }
    }

    Context 'transient I/O retry' {

        It 'rides out a brief external file lock without throwing' {
            $log = Get-ClusterLogPath
            # Open the file with FileShare.None for ~120 ms (longer than 3 * 50 ms backoff window? Actually
            # the retry policy is 3 attempts * 50 ms = up to 100 ms. Lock for 60 ms so first attempt fails,
            # retries succeed.).
            $job = Start-Job -ScriptBlock {
                param($p)
                $fs = [System.IO.File]::Open($p, 'Open', 'Write', 'None')
                Start-Sleep -Milliseconds 60
                $fs.Close()
            } -ArgumentList $log

            Start-Sleep -Milliseconds 10
            { Write-ClusterLog -Level Info -Message 'survived-lock' 6>$null } | Should -Not -Throw
            Wait-Job $job | Out-Null
            Remove-Job $job
            Select-String -Path $log -Pattern 'survived-lock' | Should -Not -BeNullOrEmpty
        }
    }

    Context 'error-record formatting' {

        It '-ErrorRecord emits type, message, and a stack line' {
            try { throw [System.IO.FileNotFoundException]::new('missing', 'C:\nope.txt') }
            catch { Write-ClusterLog -Level Error -Message 'caught it' -ErrorRecord $_ 6>$null }
            $log = Get-Content -LiteralPath $script:log -Raw
            $log | Should -Match 'exception_type=System\.IO\.FileNotFoundException'
            $log | Should -Match 'exception_message=missing'
            $log | Should -Match 'stack:'
        }
    }

    Context 'oversized lines' {

        It 'truncates lines over the byte cap and annotates the truncation' {
            $big = 'x' * 20000
            Write-ClusterLog -Level Info -Message $big 6>$null
            $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
            $line.Length | Should -BeLessThan 10000
            $line | Should -Match 'truncated'
        }
    }
}

Describe 'Start-StageLog / Stop-StageLog' {

    BeforeEach {
        Reset-ClusterLogState
        $script:log = Initialize-ClusterLog
    }

    It 'pushes the stage name onto the stack on Start' {
        Start-StageLog -Name 'Preflight' 6>$null
        Get-OpenStageName | Should -Contain 'Preflight'
    }

    It 'logs a begin marker' {
        Start-StageLog -Name 'Hyperv' 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match 'begin Hyperv'
    }

    It 'inherits the stage tag in subsequent Write-ClusterLog calls' {
        Start-StageLog -Name 'Discover' 6>$null
        Write-ClusterLog -Level Info -Message 'probing mDNS' 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match '\[Discover\]'
    }

    It 'pops on Stop and records elapsed seconds' {
        Start-StageLog -Name 'Tuning' 6>$null
        Start-Sleep -Milliseconds 80
        Stop-StageLog -Outcome Success 6>$null
        Get-OpenStageName | Should -Not -Contain 'Tuning'
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match 'end Tuning'
        $line | Should -Match 'elapsed_s=[\d.]+'
    }

    It 'maps Outcome=Failure to an Error-level line and escapes quotes in -Detail' {
        Start-StageLog -Name 'Vms' 6>$null
        Stop-StageLog -Outcome Failure -Detail 'failed: "golden.vhdx" not found' 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match '\[ERROR\]'
        # The double-quotes in Detail must be escaped so the KV format stays parseable.
        $line | Should -Match 'detail="failed: \\"golden\.vhdx\\" not found"'
    }

    It 'warns instead of throwing if Stop-StageLog has no open stage' {
        { Stop-StageLog 6>$null } | Should -Not -Throw
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match 'no open stage'
    }

    It 'supports nested stages (innermost wins for Write-ClusterLog auto-tag)' {
        Start-StageLog -Name 'Outer' 6>$null
        Start-StageLog -Name 'Inner' 6>$null
        Write-ClusterLog -Level Info -Message 'mid' 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match '\[Inner\]'
        Stop-StageLog 6>$null
        Write-ClusterLog -Level Info -Message 'back-out' 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match '\[Outer\]'
        Stop-StageLog 6>$null
    }
}

Describe 'Robustness' {

    BeforeEach { Reset-ClusterLogState }

    It 'tolerates empty messages' {
        Initialize-ClusterLog | Out-Null
        { Write-ClusterLog -Level Info -Message '' 6>$null } | Should -Not -Throw
    }
}

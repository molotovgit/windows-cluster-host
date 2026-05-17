#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Logging.psm1'

    # Force-import a clean copy on each run.
    Get-Module Logging | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    # Use a per-run temp dir for log files so Pester can clean up.
    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("clusterlog-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmpRoot -ItemType Directory -Force | Out-Null
    $env:CLUSTERHOST_LOG_DIR = $script:tmpRoot
}

AfterAll {
    Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_LOG_DIR -ErrorAction SilentlyContinue
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

    It 'is idempotent: a second call returns the same path' {
        $a = Initialize-ClusterLog
        $b = Initialize-ClusterLog
        $b | Should -Be $a
    }

    It '-Force rotates to a new file' {
        $a = Initialize-ClusterLog
        Start-Sleep -Milliseconds 1100  # log file name has second granularity
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

    It 'writes a header line into the new log' {
        $path = Initialize-ClusterLog
        $first = Get-Content -LiteralPath $path -TotalCount 1
        $first | Should -Match 'cluster-host log opened'
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
        Initialize-ClusterLog -Force -ConsoleLevel Error  # only Error to console
        Write-ClusterLog -Level Debug -Message 'noisy' 6>$null
        $hits = Select-String -Path (Get-ClusterLogPath) -Pattern 'noisy'
        $hits | Should -Not -BeNullOrEmpty
    }

    It 'sanitizes embedded newlines in -Data values to spaces' {
        Write-ClusterLog -Level Info -Message 'cleaned' -Data @{ msg = "a`r`nb" } 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match 'msg=a b'
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

    It 'maps Outcome=Failure to an Error-level line' {
        Start-StageLog -Name 'Vms' 6>$null
        Stop-StageLog -Outcome Failure -Detail 'no free disk' 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match '\[ERROR\]'
        $line | Should -Match 'detail="no free disk"'
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
        Stop-StageLog 6>$null  # closes Inner
        Write-ClusterLog -Level Info -Message 'back-out' 6>$null
        $line = Get-Content -LiteralPath $script:log | Select-Object -Last 1
        $line | Should -Match '\[Outer\]'
        Stop-StageLog 6>$null
    }
}

Describe 'Robustness' {

    BeforeEach { Reset-ClusterLogState }

    It 'creates the log directory if it does not exist' {
        $deep = Join-Path $script:tmpRoot 'a/b/c/d.log'
        Initialize-ClusterLog -LogPath $deep | Out-Null
        Test-Path -LiteralPath $deep | Should -BeTrue
    }

    It 'tolerates empty messages' {
        Initialize-ClusterLog | Out-Null
        { Write-ClusterLog -Level Info -Message '' 6>$null } | Should -Not -Throw
    }

    It 'uses UTF-8 encoding so non-ASCII characters survive a round-trip' {
        $log = Initialize-ClusterLog
        Write-ClusterLog -Level Info -Message 'héllo · 中文' 6>$null
        $content = Get-Content -LiteralPath $log -Raw -Encoding utf8
        $content | Should -Match 'héllo'
        $content | Should -Match '中文'
    }
}

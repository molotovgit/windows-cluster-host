#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $script:installPs1 = Join-Path $script:repoRoot 'install.ps1'

    # Dot-source the installer with the auto-run main block disabled so
    # the helper functions enter the BeforeAll scope.
    $env:CLUSTERHOST_NOAUTORUN = '1'
    . $script:installPs1
}

AfterAll {
    Remove-Item Env:CLUSTERHOST_NOAUTORUN -ErrorAction SilentlyContinue
}

Describe 'install.ps1 helpers' {

    It 'Test-IsAdministrator returns a bool' {
        $result = Test-IsAdministrator
        $result.GetType().Name | Should -Be 'Boolean'
    }

    It 'Resolve-ZipUrl builds the default zip url when -Override is empty' {
        Resolve-ZipUrl -Address '10.0.0.7' -Override '' | Should -Be 'https://10.0.0.7/cluster-host.zip'
    }

    It 'Resolve-ZipUrl honors an explicit -Override' {
        Resolve-ZipUrl -Address '10.0.0.7' -Override 'https://other/cluster-host.zip' | Should -Be 'https://other/cluster-host.zip'
    }

    It 'Resolve-ZipUrl returns $null when both Address and Override are empty' {
        Resolve-ZipUrl -Address '' -Override '' | Should -BeNullOrEmpty
    }

    It 'Write-StarterConfig produces parseable JSON with the controller address' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("starter-cfg-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
        try {
            Write-StarterConfig -Path $tmp -Controller '10.0.0.7'
            Test-Path -LiteralPath $tmp | Should -BeTrue
            $cfg = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
            $cfg.controller.address | Should -Be '10.0.0.7'
            $cfg.controller.port    | Should -Be 443
            $cfg.vms.count          | Should -Be 2
            $cfg.network.nat_switch_name | Should -Be 'ClusterNATSwitch'
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Write-StarterConfig produces controller.address=null when no controller passed' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("starter-cfg-null-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.json')
        try {
            Write-StarterConfig -Path $tmp -Controller $null
            $cfg = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
            $cfg.controller.address | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Copy-RepoTree returns null when called from a directory that does not look like a repo' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("not-a-repo-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -Path $tmp -ItemType Directory -Force | Out-Null
        try {
            $r = Copy-RepoTree -ScriptRoot $tmp -Destination (Join-Path $tmp 'staging')
            $r | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Copy-RepoTree successfully copies the repo when src/, config/ and REVIEW_PROMPT.md are present' {
        $dest = Join-Path ([System.IO.Path]::GetTempPath()) ("repo-copy-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        try {
            $r = Copy-RepoTree -ScriptRoot $script:repoRoot -Destination $dest
            $r | Should -Be $dest
            Test-Path -LiteralPath (Join-Path $dest 'src\Invoke-ClusterHostSetup.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $dest 'src\lib\Logging.psm1')            | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $dest 'config\cluster-config.example.json') | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'install.ps1 structural checks' {
    It 'parses cleanly under PowerShell' {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:installPs1, [ref]$null, [ref]$errs)
        $errs.Count | Should -Be 0
    }

    It 'has a comment-based help block at the top' {
        $head = Get-Content -LiteralPath $script:installPs1 -TotalCount 5
        ($head -join "`n") | Should -Match '\.SYNOPSIS'
    }

    It 'has a main-block auto-run gate keyed on CLUSTERHOST_NOAUTORUN' {
        $raw = Get-Content -LiteralPath $script:installPs1 -Raw
        $raw | Should -Match 'CLUSTERHOST_NOAUTORUN'
    }
}

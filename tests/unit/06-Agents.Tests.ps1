#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir     = Join-Path $repoRoot 'src\lib'
    $stagePath  = Join-Path $repoRoot 'src\stages\06-Agents.ps1'

    foreach ($mod in 'Logging','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    . $stagePath

    function Set-AgentsHappyPath {
        Reset-AgentsInvoker
        $caps = [pscustomobject]@{
            Calls = New-Object System.Collections.Generic.List[string]
        }
        Set-AgentsInvoker -Name GetOpenSshState        -ScriptBlock { $caps.Calls.Add('GetOpenSshState');        @{ State = 'NotPresent'; Source = 'WindowsCapability' } }.GetNewClosure()
        Set-AgentsInvoker -Name InstallOpenSshCapability -ScriptBlock { $caps.Calls.Add('InstallOpenSshCapability'); @{ Ok = $true; Detail = 'cap-ok' } }.GetNewClosure()
        Set-AgentsInvoker -Name InstallOpenSshDism     -ScriptBlock { $caps.Calls.Add('InstallOpenSshDism');     @{ Ok = $false; Detail = 'dism-not-called' } }.GetNewClosure()
        Set-AgentsInvoker -Name SetSshdService         -ScriptBlock { $caps.Calls.Add('SetSshdService');         @{ Ok = $true; Status = 'Running'; StartType = 'Automatic'; Detail = 'sshd Running, StartType=Automatic' } }.GetNewClosure()
        Set-AgentsInvoker -Name WriteSshAuthorizedKey  -ScriptBlock { param($p,$k) $caps.Calls.Add("WriteSshAuthorizedKey:$p"); @{ Ok = $true; AlreadyPresent = $false; Path = $p } }.GetNewClosure()
        Set-AgentsInvoker -Name HardenAuthorizedKeyAcl -ScriptBlock { param($p) $caps.Calls.Add("HardenAuthorizedKeyAcl:$p"); @{ Ok = $true; Detail = 'ACL hardened' } }.GetNewClosure()
        Set-AgentsInvoker -Name DownloadMeshAgent      -ScriptBlock { param($smb,$https,$dst) $caps.Calls.Add("DownloadMeshAgent:$smb|$https|$dst"); @{ Ok = $true; Source = 'smb'; Detail = 'copied' } }.GetNewClosure()
        Set-AgentsInvoker -Name VerifyMeshAgentHash    -ScriptBlock { param($p,$h) $caps.Calls.Add("VerifyMeshAgentHash:$p|$h"); @{ Ok = $true; Skipped = (-not $h); Detail = if ($h) {'verified'} else {'no hash'} } }.GetNewClosure()
        Set-AgentsInvoker -Name InstallMeshAgent       -ScriptBlock { param($p) $caps.Calls.Add("InstallMeshAgent:$p"); @{ Ok = $true; ExitCode = 0; Detail = 'installer exit=0' } }.GetNewClosure()
        Set-AgentsInvoker -Name GetMeshAgentService    -ScriptBlock { $caps.Calls.Add('GetMeshAgentService'); @{ Found = $true; Status = 'Running' } }.GetNewClosure()
        return $caps
    }
}

AfterAll {
    Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    foreach ($mod in 'Logging','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-AgentsStage' {

    AfterEach { Reset-AgentsInvoker }

    It 'happy path: every sub-step Pass, Overall=Pass' {
        # Need to override GetMeshAgentService to FIRST return not-found (so we proceed to install),
        # THEN return Running (after install verification). Track call count.
        $caps = Set-AgentsHappyPath
        $script:gmcCalls = 0
        Set-AgentsInvoker -Name GetMeshAgentService -ScriptBlock {
            $script:gmcCalls++
            if ($script:gmcCalls -eq 1) { @{ Found = $false; Status = 'NotInstalled' } }
            else                        { @{ Found = $true;  Status = 'Running'      } }
        }
        $r = Invoke-AgentsStage -SshAuthorizedKey 'ssh-ed25519 AAAA...' `
                                -MeshAgentSmbPath '\\controller\images\meshagent.exe' `
                                -MeshAgentHttpsUrl 'https://controller/meshagents?id=4' 6>$null
        $r.Overall | Should -Be 'Warn'   # SHA256 step warns when no hash supplied
        $names = @($r.Steps | ForEach-Object Name)
        $names | Should -Contain 'OpenSSH Server feature'
        $names | Should -Contain 'sshd service'
        $names | Should -Contain 'Authorized key deployment'
        $names | Should -Contain 'Authorized key ACL'
        $names | Should -Contain 'MeshAgent download'
        $names | Should -Contain 'MeshAgent SHA256'
        $names | Should -Contain 'MeshAgent install'
    }

    It 'skips OpenSSH install when capability is already Installed' {
        $caps = Set-AgentsHappyPath
        Set-AgentsInvoker -Name GetOpenSshState -ScriptBlock { @{ State = 'Installed'; Source = 'WindowsCapability' } }
        $r = Invoke-AgentsStage -SshAuthorizedKey 'ssh-rsa AAAA' -SkipMeshAgent 6>$null
        ($r.Steps | Where-Object Name -eq 'OpenSSH Server feature').Status | Should -Be 'Pass'
        $caps.Calls | Should -Not -Contain 'InstallOpenSshCapability'
    }

    It 'falls back to DISM when Add-WindowsCapability fails' {
        $caps = Set-AgentsHappyPath
        Set-AgentsInvoker -Name InstallOpenSshCapability -ScriptBlock { @{ Ok = $false; Detail = 'cap-fail' } }
        Set-AgentsInvoker -Name InstallOpenSshDism       -ScriptBlock { @{ Ok = $true;  Detail = 'dism-ok'  } }
        $r = Invoke-AgentsStage -SshAuthorizedKey 'ssh-rsa AAAA' -SkipMeshAgent 6>$null
        $ssh = $r.Steps | Where-Object Name -eq 'OpenSSH Server feature'
        $ssh.Status | Should -Be 'Pass'
        $ssh.Detail | Should -Match 'DISM fallback'
    }

    It 'reports Overall=Fail when both Add-WindowsCapability AND DISM fail' {
        $caps = Set-AgentsHappyPath
        Set-AgentsInvoker -Name InstallOpenSshCapability -ScriptBlock { @{ Ok = $false; Detail = 'cap-fail' } }
        Set-AgentsInvoker -Name InstallOpenSshDism       -ScriptBlock { @{ Ok = $false; Detail = 'dism-fail' } }
        $r = Invoke-AgentsStage -SshAuthorizedKey 'ssh-rsa AAAA' -SkipMeshAgent 6>$null
        $r.Overall | Should -Be 'Fail'
        ($r.Steps | Where-Object Name -eq 'OpenSSH Server feature').Status | Should -Be 'Fail'
    }

    It 'Warns when no SshAuthorizedKey is supplied' {
        $caps = Set-AgentsHappyPath
        $r = Invoke-AgentsStage -SkipMeshAgent 6>$null
        ($r.Steps | Where-Object Name -eq 'Authorized key deployment').Status | Should -Be 'Warn'
        # ACL step should NOT run when there's no key.
        @($r.Steps | Where-Object Name -eq 'Authorized key ACL').Count | Should -Be 0
    }

    It 'reads SshAuthorizedKey from -Config when not supplied directly' {
        $caps = Set-AgentsHappyPath
        $cfg = [pscustomobject]@{ ssh = [pscustomobject]@{ admin_public_key = 'ssh-ed25519 AAA-from-config' } }
        $r = Invoke-AgentsStage -Config $cfg -SkipMeshAgent 6>$null
        ($r.Steps | Where-Object Name -eq 'Authorized key deployment').Status | Should -Be 'Pass'
    }

    It '-SkipMeshAgent reports MeshAgent as Skipped' {
        $caps = Set-AgentsHappyPath
        $r = Invoke-AgentsStage -SshAuthorizedKey 'ssh-rsa AAAA' -SkipMeshAgent 6>$null
        ($r.Steps | Where-Object Name -eq 'MeshAgent').Status | Should -Be 'Skipped'
    }

    It 'fails MeshAgent download when SMB and HTTPS both fail' {
        $caps = Set-AgentsHappyPath
        Set-AgentsInvoker -Name GetMeshAgentService -ScriptBlock { @{ Found = $false; Status = 'NotInstalled' } }
        Set-AgentsInvoker -Name DownloadMeshAgent -ScriptBlock { param($smb,$https,$dst) @{ Ok = $false; Source = 'none'; Detail = 'both failed' } }
        $r = Invoke-AgentsStage -SshAuthorizedKey 'ssh-rsa AAAA' `
                                -MeshAgentSmbPath '\\controller\images\meshagent.exe' `
                                -MeshAgentHttpsUrl 'https://controller/meshagents?id=4' 6>$null
        ($r.Steps | Where-Object Name -eq 'MeshAgent download').Status | Should -Be 'Fail'
        $r.Overall | Should -Be 'Fail'
    }

    It 'fails Overall when SHA256 mismatch' {
        $caps = Set-AgentsHappyPath
        Set-AgentsInvoker -Name GetMeshAgentService -ScriptBlock { @{ Found = $false; Status = 'NotInstalled' } }
        Set-AgentsInvoker -Name VerifyMeshAgentHash -ScriptBlock { param($p,$h) @{ Ok = $false; Skipped = $false; Detail = 'hash mismatch' } }
        $r = Invoke-AgentsStage -SshAuthorizedKey 'ssh-rsa AAAA' `
                                -MeshAgentSmbPath '\\controller\images\meshagent.exe' `
                                -MeshAgentHttpsUrl 'https://controller/meshagents?id=4' `
                                -MeshAgentSha256 'deadbeef' 6>$null
        ($r.Steps | Where-Object Name -eq 'MeshAgent SHA256').Status | Should -Be 'Fail'
        $r.Overall | Should -Be 'Fail'
    }

    It '-DryRun reports Skipped for every sub-stage that would mutate' {
        $caps = Set-AgentsHappyPath
        $r = Invoke-AgentsStage -SshAuthorizedKey 'ssh-rsa AAAA' `
                                -MeshAgentSmbPath '\\controller\images\meshagent.exe' `
                                -MeshAgentHttpsUrl 'https://controller/meshagents?id=4' `
                                -DryRun 6>$null
        @($r.Steps | Where-Object Status -eq 'Skipped').Count | Should -BeGreaterOrEqual 3
        $caps.Calls | Should -Not -Contain 'InstallOpenSshCapability'
        $caps.Calls | Should -Not -Contain 'SetSshdService'
        $caps.Calls | Should -Not -Contain 'InstallMeshAgent'
    }

    It 'reports Warn when Mesh Agent service is not Running after install' {
        $caps = Set-AgentsHappyPath
        $script:gmcCalls = 0
        Set-AgentsInvoker -Name GetMeshAgentService -ScriptBlock {
            $script:gmcCalls++
            if ($script:gmcCalls -eq 1) { @{ Found = $false; Status = 'NotInstalled' } }
            else                        { @{ Found = $true;  Status = 'Stopped'      } }
        }
        $r = Invoke-AgentsStage -SshAuthorizedKey 'ssh-rsa AAAA' `
                                -MeshAgentSmbPath '\\controller\images\meshagent.exe' `
                                -MeshAgentHttpsUrl 'https://controller/meshagents?id=4' 6>$null
        ($r.Steps | Where-Object Name -eq 'MeshAgent install').Status | Should -Be 'Warn'
    }
}

Describe 'HardenAuthorizedKeyAcl (real ACL on a temp file)' {

    AfterEach { Reset-AgentsInvoker }

    It 'sets exactly SYSTEM and BUILTIN\Administrators FullControl with inheritance off' {
        # Use the DEFAULT (real) HardenAuthorizedKeyAcl invoker -- this is the
        # only place we exercise real Windows ACL semantics.
        Reset-AgentsInvoker
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("agents-acl-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.tmp')
        Set-Content -LiteralPath $tmp -Value 'placeholder' -Encoding utf8

        try {
            # Verify the file starts with inheritance ON (default for a freshly-created file under TEMP).
            $before = Get-Acl -Path $tmp
            $before.AreAccessRulesProtected | Should -BeFalse

            # Reach the default invoker and run it.
            $invoker = (Get-Variable -Name AgentsInvokers -ValueOnly)['HardenAuthorizedKeyAcl']
            $r = & $invoker $tmp
            $r.Ok | Should -BeTrue

            $after = Get-Acl -Path $tmp
            $after.AreAccessRulesProtected | Should -BeTrue
            # Only SYSTEM and BUILTIN\Administrators should remain.
            $identities = @($after.Access | ForEach-Object { "$($_.IdentityReference)" })
            $identities | Should -Contain 'NT AUTHORITY\SYSTEM'
            $identities | Should -Contain 'BUILTIN\Administrators'
            foreach ($id in $identities) {
                $id | Should -BeIn @('NT AUTHORITY\SYSTEM','BUILTIN\Administrators')
            }
            # Every remaining ACE must be FullControl.
            foreach ($ace in $after.Access) {
                "$($ace.FileSystemRights)" | Should -Match 'FullControl'
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'WriteSshAuthorizedKey idempotency (real file)' {

    AfterEach { Reset-AgentsInvoker }

    It 'is idempotent: second call with the same key does not duplicate the line' {
        Reset-AgentsInvoker
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("agents-keys-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.tmp')
        $key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEY admin@cluster'

        try {
            $invoker = (Get-Variable -Name AgentsInvokers -ValueOnly)['WriteSshAuthorizedKey']
            $r1 = & $invoker $tmp $key
            $r2 = & $invoker $tmp $key
            $r1.Ok             | Should -BeTrue
            $r1.AlreadyPresent | Should -BeFalse
            $r2.Ok             | Should -BeTrue
            $r2.AlreadyPresent | Should -BeTrue
            $content = Get-Content -LiteralPath $tmp -Encoding utf8
            @($content | Where-Object { $_.Trim() -eq $key }).Count | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Test seam gating' {
    It 'Set-AgentsInvoker refuses to run without CLUSTERHOST_ALLOW_TEST_SEAMS' {
        Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
        $thrown = $null
        try { Set-AgentsInvoker -Name GetOpenSshState -ScriptBlock { @{} } } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        "$thrown" | Should -Match 'CLUSTERHOST_ALLOW_TEST_SEAMS'
        $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    }
}

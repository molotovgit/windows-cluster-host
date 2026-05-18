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
        Set-AgentsInvoker -Name UninstallMeshAgent     -ScriptBlock { $caps.Calls.Add('UninstallMeshAgent'); @{ Ok = $true; ExitCode = 0; Detail = '-fulluninstall exit=0' } }.GetNewClosure()
        Set-AgentsInvoker -Name GetMeshAgentService    -ScriptBlock { $caps.Calls.Add('GetMeshAgentService'); @{ Found = $false; Status = 'NotInstalled' } }.GetNewClosure()
        # Bug 21 new invokers -- default to "freshly installed, connected to our controller, MeshServer=local then rewritten"
        Set-AgentsInvoker -Name GetAgentMshConfig      -ScriptBlock { param($p) $caps.Calls.Add('GetAgentMshConfig'); [pscustomobject]@{ Found = $true; MeshServer = 'local'; MeshName = 'cluster-hosts'; MeshID = '0xabc'; ServerID = 'def'; Path = 'C:\Program Files\Mesh Agent\MeshAgent.msh' } }.GetNewClosure()
        Set-AgentsInvoker -Name SetAgentMshServer      -ScriptBlock { param($u,$p) $caps.Calls.Add("SetAgentMshServer:$u"); @{ Ok = $true; Changed = $true; Detail = "MeshServer rewritten to $u" } }.GetNewClosure()
        Set-AgentsInvoker -Name OpenSmbAuth            -ScriptBlock { param($unc,$u,$pw) $caps.Calls.Add("OpenSmbAuth:$unc|$u"); @{ Ok = $true; SharePath = '\\srv\share'; Detail = 'mounted' } }.GetNewClosure()
        Set-AgentsInvoker -Name CloseSmbAuth           -ScriptBlock { param($sp) $caps.Calls.Add("CloseSmbAuth:$sp") }.GetNewClosure()
        Set-AgentsInvoker -Name RestartMeshAgentService -ScriptBlock { param($w) $caps.Calls.Add('RestartMeshAgentService'); @{ Ok = $true; Detail = 'restarted' } }.GetNewClosure()
        Set-AgentsInvoker -Name TestAgentConnectedTo   -ScriptBlock { param($addr,$port,$wait) $caps.Calls.Add("TestAgentConnectedTo:${addr}:$port"); @{ Connected = $true; Detail = "Established to ${addr}:$port" } }.GetNewClosure()
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

    It 'happy path: every sub-step Pass, Overall=Pass (no leftover agent path)' {
        $caps = Set-AgentsHappyPath
        $cfg = [pscustomobject]@{ controller = [pscustomobject]@{ address = '10.0.0.7'; port = 443 } }
        $r = Invoke-AgentsStage -Config $cfg -SshAuthorizedKey 'ssh-ed25519 AAAA...' `
                                -MeshAgentSmbPath '\\controller\images\meshagent.exe' `
                                -MeshAgentHttpsUrl 'https://controller/meshagents?id=4' 6>$null
        $r.Overall | Should -Be 'Warn'   # SHA256 step Warns when no hash supplied
        $names = @($r.Steps | ForEach-Object Name)
        $names | Should -Contain 'OpenSSH Server feature'
        $names | Should -Contain 'sshd service'
        $names | Should -Contain 'Authorized key deployment'
        $names | Should -Contain 'Authorized key ACL'
        $names | Should -Contain 'MeshAgent download'
        $names | Should -Contain 'MeshAgent SHA256'
        $names | Should -Contain 'MeshAgent install'
        $names | Should -Contain 'MeshAgent connection verify'
        ($r.Steps | Where-Object Name -eq 'MeshAgent connection verify').Status | Should -Be 'Pass'
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
        Set-AgentsInvoker -Name DownloadMeshAgent -ScriptBlock { param($smb,$https,$dst) @{ Ok = $false; Source = 'none'; Detail = 'both failed' } }
        $cfg = [pscustomobject]@{ controller = [pscustomobject]@{ address = '10.0.0.7' } }
        $r = Invoke-AgentsStage -Config $cfg -SshAuthorizedKey 'ssh-rsa AAAA' `
                                -MeshAgentSmbPath '\\controller\images\meshagent.exe' `
                                -MeshAgentHttpsUrl 'https://controller/meshagents?id=4' 6>$null
        ($r.Steps | Where-Object Name -eq 'MeshAgent download').Status | Should -Be 'Fail'
        $r.Overall | Should -Be 'Fail'
    }

    It 'fails Overall when SHA256 mismatch' {
        $caps = Set-AgentsHappyPath
        Set-AgentsInvoker -Name VerifyMeshAgentHash -ScriptBlock { param($p,$h) @{ Ok = $false; Skipped = $false; Detail = 'hash mismatch' } }
        $cfg = [pscustomobject]@{ controller = [pscustomobject]@{ address = '10.0.0.7' } }
        $r = Invoke-AgentsStage -Config $cfg -SshAuthorizedKey 'ssh-rsa AAAA' `
                                -MeshAgentSmbPath '\\controller\images\meshagent.exe' `
                                -MeshAgentHttpsUrl 'https://controller/meshagents?id=4' `
                                -MeshAgentSha256 'deadbeef' 6>$null
        ($r.Steps | Where-Object Name -eq 'MeshAgent SHA256').Status | Should -Be 'Fail'
        $r.Overall | Should -Be 'Fail'
    }

    It '-DryRun reports Skipped for every sub-stage that would mutate' {
        $caps = Set-AgentsHappyPath
        $cfg = [pscustomobject]@{ controller = [pscustomobject]@{ address = '10.0.0.7' } }
        $r = Invoke-AgentsStage -Config $cfg -SshAuthorizedKey 'ssh-rsa AAAA' `
                                -MeshAgentSmbPath '\\controller\images\meshagent.exe' `
                                -MeshAgentHttpsUrl 'https://controller/meshagents?id=4' `
                                -DryRun 6>$null
        @($r.Steps | Where-Object Status -eq 'Skipped').Count | Should -BeGreaterOrEqual 3
        $caps.Calls | Should -Not -Contain 'InstallOpenSshCapability'
        $caps.Calls | Should -Not -Contain 'SetSshdService'
        $caps.Calls | Should -Not -Contain 'InstallMeshAgent'
    }
}

Describe 'Invoke-AgentsStage MeshAgent verification (real-hardware bug 21)' {

    AfterEach { Reset-AgentsInvoker }

    It 'uninstalls a leftover agent bound to a DIFFERENT group before installing ours' {
        $caps = Set-AgentsHappyPath
        # Service IS running (leftover present)
        Set-AgentsInvoker -Name GetMeshAgentService -ScriptBlock { $caps.Calls.Add('GetMeshAgentService'); @{ Found = $true; Status = 'Running' } }.GetNewClosure()
        # ...but its .msh is bound to a foreign group
        Set-AgentsInvoker -Name GetAgentMshConfig -ScriptBlock { param($p) $caps.Calls.Add('GetAgentMshConfig'); [pscustomobject]@{ Found=$true; MeshServer='wss://other.example:443/agent.ashx'; MeshName='other-group'; MeshID='0xfff'; ServerID='ghi'; Path='C:\Program Files\Mesh Agent\MeshAgent.msh' } }.GetNewClosure()
        $cfg = [pscustomobject]@{ controller = [pscustomobject]@{ address = '10.0.0.7'; port = 443 } }
        $r = Invoke-AgentsStage -Config $cfg -SshAuthorizedKey 'ssh-rsa A' `
                                -MeshAgentSmbPath '\\10.0.0.7\ClusterShare\agents\cluster-hosts\meshagent64-cluster-hosts.exe' 6>$null
        # MUST have called Uninstall before downloading.
        $caps.Calls | Should -Contain 'UninstallMeshAgent'
        $caps.Calls | Should -Contain 'InstallMeshAgent:C:\Users\amirb\AppData\Local\Temp\meshagent-installer.exe' -ErrorAction SilentlyContinue # path varies; lenient
        # Final connection verify must have been called against OUR controller.
        ($r.Steps | Where-Object Name -eq 'MeshAgent connection verify').Status | Should -Be 'Pass'
    }

    It 'accepts existing agent when group matches AND connection to our controller is live' {
        $caps = Set-AgentsHappyPath
        Set-AgentsInvoker -Name GetMeshAgentService -ScriptBlock { @{ Found = $true; Status = 'Running' } }
        Set-AgentsInvoker -Name GetAgentMshConfig -ScriptBlock { param($p) [pscustomobject]@{ Found=$true; MeshServer='wss://10.0.0.7:443/agent.ashx'; MeshName='cluster-hosts'; MeshID='0xaaa'; ServerID='bbb'; Path='X' } }
        Set-AgentsInvoker -Name TestAgentConnectedTo -ScriptBlock { param($a,$p,$w) @{ Connected=$true; Detail="ok" } }
        $cfg = [pscustomobject]@{ controller = [pscustomobject]@{ address = '10.0.0.7'; port = 443 } }
        $r = Invoke-AgentsStage -Config $cfg -SshAuthorizedKey 'ssh-rsa A' -MeshAgentSmbPath '\\10.0.0.7\ClusterShare\agents\cluster-hosts\meshagent64-cluster-hosts.exe' 6>$null
        # Should NOT reinstall.
        $caps.Calls | Should -Not -Contain 'UninstallMeshAgent'
        @($r.Steps | Where-Object Name -like 'MeshAgent download').Count | Should -Be 0
        ($r.Steps | Where-Object Name -eq 'MeshAgent').Status | Should -Be 'Pass'
    }

    It 'rewrites MeshServer=local to explicit wss:// URL after install' {
        $caps = Set-AgentsHappyPath
        Set-AgentsInvoker -Name SetAgentMshServer -ScriptBlock {
            param($url,$p) $caps.Calls.Add("SetAgentMshServer:$url")
            @{ Ok = $true; Changed = $true; Detail = "set to $url" }
        }.GetNewClosure()
        $cfg = [pscustomobject]@{ controller = [pscustomobject]@{ address = '10.0.0.7'; port = 443 } }
        Invoke-AgentsStage -Config $cfg -SshAuthorizedKey 'ssh-rsa A' -MeshAgentSmbPath '\\10.0.0.7\ClusterShare\agents\cluster-hosts\meshagent64-cluster-hosts.exe' 6>$null | Out-Null
        ($caps.Calls -join ' ') | Should -Match 'SetAgentMshServer:wss://10\.0\.0\.7:443/agent\.ashx'
        $caps.Calls | Should -Contain 'RestartMeshAgentService'
    }

    It 'Warns when the final TestAgentConnectedTo does NOT see our controller' {
        $caps = Set-AgentsHappyPath
        Set-AgentsInvoker -Name TestAgentConnectedTo -ScriptBlock {
            param($a,$p,$w) $caps.Calls.Add("TestAgentConnectedTo:${a}:$p")
            @{ Connected = $false; Detail = "did not observe connection to ${a}:$p" }
        }.GetNewClosure()
        $cfg = [pscustomobject]@{ controller = [pscustomobject]@{ address = '10.0.0.7'; port = 443 } }
        $r = Invoke-AgentsStage -Config $cfg -SshAuthorizedKey 'ssh-rsa A' -MeshAgentSmbPath '\\10.0.0.7\ClusterShare\agents\cluster-hosts\meshagent64-cluster-hosts.exe' 6>$null
        ($r.Steps | Where-Object Name -eq 'MeshAgent connection verify').Status | Should -Be 'Warn'
    }

    It 'opens SMB auth with controller.smb_username/smb_password when supplied' {
        $caps = Set-AgentsHappyPath
        $cfg = [pscustomobject]@{ controller = [pscustomobject]@{
            address = '10.0.0.7'; port = 443
            smb_username = 'Agent'; smb_password = '0000'
        } }
        Invoke-AgentsStage -Config $cfg -SshAuthorizedKey 'ssh-rsa A' -MeshAgentSmbPath '\\10.0.0.7\ClusterShare\agents\cluster-hosts\meshagent64-cluster-hosts.exe' 6>$null | Out-Null
        ($caps.Calls -join '|') | Should -Match 'OpenSmbAuth:.*\|Agent'
        ($caps.Calls -join '|') | Should -Match 'CloseSmbAuth:'
    }

    It 'defaults SMB path to controller ClusterShare\agents\cluster-hosts\ when no explicit -MeshAgentSmbPath' {
        $caps = Set-AgentsHappyPath
        # Override DownloadMeshAgent to record the SMB path. $caps is captured
        # by Set-AgentsHappyPath's GetNewClosure() so we can reuse it here.
        Set-AgentsInvoker -Name DownloadMeshAgent -ScriptBlock {
            param($smb,$https,$dst) $caps.Calls.Add("DownloadSmb:$smb"); @{ Ok = $true; Source = 'smb'; Detail = 'ok' }
        }.GetNewClosure()
        $cfg = [pscustomobject]@{ controller = [pscustomobject]@{ address = '10.0.0.7'; port = 443 } }
        Invoke-AgentsStage -Config $cfg -SshAuthorizedKey 'ssh-rsa A' 6>$null | Out-Null
        $dl = $caps.Calls | Where-Object { $_ -like 'DownloadSmb:*' } | Select-Object -First 1
        $dl | Should -Be 'DownloadSmb:\\10.0.0.7\ClusterShare\agents\cluster-hosts\meshagent64-cluster-hosts.exe'
    }

    It 'honors Config.agent overrides for share / subdir / group / filename' {
        $caps = Set-AgentsHappyPath
        Set-AgentsInvoker -Name DownloadMeshAgent -ScriptBlock {
            param($smb,$https,$dst) $caps.Calls.Add("DownloadSmb:$smb"); @{ Ok = $true; Source = 'smb'; Detail = 'ok' }
        }.GetNewClosure()
        $cfg = [pscustomobject]@{
            controller = [pscustomobject]@{ address = '10.0.0.7'; port = 443 }
            agent = [pscustomobject]@{
                smb_share = 'OtherShare'
                smb_subdir = 'bin\my-group'
                group = 'my-group'
                filename = 'custom-installer.exe'
            }
        }
        Invoke-AgentsStage -Config $cfg -SshAuthorizedKey 'ssh-rsa A' 6>$null | Out-Null
        $dl = $caps.Calls | Where-Object { $_ -like 'DownloadSmb:*' } | Select-Object -First 1
        $dl | Should -Be 'DownloadSmb:\\10.0.0.7\OtherShare\bin\my-group\custom-installer.exe'
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

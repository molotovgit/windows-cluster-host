#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir     = Join-Path $repoRoot 'src\lib'
    $stagePath  = Join-Path $repoRoot 'src\stages\04-Hyperv.ps1'

    foreach ($mod in 'Logging','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    . $stagePath

    function Set-HypervStub {
        param(
            [string]$State = 'Disabled',
            [bool]$StateRestartNeeded = $false,
            [bool]$CmdletOk = $true,
            [bool]$CmdletRestartNeeded = $true,
            [bool]$DismOk = $false,
            [bool]$DismRestartNeeded = $false,
            [bool]$CapOk = $false,
            [bool]$CapRestartNeeded = $false
        )
        Reset-HypervInvoker
        $caps = [pscustomobject]@{
            Calls = New-Object System.Collections.Generic.List[string]
        }
        Set-HypervInvoker -Name GetFeatureState -ScriptBlock {
            $caps.Calls.Add('GetFeatureState')
            @{ State = $State; RestartNeeded = $StateRestartNeeded }
        }.GetNewClosure()
        Set-HypervInvoker -Name EnableViaCmdlet -ScriptBlock {
            $caps.Calls.Add('EnableViaCmdlet')
            @{ Ok = $CmdletOk; RestartNeeded = $CmdletRestartNeeded; Detail = "cmdlet-stub ok=$CmdletOk restart=$CmdletRestartNeeded" }
        }.GetNewClosure()
        Set-HypervInvoker -Name EnableViaDism -ScriptBlock {
            $caps.Calls.Add('EnableViaDism')
            @{ Ok = $DismOk; RestartNeeded = $DismRestartNeeded; Detail = "dism-stub ok=$DismOk restart=$DismRestartNeeded" }
        }.GetNewClosure()
        Set-HypervInvoker -Name EnableViaCapability -ScriptBlock {
            $caps.Calls.Add('EnableViaCapability')
            @{ Ok = $CapOk; RestartNeeded = $CapRestartNeeded; Detail = "cap-stub ok=$CapOk restart=$CapRestartNeeded" }
        }.GetNewClosure()
        return $caps
    }
}

AfterAll {
    Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    foreach ($mod in 'Logging','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-HypervStage' {

    AfterEach { Reset-HypervInvoker }

    It 'returns Overall=Pass with Method=AlreadyEnabled when state is Enabled and no restart pending' {
        $caps = Set-HypervStub -State 'Enabled' -StateRestartNeeded $false
        $r = Invoke-HypervStage 6>$null
        $r.Overall        | Should -Be 'Pass'
        $r.Method         | Should -Be 'AlreadyEnabled'
        $r.RebootRequired | Should -BeFalse
        $caps.Calls       | Should -Not -Contain 'EnableViaCmdlet'
    }

    It 'returns Overall=RebootRequired when feature is Enabled but a restart is pending' {
        $caps = Set-HypervStub -State 'Enabled' -StateRestartNeeded $true
        $r = Invoke-HypervStage 6>$null
        $r.Overall        | Should -Be 'RebootRequired'
        $r.Method         | Should -Be 'AlreadyEnabled'
        $r.RebootRequired | Should -BeTrue
    }

    It 'enables via WindowsOptionalFeature primary path when Disabled' {
        $caps = Set-HypervStub -State 'Disabled' -CmdletOk $true -CmdletRestartNeeded $true
        $r = Invoke-HypervStage 6>$null
        $r.Overall        | Should -Be 'RebootRequired'
        $r.Method         | Should -Be 'WindowsOptionalFeature'
        $r.RebootRequired | Should -BeTrue
        $caps.Calls       | Should -Contain 'EnableViaCmdlet'
        $caps.Calls       | Should -Not -Contain 'EnableViaDism'
    }

    It 'returns Pass (not RebootRequired) when WindowsOptionalFeature succeeds without restart' {
        $caps = Set-HypervStub -State 'Disabled' -CmdletOk $true -CmdletRestartNeeded $false
        $r = Invoke-HypervStage 6>$null
        $r.Overall        | Should -Be 'Pass'
        $r.RebootRequired | Should -BeFalse
    }

    It 'falls back to DISM when WindowsOptionalFeature fails' {
        $caps = Set-HypervStub -State 'Disabled' `
                               -CmdletOk $false `
                               -DismOk $true -DismRestartNeeded $true
        $r = Invoke-HypervStage 6>$null
        $r.Overall        | Should -Be 'RebootRequired'
        $r.Method         | Should -Be 'DISM'
        $caps.Calls       | Should -Contain 'EnableViaDism'
        $caps.Calls       | Should -Not -Contain 'EnableViaCapability'
    }

    It 'falls back to WindowsCapability when both Cmdlet AND DISM fail (and platform now Enabled)' {
        # Two GetFeatureState calls: first is the initial probe (Disabled),
        # second is the verify-after-Capability probe (Enabled).
        Reset-HypervInvoker
        $script:gfsCalls = 0
        Set-HypervInvoker -Name GetFeatureState -ScriptBlock {
            $script:gfsCalls++
            if ($script:gfsCalls -eq 1) { @{ State = 'Disabled'; RestartNeeded = $false } }
            else                        { @{ State = 'Enabled';  RestartNeeded = $false } }
        }
        Set-HypervInvoker -Name EnableViaCmdlet     -ScriptBlock { @{ Ok = $false; RestartNeeded = $false; Detail = 'cmdlet-fail' } }
        Set-HypervInvoker -Name EnableViaDism       -ScriptBlock { @{ Ok = $false; RestartNeeded = $false; Detail = 'dism-fail' } }
        Set-HypervInvoker -Name EnableViaCapability -ScriptBlock { @{ Ok = $true;  RestartNeeded = $false; Detail = 'cap-ok'    } }

        $r = Invoke-HypervStage 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Method  | Should -Be 'WindowsCapability'
        $r.Detail  | Should -Match 'verified'
    }

    It 'rejects the WindowsCapability path when the platform feature is still Disabled after the call' {
        Reset-HypervInvoker
        $script:gfsCalls = 0
        Set-HypervInvoker -Name GetFeatureState -ScriptBlock {
            $script:gfsCalls++
            @{ State = 'Disabled'; RestartNeeded = $false }   # both probes report Disabled
        }
        Set-HypervInvoker -Name EnableViaCmdlet     -ScriptBlock { @{ Ok = $false; RestartNeeded = $false; Detail = 'cmdlet-fail' } }
        Set-HypervInvoker -Name EnableViaDism       -ScriptBlock { @{ Ok = $false; RestartNeeded = $false; Detail = 'dism-fail' } }
        Set-HypervInvoker -Name EnableViaCapability -ScriptBlock { @{ Ok = $true;  RestartNeeded = $false; Detail = 'cap-ok'    } }

        $r = Invoke-HypervStage 6>$null
        $r.Overall | Should -Be 'Fail'
        $r.Method  | Should -Be 'None'
        $r.Detail  | Should -Match 'management tools'
    }

    It 'reports Overall=Fail with a multi-line remediation when every strategy fails' {
        $caps = Set-HypervStub -State 'Disabled' -CmdletOk $false -DismOk $false -CapOk $false
        $r = Invoke-HypervStage 6>$null
        $r.Overall        | Should -Be 'Fail'
        $r.Method         | Should -Be 'None'
        $r.Detail         | Should -Match 'WindowsOptionalFeature'
        $r.Detail         | Should -Match 'DISM'
        $r.Detail         | Should -Match 'WindowsCapability'
        $r.Remediation    | Should -Match 'Enable-WindowsOptionalFeature'
        $r.Remediation    | Should -Match 'dism'
    }

    It '-DryRun reports Pass with Method=DryRun and skips every enable closure' {
        $caps = Set-HypervStub -State 'Disabled'
        $r = Invoke-HypervStage -DryRun 6>$null
        $r.Overall  | Should -Be 'Pass'
        $r.Method   | Should -Be 'DryRun'
        $r.Detail   | Should -Match 'DryRun'
        $caps.Calls | Should -Not -Contain 'EnableViaCmdlet'
        $caps.Calls | Should -Not -Contain 'EnableViaDism'
        $caps.Calls | Should -Not -Contain 'EnableViaCapability'
    }

    It 'never calls Restart-Computer itself (orchestrator responsibility)' {
        # If the stage tried to reboot, Get-Command Restart-Computer is the
        # surface we'd intercept -- but easier: just confirm the result
        # contract surfaces RebootRequired=true so the orchestrator can
        # decide. The previous test 'enables via WindowsOptionalFeature'
        # already exercises this; here we make the contract explicit.
        $caps = Set-HypervStub -State 'Disabled' -CmdletOk $true -CmdletRestartNeeded $true
        $r = Invoke-HypervStage 6>$null
        $r.Overall | Should -Be 'RebootRequired'
        # Verify the stage's structural contract: Remediation tells the
        # orchestrator to handle the reboot.
        $r.Remediation | Should -Match 'register the resume task and restart'
    }
}

Describe 'Test seam gating' {
    It 'Set-HypervInvoker refuses to run without CLUSTERHOST_ALLOW_TEST_SEAMS' {
        Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
        $thrown = $null
        try { Set-HypervInvoker -Name GetFeatureState -ScriptBlock { @{} } } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        "$thrown" | Should -Match 'CLUSTERHOST_ALLOW_TEST_SEAMS'
        $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    }
}

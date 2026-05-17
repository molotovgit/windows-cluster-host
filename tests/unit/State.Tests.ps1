#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\State.psm1'

    Get-Module State | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    # Tests redirect the registry root to HKCU (no admin needed). Each run gets
    # its own subkey so parallel test runs don't collide.
    $script:testRegBase = "HKCU:\Software\ClusterHost-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $env:CLUSTERHOST_REG_BASE       = $script:testRegBase
    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'

    # Test seams are not exported. Call them via the module scope.
    $script:State = Get-Module State
}

AfterAll {
    if (Test-Path -LiteralPath $script:testRegBase) {
        Remove-Item -LiteralPath $script:testRegBase -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:CLUSTERHOST_REG_BASE         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Get-Module State | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Stage marker' {

    BeforeEach { Reset-ClusterRunState }

    It 'returns $null when no marker has been written' {
        Get-StageMarker | Should -BeNullOrEmpty
    }

    It 'Save-StageMarker writes the stage number and starts a run' {
        Save-StageMarker -StageNumber 3
        Get-StageMarker | Should -Be 3
        $rec = Get-ClusterRunStatus
        $rec.Status   | Should -Be 'InProgress'
        $rec.StartedAt | Should -Not -BeNullOrEmpty
        $rec.RunId     | Should -Match '^[0-9a-f-]{36}$'
    }

    It 'second Save-StageMarker preserves StartedAt and RunId but updates Stage + UpdatedAt' {
        Save-StageMarker -StageNumber 1
        $first = Get-ClusterRunStatus
        Start-Sleep -Milliseconds 30
        Save-StageMarker -StageNumber 4
        $second = Get-ClusterRunStatus
        $second.Stage     | Should -Be 4
        $second.RunId     | Should -Be $first.RunId
        $second.StartedAt | Should -Be $first.StartedAt
        $second.UpdatedAt | Should -Not -Be $first.UpdatedAt
    }

    It 'Clear-StageMarker removes the Stage value but keeps the rest of the record' {
        Save-StageMarker -StageNumber 5
        Set-ClusterRunStatus -Status Completed
        Clear-StageMarker
        Get-StageMarker | Should -BeNullOrEmpty
        (Get-ClusterRunStatus).Status | Should -Be 'Completed'
    }

    It 'Save-StageMarker rejects out-of-range stage numbers' {
        { Save-StageMarker -StageNumber 0 } | Should -Throw
        { Save-StageMarker -StageNumber 99 } | Should -Throw
    }
}

Describe 'Run status' {

    BeforeEach { Reset-ClusterRunState }

    It 'Set-ClusterRunStatus updates Status and UpdatedAt' {
        Save-StageMarker -StageNumber 1
        Start-Sleep -Milliseconds 20
        Set-ClusterRunStatus -Status Failed -LastError 'NAT switch creation failed: subnet collision'
        $rec = Get-ClusterRunStatus
        $rec.Status    | Should -Be 'Failed'
        $rec.LastError | Should -Match 'NAT switch'
    }

    It 'Set-ClusterRunStatus -Status Completed does NOT auto-clear the stage marker' {
        # Stage marker clearing is the orchestrator's explicit responsibility,
        # so this module must not do it implicitly.
        Save-StageMarker -StageNumber 8
        Set-ClusterRunStatus -Status Completed
        Get-StageMarker | Should -Be 8
    }

    It 'Get-ClusterRunStatus returns $null on an empty registry root' {
        Get-ClusterRunStatus | Should -BeNullOrEmpty
    }

    It 'Set-ClusterRunVersion stamps Version' {
        Set-ClusterRunVersion -Version '0.1.0'
        (Get-ClusterRunStatus).Version | Should -Be '0.1.0'
    }

    It 'Reset-ClusterRunState wipes the entire subtree' {
        Save-StageMarker -StageNumber 2
        Set-ClusterRunVersion -Version '0.1.0'
        Reset-ClusterRunState
        Get-ClusterRunStatus | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:testRegBase | Should -BeFalse
    }

    It 'Save-StageMarker after Reset-ClusterRunState starts a fresh run with a NEW RunId' {
        Save-StageMarker -StageNumber 1
        $firstRunId = (Get-ClusterRunStatus).RunId
        Reset-ClusterRunState
        Save-StageMarker -StageNumber 1
        $secondRunId = (Get-ClusterRunStatus).RunId
        $secondRunId | Should -Not -BeNullOrEmpty
        $secondRunId | Should -Not -Be $firstRunId
    }
}

Describe 'Resume scheduled task' {

    BeforeEach { Reset-ClusterRunState }

    BeforeAll {
        $script:fakeOrch = Join-Path ([System.IO.Path]::GetTempPath()) ("fake-orch-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.ps1')
        Set-Content -LiteralPath $script:fakeOrch -Value '# fake' -Encoding utf8
    }

    AfterAll {
        Remove-Item -LiteralPath $script:fakeOrch -Force -ErrorAction SilentlyContinue
    }

    Context 'New-ResumeTaskSpec (pure)' {

        It 'returns a spec with -Resume in the argument string and Trigger=Both by default' {
            $spec = New-ResumeTaskSpec -OrchestratorPath $script:fakeOrch
            $spec.TaskName | Should -Be 'ClusterHostResume'
            $spec.TaskPath | Should -Be '\ClusterHost\'
            $spec.Trigger  | Should -Be 'Both'
            $spec.Argument | Should -Match ' -Resume(\s|$)'
            $spec.Argument | Should -Match '-NoProfile'
            $spec.Argument | Should -Match '-ExecutionPolicy Bypass'
            $pattern = [regex]::Escape("`"$script:fakeOrch`"")
            $spec.Argument | Should -Match $pattern
        }

        It 'honors -Trigger AtLogOn / AtStartup / Both' {
            (New-ResumeTaskSpec -OrchestratorPath $script:fakeOrch -Trigger AtLogOn  ).Trigger | Should -Be 'AtLogOn'
            (New-ResumeTaskSpec -OrchestratorPath $script:fakeOrch -Trigger AtStartup).Trigger | Should -Be 'AtStartup'
            (New-ResumeTaskSpec -OrchestratorPath $script:fakeOrch -Trigger Both     ).Trigger | Should -Be 'Both'
        }

        It 'throws on missing -OrchestratorPath' {
            { New-ResumeTaskSpec -OrchestratorPath 'C:\does\not\exist.ps1' } | Should -Throw -ExpectedMessage '*not found*'
        }

        It 'appends -ExtraArgs after -Resume' {
            $spec = New-ResumeTaskSpec -OrchestratorPath $script:fakeOrch -ExtraArgs '-Verbose','-StartFromStage','4'
            $spec.Argument | Should -Match '-Resume\s+-Verbose\s+-StartFromStage\s+4'
        }

        It 'defaults PwshPath to pwsh.exe on PS7 and powershell.exe on PS5.1' {
            $spec = New-ResumeTaskSpec -OrchestratorPath $script:fakeOrch
            if ($PSVersionTable.PSVersion.Major -ge 7) {
                $spec.Execute | Should -Be 'pwsh.exe'
            } else {
                $spec.Execute | Should -Be 'powershell.exe'
            }
        }

        It 'honors an explicit -PwshPath' {
            $spec = New-ResumeTaskSpec -OrchestratorPath $script:fakeOrch -PwshPath 'C:\Custom\pwsh.exe'
            $spec.Execute | Should -Be 'C:\Custom\pwsh.exe'
        }

        It 'defaults User to USERDOMAIN\USERNAME and accepts explicit -User' {
            $spec  = New-ResumeTaskSpec -OrchestratorPath $script:fakeOrch
            $spec.User | Should -Be "$env:USERDOMAIN\$env:USERNAME"
            $spec2 = New-ResumeTaskSpec -OrchestratorPath $script:fakeOrch -User 'WORKGROUP\test'
            $spec2.User | Should -Be 'WORKGROUP\test'
        }
    }

    Context 'Register-ResumeTask via the invoker seam' {

        BeforeEach {
            $script:fakeCalls = [pscustomobject]@{ Test = 0; Register = 0; Unregister = 0; LastSpec = $null }
            $caps = $script:fakeCalls
            & $script:State { param($caps)
                Set-ResumeTaskInvoker -Operation Test       -ScriptBlock { $caps.Test++; $null }.GetNewClosure()
                Set-ResumeTaskInvoker -Operation Register   -ScriptBlock { param($s) $caps.Register++; $caps.LastSpec = $s }.GetNewClosure()
                Set-ResumeTaskInvoker -Operation Unregister -ScriptBlock { $caps.Unregister++ }.GetNewClosure()
            } $caps
        }

        AfterEach { & $script:State { Reset-ResumeTaskInvoker } }

        It 'invokes Register once when no task exists' {
            $script:fakeCalls.Test = 0; $script:fakeCalls.Register = 0; $script:fakeCalls.Unregister = 0
            Register-ResumeTask -OrchestratorPath $script:fakeOrch | Out-Null
            $script:fakeCalls.Register | Should -Be 1
            $script:fakeCalls.Unregister | Should -Be 0
            $script:fakeCalls.LastSpec.Argument | Should -Match ' -Resume(\s|$)'
            $script:fakeCalls.LastSpec.Trigger  | Should -Be 'Both'
        }

        It 'unregisters and re-registers when a task already exists (idempotency)' {
            $caps = $script:fakeCalls
            & $script:State { param($caps) Set-ResumeTaskInvoker -Operation Test -ScriptBlock { $caps.Test++; 'pre-existing' }.GetNewClosure() } $caps
            $caps.Test = 0; $caps.Register = 0; $caps.Unregister = 0

            Register-ResumeTask -OrchestratorPath $script:fakeOrch | Out-Null
            $caps.Unregister | Should -Be 1
            $caps.Register   | Should -Be 1
        }

        It 'returns the spec that was passed to Register' {
            $spec = Register-ResumeTask -OrchestratorPath $script:fakeOrch -ExtraArgs '-Verbose'
            $spec.Argument | Should -Match '-Resume\s+-Verbose'
        }

        It '-Trigger AtStartup propagates to the spec passed to Register' {
            Register-ResumeTask -OrchestratorPath $script:fakeOrch -Trigger AtStartup | Out-Null
            $script:fakeCalls.LastSpec.Trigger | Should -Be 'AtStartup'
        }
    }

    Context 'Unregister-ResumeTask via the invoker seam' {

        BeforeEach {
            $script:fakeCalls = [pscustomobject]@{ Test = 0; Unregister = 0 }
            $caps = $script:fakeCalls
            & $script:State { param($caps) Set-ResumeTaskInvoker -Operation Unregister -ScriptBlock { $caps.Unregister++ }.GetNewClosure() } $caps
        }

        AfterEach { & $script:State { Reset-ResumeTaskInvoker } }

        It 'is a no-op when no task is present' {
            $caps = $script:fakeCalls
            & $script:State { param($caps) Set-ResumeTaskInvoker -Operation Test -ScriptBlock { $caps.Test++; $null }.GetNewClosure() } $caps
            $caps.Test = 0; $caps.Unregister = 0
            Unregister-ResumeTask
            $script:fakeCalls.Unregister | Should -Be 0
        }

        It 'removes the task when present' {
            $caps = $script:fakeCalls
            & $script:State { param($caps) Set-ResumeTaskInvoker -Operation Test -ScriptBlock { $caps.Test++; 'exists' }.GetNewClosure() } $caps
            $caps.Test = 0; $caps.Unregister = 0
            Unregister-ResumeTask
            $script:fakeCalls.Unregister | Should -Be 1
        }
    }

    Context 'Test-ResumeTask via the invoker seam' {

        AfterEach { & $script:State { Reset-ResumeTaskInvoker } }

        It 'returns $false when invoker returns $null' {
            & $script:State { Set-ResumeTaskInvoker -Operation Test -ScriptBlock { $null } }
            Test-ResumeTask | Should -BeFalse
        }

        It 'returns $true when invoker returns any non-null value' {
            & $script:State { Set-ResumeTaskInvoker -Operation Test -ScriptBlock { [pscustomobject]@{ TaskName = 'ClusterHostResume' } } }
            Test-ResumeTask | Should -BeTrue
        }
    }

    Context 'Test seam gating' {

        AfterEach {
            $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
            & $script:State { Reset-ResumeTaskInvoker }
        }

        It 'Set-ResumeTaskInvoker throws when CLUSTERHOST_ALLOW_TEST_SEAMS is not set' {
            Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
            $thrown = $null
            try {
                & $script:State { Set-ResumeTaskInvoker -Operation Test -ScriptBlock { $null } }
            } catch { $thrown = $_ }
            $thrown | Should -Not -BeNullOrEmpty
            "$thrown" | Should -Match 'CLUSTERHOST_ALLOW_TEST_SEAMS'
        }
    }

    Context 'Complete-ClusterRun' {

        BeforeEach {
            $script:fakeCalls = [pscustomobject]@{ Test = 0; Unregister = 0 }
            $caps = $script:fakeCalls
            & $script:State { param($caps)
                Set-ResumeTaskInvoker -Operation Test       -ScriptBlock { $caps.Test++; 'exists' }.GetNewClosure()
                Set-ResumeTaskInvoker -Operation Unregister -ScriptBlock { $caps.Unregister++ }.GetNewClosure()
            } $caps
            Reset-ClusterRunState
            Save-StageMarker -StageNumber 8
        }

        AfterEach { & $script:State { Reset-ResumeTaskInvoker } }

        It 'sets Status=Completed, clears the stage marker, and unregisters the resume task' {
            Complete-ClusterRun
            $rec = Get-ClusterRunStatus
            $rec.Status | Should -Be 'Completed'
            Get-StageMarker | Should -BeNullOrEmpty
            $script:fakeCalls.Unregister | Should -Be 1
        }
    }

    Context 'Get-ResumeTaskInfo' {
        It 'reports the canonical task name and dedicated folder' {
            $info = Get-ResumeTaskInfo
            $info.TaskName | Should -Be 'ClusterHostResume'
            $info.TaskPath | Should -Be '\ClusterHost\'
        }
    }
}

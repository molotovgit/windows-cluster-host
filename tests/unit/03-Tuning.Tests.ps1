#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir     = Join-Path $repoRoot 'src\lib'
    $stagePath  = Join-Path $repoRoot 'src\stages\03-Tuning.ps1'

    foreach ($mod in 'Logging','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    . $stagePath

    function Reset-Stub {
        Reset-TuningInvoker
        $script:RegStore     = @{}
        $script:RegSetCalls  = New-Object System.Collections.Generic.List[hashtable]
        $script:Powercfg     = New-Object System.Collections.Generic.List[hashtable]
        $script:ActivePlan   = $null
    }
    function Stub-AllOk {
        param([string]$ActiveGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
        Reset-Stub
        $script:ActivePlan = $ActiveGuid
        $caps = [pscustomobject]@{
            RegStore    = $script:RegStore
            RegSetCalls = $script:RegSetCalls
            Powercfg    = $script:Powercfg
            ActiveGuid  = $script:ActivePlan
        }
        Set-TuningInvoker -Name GetReg -ScriptBlock {
            param([string]$Path,[string]$Name)
            $caps.RegStore["$Path\$Name"]
        }.GetNewClosure()
        Set-TuningInvoker -Name SetReg -ScriptBlock {
            param([string]$Path,[string]$Name,$Value,[string]$Type)
            $caps.RegStore["$Path\$Name"] = $Value
            $caps.RegSetCalls.Add(@{ Path = $Path; Name = $Name; Value = $Value; Type = $Type })
        }.GetNewClosure()
        Set-TuningInvoker -Name RunPowercfg -ScriptBlock {
            param([string[]]$Argv)
            $caps.Powercfg.Add(@{ Args = $Argv })
            [pscustomobject]@{ ExitCode = 0; Output = '' }
        }.GetNewClosure()
        Set-TuningInvoker -Name GetActivePowerPlanGuid -ScriptBlock {
            $caps.ActiveGuid
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

Describe 'Invoke-TuningStage' {

    AfterEach { Reset-TuningInvoker }

    It 'returns Overall=Pass and runs every tweak when state matches happy path (already-active High Performance)' {
        $caps = Stub-AllOk

        $r = Invoke-TuningStage 6>$null
        $r.Overall | Should -Be 'Pass'
        $names = @($r.Tweaks | ForEach-Object Name)
        $names | Should -Contain 'Fast Startup disabled'
        $names | Should -Contain 'Power plan: High Performance'
        $names | Should -Contain 'USB selective suspend disabled'
        $names | Should -Contain 'Never sleep on AC'
    }

    It 'reports Pass without setting when HiberbootEnabled is already 0' {
        $caps = Stub-AllOk
        $caps.RegStore['HKLM:\SYSTEM\CurrentControlSet\Control\Power\HiberbootEnabled'] = 0
        $r = Invoke-TuningStage 6>$null
        ($r.Tweaks | Where-Object Name -eq 'Fast Startup disabled').Status | Should -Be 'Pass'
        $caps.RegSetCalls.Count | Should -Be 0
    }

    It 'writes HiberbootEnabled=0 when not yet set' {
        $caps = Stub-AllOk
        # HiberbootEnabled = 1 (default Windows 11)
        $caps.RegStore['HKLM:\SYSTEM\CurrentControlSet\Control\Power\HiberbootEnabled'] = 1
        $r = Invoke-TuningStage 6>$null
        $fast = $r.Tweaks | Where-Object Name -eq 'Fast Startup disabled'
        $fast.Status  | Should -Be 'Pass'
        $fast.Changed | Should -BeTrue
        $caps.RegStore['HKLM:\SYSTEM\CurrentControlSet\Control\Power\HiberbootEnabled'] | Should -Be 0
    }

    It '-DryRun reports Skipped and does not mutate' {
        $caps = Stub-AllOk
        $caps.RegStore['HKLM:\SYSTEM\CurrentControlSet\Control\Power\HiberbootEnabled'] = 1
        $r = Invoke-TuningStage -DryRun 6>$null
        $skipped = @($r.Tweaks | Where-Object Status -eq 'Skipped')
        $skipped.Count | Should -BeGreaterThan 0
        $caps.RegSetCalls.Count | Should -Be 0
    }

    It 'activates High Performance via /SETACTIVE when not currently active' {
        $caps = Stub-AllOk -ActiveGuid '381b4222-f694-41f0-9685-ff5bb260df2e'   # Balanced
        $r = Invoke-TuningStage 6>$null
        $plan = $r.Tweaks | Where-Object Name -eq 'Power plan: High Performance'
        $plan.Status  | Should -Be 'Pass'
        $plan.Changed | Should -BeTrue
        @($caps.Powercfg | Where-Object { $_.Args -contains '/SETACTIVE' -and $_.Args -contains '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }).Count | Should -Be 1
    }

    It 'falls back to /DUPLICATESCHEME when /SETACTIVE fails (hidden plan)' {
        $caps = Stub-AllOk -ActiveGuid '381b4222-f694-41f0-9685-ff5bb260df2e'
        Set-TuningInvoker -Name RunPowercfg -ScriptBlock {
            param([string[]]$Argv)
            $caps.Powercfg.Add(@{ Args = $Argv })
            if ($Argv[0] -eq '/SETACTIVE' -and $Argv[1] -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') {
                return [pscustomobject]@{ ExitCode = 1; Output = 'scheme not found' }
            }
            if ($Argv[0] -eq '/DUPLICATESCHEME') {
                return [pscustomobject]@{ ExitCode = 0; Output = 'Power Scheme GUID: abcdef00-0000-0000-0000-000000000001  (High performance copy)' }
            }
            return [pscustomobject]@{ ExitCode = 0; Output = '' }
        }.GetNewClosure()

        $r = Invoke-TuningStage 6>$null
        $plan = $r.Tweaks | Where-Object Name -eq 'Power plan: High Performance'
        $plan.Status  | Should -Be 'Pass'
        $plan.Detail  | Should -Match 'DUPLICATESCHEME'
    }

    It 'reports Warn when USB powercfg fails on a host without an active power plan' {
        $caps = Stub-AllOk
        Set-TuningInvoker -Name GetActivePowerPlanGuid -ScriptBlock { $null }
        $r = Invoke-TuningStage 6>$null
        ($r.Tweaks | Where-Object Name -eq 'USB selective suspend disabled').Status | Should -Be 'Warn'
    }

    It 'sets AC sleep timeout to 0 via powercfg /CHANGE' {
        $caps = Stub-AllOk
        Invoke-TuningStage 6>$null | Out-Null
        @($caps.Powercfg | Where-Object { $_.Args -contains '/CHANGE' -and $_.Args -contains 'standby-timeout-ac' -and $_.Args -contains '0' }).Count | Should -Be 1
    }

    It 'falls back to powercfg /H off when registry write fails' {
        $caps = Stub-AllOk
        $caps.RegStore['HKLM:\SYSTEM\CurrentControlSet\Control\Power\HiberbootEnabled'] = 1
        # Force SetReg to throw.
        Set-TuningInvoker -Name SetReg -ScriptBlock {
            param($Path,$Name,$Value,$Type)
            throw [System.UnauthorizedAccessException]::new('registry locked')
        }
        # RunPowercfg succeeds for /H off (default closure already returns ExitCode=0).
        $r = Invoke-TuningStage 6>$null
        $fast = $r.Tweaks | Where-Object Name -eq 'Fast Startup disabled'
        $fast.Status  | Should -Be 'Pass'
        $fast.Detail  | Should -Match 'powercfg /H off'
    }

    It 'reports Fail when both registry write AND powercfg /H off fail' {
        $caps = Stub-AllOk
        $caps.RegStore['HKLM:\SYSTEM\CurrentControlSet\Control\Power\HiberbootEnabled'] = 1
        Set-TuningInvoker -Name SetReg -ScriptBlock {
            param($Path,$Name,$Value,$Type) throw 'registry locked'
        }
        Set-TuningInvoker -Name RunPowercfg -ScriptBlock {
            param([string[]]$Argv)
            return [pscustomobject]@{ ExitCode = 1; Output = 'access denied' }
        }
        # GetActivePowerPlanGuid is also stubbed (returns nothing) -- not used by Fast Startup
        Set-TuningInvoker -Name GetActivePowerPlanGuid -ScriptBlock { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
        $r = Invoke-TuningStage 6>$null
        ($r.Tweaks | Where-Object Name -eq 'Fast Startup disabled').Status | Should -Be 'Fail'
        $r.Overall | Should -Be 'Fail'
    }
}

Describe 'Test seam gating' {
    It 'Set-TuningInvoker refuses to run without CLUSTERHOST_ALLOW_TEST_SEAMS' {
        Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
        $thrown = $null
        try { Set-TuningInvoker -Name GetReg -ScriptBlock { $null } } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        "$thrown" | Should -Match 'CLUSTERHOST_ALLOW_TEST_SEAMS'
        $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    }
}

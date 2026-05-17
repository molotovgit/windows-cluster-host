#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Integration test: dot-source the orchestrator and exercise the full
# stage pipeline through every stage's invoker seam. All real Windows
# cmdlets are replaced with deterministic stubs.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    $orchPath = Join-Path $repoRoot 'src\Invoke-ClusterHostSetup.ps1'

    # Pre-import lib modules so the orchestrator's foreach-Import-Module is a no-op
    # (some are already loaded by stage tests; refresh).
    foreach ($mod in 'Logging','State','Retry','HardwareDetect','Discovery') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }

    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    $env:CLUSTERHOST_NOAUTORUN        = '1'   # tests dot-source the script; skip auto-run
    $script:testRegBase = "HKCU:\Software\ClusterHost-orch-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $env:CLUSTERHOST_REG_BASE         = $script:testRegBase
    $env:CLUSTERHOST_STATE_DIR        = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-state-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $env:CLUSTERHOST_LOG_DIR          = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-log-"   + [guid]::NewGuid().ToString('N').Substring(0,8))

    # Dot-source the orchestrator (this also dot-sources every stage script,
    # so each Invoke-*Stage and Set-*Invoker becomes available).
    . $orchPath

    function Stub-AllStage {
        param([string]$HypervOverall = 'Pass')
        # Each stage exposes a Set-*Invoker / Reset-*Invoker pair.
        # We override the most-impactful invokers so each stage returns Pass
        # without touching real Windows.
        & (Get-Module HardwareDetect) {
            Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { 'Professional' }
            Set-HardwareDetector -Name RegistryEditionID    -ScriptBlock { 'Professional' }
            Set-HardwareDetector -Name WmiOsCaption         -ScriptBlock { 'Microsoft Windows 11 Pro' }
            Set-HardwareDetector -Name ComputerInfoOsName   -ScriptBlock { 'Microsoft Windows 11 Pro' }
            Set-HardwareDetector -Name VolumeList -ScriptBlock {
                @([pscustomobject]@{ DriveLetter = 'D'; Size = 1TB; SizeRemaining = 800GB })
            }
            Set-HardwareDetector -Name SystemDriveLetter -ScriptBlock { 'C' }
            Set-HardwareDetector -Name ComputerInfoVirt -ScriptBlock {
                [pscustomobject]@{
                    HyperVisorPresent                                = $true
                    HyperVRequirementVirtualizationFirmwareEnabled   = $true
                    HyperVRequirementSecondLevelAddressTranslation   = $true
                }
            }
            Set-HardwareDetector -Name WmiProcessorVirtFlag -ScriptBlock { $true }
            Set-HardwareDetector -Name NetAdapterList -ScriptBlock {
                @([pscustomobject]@{ Name = 'Wi-Fi'; InterfaceIndex = 7; MediaType = 'Native 802.11'; Status = 'Up'; Virtual = $false })
            }
        }
        & (Get-Module Discovery) {
            Set-DiscoveryInvoker -Name Resolve -ScriptBlock { param($n) if ($n -eq 'controller.local') { '10.0.0.7' } else { $null } }
            Set-DiscoveryInvoker -Name TestTcp -ScriptBlock { param($a,$p,$t) ($a -eq '10.0.0.7' -and $p -eq 443) }
            Set-DiscoveryInvoker -Name HttpProbe -ScriptBlock {
                param($url,$timeout)
                if ($url -match '10\.0\.0\.7') { [pscustomobject]@{ Status = 200; Body = 'MeshCentral' } } else { $null }
            }
            Set-DiscoveryInvoker -Name LocalIPv4 -ScriptBlock {
                @([pscustomobject]@{ IPAddress = '192.168.1.55'; PrefixLength = 24 })
            }
            Set-DiscoveryInvoker -Name ReadConfig -ScriptBlock { param($p) $null }
            Set-DiscoveryInvoker -Name WriteDiscovered -ScriptBlock { param($p,$r) }
        }
        Set-TuningInvoker -Name GetReg          -ScriptBlock { 0 }   # HiberbootEnabled=0 already
        Set-TuningInvoker -Name SetReg          -ScriptBlock { }
        Set-TuningInvoker -Name RunPowercfg     -ScriptBlock { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Set-TuningInvoker -Name GetActivePowerPlanGuid -ScriptBlock { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }

        Set-HypervInvoker -Name GetFeatureState -ScriptBlock {
            param() if ($HypervOverall -eq 'RebootRequired') { @{ State = 'Enabled'; RestartNeeded = $true } } else { @{ State = 'Enabled'; RestartNeeded = $false } }
        }.GetNewClosure()
        Set-HypervInvoker -Name EnableViaCmdlet     -ScriptBlock { @{ Ok = $true; RestartNeeded = $false; Detail = 'cmdlet-ok' } }
        Set-HypervInvoker -Name EnableViaDism       -ScriptBlock { @{ Ok = $true; RestartNeeded = $false; Detail = 'dism-ok' } }
        Set-HypervInvoker -Name EnableViaCapability -ScriptBlock { @{ Ok = $true; RestartNeeded = $false; Detail = 'cap-ok' } }

        Set-NetworkInvoker -Name GetVMSwitch     -ScriptBlock { @() }
        Set-NetworkInvoker -Name NewVMSwitch     -ScriptBlock { param($n) }
        Set-NetworkInvoker -Name GetNetIPv4      -ScriptBlock { @() }
        Set-NetworkInvoker -Name NewNetIPAddr    -ScriptBlock { param($a,$ip,$pfx) }
        Set-NetworkInvoker -Name GetNetRoute     -ScriptBlock { @() }
        Set-NetworkInvoker -Name GetNetNat       -ScriptBlock { @() }
        Set-NetworkInvoker -Name NewNetNat       -ScriptBlock { param($n,$p) }
        Set-NetworkInvoker -Name HasNetNatCmdlet -ScriptBlock { $true }

        Set-AgentsInvoker -Name GetOpenSshState        -ScriptBlock { @{ State = 'Installed'; Source = 'WindowsCapability' } }
        Set-AgentsInvoker -Name InstallOpenSshCapability -ScriptBlock { @{ Ok = $true; Detail = '' } }
        Set-AgentsInvoker -Name InstallOpenSshDism     -ScriptBlock { @{ Ok = $true; Detail = '' } }
        Set-AgentsInvoker -Name SetSshdService         -ScriptBlock { @{ Ok = $true; Status = 'Running'; StartType = 'Automatic'; Detail = '' } }
        Set-AgentsInvoker -Name WriteSshAuthorizedKey  -ScriptBlock { param($p,$k) @{ Ok = $true; AlreadyPresent = $true; Path = $p } }
        Set-AgentsInvoker -Name HardenAuthorizedKeyAcl -ScriptBlock { param($p) @{ Ok = $true; Detail = '' } }
        Set-AgentsInvoker -Name DownloadMeshAgent      -ScriptBlock { param($s,$h,$d) @{ Ok = $true; Source = 'smb'; Detail = '' } }
        Set-AgentsInvoker -Name VerifyMeshAgentHash    -ScriptBlock { param($p,$h) @{ Ok = $true; Skipped = $true; Detail = '' } }
        Set-AgentsInvoker -Name InstallMeshAgent       -ScriptBlock { param($p) @{ Ok = $true; ExitCode = 0; Detail = '' } }
        Set-AgentsInvoker -Name GetMeshAgentService    -ScriptBlock { @{ Found = $true; Status = 'Running' } }

        Set-VmInvoker -Name SourceGoldenVhdx -ScriptBlock { param($s,$h,$l,$d) @{ Ok = $true; Source = 'smb'; Detail = '' } }
        Set-VmInvoker -Name VerifyVhdxHash   -ScriptBlock { param($p,$h) @{ Ok = $true; Skipped = $true; Detail = '' } }
        Set-VmInvoker -Name CloneVhdx        -ScriptBlock { param($s,$d) @{ Ok = $true; AlreadyPresent = $false; Detail = '' } }
        Set-VmInvoker -Name GetVm            -ScriptBlock { param($n) [pscustomobject]@{ Found = $false; State = 'NotPresent'; AutomaticStartAction = $null; SwitchName = $null; HardDrivePath = $null; MemoryStartupGb = 0; ProcessorCount = 0 } }
        Set-VmInvoker -Name CreateVm         -ScriptBlock { param($n,$v,$s,$ms,$mn,$mx,$cpu,$sb) @{ Ok = $true; Detail = '' } }
        Set-VmInvoker -Name ConfigureAutostart -ScriptBlock { param($n,$d) @{ Ok = $true; Detail = '' } }

        Set-VerifyInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found = $true; Status = 'Running'; StartType = 'Automatic' } }
        Set-VerifyInvoker -Name GetVm      -ScriptBlock { param($n) [pscustomobject]@{ Found = $true; State = 'Running'; SwitchName = 'ClusterNATSwitch'; IpAddress = '192.168.100.50' } }
        Set-VerifyInvoker -Name StartVm    -ScriptBlock { param($n) @{ Ok = $true } }
        Set-VerifyInvoker -Name TestTcp    -ScriptBlock { param($a,$p,$t) $true }
        Set-VerifyInvoker -Name WriteSummary -ScriptBlock { param($p,$body) }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:testRegBase) {
        Remove-Item -LiteralPath $script:testRegBase -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_NOAUTORUN         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_REG_BASE          -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_STATE_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_LOG_DIR           -ErrorAction SilentlyContinue
}

Describe 'Invoke-ClusterHostSetup' {

    BeforeEach {
        if (Test-Path -LiteralPath $script:testRegBase) {
            Remove-Item -LiteralPath $script:testRegBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'happy path: every stage Pass -> Overall=Pass, RunId set, stages array length 8' {
        Stub-AllStage
        $r = Invoke-ClusterHostSetup -DryRun -NoRestart 6>$null
        if ($r.Overall -ne 'Pass') {
            Write-Host "DEBUG stages on failure:" -ForegroundColor Yellow
            $r.Stages | ForEach-Object { Write-Host ("  {0} {1} {2}: {3}" -f $_.Number, $_.Name, $_.Overall, $_.Detail) }
        }
        $r.Overall | Should -Be 'Pass'
        $r.Stages.Count | Should -Be 8
        $r.RunId | Should -Match '^[0-9a-f-]{36}$'
        @($r.Stages | Where-Object Overall -eq 'Pass').Count | Should -BeGreaterOrEqual 6
    }

    It 'Hyper-V returning RebootRequired with -NoRestart -> Overall=RebootRequired' {
        Stub-AllStage -HypervOverall 'RebootRequired'
        $r = Invoke-ClusterHostSetup -DryRun -NoRestart 6>$null
        $r.Overall | Should -Be 'RebootRequired'
        # Stages 5-8 should NOT have run.
        @($r.Stages | Where-Object Number -ge 5).Count | Should -Be 0
    }

    It '-Resume picks up after the saved stage marker' {
        Stub-AllStage
        # Pre-seed marker at stage 3 ("stage 3 is what was running last").
        Save-StageMarker -StageNumber 3
        $r = Invoke-ClusterHostSetup -Resume -DryRun -NoRestart 6>$null
        # Stages 1-3 should be Skipped, 4-8 should be Pass.
        @($r.Stages | Where-Object { $_.Number -le 3 -and $_.Overall -eq 'Skipped' }).Count | Should -Be 3
        @($r.Stages | Where-Object { $_.Number -ge 4 }).Count | Should -BeGreaterOrEqual 4
    }

    It '-Resume from stage 4 re-runs stage 4 (post-reboot probe)' {
        Stub-AllStage
        Save-StageMarker -StageNumber 4
        $r = Invoke-ClusterHostSetup -Resume -DryRun -NoRestart 6>$null
        # Stage 4 should NOT be Skipped (it re-runs on resume).
        $stage4 = $r.Stages | Where-Object Number -eq 4 | Select-Object -First 1
        $stage4.Overall | Should -Not -Be 'Skipped'
    }

    It '-StartFromStage 6 skips stages 1-5' {
        Stub-AllStage
        $r = Invoke-ClusterHostSetup -StartFromStage 6 -DryRun -NoRestart 6>$null
        @($r.Stages | Where-Object { $_.Number -le 5 -and $_.Overall -eq 'Skipped' }).Count | Should -Be 5
    }

    It 'catches a stage that THROWS and records Failed status with the exception detail' {
        Stub-AllStage
        # Hijack Stage 5 (Network) to throw mid-execution rather than return Fail.
        Set-NetworkInvoker -Name GetVMSwitch -ScriptBlock { throw 'simulated stage crash' }
        $r = Invoke-ClusterHostSetup -DryRun -NoRestart 6>$null
        $r.Overall | Should -Be 'Fail'
        $stage5 = $r.Stages | Where-Object Number -eq 5 | Select-Object -First 1
        $stage5.Overall | Should -Be 'Fail'
        $stage5.Detail  | Should -Match '^Threw:'
        $stage5.Detail  | Should -Match 'simulated stage crash'
        # Stages 6-8 must NOT have run.
        @($r.Stages | Where-Object Number -ge 6).Count | Should -Be 0
        # Status in registry should be Failed.
        $status = Get-ClusterRunStatus
        $status.Status    | Should -Be 'Failed'
        $status.LastError | Should -Match 'simulated stage crash'
    }

    It 'returns Overall=Fail and stops when Preflight returns Fail' {
        Stub-AllStage
        # Override the SKU detector to return Home -> Preflight Fail.
        & (Get-Module HardwareDetect) {
            Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { 'Home' }
            Set-HardwareDetector -Name RegistryEditionID    -ScriptBlock { 'Core' }
            Set-HardwareDetector -Name WmiOsCaption         -ScriptBlock { 'Microsoft Windows 11 Home' }
            Set-HardwareDetector -Name ComputerInfoOsName   -ScriptBlock { 'Microsoft Windows 11 Home' }
        }
        $r = Invoke-ClusterHostSetup -NoRestart 6>$null
        $r.Overall | Should -Be 'Fail'
        @($r.Stages | Where-Object Number -gt 1).Count | Should -Be 0
        # Status should be recorded as Failed in the registry.
        $status = Get-ClusterRunStatus
        $status.Status | Should -Be 'Failed'
        $status.LastError | Should -Match 'Preflight'
    }
}

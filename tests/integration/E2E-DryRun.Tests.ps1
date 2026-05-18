#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# End-to-end dry-run: exercises the full orchestrator + every stage
# through realistic stubs that simulate a successful cluster install
# without touching any real Windows surfaces. This is the PRIMARY GOAL
# acceptance test: the 8-stage script must run to Overall=Pass on a
# canned-data Windows host with no real Hyper-V / no real network / no
# real registry writes.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir   = Join-Path $repoRoot 'src\lib'
    $orchPath = Join-Path $repoRoot 'src\Invoke-ClusterHostSetup.ps1'

    foreach ($mod in 'Logging','State','Retry','HardwareDetect','Discovery') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    $env:CLUSTERHOST_NOAUTORUN        = '1'
    $script:testRegBase = "HKCU:\Software\ClusterHost-e2e-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $env:CLUSTERHOST_REG_BASE         = $script:testRegBase
    $env:CLUSTERHOST_STATE_DIR        = Join-Path ([System.IO.Path]::GetTempPath()) ("e2e-state-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $env:CLUSTERHOST_LOG_DIR          = Join-Path ([System.IO.Path]::GetTempPath()) ("e2e-log-"   + [guid]::NewGuid().ToString('N').Substring(0,8))

    # Shared mutable record for cross-scope assertions. Hashtables are
    # reference types, so a scriptblock that closes over $script:probe
    # via .GetNewClosure() will mutate the SAME object the It block reads
    # -- no $global: vars (which PSAvoidGlobalVars forbids) needed.
    $script:probe = @{ lastSummary = $null; lastSummaryPath = $null }

    . $orchPath

    function Stub-FleetReadyHost {
        # Realistic stubs for a 'fleet-ready' Win11 Pro host: 16 GB RAM,
        # VT + SLAT, controller reachable, NetNat available, MeshAgent
        # already installed and Running, no existing VMs.

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
            Set-DiscoveryInvoker -Name Resolve -ScriptBlock {
                param($n) if ($n -eq 'controller.local') { '10.0.0.7' } else { $null }
            }
            Set-DiscoveryInvoker -Name TestTcp -ScriptBlock {
                param($a,$p,$t) ($a -eq '10.0.0.7' -and $p -eq 443)
            }
            Set-DiscoveryInvoker -Name HttpProbe -ScriptBlock {
                param($url,$timeout)
                if ($url -match '10\.0\.0\.7') {
                    [pscustomobject]@{ Status = 200; Body = '<title>MeshCentral</title>' }
                } else { $null }
            }
            Set-DiscoveryInvoker -Name LocalIPv4 -ScriptBlock {
                @([pscustomobject]@{ IPAddress = '192.168.1.55'; PrefixLength = 24 })
            }
            Set-DiscoveryInvoker -Name ReadConfig      -ScriptBlock { param($p) $null }
            Set-DiscoveryInvoker -Name WriteDiscovered -ScriptBlock { param($p,$r) }
        }
        Set-TuningInvoker -Name GetReg          -ScriptBlock { 0 }   # Fast Startup already 0
        Set-TuningInvoker -Name SetReg          -ScriptBlock { }
        Set-TuningInvoker -Name RunPowercfg     -ScriptBlock { [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Set-TuningInvoker -Name GetActivePowerPlanGuid -ScriptBlock { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }

        Set-HypervInvoker -Name GetFeatureState     -ScriptBlock { @{ State = 'Enabled'; RestartNeeded = $false } }
        Set-HypervInvoker -Name EnableViaCmdlet     -ScriptBlock { @{ Ok = $true; RestartNeeded = $false; Detail = '' } }
        Set-HypervInvoker -Name EnableViaDism       -ScriptBlock { @{ Ok = $true; RestartNeeded = $false; Detail = '' } }
        Set-HypervInvoker -Name EnableViaCapability -ScriptBlock { @{ Ok = $true; RestartNeeded = $false; Detail = '' } }

        Set-NetworkInvoker -Name GetVMSwitch     -ScriptBlock { @() }
        Set-NetworkInvoker -Name NewVMSwitch     -ScriptBlock { param($n) }
        Set-NetworkInvoker -Name GetNetIPv4      -ScriptBlock { @() }
        Set-NetworkInvoker -Name NewNetIPAddr    -ScriptBlock { param($a,$ip,$pfx) }
        Set-NetworkInvoker -Name GetNetRoute     -ScriptBlock {
            @([pscustomobject]@{ DestinationPrefix = '192.168.1.0/24' }
              [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'      })
        }
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
        Set-AgentsInvoker -Name VerifyMeshAgentHash    -ScriptBlock { param($p,$h) @{ Ok = $true; Skipped = (-not $h); Detail = '' } }
        Set-AgentsInvoker -Name InstallMeshAgent       -ScriptBlock { param($p) @{ Ok = $true; ExitCode = 0; Detail = '' } }
        Set-AgentsInvoker -Name GetMeshAgentService    -ScriptBlock { @{ Found = $true; Status = 'Running' } }

        Set-VmInvoker -Name SourceGoldenVhdx -ScriptBlock { param($s,$h,$l,$d) @{ Ok = $true; Source = 'smb'; Detail = '' } }
        Set-VmInvoker -Name VerifyVhdxHash   -ScriptBlock { param($p,$h) @{ Ok = $true; Skipped = (-not $h); Detail = '' } }
        Set-VmInvoker -Name CloneVhdx        -ScriptBlock { param($s,$d) @{ Ok = $true; AlreadyPresent = $false; Detail = '' } }
        Set-VmInvoker -Name GetVm            -ScriptBlock { param($n) [pscustomobject]@{ Found = $false; State = 'NotPresent'; AutomaticStartAction = $null; SwitchName = $null; HardDrivePath = $null; MemoryStartupGb = 0; ProcessorCount = 0 } }
        Set-VmInvoker -Name CreateVm         -ScriptBlock { param($n,$v,$s,$ms,$mn,$mx,$cpu,$sb) @{ Ok = $true; Detail = '' } }
        Set-VmInvoker -Name ConfigureAutostart -ScriptBlock { param($n,$d) @{ Ok = $true; Detail = '' } }

        Set-VerifyInvoker -Name GetService -ScriptBlock { param($n) [pscustomobject]@{ Found = $true; Status = 'Running'; StartType = 'Automatic' } }
        Set-VerifyInvoker -Name GetVm      -ScriptBlock {
            param($n)
            $i = if ($n -like '*-a') { 50 } else { 51 }
            [pscustomobject]@{ Found = $true; State = 'Running'; SwitchName = 'ClusterNATSwitch'; IpAddress = "192.168.100.$i" }
        }
        Set-VerifyInvoker -Name StartVm    -ScriptBlock { param($n) @{ Ok = $true } }
        Set-VerifyInvoker -Name TestTcp    -ScriptBlock { param($a,$p,$t) $true }
        # Capture $script:probe via .GetNewClosure() so the scriptblock
        # mutates the hashtable the It block reads. A bare $script:
        # assignment from inside a closure invoked across module/file
        # boundaries lands in the wrong session-state.
        $probe = $script:probe
        Set-VerifyInvoker -Name WriteSummary -ScriptBlock {
            param($p,$body)
            $probe.lastSummary     = $body
            $probe.lastSummaryPath = $p
        }.GetNewClosure()
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:testRegBase) {
        Remove-Item -LiteralPath $script:testRegBase -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS  -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_NOAUTORUN         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_REG_BASE          -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_STATE_DIR         -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_LOG_DIR           -ErrorAction SilentlyContinue
}

Describe 'E2E dry-run: fleet-ready host' {

    BeforeEach {
        if (Test-Path -LiteralPath $script:testRegBase) {
            Remove-Item -LiteralPath $script:testRegBase -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:probe.lastSummary     = $null
        $script:probe.lastSummaryPath = $null
    }

    It 'runs all 8 stages to Overall=Pass with a fully-stubbed environment' {
        Stub-FleetReadyHost
        $r = Invoke-ClusterHostSetup -DryRun -NoRestart 6>$null
        $r.Overall      | Should -Be 'Pass'
        $r.Stages.Count | Should -Be 8
        $r.RunId        | Should -Match '^[0-9a-f-]{36}$'
        # Every stage that touched real surface state in non-DryRun would
        # have logged Skipped; with -DryRun, the stages either Pass or Warn
        # (Agents Warn when no SSH key, Verify summary write skipped, etc.).
        @($r.Stages | Where-Object Overall -eq 'Fail').Count | Should -Be 0
    }

    It 'records run completion in the registry state (Status=Completed, no Stage marker)' {
        Stub-FleetReadyHost
        Invoke-ClusterHostSetup -DryRun -NoRestart 6>$null | Out-Null
        $status = Get-ClusterRunStatus
        $status.Status | Should -Be 'Completed'
        # Stage marker cleared by Complete-ClusterRun.
        Get-StageMarker | Should -BeNullOrEmpty
        $status.RunId   | Should -Match '^[0-9a-f-]{36}$'
        $status.Version | Should -Be '0.1.0'
    }

    It 'is fully idempotent: a second back-to-back run is also Overall=Pass' {
        Stub-FleetReadyHost
        $r1 = Invoke-ClusterHostSetup -DryRun -NoRestart 6>$null
        $r2 = Invoke-ClusterHostSetup -DryRun -NoRestart 6>$null
        $r1.Overall | Should -Be 'Pass'
        $r2.Overall | Should -Be 'Pass'
        $r1.RunId   | Should -Not -Be $r2.RunId   # each run gets a fresh RunId
    }

    It 'writes a Verify summary that names every expected VM and the switch' {
        # We exercise Verify directly with -DryRun:$false here. The whole-
        # orchestrator path is already covered by the other tests; for the
        # summary-content contract, going through Stage 1 Preflight just
        # forces us to also stub admin-elevation, which is brittle. Calling
        # Invoke-VerifyStage directly is closer to what we are asserting.
        Stub-FleetReadyHost
        $cfg = [pscustomobject]@{
            network = [pscustomobject]@{ nat_switch_name = 'ClusterNATSwitch' }
            vms     = [pscustomobject]@{ count = 2; name_prefix = 'vm-' }
        }
        $summaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ("e2e-summary-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.txt')
        try {
            $r = Invoke-VerifyStage -Config $cfg -SummaryPath $summaryPath -Meta @{ runId = 'test-run'; version = '0.1.0' } 6>$null
            $r.Overall | Should -Be 'Pass'
            $script:probe.lastSummary     | Should -Not -BeNullOrEmpty
            $script:probe.lastSummaryPath | Should -Be $summaryPath
            $script:probe.lastSummary     | Should -Match 'vm-a'
            $script:probe.lastSummary     | Should -Match 'vm-b'
            $script:probe.lastSummary     | Should -Match 'ClusterNATSwitch'
        } finally {
            Remove-Item -LiteralPath $summaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a full Stage 4 reboot cycle: marker=4 from prior run -> -Resume re-runs stage 4 only and completes' {
        Stub-FleetReadyHost
        # Simulate: previous run got to Stage 4, triggered reboot, registered task.
        Save-StageMarker -StageNumber 4
        $r = Invoke-ClusterHostSetup -Resume -NoRestart 6>$null
        $r.Overall | Should -Be 'Pass'
        @($r.Stages | Where-Object Number -eq 4 | Where-Object Overall -ne 'Skipped').Count | Should -Be 1
        @($r.Stages | Where-Object { $_.Number -le 3 -and $_.Overall -eq 'Skipped' }).Count | Should -Be 3
    }
}

Describe 'E2E acceptance: PRIMARY GOAL' {

    BeforeEach {
        if (Test-Path -LiteralPath $script:testRegBase) {
            Remove-Item -LiteralPath $script:testRegBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '8-stage orchestrator runs end-to-end with Overall=Pass and zero Fail stages -- the PRIMARY GOAL is met' {
        Stub-FleetReadyHost
        $r = Invoke-ClusterHostSetup -DryRun -NoRestart 6>$null
        $r.Overall | Should -Be 'Pass'
        @($r.Stages | Where-Object Overall -eq 'Fail').Count | Should -Be 0
        @($r.Stages | Where-Object { $_.Number -ne 8 -and $_.Overall -eq 'Pass' }).Count | Should -BeGreaterOrEqual 6
        # The 8-stage shape is the contract.
        $r.Stages.Count | Should -Be 8
        ($r.Stages | ForEach-Object Number) | Should -Be @(1,2,3,4,5,6,7,8)
        ($r.Stages | ForEach-Object Name)   | Should -Be @('Preflight','Discover','Tuning','Hyperv','Network','Agents','Vms','Verify')
    }
}

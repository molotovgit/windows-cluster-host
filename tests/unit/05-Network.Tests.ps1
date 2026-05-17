#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir     = Join-Path $repoRoot 'src\lib'
    $stagePath  = Join-Path $repoRoot 'src\stages\05-Network.ps1'

    foreach ($mod in 'Logging','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    . $stagePath

    function Set-NetStub {
        param(
            [pscustomobject[]]$Switches = @(),
            [pscustomobject[]]$NetIPs   = @(),
            [pscustomobject[]]$Routes   = @(),
            [pscustomobject[]]$Nats     = @(),
            [bool]$HasNetNat            = $true,
            [switch]$VmSwitchThrows
        )
        Reset-NetworkInvoker
        $caps = [pscustomobject]@{
            Switches = New-Object System.Collections.Generic.List[pscustomobject]
            NetIPs   = New-Object System.Collections.Generic.List[pscustomobject]
            Nats     = New-Object System.Collections.Generic.List[pscustomobject]
            Calls    = New-Object System.Collections.Generic.List[string]
        }
        foreach ($s in $Switches) { $caps.Switches.Add($s) }
        foreach ($i in $NetIPs)   { $caps.NetIPs.Add($i) }
        foreach ($n in $Nats)     { $caps.Nats.Add($n) }

        Set-NetworkInvoker -Name GetVMSwitch     -ScriptBlock { $caps.Calls.Add('GetVMSwitch');     @($caps.Switches.ToArray()) }.GetNewClosure()
        Set-NetworkInvoker -Name GetNetIPv4      -ScriptBlock { $caps.Calls.Add('GetNetIPv4');      @($caps.NetIPs.ToArray()) }.GetNewClosure()
        Set-NetworkInvoker -Name GetNetRoute     -ScriptBlock { $caps.Calls.Add('GetNetRoute');     @($Routes) }.GetNewClosure()
        Set-NetworkInvoker -Name GetNetNat       -ScriptBlock { $caps.Calls.Add('GetNetNat');       @($caps.Nats.ToArray()) }.GetNewClosure()
        Set-NetworkInvoker -Name HasNetNatCmdlet -ScriptBlock { $caps.Calls.Add('HasNetNatCmdlet'); $HasNetNat }.GetNewClosure()
        Set-NetworkInvoker -Name NewVMSwitch -ScriptBlock {
            param([string]$Name)
            $caps.Calls.Add("NewVMSwitch:$Name")
            if ($VmSwitchThrows) { throw [System.UnauthorizedAccessException]::new('vswitch create denied') }
            $caps.Switches.Add([pscustomobject]@{ Name = $Name; SwitchType = 'Internal'; NetAdapterInterfaceDescription = '' })
        }.GetNewClosure()
        Set-NetworkInvoker -Name NewNetIPAddr -ScriptBlock {
            param([string]$Alias, [string]$Ip, [int]$Prefix)
            $caps.Calls.Add("NewNetIPAddr:$Alias|$Ip|$Prefix")
            $caps.NetIPs.Add([pscustomobject]@{ IPAddress = $Ip; PrefixLength = $Prefix; InterfaceAlias = $Alias })
        }.GetNewClosure()
        Set-NetworkInvoker -Name NewNetNat -ScriptBlock {
            param([string]$Name, [string]$Prefix)
            $caps.Calls.Add("NewNetNat:$Name|$Prefix")
            $caps.Nats.Add([pscustomobject]@{ Name = $Name; InternalIPInterfaceAddressPrefix = $Prefix })
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

Describe 'Invoke-NetworkStage' {

    AfterEach { Reset-NetworkInvoker }

    It 'picks the first non-colliding /24 from the candidate list' {
        $caps = Set-NetStub -Routes @(
            [pscustomobject]@{ DestinationPrefix = '192.168.100.0/24' }
        )
        $r = Invoke-NetworkStage -CandidateSubnets @('192.168.100.0/24','10.50.0.0/24') 6>$null
        $r.Overall   | Should -Be 'Pass'
        $r.Subnet    | Should -Be '10.50.0.0/24'
        $r.GatewayIp | Should -Be '10.50.0.1'
    }

    It 'creates the switch, IP, and NAT in order when nothing exists' {
        $caps = Set-NetStub
        $r = Invoke-NetworkStage -SwitchName 'TestSwitch' -CandidateSubnets @('192.168.100.0/24') 6>$null
        $r.Overall    | Should -Be 'Pass'
        $r.Method     | Should -Be 'CreatedWithNat'
        $r.SwitchName | Should -Be 'TestSwitch'
        $r.GatewayIp  | Should -Be '192.168.100.1'
        @($caps.Calls | Where-Object { $_ -eq 'NewVMSwitch:TestSwitch' }).Count | Should -Be 1
        @($caps.Calls | Where-Object { $_ -like 'NewNetIPAddr:vEthernet (TestSwitch)|192.168.100.1|24' }).Count | Should -Be 1
        @($caps.Calls | Where-Object { $_ -like 'NewNetNat:TestSwitchNat|192.168.100.0/24' }).Count | Should -Be 1
    }

    It 'returns Method=AlreadyConfigured (no writes) when state already matches' {
        $caps = Set-NetStub `
            -Switches @([pscustomobject]@{ Name = 'TestSwitch'; SwitchType = 'Internal'; NetAdapterInterfaceDescription = '' }) `
            -NetIPs   @([pscustomobject]@{ IPAddress = '192.168.100.1'; PrefixLength = 24; InterfaceAlias = 'vEthernet (TestSwitch)' }) `
            -Nats     @([pscustomobject]@{ Name = 'TestSwitchNat'; InternalIPInterfaceAddressPrefix = '192.168.100.0/24' })
        $r = Invoke-NetworkStage -SwitchName 'TestSwitch' -CandidateSubnets @('192.168.100.0/24') 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Method  | Should -Be 'AlreadyConfigured'
        @($caps.Calls | Where-Object { $_ -like 'NewVMSwitch*' }).Count | Should -Be 0
    }

    It 'falls back to internal-only (Warn) when NetNat is unavailable' {
        $caps = Set-NetStub -HasNetNat $false
        $r = Invoke-NetworkStage -SwitchName 'TestSwitch' -CandidateSubnets @('192.168.100.0/24') 6>$null
        $r.Overall  | Should -Be 'Warn'
        $r.Method   | Should -Be 'CreatedInternalOnly'
        $r.Detail   | Should -Match 'NetNat'
        @($caps.Calls | Where-Object { $_ -like 'NewNetNat*' }).Count | Should -Be 0
    }

    It 'detects partial overlap: /16 route excludes a /24 candidate inside it' {
        $caps = Set-NetStub -Routes @(
            [pscustomobject]@{ DestinationPrefix = '192.168.0.0/16' }
        )
        $r = Invoke-NetworkStage -CandidateSubnets @('192.168.100.0/24','10.50.0.0/24') 6>$null
        $r.Overall   | Should -Be 'Pass'
        $r.Subnet    | Should -Be '10.50.0.0/24'   # 192.168.100.0/24 is inside 192.168.0.0/16 so collides
    }

    It 'ignores the always-present default route 0.0.0.0/0 when checking collisions' {
        $caps = Set-NetStub -Routes @(
            [pscustomobject]@{ DestinationPrefix = '0.0.0.0/0' }
            [pscustomobject]@{ DestinationPrefix = '169.254.0.0/16' }
        )
        $r = Invoke-NetworkStage -CandidateSubnets @('192.168.100.0/24') 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Subnet  | Should -Be '192.168.100.0/24'
    }

    It 'returns Fail with a clear remediation when a DIFFERENT NetNat already exists' {
        $caps = Set-NetStub -Nats @(
            [pscustomobject]@{ Name = 'OtherNat'; InternalIPInterfaceAddressPrefix = '10.99.0.0/24' }
        )
        $r = Invoke-NetworkStage -CandidateSubnets @('192.168.100.0/24') 6>$null
        $r.Overall     | Should -Be 'Fail'
        $r.Method      | Should -Be 'None'
        $r.Detail      | Should -Match 'OtherNat'
        $r.Remediation | Should -Match 'Remove-NetNat'
        @($caps.Calls | Where-Object { $_ -like 'NewNetNat*' }).Count | Should -Be 0
    }

    It 'existing-state alias check is strict: vEthernet (ClusterStorage) does not match SwitchName=Cluster' {
        $caps = Set-NetStub `
            -Switches @([pscustomobject]@{ Name = 'Cluster'; SwitchType = 'Internal'; NetAdapterInterfaceDescription = '' }) `
            -NetIPs   @([pscustomobject]@{ IPAddress = '192.168.100.1'; PrefixLength = 24; InterfaceAlias = 'vEthernet (ClusterStorage)' })
        $r = Invoke-NetworkStage -SwitchName 'Cluster' -CandidateSubnets @('192.168.100.0/24') 6>$null
        # Should NOT short-circuit to AlreadyConfigured because the IP is on
        # 'vEthernet (ClusterStorage)' not 'vEthernet (Cluster)'.
        $r.Method | Should -Not -Be 'AlreadyConfigured'
        @($caps.Calls | Where-Object { $_ -like 'NewNetIPAddr:vEthernet (Cluster)*' }).Count | Should -Be 1
    }

    It 'returns Overall=Fail when every candidate subnet collides' {
        $caps = Set-NetStub -Routes @(
            [pscustomobject]@{ DestinationPrefix = '192.168.100.0/24' }
            [pscustomobject]@{ DestinationPrefix = '10.50.0.0/24' }
        )
        $r = Invoke-NetworkStage -CandidateSubnets @('192.168.100.0/24','10.50.0.0/24') 6>$null
        $r.Overall     | Should -Be 'Fail'
        $r.Remediation | Should -Match 'nat_candidate_subnets'
    }

    It '-DryRun reports Pass / DryRun without making any writes' {
        $caps = Set-NetStub
        $r = Invoke-NetworkStage -SwitchName 'TestSwitch' -CandidateSubnets @('192.168.100.0/24') -DryRun 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Method  | Should -Be 'DryRun'
        @($caps.Calls | Where-Object { $_ -like 'New*' }).Count | Should -Be 0
    }

    It 'returns Overall=Fail when New-VMSwitch throws' {
        $caps = Set-NetStub -VmSwitchThrows
        $r = Invoke-NetworkStage -SwitchName 'TestSwitch' -CandidateSubnets @('192.168.100.0/24') 6>$null
        $r.Overall     | Should -Be 'Fail'
        $r.Method      | Should -Be 'None'
        $r.Detail      | Should -Match 'vswitch create denied'
        $r.Remediation | Should -Match 'New-VMSwitch'
    }

    It 'reads switch name and subnet list from -Config when -SwitchName / -CandidateSubnets omitted' {
        $cfg = [pscustomobject]@{
            network = [pscustomobject]@{
                nat_switch_name      = 'FromConfig'
                nat_candidate_subnets = @('172.20.50.0/24')
            }
        }
        $caps = Set-NetStub
        $r = Invoke-NetworkStage -Config $cfg 6>$null
        $r.SwitchName | Should -Be 'FromConfig'
        $r.Subnet     | Should -Be '172.20.50.0/24'
        $r.GatewayIp  | Should -Be '172.20.50.1'
    }

    It 'tolerates partial -Config (network without nat_switch_name)' {
        $cfg = [pscustomobject]@{ network = [pscustomobject]@{ nat_candidate_subnets = @('10.50.0.0/24') } }
        $caps = Set-NetStub
        $r = Invoke-NetworkStage -Config $cfg 6>$null
        $r.SwitchName | Should -Be 'ClusterNATSwitch'   # default
        $r.Subnet     | Should -Be '10.50.0.0/24'
    }
}

Describe 'Convert-CidrToPrefix' {
    It 'parses a /24 CIDR into Network/Prefix/Gateway' {
        $r = Convert-CidrToPrefix -Cidr '192.168.42.0/24'
        $r.Network | Should -Be '192.168.42.0'
        $r.Prefix  | Should -Be 24
        $r.Gateway | Should -Be '192.168.42.1'
    }
    It 'throws on malformed input' {
        { Convert-CidrToPrefix -Cidr 'not-a-cidr' } | Should -Throw
        { Convert-CidrToPrefix -Cidr '1.2.3'      } | Should -Throw
    }
}

Describe 'Test seam gating' {
    It 'Set-NetworkInvoker refuses to run without CLUSTERHOST_ALLOW_TEST_SEAMS' {
        Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
        $thrown = $null
        try { Set-NetworkInvoker -Name GetVMSwitch -ScriptBlock { @() } } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        "$thrown" | Should -Match 'CLUSTERHOST_ALLOW_TEST_SEAMS'
        $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    }
}

#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir     = Join-Path $repoRoot 'src\lib'
    $stagePath  = Join-Path $repoRoot 'src\stages\08-Verify.ps1'

    foreach ($mod in 'Logging','Retry') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    . $stagePath

    function Set-VerifyStub {
        param(
            [string]$MeshSvcStatus = 'Running',
            [string]$SshdSvcStatus = 'Running',
            [hashtable]$Vms = $null,
            [bool]$TcpOk = $true,
            [switch]$NoMesh,
            [switch]$NoSshd
        )
        Reset-VerifyInvoker
        $caps = [pscustomobject]@{
            ServiceCalls = New-Object System.Collections.Generic.List[string]
            GetVmCalls   = New-Object System.Collections.Generic.List[string]
            StartVmCalls = New-Object System.Collections.Generic.List[string]
            TcpCalls     = New-Object System.Collections.Generic.List[string]
            Writes       = New-Object System.Collections.Generic.List[hashtable]
            VmMap        = if ($Vms) { $Vms } else { @{} }
        }
        Set-VerifyInvoker -Name GetService -ScriptBlock {
            param($name)
            $caps.ServiceCalls.Add($name)
            switch ($name) {
                'Mesh Agent' {
                    if ($NoMesh) { return [pscustomobject]@{ Found = $false; Status = 'NotInstalled'; StartType = $null } }
                    return [pscustomobject]@{ Found = $true; Status = $MeshSvcStatus; StartType = 'Automatic' }
                }
                'sshd' {
                    if ($NoSshd) { return [pscustomobject]@{ Found = $false; Status = 'NotInstalled'; StartType = $null } }
                    return [pscustomobject]@{ Found = $true; Status = $SshdSvcStatus; StartType = 'Automatic' }
                }
            }
        }.GetNewClosure()
        Set-VerifyInvoker -Name GetVm -ScriptBlock {
            param($name)
            $caps.GetVmCalls.Add($name)
            if ($caps.VmMap.ContainsKey($name)) { return $caps.VmMap[$name] }
            return [pscustomobject]@{ Found = $false; State = 'NotPresent'; SwitchName = $null; IpAddress = $null }
        }.GetNewClosure()
        Set-VerifyInvoker -Name StartVm -ScriptBlock {
            param($name)
            $caps.StartVmCalls.Add($name)
            @{ Ok = $true }
        }.GetNewClosure()
        Set-VerifyInvoker -Name TestTcp -ScriptBlock {
            param($ip,$port,$timeout)
            $caps.TcpCalls.Add("$ip`:$port")
            $TcpOk
        }.GetNewClosure()
        Set-VerifyInvoker -Name WriteSummary -ScriptBlock {
            param($path,$body)
            $caps.Writes.Add(@{ Path = $path; Body = $body })
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

Describe 'Invoke-VerifyStage' {

    AfterEach { Reset-VerifyInvoker }

    It 'happy path: Mesh+sshd running, all VMs running with IPs -> Overall=Pass' {
        $caps = Set-VerifyStub -Vms @{
            'vm-a' = [pscustomobject]@{ Found = $true; State = 'Running'; SwitchName = 'ClusterNATSwitch'; IpAddress = '192.168.100.50' }
            'vm-b' = [pscustomobject]@{ Found = $true; State = 'Running'; SwitchName = 'ClusterNATSwitch'; IpAddress = '192.168.100.51' }
        }
        $r = Invoke-VerifyStage -VmNames @('vm-a','vm-b') -SwitchName 'ClusterNATSwitch' 6>$null
        $r.Overall | Should -Be 'Pass'
        $caps.Writes.Count | Should -Be 1
    }

    It 'Fail when Mesh Agent service is missing' {
        $caps = Set-VerifyStub -NoMesh
        $r = Invoke-VerifyStage -VmNames @('vm-a') -SwitchName 'ClusterNATSwitch' 6>$null
        $r.Overall | Should -Be 'Fail'
        ($r.Checks | Where-Object Name -eq 'Mesh Agent service').Status | Should -Be 'Fail'
    }

    It 'Fail when a VM is missing' {
        $caps = Set-VerifyStub -Vms @{}   # GetVm returns Found=$false for every name
        $r = Invoke-VerifyStage -VmNames @('vm-a','vm-b') -SwitchName 'ClusterNATSwitch' 6>$null
        $r.Overall | Should -Be 'Fail'
        @($r.Checks | Where-Object { $_.Name -like '* present' -and $_.Status -eq 'Fail' }).Count | Should -Be 2
    }

    It 'Warn when a VM is Off and -StartStoppedVMs not specified' {
        $caps = Set-VerifyStub -Vms @{
            'vm-a' = [pscustomobject]@{ Found = $true; State = 'Off'; SwitchName = 'ClusterNATSwitch'; IpAddress = $null }
        }
        $r = Invoke-VerifyStage -VmNames @('vm-a') -SwitchName 'ClusterNATSwitch' 6>$null
        ($r.Checks | Where-Object Name -eq "VM 'vm-a' running").Status | Should -Be 'Warn'
        $caps.StartVmCalls.Count | Should -Be 0
    }

    It '-StartStoppedVMs calls Start-VM for a Stopped VM' {
        $caps = Set-VerifyStub -Vms @{
            'vm-a' = [pscustomobject]@{ Found = $true; State = 'Off'; SwitchName = 'ClusterNATSwitch'; IpAddress = $null }
        }
        $r = Invoke-VerifyStage -VmNames @('vm-a') -SwitchName 'ClusterNATSwitch' -StartStoppedVMs -StartWaitSeconds 1 6>$null
        $caps.StartVmCalls | Should -Contain 'vm-a'
    }

    It 'Warn when a VM is attached to the wrong switch' {
        $caps = Set-VerifyStub -Vms @{
            'vm-a' = [pscustomobject]@{ Found = $true; State = 'Running'; SwitchName = 'OtherSwitch'; IpAddress = '192.168.100.50' }
        }
        $r = Invoke-VerifyStage -VmNames @('vm-a') -SwitchName 'ClusterNATSwitch' 6>$null
        ($r.Checks | Where-Object Name -eq "VM 'vm-a' switch").Status | Should -Be 'Warn'
    }

    It 'Warn (not Fail) when TCP probe to a VM IP misses' {
        $caps = Set-VerifyStub -TcpOk $false -Vms @{
            'vm-a' = [pscustomobject]@{ Found = $true; State = 'Running'; SwitchName = 'ClusterNATSwitch'; IpAddress = '192.168.100.50' }
        }
        $r = Invoke-VerifyStage -VmNames @('vm-a') -SwitchName 'ClusterNATSwitch' 6>$null
        ($r.Checks | Where-Object { $_.Name -like '*tcp:*' }).Status | Should -Be 'Warn'
    }

    It '-DryRun does not call WriteSummary' {
        $caps = Set-VerifyStub -Vms @{
            'vm-a' = [pscustomobject]@{ Found = $true; State = 'Running'; SwitchName = 'ClusterNATSwitch'; IpAddress = '192.168.100.50' }
        }
        $r = Invoke-VerifyStage -VmNames @('vm-a') -SwitchName 'ClusterNATSwitch' -DryRun 6>$null
        $caps.Writes.Count | Should -Be 0
    }

    It 'derives VM names from -Config when -VmNames omitted' {
        $caps = Set-VerifyStub -Vms @{
            'host-a' = [pscustomobject]@{ Found = $true; State = 'Running'; SwitchName = 'ClusterNATSwitch'; IpAddress = '192.168.100.50' }
            'host-b' = [pscustomobject]@{ Found = $true; State = 'Running'; SwitchName = 'ClusterNATSwitch'; IpAddress = '192.168.100.51' }
            'host-c' = [pscustomobject]@{ Found = $true; State = 'Running'; SwitchName = 'ClusterNATSwitch'; IpAddress = '192.168.100.52' }
        }
        $cfg = [pscustomobject]@{
            network = [pscustomobject]@{ nat_switch_name = 'ClusterNATSwitch' }
            vms     = [pscustomobject]@{ count = 3; name_prefix = 'host-' }
        }
        $r = Invoke-VerifyStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Pass'
        $caps.GetVmCalls | Should -Be @('host-a','host-b','host-c')
    }

    It 'Summary text contains the VM names + switch + check rows' {
        $caps = Set-VerifyStub -Vms @{
            'vm-a' = [pscustomobject]@{ Found = $true; State = 'Running'; SwitchName = 'ClusterNATSwitch'; IpAddress = '192.168.100.50' }
        }
        $r = Invoke-VerifyStage -VmNames @('vm-a') -SwitchName 'ClusterNATSwitch' -Meta @{ runId = 'abc'; version = '0.1.0' } 6>$null
        $r.Summary | Should -Match 'Cluster host setup summary'
        $r.Summary | Should -Match 'vm-a'
        $r.Summary | Should -Match 'ClusterNATSwitch'
        $r.Summary | Should -Match 'runId\s+abc'
        $r.Summary | Should -Match 'version\s+0\.1\.0'
        $r.Summary | Should -Match 'Mesh Agent service'
    }
}

Describe 'Test seam gating' {
    It 'Set-VerifyInvoker refuses to run without CLUSTERHOST_ALLOW_TEST_SEAMS' {
        Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
        $thrown = $null
        try { Set-VerifyInvoker -Name GetService -ScriptBlock { } } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        "$thrown" | Should -Match 'CLUSTERHOST_ALLOW_TEST_SEAMS'
        $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    }
}

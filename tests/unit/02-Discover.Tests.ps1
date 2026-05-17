#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir     = Join-Path $repoRoot 'src\lib'
    $stagePath  = Join-Path $repoRoot 'src\stages\02-Discover.ps1'

    foreach ($mod in 'Logging','Discovery') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    $script:Disc = Get-Module Discovery
    . $stagePath

    function Reset-Invoker {
        & $script:Disc { Reset-DiscoveryInvoker }
    }
    function Stub-AllInvoker {
        param(
            [string[]]$ResolveMap = @(),
            [hashtable]$ProbeStatus = @{},
            [hashtable]$TcpOk      = @{},
            [pscustomobject[]]$LocalIPv4 = @()
        )
        $caps = [pscustomobject]@{
            ResolveMap   = $ResolveMap
            ProbeStatus  = $ProbeStatus
            TcpOk        = $TcpOk
            LocalIPv4    = $LocalIPv4
            ResolveCalls = New-Object System.Collections.Generic.List[string]
            TcpCalls     = New-Object System.Collections.Generic.List[string]
            HttpCalls    = New-Object System.Collections.Generic.List[string]
            Writes       = New-Object System.Collections.Generic.List[string]
        }
        & $script:Disc {
            param($caps)
            Set-DiscoveryInvoker -Name Resolve -ScriptBlock {
                param([string]$Name)
                $caps.ResolveCalls.Add($Name)
                $map = $caps.ResolveMap
                for ($i = 0; $i -lt $map.Count; $i += 2) { if ($map[$i] -eq $Name) { return $map[$i+1] } }
                return $null
            }.GetNewClosure()
            Set-DiscoveryInvoker -Name TestTcp -ScriptBlock {
                param([string]$Address, [int]$Port, [int]$TimeoutMs)
                $k = "$Address`:$Port"
                $caps.TcpCalls.Add($k)
                if ($caps.TcpOk.ContainsKey($k)) { return $caps.TcpOk[$k] }
                return $false
            }.GetNewClosure()
            Set-DiscoveryInvoker -Name HttpProbe -ScriptBlock {
                param([string]$Url, [int]$TimeoutSec)
                $caps.HttpCalls.Add($Url)
                if ($caps.ProbeStatus.ContainsKey($Url)) { return $caps.ProbeStatus[$Url] }
                return $null
            }.GetNewClosure()
            Set-DiscoveryInvoker -Name LocalIPv4 -ScriptBlock { return $caps.LocalIPv4 }.GetNewClosure()
            Set-DiscoveryInvoker -Name WriteDiscovered -ScriptBlock {
                param([string]$Path, [hashtable]$Record)
                $caps.Writes.Add($Path)
            }.GetNewClosure()
        } $caps
        return $caps
    }

    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("disc-stage-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmpRoot -ItemType Directory -Force | Out-Null
}

AfterAll {
    Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    foreach ($mod in 'Logging','Discovery') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-DiscoverStage' {

    AfterEach { Reset-Invoker }

    It 'returns Overall=Pass when DNS resolves and the probe succeeds' {
        $caps = Stub-AllInvoker `
            -ResolveMap  @('controller.local','10.0.0.7') `
            -TcpOk       @{ '10.0.0.7:443' = $true } `
            -ProbeStatus @{ 'https://10.0.0.7:443/' = [pscustomobject]@{ Status = 200; Body = 'MeshCentral' } }

        $persist = Join-Path $script:tmpRoot 'persist-1.json'
        $r = Invoke-DiscoverStage -PersistPath $persist 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Address | Should -Be '10.0.0.7'
        $r.Source  | Should -Be 'dns:controller.local'
        $r.Url     | Should -Match 'https://10\.0\.0\.7:443/'
        $caps.Writes | Should -Contain $persist
    }

    It 'returns Overall=Fail with a multi-line remediation when no controller responds' {
        $caps = Stub-AllInvoker   # everything returns failure by default

        $r = Invoke-DiscoverStage -ConfigPath (Join-Path $script:tmpRoot 'no-such-cfg.json') 6>$null
        $r.Overall     | Should -Be 'Fail'
        $r.Address     | Should -BeNullOrEmpty
        $r.Remediation | Should -Match 'DNS / mDNS'
        $r.Remediation | Should -Match 'cluster-config\.json'
    }

    It 'uses the config-supplied controller.address when it answers' {
        $cfgPath = Join-Path $script:tmpRoot 'cfg-good.json'
        Set-Content -LiteralPath $cfgPath -Value (ConvertTo-Json @{ controller = @{ address = '192.168.1.50' } }) -Encoding utf8

        $caps = Stub-AllInvoker `
            -TcpOk       @{ '192.168.1.50:443' = $true } `
            -ProbeStatus @{ 'https://192.168.1.50:443/' = [pscustomobject]@{ Status = 200; Body = 'MeshCentral' } }

        $r = Invoke-DiscoverStage -ConfigPath $cfgPath 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Source  | Should -Be 'config'
    }

    It 'honors -Config controller.port to override the candidate port set' {
        $cfg = [pscustomobject]@{ controller = [pscustomobject]@{ port = 8443 } }
        $caps = Stub-AllInvoker `
            -ResolveMap  @('controller.local','10.0.0.7') `
            -TcpOk       @{ '10.0.0.7:8443' = $true } `
            -ProbeStatus @{ 'https://10.0.0.7:8443/' = [pscustomobject]@{ Status = 200; Body = 'MeshCentral' } }

        $r = Invoke-DiscoverStage -Config $cfg 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Port    | Should -Be 8443
    }

    It 'tolerates a partial config (controller object without address)' {
        $cfgPath = Join-Path $script:tmpRoot 'cfg-no-address.json'
        Set-Content -LiteralPath $cfgPath -Value (ConvertTo-Json @{ controller = @{ port = 443 } }) -Encoding utf8

        $caps = Stub-AllInvoker `
            -ResolveMap  @('controller.local','10.0.0.7') `
            -TcpOk       @{ '10.0.0.7:443' = $true } `
            -ProbeStatus @{ 'https://10.0.0.7:443/' = [pscustomobject]@{ Status = 200; Body = 'MeshCentral' } }

        $r = Invoke-DiscoverStage -ConfigPath $cfgPath 6>$null
        $r.Overall | Should -Be 'Pass'
        $r.Source  | Should -Be 'dns:controller.local'
    }

    It 'returns PersistPath in the result so the orchestrator can find the saved file' {
        $persist = Join-Path $script:tmpRoot 'persist-out.json'
        $caps = Stub-AllInvoker   # no resolution -> Fail, but PersistPath still surfaces
        $r = Invoke-DiscoverStage -PersistPath $persist 6>$null
        $r.PersistPath | Should -Be $persist
    }
}

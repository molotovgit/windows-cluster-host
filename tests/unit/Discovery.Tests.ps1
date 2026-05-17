#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\Discovery.psm1'

    Get-Module Discovery | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    $script:Disc = Get-Module Discovery
    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("discovery-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -Path $script:tmpRoot -ItemType Directory -Force | Out-Null

    # Helper visible to all It blocks (Pester 5 puts BeforeAll-defined
    # functions into the same scope the It blocks run in).
    function Set-AllOkInvokers {
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
        }
        & $script:Disc {
            param($caps)
            Set-DiscoveryInvoker -Name Resolve -ScriptBlock {
                param([string]$Name)
                $caps.ResolveCalls.Add($Name)
                $map = $caps.ResolveMap
                for ($i = 0; $i -lt $map.Count; $i += 2) {
                    if ($map[$i] -eq $Name) { return $map[$i+1] }
                }
                return $null
            }.GetNewClosure()
            Set-DiscoveryInvoker -Name TestTcp -ScriptBlock {
                param([string]$Address, [int]$Port, [int]$TimeoutMs)
                $caps.TcpCalls.Add("$Address`:$Port")
                $k = "$Address`:$Port"
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
        } $caps
        return $caps
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Get-Module Discovery | Remove-Module -Force -ErrorAction SilentlyContinue
}

# ---------- tests ----------

Describe 'Test-ProbeOk-like behavior via Test-ControllerEndpoint' {

    AfterEach { & $script:Disc { Reset-DiscoveryInvoker } }

    It 'returns Ok=true on a 200 response' {
        $caps = Set-AllOkInvokers `
            -TcpOk      @{ '10.0.0.7:443' = $true } `
            -ProbeStatus @{ 'https://10.0.0.7:443/' = 200 }
        $r = Test-ControllerEndpoint -Address '10.0.0.7' -Port 443 6>$null
        $r.Ok | Should -BeTrue
        $r.Status | Should -Be 200
    }

    It 'returns Ok=true on a 401 (typical MeshCentral unauthenticated GET)' {
        $caps = Set-AllOkInvokers `
            -TcpOk      @{ '10.0.0.7:443' = $true } `
            -ProbeStatus @{ 'https://10.0.0.7:443/' = 401 }
        (Test-ControllerEndpoint -Address '10.0.0.7' -Port 443 6>$null).Ok | Should -BeTrue
    }

    It 'returns Ok=false on a 500' {
        $caps = Set-AllOkInvokers `
            -TcpOk      @{ '10.0.0.7:443' = $true } `
            -ProbeStatus @{ 'https://10.0.0.7:443/' = 500 }
        $r = Test-ControllerEndpoint -Address '10.0.0.7' -Port 443 6>$null
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'http-500'
    }

    It 'returns Ok=false with reason=tcp-closed when the port is closed' {
        $caps = Set-AllOkInvokers -TcpOk @{ '10.0.0.7:443' = $false }
        $r = Test-ControllerEndpoint -Address '10.0.0.7' -Port 443 6>$null
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'tcp-closed'
    }
}

Describe 'Get-SubnetScanTarget' {

    AfterEach { & $script:Disc { Reset-DiscoveryInvoker } }

    It 'produces .1 .10 .100 .254 candidates per usable /24 interface' {
        $caps = Set-AllOkInvokers -LocalIPv4 @(
            [pscustomobject]@{ IPAddress = '192.168.1.55';   PrefixLength = 24 }
            [pscustomobject]@{ IPAddress = '10.0.0.4';       PrefixLength = 22 }
        )
        $t = Get-SubnetScanTarget
        $t | Should -Contain '192.168.1.1'
        $t | Should -Contain '192.168.1.10'
        $t | Should -Contain '192.168.1.100'
        $t | Should -Contain '192.168.1.254'
        $t | Should -Contain '10.0.0.1'
        $t | Should -Not -Contain '192.168.1.55'   # exclude self
    }

    It 'skips /8 / /16 interfaces (too large to scan)' {
        $caps = Set-AllOkInvokers -LocalIPv4 @(
            [pscustomobject]@{ IPAddress = '10.0.0.4'; PrefixLength = 8 }
        )
        Get-SubnetScanTarget | Should -HaveCount 0
    }

    It 'returns an empty array when LocalIPv4 yields nothing' {
        $caps = Set-AllOkInvokers -LocalIPv4 @()
        Get-SubnetScanTarget | Should -HaveCount 0
    }
}

Describe 'Find-Controller strategy order' {

    AfterEach { & $script:Disc { Reset-DiscoveryInvoker } }

    It 'uses the config-supplied address when it answers (strategy 1)' {
        $cfgPath = Join-Path $script:tmpRoot 'cfg-good.json'
        Set-Content -LiteralPath $cfgPath -Value (ConvertTo-Json @{ controller = @{ address = '10.0.0.7' } }) -Encoding utf8
        $caps = Set-AllOkInvokers `
            -TcpOk       @{ '10.0.0.7:443' = $true } `
            -ProbeStatus @{ 'https://10.0.0.7:443/' = 200 }
        $r = Find-Controller -ConfigPath $cfgPath 6>$null
        $r.Address | Should -Be '10.0.0.7'
        $r.Source  | Should -Be 'config'
        $caps.ResolveCalls.Count | Should -Be 0   # never reached DNS
    }

    It 'falls through to DNS when the config address does not respond' {
        $cfgPath = Join-Path $script:tmpRoot 'cfg-stale.json'
        Set-Content -LiteralPath $cfgPath -Value (ConvertTo-Json @{ controller = @{ address = '10.0.0.99' } }) -Encoding utf8
        $caps = Set-AllOkInvokers `
            -ResolveMap  @('controller.local','10.0.0.7') `
            -TcpOk       @{ '10.0.0.99:443' = $false; '10.0.0.7:443' = $true } `
            -ProbeStatus @{ 'https://10.0.0.7:443/' = 200 }
        $r = Find-Controller -ConfigPath $cfgPath 6>$null
        $r.Address | Should -Be '10.0.0.7'
        $r.Source  | Should -Be 'dns:controller.local'
        $caps.ResolveCalls | Should -Contain 'controller.local'
    }

    It 'falls back from DNS to subnet scan' {
        $caps = Set-AllOkInvokers `
            -ResolveMap  @('controller.local',$null,'controller',$null) `
            -LocalIPv4   @([pscustomobject]@{ IPAddress = '192.168.1.55'; PrefixLength = 24 }) `
            -TcpOk       @{ '192.168.1.10:443' = $true } `
            -ProbeStatus @{ 'https://192.168.1.10:443/' = 200 }
        $r = Find-Controller 6>$null
        $r.Address | Should -Be '192.168.1.10'
        $r.Source  | Should -Be 'subnet-scan'
    }

    It 'returns $null when every strategy fails' {
        $caps = Set-AllOkInvokers `
            -ResolveMap @('controller.local',$null,'controller',$null) `
            -LocalIPv4  @([pscustomobject]@{ IPAddress = '192.168.1.55'; PrefixLength = 24 })
        # No TcpOk entries -> all TCP probes return $false.
        Find-Controller 6>$null | Should -BeNullOrEmpty
    }

    It 'persists the discovered address when -PersistPath is supplied AND the source is not config' {
        $persistPath = Join-Path $script:tmpRoot ("discovered-" + [guid]::NewGuid().ToString('N').Substring(0,6) + ".json")
        $caps = Set-AllOkInvokers `
            -ResolveMap  @('controller.local','10.0.0.7') `
            -TcpOk       @{ '10.0.0.7:443' = $true } `
            -ProbeStatus @{ 'https://10.0.0.7:443/' = 200 }
        Find-Controller -PersistPath $persistPath 6>$null | Out-Null
        Test-Path -LiteralPath $persistPath | Should -BeTrue
        $j = Get-Content -LiteralPath $persistPath -Raw | ConvertFrom-Json
        $j.address | Should -Be '10.0.0.7'
        $j.source  | Should -Be 'dns:controller.local'
    }

    It 'does NOT persist when the source was the config file (already there)' {
        $cfgPath     = Join-Path $script:tmpRoot 'cfg-noperist.json'
        $persistPath = Join-Path $script:tmpRoot 'should-not-be-written.json'
        Set-Content -LiteralPath $cfgPath -Value (ConvertTo-Json @{ controller = @{ address = '10.0.0.7' } }) -Encoding utf8
        $caps = Set-AllOkInvokers `
            -TcpOk       @{ '10.0.0.7:443' = $true } `
            -ProbeStatus @{ 'https://10.0.0.7:443/' = 200 }
        Find-Controller -ConfigPath $cfgPath -PersistPath $persistPath 6>$null | Out-Null
        Test-Path -LiteralPath $persistPath | Should -BeFalse
    }

    It 'caps the subnet scan at -MaxSubnetScans' {
        $caps = Set-AllOkInvokers `
            -ResolveMap  @('controller.local',$null,'controller',$null) `
            -LocalIPv4   @(
                [pscustomobject]@{ IPAddress = '192.168.1.55';   PrefixLength = 24 }
                [pscustomobject]@{ IPAddress = '192.168.2.55';   PrefixLength = 24 }
                [pscustomobject]@{ IPAddress = '192.168.3.55';   PrefixLength = 24 }
                [pscustomobject]@{ IPAddress = '192.168.4.55';   PrefixLength = 24 }
            )
        Find-Controller -MaxSubnetScans 3 6>$null | Out-Null
        # 3 candidates x 1 port = 3 TCP probes max (config probe didn't happen because no ConfigPath).
        $caps.TcpCalls.Count | Should -BeLessOrEqual 3
    }
}

Describe 'Test seam gating' {
    It 'Set-DiscoveryInvoker throws when CLUSTERHOST_ALLOW_TEST_SEAMS is unset' {
        Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
        $thrown = $null
        try { & $script:Disc { Set-DiscoveryInvoker -Name Resolve -ScriptBlock { $null } } } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        "$thrown" | Should -Match 'CLUSTERHOST_ALLOW_TEST_SEAMS'
        $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    }

    It 'rejects an unknown invoker name' {
        { & $script:Disc { Set-DiscoveryInvoker -Name 'Bogus' -ScriptBlock { } } } |
            Should -Throw -ExpectedMessage '*unknown invoker*'
    }
}

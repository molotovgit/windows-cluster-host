#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $modulePath = Join-Path $repoRoot 'src\lib\HardwareDetect.psm1'

    Get-Module HardwareDetect | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force

    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    $script:HD = Get-Module HardwareDetect
}

AfterAll {
    Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    Get-Module HardwareDetect | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-CanonicalSku' {

    It 'maps Pro / Professional / pro-suffix-variants' {
        ConvertTo-CanonicalSku 'Professional'                | Should -Be 'Pro'
        ConvertTo-CanonicalSku 'Windows 11 Pro'              | Should -Be 'Pro'
        ConvertTo-CanonicalSku 'Pro for Workstations'        | Should -Be 'Pro'
    }
    It 'maps Home / Core variants' {
        ConvertTo-CanonicalSku 'Home'                | Should -Be 'Home'
        ConvertTo-CanonicalSku 'Windows 11 Home'     | Should -Be 'Home'
        ConvertTo-CanonicalSku 'CoreSingleLanguage'  | Should -Be 'Home'
    }
    It 'maps Enterprise + Education' {
        ConvertTo-CanonicalSku 'Enterprise'          | Should -Be 'Enterprise'
        ConvertTo-CanonicalSku 'Education'           | Should -Be 'Education'
    }
    It 'returns Unknown for empty / unrecognized input' {
        ConvertTo-CanonicalSku $null   | Should -Be 'Unknown'
        ConvertTo-CanonicalSku ''      | Should -Be 'Unknown'
        ConvertTo-CanonicalSku 'XYZ'   | Should -Be 'Unknown'
    }
}

Describe 'Get-WindowsSku (strategy fallbacks)' {

    AfterEach { & $script:HD { Reset-HardwareDetector } }

    It 'returns Pro from the Get-WindowsEdition strategy when it answers' {
        & $script:HD { Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { 'Professional' } }
        $r = Get-WindowsSku 6>$null
        $r.Sku    | Should -Be 'Pro'
        $r.Source | Should -Be 'Get-WindowsEdition'
        $r.Raw    | Should -Be 'Professional'
    }

    It 'falls back to Registry.EditionID when the cmdlet returns null' {
        & $script:HD {
            Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { $null }
            Set-HardwareDetector -Name RegistryEditionID    -ScriptBlock { 'Enterprise' }
        }
        $r = Get-WindowsSku 6>$null
        $r.Sku    | Should -Be 'Enterprise'
        $r.Source | Should -Be 'Registry.EditionID'
    }

    It 'falls back to WMI.Caption when cmdlet + registry both fail' {
        & $script:HD {
            Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { $null }
            Set-HardwareDetector -Name RegistryEditionID    -ScriptBlock { $null }
            Set-HardwareDetector -Name WmiOsCaption         -ScriptBlock { 'Microsoft Windows 11 Education' }
        }
        $r = Get-WindowsSku 6>$null
        $r.Sku    | Should -Be 'Education'
        $r.Source | Should -Be 'WMI.Caption'
    }

    It 'returns Unknown when every strategy yields nothing' {
        & $script:HD {
            foreach ($n in 'WindowsEditionCmdlet','RegistryEditionID','WmiOsCaption','ComputerInfoOsName') {
                Set-HardwareDetector -Name $n -ScriptBlock { $null }
            }
        }
        $r = Get-WindowsSku 6>$null
        $r.Sku    | Should -Be 'Unknown'
        $r.Source | Should -Be 'none'
    }

    It 'returns Unknown when raw values are non-empty but unrecognized' {
        & $script:HD {
            Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { 'IoTLTSC' }   # not in our canonical set
            Set-HardwareDetector -Name RegistryEditionID    -ScriptBlock { 'Server'   }   # also unrecognized
            Set-HardwareDetector -Name WmiOsCaption         -ScriptBlock { 'Microsoft Windows Server 2022' }
            Set-HardwareDetector -Name ComputerInfoOsName   -ScriptBlock { 'Server'   }
        }
        $r = Get-WindowsSku 6>$null
        $r.Sku | Should -Be 'Unknown'
    }
}

Describe 'Get-PhysicalDriveBest' {

    AfterEach { & $script:HD { Reset-HardwareDetector } }

    It 'picks the volume with the largest free space' {
        & $script:HD {
            Set-HardwareDetector -Name VolumeList -ScriptBlock {
                @(
                    [pscustomobject]@{ DriveLetter = 'C'; Size = 500GB; SizeRemaining = 100GB }
                    [pscustomobject]@{ DriveLetter = 'D'; Size = 1TB;   SizeRemaining = 800GB }
                    [pscustomobject]@{ DriveLetter = 'E'; Size = 250GB; SizeRemaining = 200GB }
                )
            }
            Set-HardwareDetector -Name SystemDriveLetter -ScriptBlock { 'C' }
        }
        $r = Get-PhysicalDriveBest -MinFreeGb 50 6>$null
        $r.DriveLetter | Should -Be 'D'
        $r.FreeGb      | Should -Be 800
        $r.Source      | Should -Be 'Get-Volume'
    }

    It 'honors -MinFreeGb and excludes too-small drives' {
        & $script:HD {
            Set-HardwareDetector -Name VolumeList -ScriptBlock {
                @(
                    [pscustomobject]@{ DriveLetter = 'C'; Size = 500GB; SizeRemaining = 30GB }
                    [pscustomobject]@{ DriveLetter = 'D'; Size = 250GB; SizeRemaining = 40GB }
                )
            }
            Set-HardwareDetector -Name SystemDriveLetter -ScriptBlock { 'C' }
        }
        Get-PhysicalDriveBest -MinFreeGb 100 6>$null | Should -BeNullOrEmpty
    }

    It '-ExcludeSystem drops the system drive even if it has the most free' {
        & $script:HD {
            Set-HardwareDetector -Name VolumeList -ScriptBlock {
                @(
                    [pscustomobject]@{ DriveLetter = 'C'; Size = 500GB; SizeRemaining = 400GB }
                    [pscustomobject]@{ DriveLetter = 'D'; Size = 250GB; SizeRemaining = 200GB }
                )
            }
            Set-HardwareDetector -Name SystemDriveLetter -ScriptBlock { 'C' }
        }
        $r = Get-PhysicalDriveBest -MinFreeGb 50 -ExcludeSystem 6>$null
        $r.DriveLetter | Should -Be 'D'
    }

    It 'falls back to WMI Win32_LogicalDisk when Get-Volume returns nothing' {
        & $script:HD {
            Set-HardwareDetector -Name VolumeList         -ScriptBlock { @() }
            Set-HardwareDetector -Name WmiLogicalDiskList -ScriptBlock {
                @(
                    [pscustomobject]@{ DeviceID = 'C:'; Size = 500GB; FreeSpace = 300GB }
                    [pscustomobject]@{ DeviceID = 'E:'; Size = 1TB;   FreeSpace = 700GB }
                )
            }
            Set-HardwareDetector -Name SystemDriveLetter  -ScriptBlock { 'C' }
        }
        $r = Get-PhysicalDriveBest -MinFreeGb 100 6>$null
        $r.DriveLetter | Should -Be 'E'
        $r.Source      | Should -Be 'Win32_LogicalDisk'
    }

    It 'returns $null when both Get-Volume and WMI return nothing useful' {
        & $script:HD {
            Set-HardwareDetector -Name VolumeList         -ScriptBlock { @() }
            Set-HardwareDetector -Name WmiLogicalDiskList -ScriptBlock { @() }
            Set-HardwareDetector -Name SystemDriveLetter  -ScriptBlock { 'C' }
        }
        Get-PhysicalDriveBest -MinFreeGb 1 6>$null | Should -BeNullOrEmpty
    }

    It 'rejects MinFreeGb outside the validated range' {
        { Get-PhysicalDriveBest -MinFreeGb 0     6>$null } | Should -Throw
        { Get-PhysicalDriveBest -MinFreeGb 99999 6>$null } | Should -Throw
    }
}

Describe 'Get-ActiveWifiAdapter' {

    AfterEach { & $script:HD { Reset-HardwareDetector } }

    It 'returns the first Up adapter with Native 802.11 MediaType' {
        & $script:HD {
            Set-HardwareDetector -Name NetAdapterList -ScriptBlock {
                @(
                    [pscustomobject]@{ Name = 'Ethernet'; InterfaceIndex = 5; MediaType = '802.3';            Status = 'Up' }
                    [pscustomobject]@{ Name = 'Wi-Fi';    InterfaceIndex = 7; MediaType = 'Native 802.11';    Status = 'Up' }
                )
            }
        }
        $r = Get-ActiveWifiAdapter 6>$null
        $r.Name    | Should -Be 'Wi-Fi'
        $r.Source  | Should -Be 'Get-NetAdapter'
    }

    It 'falls back to WMI Win32_NetworkAdapter when NetAdapter has no match' {
        & $script:HD {
            Set-HardwareDetector -Name NetAdapterList    -ScriptBlock { @() }
            Set-HardwareDetector -Name WmiNetAdapterList -ScriptBlock {
                @(
                    [pscustomobject]@{ Name = 'Wireless USB'; InterfaceIndex = 9; AdapterType = 'Wireless'; NetConnectionStatus = 2 }
                )
            }
        }
        $r = Get-ActiveWifiAdapter 6>$null
        $r.Name   | Should -Be 'Wireless USB'
        $r.Source | Should -Be 'Win32_NetworkAdapter'
    }

    It 'returns $null when nothing wireless is up' {
        & $script:HD {
            Set-HardwareDetector -Name NetAdapterList    -ScriptBlock { @(
                [pscustomobject]@{ Name = 'eth0'; InterfaceIndex = 1; MediaType = '802.3'; Status = 'Up' }
            ) }
            Set-HardwareDetector -Name WmiNetAdapterList -ScriptBlock { @() }
        }
        Get-ActiveWifiAdapter 6>$null | Should -BeNullOrEmpty
    }

    It 'ignores Down wireless adapters' {
        & $script:HD {
            Set-HardwareDetector -Name NetAdapterList -ScriptBlock { @(
                [pscustomobject]@{ Name = 'Wi-Fi'; InterfaceIndex = 7; MediaType = 'Native 802.11'; Status = 'Disabled' }
            ) }
            Set-HardwareDetector -Name WmiNetAdapterList -ScriptBlock { @() }
        }
        Get-ActiveWifiAdapter 6>$null | Should -BeNullOrEmpty
    }
}

Describe 'Get-VirtualizationSupport' {

    AfterEach { & $script:HD { Reset-HardwareDetector } }

    It 'composes HyperVisorPresent / VtSupported / SlatSupported from Get-ComputerInfo' {
        & $script:HD {
            Set-HardwareDetector -Name ComputerInfoVirt -ScriptBlock {
                [pscustomobject]@{
                    HyperVisorPresent                                = $true
                    HyperVRequirementVirtualizationFirmwareEnabled   = $true
                    HyperVRequirementSecondLevelAddressTranslation   = $true
                }
            }
            Set-HardwareDetector -Name WmiProcessorVirtFlag -ScriptBlock { $null }
        }
        $r = Get-VirtualizationSupport 6>$null
        $r.HyperVisorPresent | Should -BeTrue
        $r.VtSupported       | Should -BeTrue
        $r.SlatSupported     | Should -BeTrue
        $r.CanRunHyperV      | Should -BeTrue
    }

    It 'CanRunHyperV is false when SLAT is missing even if VT is on' {
        & $script:HD {
            Set-HardwareDetector -Name ComputerInfoVirt -ScriptBlock {
                [pscustomobject]@{
                    HyperVisorPresent                                = $false
                    HyperVRequirementVirtualizationFirmwareEnabled   = $true
                    HyperVRequirementSecondLevelAddressTranslation   = $false
                }
            }
            Set-HardwareDetector -Name WmiProcessorVirtFlag -ScriptBlock { $null }
        }
        $r = Get-VirtualizationSupport 6>$null
        $r.CanRunHyperV | Should -BeFalse
    }

    It 'falls back to Win32_Processor for VtSupported when Get-ComputerInfo path is missing' {
        & $script:HD {
            Set-HardwareDetector -Name ComputerInfoVirt     -ScriptBlock { $null }
            Set-HardwareDetector -Name WmiProcessorVirtFlag -ScriptBlock { $true }
        }
        $r = Get-VirtualizationSupport 6>$null
        $r.VtSupported            | Should -BeTrue
        $r.Reasons['VtSource']    | Should -Be 'Win32_Processor.VirtualizationFirmwareEnabled'
    }
}

Describe 'Test seam gating' {
    It 'Set-HardwareDetector throws when CLUSTERHOST_ALLOW_TEST_SEAMS is unset' {
        Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
        $thrown = $null
        try { & $script:HD { Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { 'x' } } }
        catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        "$thrown" | Should -Match 'CLUSTERHOST_ALLOW_TEST_SEAMS'
        $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'  # restore for subsequent tests
    }

    It 'Set-HardwareDetector rejects an unknown detector name' {
        { & $script:HD { Set-HardwareDetector -Name 'BogusDetector' -ScriptBlock { } } } |
            Should -Throw -ExpectedMessage '*unknown detector*'
    }
}

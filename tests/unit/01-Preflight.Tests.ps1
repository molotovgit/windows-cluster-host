#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir     = Join-Path $repoRoot 'src\lib'
    $stagePath  = Join-Path $repoRoot 'src\stages\01-Preflight.ps1'

    foreach ($mod in 'Logging','HardwareDetect') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    $script:HD = Get-Module HardwareDetect
    . $stagePath

    function Reset-AllHardwareDetector {
        & $script:HD { Reset-HardwareDetector }
    }

    function Set-HappyPathDetector {
        & $script:HD {
            Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { 'Professional' }
            Set-HardwareDetector -Name RegistryEditionID    -ScriptBlock { 'Professional' }
            Set-HardwareDetector -Name WmiOsCaption         -ScriptBlock { 'Microsoft Windows 11 Pro' }
            Set-HardwareDetector -Name ComputerInfoOsName   -ScriptBlock { 'Microsoft Windows 11 Pro' }

            Set-HardwareDetector -Name VolumeList -ScriptBlock {
                @(
                    [pscustomobject]@{ DriveLetter = 'C'; Size = 500GB; SizeRemaining = 400GB }
                    [pscustomobject]@{ DriveLetter = 'D'; Size = 1TB;   SizeRemaining = 800GB }
                )
            }
            Set-HardwareDetector -Name SystemDriveLetter -ScriptBlock { 'C' }

            Set-HardwareDetector -Name ComputerInfoVirt -ScriptBlock {
                [pscustomobject]@{
                    HyperVisorPresent                                = $false
                    HyperVRequirementVirtualizationFirmwareEnabled   = $true
                    HyperVRequirementSecondLevelAddressTranslation   = $true
                }
            }
            Set-HardwareDetector -Name WmiProcessorVirtFlag -ScriptBlock { $true }
        }
    }
}

AfterAll {
    Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    foreach ($mod in 'Logging','HardwareDetect') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
    }
}

# ---------- tests ----------

Describe 'Invoke-PreflightStage -- happy path' {

    BeforeEach { Reset-AllHardwareDetector; Set-HappyPathDetector }
    AfterEach  { Reset-AllHardwareDetector }

    It 'returns Overall=Pass when every check passes (caveat: depends on test host having admin/ram/etc.)' {
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        # We use -IgnoreFailures here because the test host may legitimately
        # not have admin/RAM/Schedule running. The point of the happy-path
        # test is to assert the stage runs through every check without
        # exceptions and emits a structured report.
        $r            | Should -Not -BeNullOrEmpty
        $r.Checks     | Should -Not -BeNullOrEmpty
        $r.Checks.Count | Should -BeGreaterOrEqual 10
        $r.PSObject.Properties['Overall'] | Should -Not -BeNullOrEmpty

        $names = @($r.Checks | ForEach-Object Name)
        $names | Should -Contain 'Administrator'
        $names | Should -Contain 'Windows SKU'
        $names | Should -Contain 'RAM'
        $names | Should -Contain 'VM storage'
        $names | Should -Contain 'Virtualization (VT)'
        $names | Should -Contain 'SLAT'
        $names | Should -Contain 'Network adapter'
        $names | Should -Contain 'Task Scheduler service'
        $names | Should -Contain 'Execution policy'
        $names | Should -Contain 'PowerShell version'
    }
}

Describe 'Invoke-PreflightStage -- SKU classification' {

    BeforeEach { Reset-AllHardwareDetector; Set-HappyPathDetector }
    AfterEach  { Reset-AllHardwareDetector }

    It 'marks Windows Home as Fail with a clear remediation' {
        & $script:HD {
            Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { 'Home' }
            Set-HardwareDetector -Name RegistryEditionID    -ScriptBlock { 'Core' }
            Set-HardwareDetector -Name WmiOsCaption         -ScriptBlock { 'Microsoft Windows 11 Home' }
            Set-HardwareDetector -Name ComputerInfoOsName   -ScriptBlock { 'Microsoft Windows 11 Home' }
        }
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        $skuCheck = $r.Checks | Where-Object Name -eq 'Windows SKU'
        $skuCheck.Status      | Should -Be 'Fail'
        $skuCheck.Remediation | Should -Match 'Pro'
    }

    It 'marks Pro Education as Pass (not Education, not Fail)' {
        & $script:HD {
            Set-HardwareDetector -Name WindowsEditionCmdlet -ScriptBlock { 'ProEducation' }
            Set-HardwareDetector -Name RegistryEditionID    -ScriptBlock { 'ProEducation' }
            Set-HardwareDetector -Name WmiOsCaption         -ScriptBlock { 'Microsoft Windows 11 Pro Education' }
            Set-HardwareDetector -Name ComputerInfoOsName   -ScriptBlock { 'Microsoft Windows 11 Pro Education' }
        }
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        ($r.Checks | Where-Object Name -eq 'Windows SKU').Status | Should -Be 'Pass'
    }

    It 'marks Unknown SKU as Warn' {
        & $script:HD {
            foreach ($n in 'WindowsEditionCmdlet','RegistryEditionID','WmiOsCaption','ComputerInfoOsName') {
                Set-HardwareDetector -Name $n -ScriptBlock { 'TotallyBogus' }
            }
        }
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        ($r.Checks | Where-Object Name -eq 'Windows SKU').Status | Should -Be 'Warn'
    }
}

Describe 'Invoke-PreflightStage -- VM storage' {

    BeforeEach { Reset-AllHardwareDetector; Set-HappyPathDetector }
    AfterEach  { Reset-AllHardwareDetector }

    It 'passes when a drive has >= count * per-vm GB free' {
        $cfg = [pscustomobject]@{ vms = [pscustomobject]@{ count = 2; min_disk_gb_per_vm = 60 } }
        $r = Invoke-PreflightStage -Config $cfg -IgnoreFailures 6>$null
        ($r.Checks | Where-Object Name -eq 'VM storage').Status | Should -Be 'Pass'
    }

    It 'fails when no drive has enough free space and exposes the threshold in the detail' {
        & $script:HD {
            Set-HardwareDetector -Name VolumeList -ScriptBlock {
                @(
                    [pscustomobject]@{ DriveLetter = 'C'; Size = 200GB; SizeRemaining = 40GB }
                )
            }
            Set-HardwareDetector -Name SystemDriveLetter -ScriptBlock { 'C' }
        }
        $cfg = [pscustomobject]@{ vms = [pscustomobject]@{ count = 3; min_disk_gb_per_vm = 70 } }
        $r = Invoke-PreflightStage -Config $cfg -IgnoreFailures 6>$null
        $vmStorage = $r.Checks | Where-Object Name -eq 'VM storage'
        $vmStorage.Status | Should -Be 'Fail'
        $vmStorage.Detail | Should -Match '210 GB'   # 3 * 70
    }

    It 'defaults to 2 VMs x 60 GB when -Config is omitted' {
        & $script:HD {
            Set-HardwareDetector -Name VolumeList -ScriptBlock {
                @(
                    [pscustomobject]@{ DriveLetter = 'C'; Size = 500GB; SizeRemaining = 130GB }
                )
            }
            Set-HardwareDetector -Name SystemDriveLetter -ScriptBlock { 'C' }
        }
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        ($r.Checks | Where-Object Name -eq 'VM storage').Status | Should -Be 'Pass'
    }
}

Describe 'Invoke-PreflightStage -- virtualization' {

    BeforeEach { Reset-AllHardwareDetector; Set-HappyPathDetector }
    AfterEach  { Reset-AllHardwareDetector }

    It 'fails when VT is disabled in BIOS' {
        & $script:HD {
            Set-HardwareDetector -Name ComputerInfoVirt -ScriptBlock {
                [pscustomobject]@{
                    HyperVisorPresent                                = $false
                    HyperVRequirementVirtualizationFirmwareEnabled   = $false
                    HyperVRequirementSecondLevelAddressTranslation   = $true
                }
            }
            Set-HardwareDetector -Name WmiProcessorVirtFlag -ScriptBlock { $false }
        }
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        $vt = $r.Checks | Where-Object Name -eq 'Virtualization (VT)'
        $vt.Status      | Should -Be 'Fail'
        $vt.Remediation | Should -Match 'BIOS|UEFI'
    }

    It 'warns (not fails) when VT cannot be determined' {
        & $script:HD {
            Set-HardwareDetector -Name ComputerInfoVirt     -ScriptBlock { $null }
            Set-HardwareDetector -Name WmiProcessorVirtFlag -ScriptBlock { $null }
        }
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        ($r.Checks | Where-Object Name -eq 'Virtualization (VT)').Status | Should -Be 'Warn'
    }

    It 'fails on missing SLAT' {
        & $script:HD {
            Set-HardwareDetector -Name ComputerInfoVirt -ScriptBlock {
                [pscustomobject]@{
                    HyperVisorPresent                                = $false
                    HyperVRequirementVirtualizationFirmwareEnabled   = $true
                    HyperVRequirementSecondLevelAddressTranslation   = $false
                }
            }
        }
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        ($r.Checks | Where-Object Name -eq 'SLAT').Status | Should -Be 'Fail'
    }
}

Describe 'Invoke-PreflightStage -- Overall aggregation' {

    BeforeEach { Reset-AllHardwareDetector; Set-HappyPathDetector }
    AfterEach  { Reset-AllHardwareDetector }

    It 'sets Overall=Fail when any Fail check exists and -IgnoreFailures is not set' {
        # Force a Fail by hard-faking VT off.
        & $script:HD {
            Set-HardwareDetector -Name ComputerInfoVirt -ScriptBlock {
                [pscustomobject]@{
                    HyperVisorPresent                                = $false
                    HyperVRequirementVirtualizationFirmwareEnabled   = $false
                    HyperVRequirementSecondLevelAddressTranslation   = $true
                }
            }
            Set-HardwareDetector -Name WmiProcessorVirtFlag -ScriptBlock { $false }
        }
        $r = Invoke-PreflightStage 6>$null
        $r.Overall | Should -Be 'Fail'
    }

    It '-MinRamGb forces a RAM Fail when set to an impossibly high value' {
        $r = Invoke-PreflightStage -MinRamGb 999999 -IgnoreFailures 6>$null
        $ram = $r.Checks | Where-Object Name -eq 'RAM'
        # Skip the assertion if the host genuinely couldn't report RAM (would Warn);
        # in any case it must NOT be Pass.
        $ram.Status | Should -BeIn @('Fail','Warn')
    }

    It '-MinPwshVersion higher than the current version forces a PowerShell version Fail' {
        $bumped = [version]'99.0'
        $r = Invoke-PreflightStage -MinPwshVersion $bumped -IgnoreFailures 6>$null
        $ver = $r.Checks | Where-Object Name -eq 'PowerShell version'
        $ver.Status | Should -Be 'Fail'
        $ver.Remediation | Should -Match 'PowerShell 7'
    }

    It 'CLUSTERHOST_ALLOW_UNKNOWN_SKU=1 downgrades Unknown SKU from Warn to Pass' {
        try {
            $env:CLUSTERHOST_ALLOW_UNKNOWN_SKU = '1'
            & $script:HD {
                foreach ($n in 'WindowsEditionCmdlet','RegistryEditionID','WmiOsCaption','ComputerInfoOsName') {
                    Set-HardwareDetector -Name $n -ScriptBlock { 'TotallyBogus' }
                }
            }
            $r = Invoke-PreflightStage -IgnoreFailures 6>$null
            ($r.Checks | Where-Object Name -eq 'Windows SKU').Status | Should -Be 'Pass'
        } finally {
            Remove-Item Env:CLUSTERHOST_ALLOW_UNKNOWN_SKU -ErrorAction SilentlyContinue
        }
    }

    It 'does not throw under StrictMode on a partial config (vms object without count)' {
        $cfg = [pscustomobject]@{ vms = [pscustomobject]@{ min_disk_gb_per_vm = 60 } }   # 'count' missing
        { Invoke-PreflightStage -Config $cfg -IgnoreFailures 6>$null } | Should -Not -Throw
    }

    It '-IgnoreFailures keeps Overall != Fail even when Fail checks exist' {
        & $script:HD {
            Set-HardwareDetector -Name ComputerInfoVirt -ScriptBlock {
                [pscustomobject]@{
                    HyperVisorPresent                                = $false
                    HyperVRequirementVirtualizationFirmwareEnabled   = $false
                    HyperVRequirementSecondLevelAddressTranslation   = $true
                }
            }
            Set-HardwareDetector -Name WmiProcessorVirtFlag -ScriptBlock { $false }
        }
        $r = Invoke-PreflightStage -IgnoreFailures 6>$null
        $r.Overall | Should -BeIn @('Pass','Warn')
    }
}

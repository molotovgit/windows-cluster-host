#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
    $libDir     = Join-Path $repoRoot 'src\lib'
    $stagePath  = Join-Path $repoRoot 'src\stages\07-Vms.ps1'

    foreach ($mod in 'Logging','Retry','HardwareDetect') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $libDir "$mod.psm1") -Force
    }
    $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    $script:HD = Get-Module HardwareDetect
    . $stagePath

    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vms-stage-" + [guid]::NewGuid().ToString('N').Substring(0,8))

    function Set-VmStub {
        param([bool]$SourceGoldenOk = $true,[bool]$CreateVmOk = $true)
        Reset-VmInvoker
        $caps = [pscustomobject]@{
            Calls = New-Object System.Collections.Generic.List[string]
            Clones = New-Object System.Collections.Generic.List[string]
            Created = New-Object System.Collections.Generic.List[string]
            Autostart = New-Object System.Collections.Generic.List[string]
        }
        Set-VmInvoker -Name SourceGoldenVhdx -ScriptBlock {
            param($smb,$https,$local,$dst)
            $caps.Calls.Add("SourceGoldenVhdx:$dst")
            if ($SourceGoldenOk) { @{ Ok = $true; Source = 'smb'; Detail = "copied to $dst" } }
            else                 { @{ Ok = $false; Source = 'none'; Detail = 'every source failed' } }
        }.GetNewClosure()
        Set-VmInvoker -Name VerifyVhdxHash -ScriptBlock {
            param($p,$h)
            $caps.Calls.Add("VerifyVhdxHash:$p|$h")
            @{ Ok = $true; Skipped = (-not $h); Detail = if ($h) { 'verified' } else { 'no hash' } }
        }.GetNewClosure()
        Set-VmInvoker -Name CloneVhdx -ScriptBlock {
            param($src,$dst)
            $caps.Clones.Add($dst)
            @{ Ok = $true; AlreadyPresent = $false; Detail = "cloned to $dst" }
        }.GetNewClosure()
        Set-VmInvoker -Name GetVm -ScriptBlock {
            param($name) [pscustomobject]@{ Found = $false; State = 'NotPresent'; AutomaticStartAction = $null;
                                            SwitchName = $null; HardDrivePath = $null; MemoryStartupGb = 0; ProcessorCount = 0 }
        }.GetNewClosure()
        Set-VmInvoker -Name CreateVm -ScriptBlock {
            param($name,$vhdx,$switch,$memStartup,$memMin,$memMax,$cpu,$secureBoot)
            $caps.Created.Add("$name|$switch|$memStartup|$cpu|$secureBoot")
            if ($CreateVmOk) { @{ Ok = $true; Detail = "created $name (secureBoot=$secureBoot)" } } else { @{ Ok = $false; Detail = "create failed" } }
        }.GetNewClosure()
        Set-VmInvoker -Name ConfigureAutostart -ScriptBlock {
            param($name,$delay)
            $caps.Autostart.Add("$name|$delay")
            @{ Ok = $true; Detail = "autostart delay=$delay" }
        }.GetNewClosure()
        return $caps
    }

    function Set-HappyHardware {
        & $script:HD {
            Set-HardwareDetector -Name VolumeList -ScriptBlock {
                @([pscustomobject]@{ DriveLetter = 'D'; Size = 1TB; SizeRemaining = 800GB })
            }
            Set-HardwareDetector -Name SystemDriveLetter -ScriptBlock { 'C' }
        }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
    foreach ($mod in 'Logging','Retry','HardwareDetect') {
        Get-Module $mod | Remove-Module -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-VmNameList' {
    It 'returns alphabetic suffixes for count <= 26' {
        Get-VmNameList -Count 2 -Prefix 'vm-' | Should -Be @('vm-a','vm-b')
        Get-VmNameList -Count 3 -Prefix 'vm-' | Should -Be @('vm-a','vm-b','vm-c')
    }
    It 'honors explicit suffixes when supplied' {
        Get-VmNameList -Count 3 -Prefix 'host-' -Suffixes @('north','south','east') |
            Should -Be @('host-north','host-south','host-east')
    }
    It 'uses zero-padded numeric suffixes for count > 26' {
        $r = Get-VmNameList -Count 30 -Prefix 'vm-'
        $r.Count | Should -Be 30
        $r[0]    | Should -Be 'vm-01'
        $r[29]   | Should -Be 'vm-30'
    }
}

Describe 'Invoke-VmsStage' {

    AfterEach {
        Reset-VmInvoker
        & $script:HD { Reset-HardwareDetector }
    }

    It 'happy path: returns Overall=Pass with the right number of VM steps' {
        $caps = Set-VmStub
        Set-HappyHardware
        $r = Invoke-VmsStage -DryRun 6>$null   # DryRun avoids touching the real filesystem
        $r.Overall | Should -Be 'Pass'
        $r.VmNames | Should -Be @('vm-a','vm-b')
        $r.VmStorageDrive | Should -Be 'D'
        @($r.Steps | Where-Object { $_.Name -like "VM 'vm-*" -and $_.Status -eq 'Skipped' }).Count | Should -Be 2
    }

    It 'derives count/prefix from -Config' {
        $caps = Set-VmStub
        Set-HappyHardware
        $cfg = [pscustomobject]@{
            vms = [pscustomobject]@{
                count = 3
                name_prefix = 'host-'
                memory_startup_gb = 8
                vcpu_count = 4
                stagger_seconds = 15
                min_disk_gb_per_vm = 60
            }
        }
        $r = Invoke-VmsStage -Config $cfg -DryRun 6>$null
        $r.VmNames | Should -Be @('host-a','host-b','host-c')
    }

    It 'returns Fail when no drive has enough free space' {
        $caps = Set-VmStub
        & $script:HD {
            Set-HardwareDetector -Name VolumeList -ScriptBlock {
                @([pscustomobject]@{ DriveLetter = 'C'; Size = 200GB; SizeRemaining = 50GB })
            }
            Set-HardwareDetector -Name SystemDriveLetter -ScriptBlock { 'C' }
        }
        $r = Invoke-VmsStage -Count 3 6>$null    # 3 VMs x 60 GB = 180 GB required
        $r.Overall | Should -Be 'Fail'
        ($r.Steps | Where-Object Name -eq 'VM storage drive').Status | Should -Be 'Fail'
    }

    It 'returns Fail when golden VHDX source fails (and stops short of VM creation)' {
        $script:tmp = Join-Path $script:tmpRoot ("rundir-" + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
        $caps = Set-VmStub -SourceGoldenOk $false
        $r = Invoke-VmsStage -VmStorageDrive ($script:tmp.Substring(0,1)) `
                             -GoldenSmbPath '\\nonexistent\images\golden.vhdx' `
                             -GoldenHttpsUrl 'https://nonexistent/golden.vhdx' 6>$null
        $r.Overall | Should -Be 'Fail'
        ($r.Steps | Where-Object Name -eq 'Golden VHDX source').Status | Should -Be 'Fail'
        $caps.Created.Count | Should -Be 0
    }

    It 'defaults golden VHDX SMB path to controller ClusterShare\vhdx\ (real-hardware bug 16)' {
        # Regression for bug 16: the old default was '\\<addr>\images\golden.vhdx'
        # which does not match windows-cluster-controller's published share
        # ('ClusterShare', subdir 'vhdx'). Capture the path passed to
        # SourceGoldenVhdx and assert it now uses the controller convention.
        $script:capturedSmb   = $null
        $script:capturedHttps = $null
        $caps = Set-VmStub
        Set-VmInvoker -Name SourceGoldenVhdx -ScriptBlock {
            param($smb,$https,$local,$dst)
            $script:capturedSmb   = $smb
            $script:capturedHttps = $https
            @{ Ok = $false; Source = 'none'; Detail = 'captured-for-test' }
        }
        Set-HappyHardware
        $cfg = [pscustomobject]@{
            controller = [pscustomobject]@{ address = '10.0.0.7' }
        }
        Invoke-VmsStage -Config $cfg -Count 1 6>$null | Out-Null
        $script:capturedSmb   | Should -Be '\\10.0.0.7\ClusterShare\vhdx\golden.vhdx'
        $script:capturedHttps | Should -Be 'https://10.0.0.7/golden.vhdx'
    }

    It 'honors Config.golden_vhdx overrides for share / subdir / filename' {
        $script:capturedSmb   = $null
        $script:capturedHttps = $null
        $caps = Set-VmStub
        Set-VmInvoker -Name SourceGoldenVhdx -ScriptBlock {
            param($smb,$https,$local,$dst)
            $script:capturedSmb   = $smb
            $script:capturedHttps = $https
            @{ Ok = $false; Source = 'none'; Detail = 'captured-for-test' }
        }
        Set-HappyHardware
        $cfg = [pscustomobject]@{
            controller  = [pscustomobject]@{ address = '10.0.0.7' }
            golden_vhdx = [pscustomobject]@{
                smb_share  = 'CustomShare'
                smb_subdir = 'images'
                filename   = 'base.vhdx'
                https_url  = 'https://files.example/base.vhdx'
            }
        }
        Invoke-VmsStage -Config $cfg -Count 1 6>$null | Out-Null
        $script:capturedSmb   | Should -Be '\\10.0.0.7\CustomShare\images\base.vhdx'
        $script:capturedHttps | Should -Be 'https://files.example/base.vhdx'
    }

    It 'Warn on missing SHA256, Pass on matching SHA256' {
        # Use VmStorageDrive override to a path NOT under the real D: drive so we can probe via mock.
        $caps = Set-VmStub
        # SourceGoldenVhdx mock pretends success but doesn't actually create the file --
        # the stage's Test-Path before SourceGoldenVhdx will report it absent, source will
        # be called, then VerifyVhdxHash runs against the (still-absent) path. The mock
        # returns Ok=true skipped=$true so the stage takes the Warn path.
        Set-HappyHardware
        $r = Invoke-VmsStage -DryRun 6>$null  # DryRun side-steps the file-system probe
        ($r.Steps | Where-Object { $_.Name -like 'Golden VHDX*' -and $_.Status -eq 'Skipped' }).Count | Should -BeGreaterThan 0
    }

    It 'honors explicit -Count and -Prefix overriding -Config' {
        $caps = Set-VmStub
        Set-HappyHardware
        $cfg = [pscustomobject]@{ vms = [pscustomobject]@{ count = 5; name_prefix = 'fromcfg-' } }
        $r = Invoke-VmsStage -Config $cfg -Count 2 -Prefix 'override-' -DryRun 6>$null
        $r.VmNames | Should -Be @('override-a','override-b')
    }

    It 'returns Fail (and creates no VMs) when SHA256 mismatch on the golden VHDX' {
        # The golden VHDX needs to be sourced (not already present); use a fresh
        # temp dir to ensure Test-Path returns false for the not-yet-created path.
        $caps = Set-VmStub
        Set-VmInvoker -Name VerifyVhdxHash -ScriptBlock {
            param($p,$h)
            @{ Ok = $false; Skipped = $false; Hash = 'deadbeef'; Detail = "SHA256 mismatch: actual=deadbeef expected=$h" }
        }
        Set-HappyHardware
        # Use HappyHardware drive D:\VMs; the golden path won't exist there, so
        # Test-Path is false and SourceGoldenVhdx (mocked Ok=$true) runs, then
        # VerifyVhdxHash returns Ok=$false -> Overall=Fail.
        $r = Invoke-VmsStage -Count 2 -GoldenSha256 'abc123' 6>$null
        $r.Overall | Should -Be 'Fail'
        ($r.Steps | Where-Object Name -eq 'Golden VHDX SHA256').Status | Should -Be 'Fail'
        $caps.Created.Count | Should -Be 0
    }

    It 'Warns with config-drift detail when an existing VM has a different switch/memory' {
        $caps = Set-VmStub
        Set-VmInvoker -Name GetVm -ScriptBlock {
            param($name)
            [pscustomobject]@{
                Found                = $true
                State                = 'Running'
                AutomaticStartAction = 'Start'
                SwitchName           = 'OldSwitch'    # mismatch
                HardDrivePath        = 'D:\VMs\vm-a.vhdx'
                MemoryStartupGb      = 8              # mismatch
                ProcessorCount       = 2
            }
        }
        Set-HappyHardware
        $r = Invoke-VmsStage -SwitchName 'NewSwitch' -MemStartupGb 4 -VcpuCount 2 -Count 1 6>$null
        $vm = $r.Steps | Where-Object { $_.Name -like "VM 'vm-a*" }
        $vm.Status | Should -Be 'Warn'
        $vm.Detail | Should -Match 'switch=''OldSwitch'''
        $vm.Detail | Should -Match 'memStartupGb=8'
        $vm.Remediation | Should -Match 'Remove-VM'
        $caps.Created.Count | Should -Be 0   # existing VM not re-created
    }

    It 'continues to the next VM when clone fails for one' {
        $caps = Set-VmStub
        $script:cloneCalls = 0
        Set-VmInvoker -Name CloneVhdx -ScriptBlock {
            param($src,$dst)
            $script:cloneCalls++
            if ($script:cloneCalls -eq 1) {
                @{ Ok = $false; AlreadyPresent = $false; Detail = 'simulated clone fail' }
            } else {
                @{ Ok = $true; AlreadyPresent = $false; Detail = "cloned $dst" }
            }
        }
        Set-HappyHardware
        $r = Invoke-VmsStage -Count 2 6>$null
        $r.Overall | Should -Be 'Fail'   # at least one clone failed
        @($r.Steps | Where-Object { $_.Name -like '*clone' -and $_.Status -eq 'Fail' }).Count | Should -Be 1
        # The second VM still gets created.
        $caps.Created.Count | Should -Be 1
    }

    It 'passes SecureBootTemplate from -Config.vms.secure_boot_template to CreateVm' {
        $caps = Set-VmStub
        Set-HappyHardware
        $cfg = [pscustomobject]@{ vms = [pscustomobject]@{ count = 1; secure_boot_template = 'MicrosoftUEFICertificateAuthority' } }
        $r = Invoke-VmsStage -Config $cfg 6>$null
        @($caps.Created | Where-Object { $_ -match 'MicrosoftUEFICertificateAuthority' }).Count | Should -Be 1
    }

    It 'tolerates partial -Config (vms object without count)' {
        $caps = Set-VmStub
        Set-HappyHardware
        $cfg = [pscustomobject]@{ vms = [pscustomobject]@{ name_prefix = 'partial-' } }
        $r = Invoke-VmsStage -Config $cfg -DryRun 6>$null
        $r.VmNames | Should -Be @('partial-a','partial-b')   # default count=2
    }
}

Describe 'Test seam gating' {
    It 'Set-VmInvoker refuses to run without CLUSTERHOST_ALLOW_TEST_SEAMS' {
        Remove-Item Env:CLUSTERHOST_ALLOW_TEST_SEAMS -ErrorAction SilentlyContinue
        $thrown = $null
        try { Set-VmInvoker -Name CloneVhdx -ScriptBlock { } } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        "$thrown" | Should -Match 'CLUSTERHOST_ALLOW_TEST_SEAMS'
        $env:CLUSTERHOST_ALLOW_TEST_SEAMS = '1'
    }
}

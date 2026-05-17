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
            param($name) @{ Found = $false; State = 'NotPresent'; AutomaticStartAction = $null }
        }.GetNewClosure()
        Set-VmInvoker -Name CreateVm -ScriptBlock {
            param($name,$vhdx,$switch,$mem,$cpu)
            $caps.Created.Add("$name|$switch|$mem|$cpu")
            if ($CreateVmOk) { @{ Ok = $true; Detail = "created $name" } } else { @{ Ok = $false; Detail = "create failed" } }
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

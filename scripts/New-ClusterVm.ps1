<#
.SYNOPSIS
    Clone the prepared golden VHDX into one or more new cluster VMs.

.DESCRIPTION
    Companion to Prepare-GoldenVhdx.ps1. Where the prep script bakes
    the firstboot bootstrap into a golden image, this script consumes
    that image to mint operational VMs on a host PC. It:

      1. Validates Hyper-V tooling, the configured switch, and the
         golden VHDX are present.
      2. For each requested name, refuses to overwrite an existing VM
         or VHDX (call with -Force to take both down first).
      3. Clones the golden to <StoragePath>\<Name>.vhdx.
      4. Creates a Gen 2 VM with secure boot intact, attaches the new
         VHDX, hooks it to the cluster NAT switch.
      5. Disables automatic checkpoints (the .avhdx that Hyper-V
         creates by default locks the parent VHDX from later cloning;
         this is real-hardware bug-22-territory and we don't want
         operators to relearn it).
      6. Sets AutomaticStartAction so the VM survives a host reboot.
      7. Starts the VM.

    The new VM auto-configures itself via the firstboot script baked
    into the golden image (see Prepare-GoldenVhdx.ps1). Expect it to
    appear in MeshCentral under whichever device group the golden was
    prepped for (cluster-vms by default) within ~2-3 minutes.

.PARAMETER Name
    One or more VM names. Use `vm-c`, `vm-d`, etc. Hyper-V will
    refuse names with reserved characters; this script doesn't
    re-validate that.

.PARAMETER GoldenVhdx
    Source VHDX. Default 'C:\VMs\golden.vhdx'.

.PARAMETER StoragePath
    Directory that holds per-VM VHDX files. Default 'C:\VMs'.

.PARAMETER MemoryStartupGB
    Startup RAM in GB. Default 4.

.PARAMETER VCpuCount
    Virtual processor count. Default 2.

.PARAMETER Switch
    Hyper-V virtual switch to attach. Default 'ClusterNATSwitch'.

.PARAMETER AutomaticStartDelay
    Seconds to wait at host boot before starting THIS VM. Use to
    stagger startup (e.g. 0 for the first VM, 30 for the second).
    Default 30 to avoid all VMs racing for resources at host boot.

.PARAMETER Force
    Delete any existing VM and VHDX with the same name(s) before
    cloning. Off by default to protect the operator from typos.

.EXAMPLE
    .\New-ClusterVm.ps1 -Name vm-c
    # Quick path: one VM, defaults everywhere.

.EXAMPLE
    .\New-ClusterVm.ps1 -Name vm-c,vm-d,vm-e -MemoryStartupGB 8
    # Batch: three VMs at 8 GB each. Staggered starts 30s apart.

.NOTES
    Must run elevated. Hyper-V cmdlets require admin.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string[]]$Name,
    [string]$GoldenVhdx          = 'C:\VMs\golden.vhdx',
    [string]$StoragePath         = 'C:\VMs',
    [int]$MemoryStartupGB        = 4,
    [int]$VCpuCount              = 2,
    [string]$Switch              = 'ClusterNATSwitch',
    [int]$AutomaticStartDelay    = 30,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [System.Security.Principal.WindowsPrincipal]::new($id)
    if (-not $pr.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw 'New-ClusterVm.ps1 must run as Administrator (Hyper-V cmdlets require it).'
    }
}

# ---------- Preflight ----------
Assert-Admin

if (-not (Get-Command -Name New-VM -ErrorAction SilentlyContinue)) {
    throw "Hyper-V PowerShell module not available. Install via 'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell'."
}
if (-not (Test-Path -LiteralPath $GoldenVhdx)) {
    throw "Golden VHDX not found at '$GoldenVhdx'. Run Prepare-GoldenVhdx.ps1 first or pass -GoldenVhdx explicitly."
}
if (-not (Get-VMSwitch -Name $Switch -ErrorAction SilentlyContinue)) {
    throw "VMSwitch '$Switch' not found. Stage 5 (Network) of the host setup creates ClusterNATSwitch; re-run install.ps1 or pass -Switch."
}
if (-not (Test-Path -LiteralPath $StoragePath)) {
    New-Item -Path $StoragePath -ItemType Directory -Force | Out-Null
}

# ---------- Per-VM mint loop ----------
$summary = @()
foreach ($vmName in $Name) {
    Write-Host ""
    Write-Host "=== $vmName ===" -ForegroundColor Cyan

    $vhdxOut = Join-Path $StoragePath "$vmName.vhdx"

    $existingVm   = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    $existingDisk = Test-Path -LiteralPath $vhdxOut

    if ($existingVm -or $existingDisk) {
        if (-not $Force) {
            $what = @()
            if ($existingVm)   { $what += "VM '$vmName'" }
            if ($existingDisk) { $what += "VHDX '$vhdxOut'" }
            throw ("Already exists: " + ($what -join ' and ') + ". Re-run with -Force to delete first.")
        }
        if ($existingVm) {
            Write-Host "  -Force: stopping and removing existing VM" -ForegroundColor Yellow
            Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
            Remove-VM -Name $vmName -Force -ErrorAction Stop
        }
        if ($existingDisk) {
            Write-Host "  -Force: deleting existing VHDX" -ForegroundColor Yellow
            Remove-Item -LiteralPath $vhdxOut -Force -ErrorAction Stop
        }
    }

    # Clone (file copy; ~45 GB on local SSD = ~2-5 minutes)
    $t0 = Get-Date
    Write-Host "  cloning golden -> $vhdxOut"
    Copy-Item -LiteralPath $GoldenVhdx -Destination $vhdxOut
    $elapsed = (Get-Date) - $t0
    $sizeGB  = [math]::Round((Get-Item -LiteralPath $vhdxOut).Length / 1GB, 1)
    Write-Host ("    {0:N1} GB in {1:N1}s ({2:N0} MB/s)" -f $sizeGB, $elapsed.TotalSeconds, (($sizeGB * 1024) / [math]::Max($elapsed.TotalSeconds, 0.1)))

    # Create the VM
    Write-Host "  creating Gen 2 VM, ${MemoryStartupGB} GB RAM, $VCpuCount vCPU, switch '$Switch'"
    New-VM -Name $vmName `
           -MemoryStartupBytes ($MemoryStartupGB * 1GB) `
           -Generation 2 `
           -VHDPath $vhdxOut `
           -SwitchName $Switch | Out-Null

    Set-VMProcessor -VMName $vmName -Count $VCpuCount

    # Auto-checkpoints break later cloning of any disk that's ever been a parent.
    Set-VM -Name $vmName -AutomaticCheckpointsEnabled $false

    Set-VM -Name $vmName -AutomaticStartAction Start -AutomaticStartDelay $AutomaticStartDelay

    Write-Host "  starting $vmName"
    Start-VM -Name $vmName

    $summary += [pscustomobject]@{
        Name        = $vmName
        VhdxPath    = $vhdxOut
        MemoryGB    = $MemoryStartupGB
        VCpu        = $VCpuCount
        StartDelayS = $AutomaticStartDelay
        State       = (Get-VM -Name $vmName).State
    }
}

Write-Host ""
Write-Host "All requested VMs minted:" -ForegroundColor Green
$summary | Format-Table -AutoSize | Out-String | Write-Host

Write-Host "Expect each VM to appear in MeshCentral within ~2-3 minutes (firstboot timing)." -ForegroundColor Green
Write-Host "Verify with: meshctrl ListDevices --group <whichever-group-the-golden-was-prepped-for>" -ForegroundColor DarkGray

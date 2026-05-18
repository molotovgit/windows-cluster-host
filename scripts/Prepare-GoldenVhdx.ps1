<#
.SYNOPSIS
    Bake cluster-bootstrap files into a golden VHDX so that VMs cloned
    from it auto-configure themselves on first boot (static IP, known
    admin account, MeshAgent install pointed at our controller).

.DESCRIPTION
    Runs on a Windows machine with Hyper-V tools installed (or just
    Mount-VHD, which is part of the Hyper-V PowerShell module). Takes
    a -VhdxPath, an offline copy of the golden, plus parameters that
    parameterize the firstboot script (controller address/port, admin
    password, MeshAgent installer path). Mounts the VHDX, drops:

      C:\Setup\cluster-vm-firstboot.ps1     (the bootstrap logic; this
                                             script is loaded from a
                                             sibling file and has its
                                             '__*_PLACEHOLDER__' tokens
                                             substituted)
      C:\Setup\meshagent64-<group>.exe      (the MeshAgent installer
                                             that the bootstrap runs)
      C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\
        cluster-firstboot-launcher.cmd      (Startup-folder entry that
                                             fires at first user login;
                                             schedules + runs the
                                             SYSTEM-context bootstrap
                                             task)

    Bug 22 (no DHCP on NAT switch): the bootstrap script assigns a
    deterministic static IPv4 inside 192.168.100.0/24 from the VM's
    name read via Hyper-V KVP. vm-a -> .10, vm-b -> .11, etc.

    Bug 23 (golden VHDX is opaque to the cluster): the prep step bakes
    in our identity (admin user, agent, .msh URL) so VMs join MeshCentral
    the first time they boot, without any operator login.

    Idempotent: re-running on a prepared VHDX overwrites the same files
    in the same locations.

.PARAMETER VhdxPath
    Path to the golden VHDX (e.g. C:\VMs\golden.vhdx). The VHDX must NOT
    be attached to a running VM; mount will fail if it is.

.PARAMETER ControllerAddress
    LAN address the guest VMs reach the cluster controller at, e.g.
    '192.168.1.22'. Baked into the MeshAgent .msh and into the static
    IP gateway computation.

.PARAMETER ControllerPort
    HTTPS / WSS port. Default 443.

.PARAMETER AdminPassword
    Password assigned to the cluster-admin local account inside the VM.
    Required: complexity must satisfy Windows' default policy
    (>=8 chars, upper+lower+digit+symbol).

.PARAMETER MeshAgentInstaller
    Path on THIS machine to the meshagent64-<group>.exe file produced by
    windows-cluster-controller's Stage 10 AgentDownload. Copied into the
    VHDX so VMs don't need network at firstboot time before they get
    their static IP.

.PARAMETER FirstbootScript
    Path to cluster-vm-firstboot.ps1 (default: sibling of this script).

.PARAMETER LauncherScript
    Path to cluster-firstboot-launcher.cmd (default: sibling of this script).

.EXAMPLE
    .\Prepare-GoldenVhdx.ps1 -VhdxPath C:\VMs\golden.vhdx `
        -ControllerAddress 192.168.1.22 `
        -AdminPassword 'Cluster1!Secret' `
        -MeshAgentInstaller '\\192.168.1.22\ClusterShare\agents\cluster-vms\meshagent64-cluster-vms.exe'

.NOTES
    Must run elevated. Mount-VHD requires admin.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VhdxPath,
    [Parameter(Mandatory)][string]$ControllerAddress,
    [int]$ControllerPort = 443,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$MeshAgentInstaller,
    [string]$FirstbootScript = (Join-Path $PSScriptRoot 'cluster-vm-firstboot.ps1'),
    [string]$LauncherScript  = (Join-Path $PSScriptRoot 'cluster-firstboot-launcher.cmd')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [System.Security.Principal.WindowsPrincipal]::new($id)
    if (-not $pr.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw "Prepare-GoldenVhdx.ps1 must run as Administrator (Mount-VHD requires it)."
    }
}

function Resolve-WindowsVolume {
    param([Parameter(Mandatory)]$Disk)
    # Find the partition with a Windows install. Some disks expose multiple
    # partitions (EFI / MSR / Windows / Recovery); we want the one whose
    # mounted drive letter has \Windows\System32 in its root.
    $partitions = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue)
    Write-Host ("  found {0} partition(s) on disk #{1}" -f $partitions.Count, $Disk.Number)
    foreach ($p in $partitions) {
        $letter = $p.DriveLetter
        $size   = [math]::Round($p.Size / 1GB, 1)
        Write-Host ("    PartitionNumber=$($p.PartitionNumber)  DriveLetter='$letter'  Size=${size} GB  Type=$($p.Type)")
        if (-not $letter -or $letter -eq 0 -or $letter -eq [char]0) { continue }
        $candidate = "${letter}:\Windows\System32"
        if (Test-Path -LiteralPath $candidate) {
            Write-Host "    -> Windows partition confirmed at ${letter}:" -ForegroundColor Green
            return $p
        }
    }
    return $null
}

# ---------- Validate inputs ----------
Assert-Admin
foreach ($req in $VhdxPath, $FirstbootScript, $LauncherScript, $MeshAgentInstaller) {
    if (-not (Test-Path -LiteralPath $req)) {
        throw "Required file not found: $req"
    }
}
if ($AdminPassword.Length -lt 8) { throw "AdminPassword too short (need >=8 chars to satisfy Windows complexity policy)." }

# ---------- Read + substitute firstboot script ----------
$rawFirst = Get-Content -LiteralPath $FirstbootScript -Raw
$rawFirst = $rawFirst.Replace('__ADMIN_PASS_PLACEHOLDER__', $AdminPassword)
$rawFirst = $rawFirst.Replace('__CONTROLLER_ADDR_PLACEHOLDER__', $ControllerAddress)
$rawFirst = $rawFirst.Replace('__CONTROLLER_PORT_PLACEHOLDER__', "$ControllerPort")
if ($rawFirst -match 'PLACEHOLDER__') {
    throw "Firstboot script still contains unsubstituted PLACEHOLDER tokens after rewrite."
}

# ---------- Mount the VHDX ----------
Write-Host "Mounting $VhdxPath ..." -ForegroundColor Cyan
$disk = Mount-VHD -Path $VhdxPath -Passthru -ErrorAction Stop | Get-Disk
try {
    $part = Resolve-WindowsVolume -Disk $disk
    if (-not $part) {
        throw "Could not locate a Windows partition on $VhdxPath after mount."
    }
    $drive = "$($part.DriveLetter):"
    Write-Host "Mounted Windows partition at $drive" -ForegroundColor Green

    # ---------- Drop firstboot files ----------
    # We use Group Policy STARTUP scripts (not the All-Users Startup folder)
    # because the latter runs in the User's auto-logon session, which has a
    # UAC-stripped token; `schtasks /create /ru SYSTEM` from that context
    # silently fails. GP startup scripts run as SYSTEM at machine boot,
    # BEFORE any user logon — exactly what we need.
    $setupDir       = Join-Path $drive 'Setup'
    $gpRoot         = Join-Path $drive 'Windows\System32\GroupPolicy'
    $gpMachineDir   = Join-Path $gpRoot 'Machine'
    $gpScriptsDir   = Join-Path $gpMachineDir 'Scripts'
    $gpStartupDir   = Join-Path $gpScriptsDir 'Startup'
    foreach ($d in $setupDir, $gpRoot, $gpMachineDir, $gpScriptsDir, $gpStartupDir) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -Path $d -ItemType Directory -Force | Out-Null
        }
    }

    # The actual firstboot PowerShell script (stays under C:\Setup\).
    $firstbootInVhdx = Join-Path $setupDir 'cluster-vm-firstboot.ps1'
    [System.IO.File]::WriteAllText($firstbootInVhdx, $rawFirst, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  wrote $firstbootInVhdx"

    # The GP startup script: a one-line .cmd that launches the .ps1.
    $gpStartupCmd = Join-Path $gpStartupDir 'cluster-firstboot.cmd'
    $gpCmdBody = @'
@echo off
REM Triggered by Local Group Policy Computer Configuration > Windows
REM Settings > Scripts (Startup). Runs as NT AUTHORITY\SYSTEM at every
REM machine boot; cluster-vm-firstboot.ps1 self-gates on a marker file
REM so it only does real work the first time.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Setup\cluster-vm-firstboot.ps1 >>C:\Windows\Setup\cluster-firstboot-launcher.log 2>&1
'@
    [System.IO.File]::WriteAllText($gpStartupCmd, $gpCmdBody, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  wrote $gpStartupCmd"

    # scripts.ini — tells the Group Policy engine which scripts to run.
    $scriptsIni = Join-Path $gpScriptsDir 'scripts.ini'
    $scriptsIniBody = @'
[Startup]
0CmdLine=cluster-firstboot.cmd
0Parameters=
'@
    # scripts.ini must be UTF-16 LE with BOM for the GP engine to parse it.
    [System.IO.File]::WriteAllText($scriptsIni, $scriptsIniBody, [System.Text.UnicodeEncoding]::new($false, $true))
    Write-Host "  wrote $scriptsIni"

    # gpt.ini — registers the machine-policy extension for Scripts CSE so
    # the GP engine actually processes scripts.ini on first boot.
    # gPCMachineExtensionNames: {42B5FAAE-6536-11D2-AE5A-0000F87571E3} is
    # the Scripts client-side extension; {40B6664F-4972-11D1-A7CA-0000F87571E3}
    # is the userenv/processing GUID.
    $gptIni = Join-Path $gpRoot 'gpt.ini'
    $gptIniBody = @'
[General]
gPCMachineExtensionNames=[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]
Version=65539
'@
    [System.IO.File]::WriteAllText($gptIni, $gptIniBody, [System.Text.UnicodeEncoding]::new($false, $true))
    Write-Host "  wrote $gptIni"

    # The MeshAgent installer ships next to the firstboot script.
    $agentInVhdx = Join-Path $setupDir ([System.IO.Path]::GetFileName($MeshAgentInstaller))
    Copy-Item -LiteralPath $MeshAgentInstaller -Destination $agentInVhdx -Force
    $agentSize = (Get-Item -LiteralPath $agentInVhdx).Length
    Write-Host ("  wrote $agentInVhdx ({0:N0} bytes)" -f $agentSize)

    # Clean up any stale launcher in the old (StartUp folder) location.
    $oldStartupDir = Join-Path $drive 'ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp'
    $oldLauncher   = Join-Path $oldStartupDir 'cluster-firstboot-launcher.cmd'
    if (Test-Path -LiteralPath $oldLauncher) {
        Remove-Item -LiteralPath $oldLauncher -Force -ErrorAction SilentlyContinue
        Write-Host "  removed stale $oldLauncher"
    }

    Write-Host "Bootstrap files staged into VHDX." -ForegroundColor Green
} finally {
    Write-Host "Dismounting $VhdxPath ..." -ForegroundColor Cyan
    Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
}

Write-Host "" -ForegroundColor Green
Write-Host "Done. Clones of $VhdxPath will, on first boot:" -ForegroundColor Green
Write-Host "  - Read their VM name from Hyper-V KVP" -ForegroundColor Green
Write-Host "  - Set a static IP 192.168.100.X (X derived from name)" -ForegroundColor Green
Write-Host "  - Create local admin 'cluster-admin' with the password you supplied" -ForegroundColor Green
Write-Host "  - Install MeshAgent and point it at wss://${ControllerAddress}:${ControllerPort}/agent.ashx" -ForegroundColor Green

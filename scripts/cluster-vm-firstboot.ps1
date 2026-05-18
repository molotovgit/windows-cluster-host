<#
.SYNOPSIS
    Run-once first-boot bootstrap for cluster VMs created from a
    prepared golden VHDX. Injected by scripts/Prepare-GoldenVhdx.ps1.

.DESCRIPTION
    Executes inside the guest VM at first boot, scheduled as
    NT AUTHORITY\SYSTEM by a Startup-folder launcher. Tasks:

      1. Read the VM's name from the Hyper-V KVP exchange
         (HKLM:\SOFTWARE\Microsoft\Virtual Machine\External\VirtualMachineName).
      2. Rename the guest OS to match (so two clones don't share a hostname).
      3. Assign a deterministic static IPv4 inside 192.168.100.0/24 by
         hashing the VM name (no DHCP exists on the NAT switch; this is
         the cluster's standing workaround until a real DHCP shim lands).
      4. Create a known local admin account so the controller / operator
         can PowerShell-Direct in when needed (credentials are intentionally
         passable via -AdminPassword at prep time; default below is the
         documented placeholder).
      5. Install the MeshAgent installer that the prep step staged under
         C:\Setup\, point it at the controller via .msh edit, restart it.
      6. Drop a marker file so we never run again, then optionally reboot
         to apply the hostname rename.

    Idempotent: marker C:\Windows\Setup\cluster-bootstrap-done.marker
    causes immediate exit on subsequent boots.
#>

$ErrorActionPreference = 'Continue'
$markerFile = 'C:\Windows\Setup\cluster-bootstrap-done.marker'
$logFile    = 'C:\Windows\Setup\cluster-firstboot.log'

function Write-Log {
    param([string]$Msg)
    $line = "$([datetime]::UtcNow.ToString('o')) $Msg"
    Write-Host $line
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding utf8 } catch { $null = $_ }
}

if (Test-Path -LiteralPath $markerFile) {
    Write-Log "Marker already present at $markerFile; firstboot already ran. Exiting."
    return
}

# Ensure parent dirs exist for log + marker
$setupDir = Split-Path -Parent $logFile
if (-not (Test-Path -LiteralPath $setupDir)) { New-Item -Path $setupDir -ItemType Directory -Force | Out-Null }

Write-Log "Cluster VM firstboot starting."

# ---------- 1. Derive VM identity from primary NIC MAC ----------
# We do NOT use Hyper-V's KVP VirtualMachineName key: Hyper-V doesn't push
# that to guests by default (it requires explicit Add-VMKvpItem from the
# host side, which we'd rather avoid). The MAC address of the synthetic
# Hyper-V NIC is guaranteed to be unique across cloned VMs (Hyper-V mints
# it from its dynamic MAC pool 00:15:5D:xx:xx:xx when each VM is created),
# so we derive both the hostname suffix and the static IP from it.
$primaryMac = $null
try {
    $primaryMac = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' -and -not $_.Virtual } | Select-Object -First 1).MacAddress
    if (-not $primaryMac) {
        $primaryMac = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).MacAddress
    }
    Write-Log "Primary MAC: $primaryMac"
} catch {
    Write-Log "Could not read primary NIC MAC: $($_.Exception.Message)"
}

# Build vmName from the last 2 octets of MAC, e.g. 00-15-5D-28-4E-01 -> vm-4E01
$vmName = $env:COMPUTERNAME
if ($primaryMac) {
    $cleanMac = $primaryMac -replace '[:-]', ''
    if ($cleanMac.Length -ge 4) {
        $suffix = $cleanMac.Substring($cleanMac.Length - 4)
        $vmName = "vm-$suffix"
        Write-Log "Derived VM name from MAC: '$vmName'"
    }
}

# ---------- 2. Rename computer if needed ----------
$currentName = $env:COMPUTERNAME
$needsReboot = $false
if ($vmName -and ($currentName -ne $vmName)) {
    try {
        Rename-Computer -NewName $vmName -Force -ErrorAction Stop
        Write-Log "Renamed computer: $currentName -> $vmName (reboot required)"
        $needsReboot = $true
    } catch {
        Write-Log "Rename-Computer failed: $($_.Exception.Message)"
    }
}

# ---------- 3. Static IP from VM name ----------
function Get-ClusterStaticIp {
    param([string]$Name, [string]$Mac)
    # Prefer MAC-derived: take the last MAC octet (e.g. 01, 02, ..., FE), shift
    # into 10..253 (skip 0, 1=gateway, 2..9 reserved, 254=broadcast-adjacent).
    if ($Mac) {
        $cleanMac = $Mac -replace '[:-]', ''
        if ($cleanMac.Length -ge 2) {
            $lastHex = $cleanMac.Substring($cleanMac.Length - 2)
            $lastByte = [Convert]::ToInt32($lastHex, 16)
            # Map 0..FF -> 10..253 by adding 10, clamping at 253
            $octet = 10 + ($lastByte % 244)
            if ($octet -gt 253) { $octet = 253 }
            return @{ Octet = $octet; FromPattern = $true }
        }
    }
    # Legacy fallback: 'vm-a' -> 10, etc.
    if ($Name -match '^vm-([a-z])$') {
        $letter = $Matches[1]
        $offset = [int][char]$letter - [int][char]'a'
        return @{ Octet = 10 + $offset; FromPattern = $true }
    }
    # Last-resort fallback: deterministic hash of the name
    $h = 0
    foreach ($c in [char[]]$Name) { $h = (($h * 31) -bxor [int]$c) -band 0xFF }
    if ($h -lt 10) { $h = 10 + $h }
    return @{ Octet = $h; FromPattern = $false }
}

$ipInfo  = Get-ClusterStaticIp -Name $vmName -Mac $primaryMac
$octet   = $ipInfo.Octet
$ipAddr  = "192.168.100.$octet"
$gateway = '192.168.100.1'
$dns     = '192.168.1.1'

try {
    $iface = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' } | Select-Object -First 1
    if (-not $iface) {
        $iface = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    }
    if ($iface) {
        $ifname = $iface.Name
        Write-Log "Configuring static IP $ipAddr/24 gw=$gateway dns=$dns on '$ifname'"
        & netsh interface ipv4 set address name="$ifname" static $ipAddr 255.255.255.0 $gateway 2>&1 | ForEach-Object { Write-Log "  netsh: $_" }
        & netsh interface ipv4 set dnsservers name="$ifname" static $dns primary 2>&1 | ForEach-Object { Write-Log "  netsh: $_" }
    } else {
        Write-Log "No Up Ethernet adapter found; skipping static IP."
    }
} catch {
    Write-Log "Static IP configuration threw: $($_.Exception.Message)"
}

# ---------- 4. Create known admin account ----------
$adminUser = 'cluster-admin'
$adminPass = '__ADMIN_PASS_PLACEHOLDER__'   # Prepare-GoldenVhdx.ps1 rewrites this token
try {
    & net user $adminUser $adminPass /add /Y 2>&1 | ForEach-Object { Write-Log "  net user: $_" }
    & net localgroup Administrators $adminUser /add 2>&1 | ForEach-Object { Write-Log "  net localgroup: $_" }
    # Mark the account so its password never expires (long-running cluster nodes).
    wmic useraccount where "Name='$adminUser'" set PasswordExpires=FALSE 2>&1 | Out-Null
    Write-Log "Ensured local admin '$adminUser' exists."
} catch {
    Write-Log "Admin creation failed: $($_.Exception.Message)"
}

# ---------- 4b. Regenerate MachineGuid so cloned VMs are distinct in MeshCentral ----------
# Clones of the same VHDX inherit the same HKLM:\SOFTWARE\Microsoft\Cryptography\
# MachineGuid. MeshAgent derives its node ID from MachineGuid; without this
# rewrite, every cloned VM would re-register as the SAME device, with each
# overwriting the previous in the MeshCentral device list. We rewrite the
# GUID to a fresh value BEFORE the MeshAgent install runs.
try {
    $cryptoKey = 'HKLM:\SOFTWARE\Microsoft\Cryptography'
    $oldGuid   = (Get-ItemProperty -LiteralPath $cryptoKey -Name MachineGuid -ErrorAction Stop).MachineGuid
    $newGuid   = [guid]::NewGuid().ToString()
    Set-ItemProperty -LiteralPath $cryptoKey -Name MachineGuid -Value $newGuid -ErrorAction Stop
    Write-Log "Rewrote MachineGuid: $oldGuid -> $newGuid"
} catch {
    Write-Log "MachineGuid rewrite failed: $($_.Exception.Message)"
}

# ---------- 5. Install MeshAgent + point at our controller ----------
$controllerAddr = '__CONTROLLER_ADDR_PLACEHOLDER__'    # rewritten at prep time, e.g. 192.168.1.22
$controllerPort = '__CONTROLLER_PORT_PLACEHOLDER__'    # rewritten at prep time, e.g. 443
$agentExe = Get-ChildItem 'C:\Setup\meshagent64*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $agentExe) {
    Write-Log "No MeshAgent installer found under C:\Setup\meshagent64*.exe; skipping agent install."
} else {
    Write-Log "Installing MeshAgent: $($agentExe.FullName)"
    try {
        $p = Start-Process -FilePath $agentExe.FullName -ArgumentList '-fullinstall' -Wait -PassThru -NoNewWindow
        Write-Log "MeshAgent installer exit=$($p.ExitCode)"
        Start-Sleep -Seconds 10
        # Rewrite MeshServer=local to explicit URL (mDNS won't route on NAT subnet)
        $msh = 'C:\Program Files\Mesh Agent\MeshAgent.msh'
        if (Test-Path -LiteralPath $msh) {
            $content = Get-Content -LiteralPath $msh -Raw
            $target  = "wss://${controllerAddr}:${controllerPort}/agent.ashx"
            if ($content -match 'MeshServer\s*=\s*local') {
                $new = $content -replace '(?m)^MeshServer\s*=\s*.+$', "MeshServer=$target"
                [System.IO.File]::WriteAllText($msh, $new, [System.Text.UTF8Encoding]::new($false))
                Write-Log "Rewrote MeshServer to $target"
                Restart-Service 'Mesh Agent' -Force -ErrorAction SilentlyContinue
                Write-Log "Restarted Mesh Agent service"
            } else {
                Write-Log ".msh did not contain MeshServer=local (already explicit?); leaving as-is."
            }
        } else {
            Write-Log "MeshAgent.msh not found at $msh after install."
        }
    } catch {
        Write-Log "MeshAgent install threw: $($_.Exception.Message)"
    }
}

# ---------- 6. Write marker + cleanup launcher + optional reboot ----------
try {
    Set-Content -LiteralPath $markerFile -Value ([datetime]::UtcNow.ToString('o')) -Encoding utf8
    Write-Log "Wrote marker $markerFile"
} catch { Write-Log "Marker write failed: $($_.Exception.Message)" }

# No-op cleanup: the GP startup script is gated by the marker file (above),
# so it self-suppresses on subsequent boots. We leave the script in place
# rather than deleting it; the marker is the single source of truth.

if ($needsReboot) {
    Write-Log "Rebooting to apply computer rename..."
    Start-Sleep -Seconds 3
    Restart-Computer -Force
}

Write-Log "Cluster VM firstboot complete."

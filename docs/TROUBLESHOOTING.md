# Troubleshooting Guide

> Common failure modes and what to do about them.

## Pre-script checklist failed

### "Windows edition is not Pro/Enterprise/Education"

Hyper-V requires Pro or higher SKU. Verify with:

```powershell
(Get-WindowsEdition -Online).Edition
```

Upgrade in-place via:
- Settings → System → About → Change product key
- Or download Windows 11 Pro upgrade ISO

### "Not running as Administrator"

Right-click PowerShell → Run as Administrator. The script will refuse to run otherwise — there's no way to safely enable Hyper-V or install services without admin rights.

### "Network adapter not connected"

The script needs to reach the controller. Verify with:

```powershell
Test-NetConnection -ComputerName <controller-hostname-or-ip> -Port 443
```

## Discovery failures

### "Controller not found via any strategy"

The script tried in order: config file → mDNS → DNS → broadcast scan → operator prompt. If all fail:

1. Verify the controller is online and MeshCentral is running: open `https://<controller-ip>` in a browser from any other machine on the network
2. Verify firewall on the controller allows inbound 443
3. Manually edit `config/cluster-config.json` and set `controller.address` to the IP or hostname
4. Re-run: `.\install.ps1`

### mDNS not working

Common cause: WiFi router blocks multicast. Workarounds:

- Use `controller.address` in `cluster-config.json` directly
- Add a hosts file entry: `192.168.1.100  controller.local` in `C:\Windows\System32\drivers\etc\hosts`

## Hyper-V install failures

### "Enable-WindowsOptionalFeature failed"

The script automatically falls back to DISM. If both fail:

1. Check Windows Update is fully applied — `Get-WindowsUpdate` (PSWindowsUpdate module) or open Settings → Update
2. Verify virtualization is enabled in BIOS — `(Get-ComputerInfo).HyperVisorPresent` should be `True`
3. Manually run: `dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /norestart`

### Script doesn't resume after Hyper-V reboot

1. Check resume task exists: `Get-ScheduledTask -TaskName 'ClusterHostResume'`
2. Check resume marker: `Get-ItemProperty 'HKLM:\Software\ClusterHost' -Name Stage`
3. Manually resume: `.\src\Invoke-ClusterHostSetup.ps1 -Resume`

## Network failures

### "NAT switch creation failed"

The script tries each subnet from `network.nat_candidate_subnets`. If all collide with existing routes:

1. Check existing routes: `Get-NetRoute`
2. Add a new candidate subnet to `cluster-config.json` that doesn't collide
3. Re-run only the network stage: `.\src\Invoke-ClusterHostSetup.ps1 -StartFromStage 5`

### "VMs can't reach controller"

VMs use NAT through the host. Verify:

```powershell
Get-NetNat
Get-NetNatStaticMapping
```

The NAT should be configured for the subnet the VMs are on. If missing, run network stage again.

## Agent failures

### "MeshAgent install succeeded but host not in MeshCentral console"

- Wait 30 seconds — agent registration is async
- Check agent service: `Get-Service -Name 'Mesh Agent'`
- Check agent log: `C:\Program Files\Mesh Agent\meshagent.log`
- Verify controller URL in `cluster-config.json` is reachable from the host

### "OpenSSH key auth refused"

Windows is picky about the admin key file ACL:

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys
```

Should show only SYSTEM:F and Administrators:F with `(I)` (inherited) flags removed. If wrong:

```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r `
       /grant 'SYSTEM:F' /grant 'Administrators:F'
```

## VM deployment failures

### "Golden VHDX source not reachable"

Script tries SMB → HTTPS → local file in order. If all fail:

1. Verify the controller has the file at `\\<controller>\images\golden.vhdx`
2. Verify HTTPS endpoint: `iwr https://<controller>/golden.vhdx -OutFile test.vhdx`
3. Manually copy the VHDX to `C:\VMs\golden.vhdx` on the host and re-run with `-LocalGoldenPath C:\VMs\golden.vhdx`

### "Not enough free disk space for VMs"

Each VM needs ~50 GB realistic. For 2 VMs you need at least ~120 GB free on the chosen drive.

1. Free up space, OR
2. Edit `cluster-config.json` and set `host.vm_storage_path` to a different drive with more space
3. Re-run

## Log locations

| Log | Path |
|---|---|
| Setup script | `C:\ProgramData\ClusterHost\logs\setup-*.log` |
| MeshAgent | `C:\Program Files\Mesh Agent\meshagent.log` |
| OpenSSH | `C:\ProgramData\ssh\logs\sshd.log` |
| Hyper-V | Event Viewer → Applications and Services → Microsoft → Windows → Hyper-V-* |

## Reset state and start over

```powershell
# Clear resume marker
Remove-Item 'HKLM:\Software\ClusterHost' -Recurse -Force

# Remove resume scheduled task
Unregister-ScheduledTask -TaskName 'ClusterHostResume' -Confirm:$false

# Optionally remove VMs (DANGER — destroys all VMs created by script).
# Derive the names from cluster-config.json so this works with non-default vms.name_prefix / vms.count.
$cfg    = Get-Content 'C:\ProgramData\ClusterHost\config\cluster-config.json' -Raw | ConvertFrom-Json
$prefix = if ($cfg.vms.name_prefix) { $cfg.vms.name_prefix } else { 'vm-' }
$names  = if ($cfg.vms.name_suffixes) {
    $cfg.vms.name_suffixes | ForEach-Object { "$prefix$_" }
} else {
    @('a','b') | ForEach-Object { "$prefix$_" }   # default for count=2
}
Get-VM | Where-Object { $names -contains $_.Name } | ForEach-Object {
    Stop-VM $_ -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM $_ -Force
}

# Optionally remove MeshAgent
& 'C:\Program Files\Mesh Agent\meshagent.exe' -fulluninstall

# Re-run
.\install.ps1
```

## Getting more detail in logs

Edit `cluster-config.json`:

```json
"advanced": {
  "log_level": "Debug"
}
```

This makes the script emit verbose internal state to the log file.

## Where to ask for help

1. Check the [GitHub issues](https://github.com/molotovgit/windows-cluster-host/issues)
2. Open a new issue with: the failing log file, the output of `Get-ComputerInfo | Out-String`, your `cluster-config.json` with secrets redacted

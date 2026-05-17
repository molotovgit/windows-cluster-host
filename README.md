# windows-cluster-host

Automated setup script for the **host PCs** of a 30-node self-healing Windows cluster.

## What this configures on each host PC

| Step | What happens |
|---|---|
| **Windows tuning** | Disable Fast Startup, configure auto-WiFi-join, set power plan |
| **Hyper-V** | Enable the Windows feature, create a NAT virtual switch for VMs |
| **MeshAgent** | Install as Windows Service so the host phones home to the controller |
| **OpenSSH Server** | Install + enable for the second automation channel |
| **VM deploy** | Pull the golden VHDX from the controller, clone twice, create vm-a + vm-b with Hyper-V autostart |

After running on a host, the host plus its 2 VMs appear in the controller's MeshCentral console — 3 new green nodes per host.

## Architecture context

This repo is **half of a pair**. The companion repo, [`windows-cluster-controller`](https://github.com/molotovgit/windows-cluster-controller), automates the controller PC.

| Repo | Runs on | Sets up |
|---|---|---|
| `windows-cluster-controller` | 1× controller PC | MeshCentral server stack |
| `windows-cluster-host` (this one) | 10× host PCs | Hyper-V + 2 VMs per host + MeshAgent |

## Requirements

- Windows 11 Pro on each host (Home is NOT supported — no Hyper-V)
- Administrator rights
- WiFi credentials configured (same SSID as the controller)
- Network reachability to the controller PC (for pulling golden VHDX + agent installer)
- BIOS settings already applied manually: **Restore on AC Power Loss = On**, **VT-x/AMD-V**, **IOMMU**, **WoL enabled**, **Fast Boot disabled**

## Status

🚧 In active development. Setup scripts coming soon.

## Cost

**$0 in new hardware.** Uses your existing PCs and WiFi. Only real cost is Windows 11 Pro licenses for the 20 VMs (if not already owned).

## License

TBD

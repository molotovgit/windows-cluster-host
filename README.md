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

🚧 In active development.

Repo layout:

```
├── src/
│   ├── lib/         # Reusable PowerShell modules (logging, state, retry, …)
│   ├── stages/      # The 8 setup stages, each a self-contained .ps1
│   └── Invoke-ClusterHostSetup.ps1   # Top-level orchestrator (built in PR 16)
├── config/
│   └── cluster-config.example.json
├── scripts/         # Operator helpers (preflight, uninstall, repair)
├── tests/
│   ├── unit/        # Pester unit tests with mocked external cmdlets
│   ├── integration/ # End-to-end dry-run with all I/O mocked
│   └── fixtures/    # Mock data for tests
├── docs/
│   ├── ARCHITECTURE.md
│   ├── TROUBLESHOOTING.md
│   └── REVIEW_PROCESS.md
├── REVIEW_PROMPT.md # Reviewer brief used by the peer-review subagent
└── install.ps1      # One-liner bootstrap (PR 17)
```

Every change is reviewed by an independent Claude subagent against `REVIEW_PROMPT.md` before merge — see [docs/REVIEW_PROCESS.md](docs/REVIEW_PROCESS.md).

## Cost

**$0 in new hardware.** Uses your existing PCs and WiFi. Only real cost is Windows 11 Pro licenses for the 20 VMs (if not already owned).

## License

TBD

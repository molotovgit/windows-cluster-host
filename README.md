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

✅ All 8 stages implemented and unit + integration tested. End-to-end
orchestrator dry-run passes Overall=Pass on a fully-stubbed Win11 Pro
sandbox.

**One-liner install** (paste under an elevated **pwsh 7** prompt):

```powershell
iwr -useb https://raw.githubusercontent.com/molotovgit/windows-cluster-host/main/install.ps1 -OutFile install.ps1
.\install.ps1 -FromGitHub -ControllerAddress 10.0.0.7 -WriteConfig
```

`-FromGitHub` makes `install.ps1` pull the rest of the repo from the GitHub
archive zip (`molotovgit/windows-cluster-host @ main`) — the default
controller configuration does NOT serve install files over HTTPS, so this is
the recommended bootstrap path.

Or from a local checkout (USB stick, share, git clone):

```powershell
git clone https://github.com/molotovgit/windows-cluster-host
cd windows-cluster-host
.\install.ps1 -ControllerAddress 10.0.0.7 -WriteConfig
```

For a no-mutation preview:

```powershell
.\install.ps1 -ControllerAddress 10.0.0.7 -DryRun -NoRestart
```

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

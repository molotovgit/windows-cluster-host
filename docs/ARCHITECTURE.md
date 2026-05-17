# Architecture

> Detailed design of the host setup script. For high-level overview, see the [main README](../README.md).

## Goals

1. **Fully automated** — zero operator interaction after start
2. **Dynamic per-host** — adapts to each PC's unique hardware, network, drive layout
3. **Idempotent** — safe to re-run after partial failures
4. **Reboot-resilient** — survives the forced reboot Hyper-V install requires
5. **Fallback chains everywhere** — every primary operation has alternative paths if the primary fails
6. **Discoverable** — no hardcoded controller addresses or VM paths
7. **Auditable** — every action logged with timestamps and outcomes

## Eight Stages

```
┌────────────────────────────────────────────────────────────────┐
│  STAGE 1 · Preflight                                            │
│    Verify Win 11 Pro, admin rights, hardware, network           │
├────────────────────────────────────────────────────────────────┤
│  STAGE 2 · Discover                                             │
│    Find controller via config → mDNS → DNS → scan → prompt      │
├────────────────────────────────────────────────────────────────┤
│  STAGE 3 · Tuning                                               │
│    Disable Fast Startup, power plan, WiFi auto-join             │
├────────────────────────────────────────────────────────────────┤
│  STAGE 4 · Hyper-V                                              │
│    Enable Hyper-V → REBOOT → resume after reboot                │
├────────────────────────────────────────────────────────────────┤
│  STAGE 5 · Network                                              │
│    Create NAT virtual switch, find free subnet                  │
├────────────────────────────────────────────────────────────────┤
│  STAGE 6 · Agents                                               │
│    Install OpenSSH + MeshAgent, deploy SSH key, harden ACLs     │
├────────────────────────────────────────────────────────────────┤
│  STAGE 7 · VMs                                                  │
│    Pull golden VHDX, clone, create VMs with autostart           │
├────────────────────────────────────────────────────────────────┤
│  STAGE 8 · Verify                                               │
│    Confirm host + 2 VMs visible in MeshCentral                  │
└────────────────────────────────────────────────────────────────┘
```

## Fallback chains

Every operation has at least 2-3 fallback paths chosen by the output of the primary attempt:

| Operation | Primary | Fallback 1 | Fallback 2 |
|---|---|---|---|
| Detect Windows edition | `Get-WindowsEdition` | Registry: `EditionID` | WMI: `OperatingSystem.Caption` |
| Discover controller | `cluster-config.json` | mDNS query `controller.local` | Subnet broadcast scan |
| Enable Hyper-V | `Enable-WindowsOptionalFeature` | `DISM /Enable-Feature` | Capability install |
| Install OpenSSH | `Add-WindowsCapability` | `DISM /Add-Capability` | Manual download + install |
| Download MeshAgent | SMB from controller | HTTPS from controller | Local copy via USB |
| VHDX source | SMB share | HTTPS from controller | Local file path |

## Resume mechanism

Hyper-V install requires a reboot. The script handles this by:

1. Writing current stage number to `HKLM:\Software\ClusterHost\Stage`
2. Registering a scheduled task that auto-runs the orchestrator with `-Resume` at next logon
3. Forcing reboot via `Restart-Computer`
4. On resume, the orchestrator reads the stage marker and jumps to the next unfinished stage
5. On final success, the resume task is removed

## Dynamic discovery

The script never assumes:
- Controller IP / hostname (discovers via config → mDNS → scan → prompt)
- VM storage path (picks largest drive with at least `vms.count × vms.min_disk_gb_per_vm` free — default 120 GB for 2 VMs at 60 GB each)
- WiFi adapter name (uses any active wireless interface)
- NAT subnet (picks first from candidate list that doesn't collide with existing routes)
- Hostname (uses existing or operator-provided)

## Logging

- Console: colorized, level-filtered output
- File: `C:\ProgramData\ClusterHost\logs\setup-YYYYMMDD-HHmmss.log`
- Format: `[ISO-8601 timestamp] [LEVEL] [Stage] Message`
- Rotation: never auto-rotated; operator can delete old logs

## State store

- Registry: `HKLM:\Software\ClusterHost\` (machine-wide, survives reboots)
  - `Stage` (DWORD) — current stage number
  - `LastRun` (string) — ISO timestamp of last invocation
  - `Version` (string) — script version
  - `Status` (string) — `InProgress` / `Completed` / `Failed`

## Modules

| Module | Purpose |
|---|---|
| `lib/Logging.psm1` | `Write-ClusterLog`, `Start-StageLog`, `Stop-StageLog` |
| `lib/State.psm1` | Resume markers, scheduled task management |
| `lib/Discovery.psm1` | Multi-strategy controller discovery |
| `lib/HardwareDetect.psm1` | Detect SKU, drives, NICs, RAM, virtualization support |
| `lib/Retry.psm1` | Exponential backoff retry helpers for flaky operations |

## Entry points

- `install.ps1` — one-liner bootstrap (downloads everything, then invokes orchestrator)
- `src/Invoke-ClusterHostSetup.ps1` — full orchestrator (calls each stage in order)
- `scripts/Test-Prerequisites.ps1` — read-only preflight check
- `scripts/Uninstall.ps1` — partial rollback (removes MeshAgent, sshd, VMs)

## Testing

- `tests/unit/` — Pester tests for individual functions
- `tests/integration/` — End-to-end syntax + semantic validation
- `tests/fixtures/` — Mock data for tests
- `tests/Invoke-Lint.ps1` — PSScriptAnalyzer wrapper

# Windows Endpoint Remediation Toolkit

Standardized tools and runbooks for enterprise Windows endpoint support. Built for help desk and desktop support teams managing Windows 10/11 fleets.

## What's Included

**Automated Remediation**
- Modular PowerShell orchestrator with opt-in remediation switches and per-operation rollback
- Covers: Windows Update, Print Spooler, Time Service, Network Identity, Defender, Profile Health, Disk Pressure

**Golden Image Toolkit**
- Profile mirror script that clones a reference admin profile into `C:\Users\Default`
- Taskbar layout generation, wallpaper staging, and local security policy application
- Full build-to-deploy imaging runbook

**ManageEngine Endpoint Central SOP**
- 15-section operational manual for Endpoint Central Cloud (Security Edition)
- Decision-tree troubleshooting for 6 common failure scenarios
- Windows-only, step-by-step procedures

**Standalone Troubleshooting Runbooks**
- Decision-tree format designed for field use under pressure
- Domain trust recovery, Windows Update repair, profile errors, CHKDSK loops, disk space investigation

## Repository Structure

```
├── orchestrator/
│   ├── Invoke-HelpDeskOrchestrator.ps1
│   ├── Invoke-HelpDeskRollback.ps1
│   └── RUNBOOK.md
├── golden-image/
│   ├── Invoke-GoldenImageProfileMirror.ps1
│   └── RUNBOOK.md
├── mec-sop/
│   └── Endpoint-Central-SOP.md
└── runbooks/
    └── standalone/
        ├── Domain-Trust-Recovery.md
        ├── Windows-Update-Repair.md
        ├── Profile-Error-Recovery.md
        ├── CHKDSK-Loop-Fix.md
        └── Disk-Space-Investigation.md
```

## Requirements

| Requirement | Detail |
|---|---|
| PowerShell | 5.1 or later |
| OS | Windows 10 / Windows 11 (Desktop) |
| Privileges | Administrator (orchestrator does not self-elevate) |

## Quick Start

```powershell
# Fix a Windows Update failure
.\orchestrator\Invoke-HelpDeskOrchestrator.ps1 -RepairWindowsUpdate -ClearLegacyWsusPolicy

# Audit profile health (read-only, changes nothing)
.\orchestrator\Invoke-HelpDeskOrchestrator.ps1 -AuditProfileHealth

# Roll back the last operation
.\orchestrator\Invoke-HelpDeskRollback.ps1 -UseLatestOperation
```

## Design Principles

1. **Nothing runs unless explicitly selected.** No default actions, no silent fixes.
2. **Irreversible actions are gated.** Requires `-AllowIrreversible` flag.
3. **Every run produces a rollback snapshot.** Stored as JSON with a unique OperationId.
4. **Profile remediation is audit-only.** Destructive profile operations stay manual.
5. **Escalate, don't stack.** If one module doesn't fix it, stop and escalate.

## License

MIT

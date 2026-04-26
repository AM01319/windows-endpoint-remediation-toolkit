# Help Desk Automation Orchestrator
## Runbook and Switch Reference

| Item | Value |
|------|-------|
| Package | Invoke-HelpDeskOrchestrator.ps1, Invoke-HelpDeskRollback.ps1 |
| State Path | C:\ProgramData\HelpDeskAutomation\State\Operations |
| Log Path | C:\ProgramData\HelpDeskAutomation\Logs |
| Version | 2.0 |

---

## 1. Prerequisites

| Requirement | Detail |
|---|---|
| PowerShell | 5.1 or later |
| Execution context | Run as Administrator. Does not self-elevate to SYSTEM. |
| Execution policy | Must allow script execution. Use `Set-ExecutionPolicy Bypass -Scope Process` if needed. |
| OS | Windows 10 / Windows 11 Desktop. Not validated on Server. |
| File placement | Keep both scripts in the same folder. |
| Signed scripts | If your environment enforces signing or Constrained Language Mode, sign the scripts before deployment. |

---

## 2. Operating Model

- Nothing runs unless a remediation switch is explicitly selected.
- Irreversible actions are blocked unless `-AllowIrreversible` is supplied.
- Every run writes timestamped logs and an operation snapshot for rollback.
- Rollback is available only for modules that capture restorable state.
- Profile health is audit-only by design.

---

## 3. Quick Start

```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -RepairWindowsUpdate -ClearLegacyWsusPolicy -ResetWindowsUpdateWinHttpProxy

.\Invoke-HelpDeskRollback.ps1 -UseLatestOperation

.\Invoke-HelpDeskRollback.ps1 -OperationId OP-20260331_153000-AB12CD34
```

---

## 4. Files and Default Locations

| Item | Purpose | Default Location |
|------|---------|-----------------|
| Orchestrator | Primary entry point for approved remediations | Package folder |
| Rollback script | Emergency backout for reversible changes | Package folder |
| Logs | Per-run log files | C:\ProgramData\HelpDeskAutomation\Logs |
| Operation snapshots | Rollback metadata and backup state | C:\ProgramData\HelpDeskAutomation\State\Operations |
| Baseline runner | Script created by the weekly scheduled task | C:\ProgramData\HelpDeskAutomation\Scripts |
| Print quarantine | Spool files moved out of the live queue | C:\ProgramData\HelpDeskAutomation\PrintSpoolerQuarantine |

---

## 5. Log Format

Each run creates a log file named `{OperationId}.log`. Format:

```
[2026-04-01 14:30:00] [INFO] === MODULE: RepairWindowsUpdate ===
[2026-04-01 14:30:01] [INFO] Stopping service: wuauserv
[2026-04-01 14:30:02] [INFO] Backing up SoftwareDistribution
[2026-04-01 14:30:05] [SUCCESS] RepairWindowsUpdate completed successfully
```

Levels: `INFO` (normal step), `SUCCESS` (module completed), `WARN` (action completed but needs attention), `ERROR` (module failed), `AUDIT` (profile health finding, no changes made).

The OperationId is printed at the start and end of every run. It is also the filename of both the log and the snapshot JSON.

---

## 6. Control and Rollback Switches

| Switch | Used with | What it does |
|--------|-----------|-------------|
| -AllowIrreversible | Orchestrator | Unlocks guarded actions without reliable rollback |
| -BaselineTaskName | Orchestrator | Overrides the scheduled task name |
| -BaselineDayOfWeek | Orchestrator | Sets the weekly day for the baseline task |
| -BaselineTime | Orchestrator | Sets the task start time |
| -OperationId | Rollback | Targets a specific operation snapshot |
| -UseLatestOperation | Rollback | Targets the most recent operation snapshot |
| -Modules | Rollback | Limits rollback to specific module names |

Accepted rollback module names: WindowsUpdate, PrintSpooler, TimeService, NetworkIdentity, Defender, DiskPressure, WeeklyBaselineRegister.

---

## 7. Primary Remediation Switches

| Switch | What it targets | Common modifiers | Rollback coverage |
|--------|----------------|-----------------|-------------------|
| -RepairWindowsUpdate | Update scan hangs, WSUS residue, cache corruption | -ClearLegacyWsusPolicy, -ResetWindowsUpdateWinHttpProxy | Restores WSUS registry values, WinHTTP proxy, and cache backups |
| -RepairPrintSpooler | Stuck print jobs, spool queue corruption | None required | Restores spooler startup mode and quarantined spool files |
| -RepairTimeService | Clock skew, domain hierarchy resync | -ManualPeerList | Restores W32Time startup mode and prior config |
| -RepairNetworkIdentity | DNS, DHCP, WinHTTP proxy issues | -RenewDhcpLease, -ResetNetworkWinHttpProxy | Restores WinHTTP proxy only |
| -RepairDefender | Signature drift, update source validation | -DefenderSignatureFallbackOrder, -DefenderUpdateSource, -DefenderScheduleDailyCheck | Restores Defender update preferences |
| -AuditProfileHealth | TEMP profiles, orphaned SIDs, .bak entries | -DeleteProfilesUnusedForDays | N/A (audit-only, no changes made) |
| -RelieveDiskPressure | Low free space, temp bloat, hibernation | -CleanupTemp, -RunComponentCleanup, -DisableHibernation | Re-enables hibernation only |
| -RegisterWeeklyBaseline | Scheduled maintenance task | -BaselineTaskName, -BaselineDayOfWeek, -BaselineTime | Unregisters the scheduled task |

---

## 8. Irreversible Actions

These require `-AllowIrreversible`:

**-RunComponentCleanup** — Runs `DISM /StartComponentCleanup /ResetBase`. Compresses the WinSxS component store and permanently removes superseded updates. After this runs, those updates cannot be uninstalled. Use only when disk space is critically low and the endpoint is stable on its current update level.

---

## 9. Standard Workflows

### Windows Update failure
```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -RepairWindowsUpdate -ClearLegacyWsusPolicy -ResetWindowsUpdateWinHttpProxy
```

### Print queue stuck
```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -RepairPrintSpooler
```

### Clock skew / authentication issue
```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -RepairTimeService
```

### DNS / proxy / stale registration
```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -RepairNetworkIdentity -RenewDhcpLease -ResetNetworkWinHttpProxy
```

### Defender health drift
```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -RepairDefender
```

### Low disk space
```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -RelieveDiskPressure -CleanupTemp -DisableHibernation
```

### Weekly baseline deployment
```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -RegisterWeeklyBaseline -BaselineDayOfWeek Sunday -BaselineTime 03:00
```

### Profile health check
```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -AuditProfileHealth -DeleteProfilesUnusedForDays 60
```
Audit-only. Review output, then follow manual remediation steps in Section 12.

---

## 10. Rollback Procedure

1. Find the OperationId in the orchestrator output or log filename.
2. Run the rollback script:

```powershell
# Roll back everything from a specific operation
.\Invoke-HelpDeskRollback.ps1 -OperationId OP-20260401_143000-A1B2C3D4

# Roll back only specific modules
.\Invoke-HelpDeskRollback.ps1 -OperationId OP-20260401_143000-A1B2C3D4 -Modules WindowsUpdate,PrintSpooler

# Roll back the most recent operation
.\Invoke-HelpDeskRollback.ps1 -UseLatestOperation
```

3. Validate service state and functionality after rollback.

### Partial Failure Handling

If the orchestrator runs multiple modules and one fails, the snapshot still captures rollback data for all modules that ran. You can roll back modules independently using `-Modules`. A failure in one module does not corrupt rollback data for other modules.

---

## 11. Rollback Matrix

| Module | Can restore | Cannot restore |
|--------|------------|----------------|
| WindowsUpdate | SoftwareDistribution cache, catroot2 cache, WSUS registry values, WinHTTP proxy | Re-registered DLLs (harmless) |
| PrintSpooler | Quarantined spool files, startup mode | N/A |
| TimeService | Startup mode, partial config | Manual peer list may need reconfiguration |
| NetworkIdentity | WinHTTP proxy | DNS flush and DHCP renew are non-destructive |
| Defender | Signature fallback order, update preferences | Forced signature update stays (not harmful) |
| ProfileHealth | N/A (audit-only) | N/A |
| DiskPressure | Hibernation on/off | Deleted temp files, DISM component cleanup |
| WeeklyBaseline | Unregisters scheduled task | N/A |

---

## 12. Post-Audit Remediation: Profile Health

When `-AuditProfileHealth` reports findings, these manual steps are recommended. These are intentionally not automated because they involve destructive registry changes.

### .bak Registry Entries (Duplicate SID)
1. Open Registry Editor → `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`.
2. Find the SID with `.bak` suffix and the duplicate without `.bak`.
3. Rename the non-.bak entry to `.old`, then remove `.bak` from the original entry.
4. Reboot and verify.

### TEMP Profile Accumulation
1. Log the affected user off completely.
2. Delete `C:\Users\TEMP.*` folders.
3. Fix the underlying .bak entry (see above).
4. Reboot and verify.

### Orphaned Registry Entries
1. Back up the registry key.
2. Delete the orphaned SID key from ProfileList.

### Stale Profiles
1. Confirm with user/manager that the profile is no longer needed.
2. Remove with `Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -eq 'C:\Users\USERNAME' } | Remove-CimInstance`.

**Escalation:** If more than 5 profiles are affected or 10+ TEMP folders exist, escalate before manual remediation. This pattern often indicates a deeper domain trust, GPO, or SID replication issue.

---

## 13. Escalation Rule

Do not stack heavy remediations on the same endpoint. If one controlled module does not solve the issue, stop and escalate rather than turning the machine into a moving target.

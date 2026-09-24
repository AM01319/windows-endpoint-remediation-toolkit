# CHKDSK Loop Fix

**Issue:** CHKDSK runs after every reboot. The volume is flagged dirty and won't clear.

> **Key correction:** do NOT use `chkdsk C: /f /r /x` on the live system drive. The
> `/x` switch forces a dismount, which the running OS cannot do to C:, so the check
> is deferred to boot time - and if it fails to clear the dirty bit (very common with
> Fast Startup on), it re-runs every boot. That is usually the CAUSE of the loop, not
> the fix. Use `/x` only on non-system volumes that can actually dismount.

---

## Decision Tree

```
CHKDSK runs every reboot
├── Check dirty bit:  fsutil dirty query C:
│   ├── "Volume - C: is Dirty"
│   │   ├── Is Fast Startup ON?  (most common cause of the loop)
│   │   │   ├── YES → turn it OFF (Fix A step 1), reboot, recheck dirty bit
│   │   │   └── NO  → run online scan:  chkdsk C: /scan
│   │   │           ├── Cleared → Resolved. Monitor.
│   │   │           └── Still dirty → Fix B (offline repair in WinRE)
│   ├── "Volume - C: is NOT Dirty" but CHKDSK still runs
│   │   └── Boot-time schedule is stuck → Fix C (clear BootExecute / chkntfs)
```

---

## FIX A: Break the loop on the live system drive (do this first)

**Step 1 - turn off Fast Startup** (it does a hybrid shutdown that skips the full
dirty-bit reset, so the check never clears):

CMD:
```cmd
powercfg /h off
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
```
PowerShell:
```powershell
powercfg /h off
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled -Value 0
```

**Step 2 - run an ONLINE scan** (no dismount, does not schedule a boot check).
This is the correct command for the system drive:

CMD / PowerShell (same):
```cmd
chkdsk C: /scan
```
`/scan` runs against the live volume and can clear soft dirty-bit conditions. If it
reports it fixed problems, reboot and re-check `fsutil dirty query C:`.

**Step 3 - if the bit is now clear, restore default boot behavior:**
```cmd
chkntfs /d
```

Recheck:
```cmd
fsutil dirty query C:
```
"NOT Dirty" → resolved.

---

## FIX B: Offline repair (when /scan cannot clear it)

The system drive can only be fully repaired while it is offline, in the Recovery
Environment (WinRE), where C: is genuinely dismounted.

1. Boot to WinRE: Settings > System > Recovery > Advanced startup > Restart now,
   OR hold Shift while clicking Restart, OR boot Windows install media.
2. Troubleshoot > Advanced options > Command Prompt.
3. In WinRE the system drive may be lettered D: - confirm first:
```cmd
bcdedit | find "osdevice"
```
4. Run the full repair against the correct letter (only here is `/f /r` on the system
   drive appropriate, because it is offline):
```cmd
chkdsk C: /f /r
```
Let it complete all five stages (can take 1-4 hours on a large or failing disk).
5. Reboot normally and verify:
```cmd
fsutil dirty query C:
```

> `/x` is still not needed here - WinRE already has the volume offline. Reserve `/x`
> for non-system data volumes (e.g. `chkdsk D: /f /x`) that can dismount live.

---

## FIX C: Dirty bit is clear but CHKDSK still runs at boot

This means a stale boot-time schedule, not a dirty volume.

**Check what is scheduled:**
```cmd
chkntfs C:
```
- "…will be checked at next reboot" or "…is dirty" → a check is queued.

**Exclude the drive from the boot check (stops the scheduled run):**
```cmd
chkntfs /x C:
```
Reboot. If CHKDSK no longer runs, the schedule was the problem.

**Restore default behavior afterward** (so real dirty volumes still get checked):
```cmd
chkntfs /d
```

**If it persists, inspect the BootExecute key directly.** The default value is exactly
`autocheck autochk *`. Extra entries force checks:

CMD:
```cmd
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager" /v BootExecute
```
PowerShell:
```powershell
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name BootExecute | Select-Object -ExpandProperty BootExecute
```
If it shows anything other than `autocheck autochk *` (for example `autocheck autochk /r \??\C:`),
reset it to default:

CMD:
```cmd
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager" /v BootExecute /t REG_MULTI_SZ /d "autocheck autochk *" /f
```
PowerShell:
```powershell
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name BootExecute -Value @("autocheck autochk *")
```
Reboot.

---

## FIX D: Dirty bit keeps coming BACK after clearing

Something is re-dirtying the volume - usually a failing disk or a filter driver.

1. Check for NTFS corruption events:
```cmd
wevtutil qe System /q:"*[System[Provider[@Name='Ntfs'] and (EventID=55 or EventID=137)]]" /c:10 /f:text
```
2. Check physical drive health:

PowerShell:
```powershell
Get-PhysicalDisk | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus
```
CMD (WMIC is deprecated but present on many builds):
```cmd
wmic diskdrive get Model,Status
```
If HealthStatus is "Warning"/"Unhealthy" or Status is not "OK" → back up immediately
and replace the drive. A recurring dirty bit on healthy-testing hardware points at a
third-party disk/AV filter driver - remove or update it.

---

## Prevention

- Keep **Fast Startup OFF** on machines that have shown the loop; the hybrid shutdown
  is the single most common reason the dirty bit never clears.
- Always shut down cleanly - abrupt power loss sets the dirty bit.
- Recurring loops on the same machine usually mean a degrading drive; replace proactively.

---
*Windows Endpoint Remediation Toolkit — Author: Adrian Melendez*

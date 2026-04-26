# CHKDSK Loop Fix

**Issue:** CHKDSK runs after every reboot. Volume is flagged dirty and won't clear.

---

## Decision Tree

```
CHKDSK runs every reboot
├── Check dirty bit: fsutil dirty query C:
│   ├── "Volume - C: is Dirty"
│   │   ├── Run chkdsk C: /f /r → Did it run on reboot?
│   │   │   ├── YES, completed → Check dirty bit again
│   │   │   │   ├── Still dirty → FIX B (persistent dirty bit)
│   │   │   │   └── Clean → Resolved. Monitor for recurrence.
│   │   │   └── NO, skipped
│   │   │       → chkntfs C: → auto-check disabled?
│   │   │           ├── YES → chkntfs /d (reset default) → reboot
│   │   │           └── NO → chkdsk C: /f /r /x (force dismount)
│   │   └── Cannot run chkdsk → Schedule: chkdsk C: /f /r → reboot
│   └── "Volume - C: is NOT Dirty"
│       └── Check scheduled tasks and chkntfs /t for misconfiguration
```

---

## FIX A: Standard CHKDSK Repair

```cmd
chkdsk C: /f /r /x
```
If volume is in use, type Y to schedule on next reboot. Let it complete fully (1-4 hours).

Verify after:
```cmd
fsutil dirty query C:
```

---

## FIX B: Persistent Dirty Bit

1. Check for drivers re-dirtying the volume:
```cmd
wevtutil qe System /q:"*[System[Provider[@Name='Ntfs'] and (EventID=55 or EventID=137)]]" /c:10 /f:text
```

2. Run CHKDSK from recovery environment (volume fully dismounted):
   - Boot from Windows installation media or WinPE.
   - Open command prompt.
   - Run `chkdsk C: /f /r`.

3. If CHKDSK finds bad sectors, check drive health:
```powershell
Get-PhysicalDisk | Select-Object MediaType, HealthStatus, OperationalStatus
```
If HealthStatus is "Warning" or "Unhealthy" → back up data immediately and replace the drive.

---

## Temporary Band-Aid

```cmd
:: Stop the loop while you investigate (not a fix)
chkntfs /x C:

:: Re-enable later
chkntfs /d
```

---

## Prevention

- Monitor drive health with SMART data.
- Ensure clean shutdown procedures — dirty shutdowns are the #1 cause.
- If recurring on the same machine, the drive is likely degrading. Replace proactively.

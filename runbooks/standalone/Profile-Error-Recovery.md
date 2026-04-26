# Windows Profile Error Recovery

**Issue:** "User Profile Service service failed the sign-in" or user is logged into a TEMP profile. TEMP.DOMAIN.001, .002 folders accumulating in C:\Users.

---

## Decision Tree

```
User reports profile error at login
├── Getting a TEMP profile (desktop empty, settings missing)?
│   ├── YES → Check C:\Users for TEMP.* folders
│   │   ├── Multiple TEMP folders → FIX A (SID .bak collision)
│   │   └── One TEMP folder → Does original profile folder exist?
│   │       ├── YES → FIX A
│   │       └── NO → Profile deleted/corrupted → FIX B
│   └── "User Profile Service failed the sign-in" — can't log in at all
│       ├── Can log in as local admin? → FIX A from admin context
│       └── Cannot log in at all → Boot Safe Mode → FIX A
├── Happens to ALL domain users on this machine?
│   ├── YES → Machine-level issue: check disk space, Default profile integrity
│   └── NO → User-specific SID issue → FIX A
```

---

## FIX A: SID .bak Registry Repair

Fixes 90%+ of TEMP profile cases.

1. Log in as local Administrator.
2. Open `regedit` as Administrator.
3. Navigate to `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`.
4. Find the affected user's SID. You'll typically see:
```
S-1-5-21-xxx-xxx-xxx-xxxx        ← Points to TEMP path
S-1-5-21-xxx-xxx-xxx-xxxx.bak    ← Points to real profile path
```
5. The `.bak` entry is the original. The non-.bak is the failed redirect.
6. Rename the non-.bak entry → add `.old` suffix.
7. Rename the .bak entry → remove `.bak` suffix.
8. In the renamed entry, set `RefCount` to `0` and `State` to `0` (if they exist).
9. Close regedit.
10. Delete `C:\Users\TEMP.*` folders (user must be logged off).
11. Reboot.

---

## FIX B: Profile Folder Missing

1. Delete the orphaned SID entry from ProfileList (back it up first).
2. Delete any TEMP folders for that user.
3. Reboot — Windows creates a fresh profile on next login.
4. Restore documents from backup if available.

---

## FIX C: Disk Full Causing Profile Failures

Profile creation fails silently when the drive is full.

```powershell
# Check free space
(Get-PSDrive C).Free / 1GB

# If under 2 GB, free space first
.\Invoke-HelpDeskOrchestrator.ps1 -RelieveDiskPressure -CleanupTemp -DisableHibernation
```
Then proceed with FIX A.

---

## Bulk Cleanup

```powershell
# List TEMP profile folders
Get-ChildItem C:\Users -Directory | Where-Object { $_.Name -match "^TEMP\." }

# Remove them (ensure users are logged off)
Get-ChildItem C:\Users -Directory | Where-Object { $_.Name -match "^TEMP\." } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
```

---

## Prevention

- Run `-AuditProfileHealth` weekly to catch .bak entries early.
- Maintain minimum 10 GB free on system drives.
- If recurring across multiple machines, investigate domain trust, GPO, or SID replication issues.

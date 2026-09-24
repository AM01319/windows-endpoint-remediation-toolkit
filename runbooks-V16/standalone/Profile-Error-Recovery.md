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
8. In the renamed entry, set both `RefCount` and `State` to `0`. See the note below
   if either value is missing.
9. Close regedit.
10. Delete `C:\Users\TEMP.*` folders (user must be logged off).
11. Reboot.

### If RefCount or State is not present

These are `REG_DWORD` values. On many profiles - especially ones that never fully
loaded - `RefCount` (and sometimes `State`) simply does not exist yet. That is normal.
Do NOT skip the step; CREATE the missing value and set it to `0`, because Windows reads
a missing value differently from an explicit `0`.

- `RefCount` = the count of active loads of the hive. Missing usually means 0 loads,
  but creating it as `0` makes that explicit so Windows does not treat the profile as
  in-use and re-route to a TEMP profile.
- `State` = the profile state flags. `0` means "normal / healthy." A non-zero value
  (commonly `0x8000` = 32768, or other bits) marks it corrupt/temporary; forcing `0`
  clears that flag.

**Create a missing value in regedit:** with the renamed (non-.bak) SID key selected,
right-click in the right pane > New > DWORD (32-bit) Value > name it exactly `RefCount`
(or `State`) > double-click it > set Value data to `0` (Base: Hexadecimal or Decimal,
`0` is the same either way).

**Or set/create both from the command line** (replace the SID with the real one from
step 4; the key must already be the renamed non-.bak key):

CMD:
```cmd
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\S-1-5-21-xxx-xxx-xxx-xxxx" /v RefCount /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\S-1-5-21-xxx-xxx-xxx-xxxx" /v State /t REG_DWORD /d 0 /f
```
PowerShell:
```powershell
$sid = "S-1-5-21-xxx-xxx-xxx-xxxx"
$key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
New-ItemProperty -Path $key -Name RefCount -PropertyType DWord -Value 0 -Force
New-ItemProperty -Path $key -Name State    -PropertyType DWord -Value 0 -Force
```
`New-ItemProperty ... -Force` and `reg add ... /f` both CREATE the value if absent and
overwrite it if present, so the same command works either way.

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
```
CMD:
```cmd
dir C:\ | find "bytes free"

# If under 2 GB, free space first
.\Invoke-HelpDeskOrchestrator.ps1 -RelieveDiskPressure -CleanupTemp -DisableHibernation
```
Then proceed with FIX A.

---

## Bulk Cleanup

```powershell
# List TEMP profile folders
Get-ChildItem C:\Users -Directory | Where-Object { $_.Name -match "^TEMP\." }
```
CMD (list TEMP profile folders):
```cmd
dir /ad "C:\Users\TEMP*"

# Remove them (ensure users are logged off)
Get-ChildItem C:\Users -Directory | Where-Object { $_.Name -match "^TEMP\." } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
```

---

## Prevention

- Run `-AuditProfileHealth` weekly to catch .bak entries early.
- Maintain minimum 10 GB free on system drives.
- If recurring across multiple machines, investigate domain trust, GPO, or SID replication issues.

---
*Windows Endpoint Remediation Toolkit — Author: Adrian Melendez*

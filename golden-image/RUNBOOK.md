# Golden Image Build Runbook
## Mirror a Local Admin Profile to All New Users

**OS:** Windows 11 Pro  
**Method:** Profile mirror (unsupported but functional) with optional CopyProfile alternative  
**Version:** 2.0

---

## What This Produces

A Windows 11 golden image where every new user profile on every deployed machine inherits:

- Custom wallpaper and lock screen
- Desktop shortcuts in a defined arrangement
- Taskbar pins in a defined order
- Login security policies (Ctrl+Alt+Del, legal notice, hide last user)
- Shell preferences from the reference admin profile

---

## Prerequisites

| Requirement | Detail |
|---|---|
| Build machine | Clean Windows 11 Pro install, not domain-joined during build |
| Local admin | Create a dedicated imaging account (e.g., "ImageAdmin") |
| Software | All apps that need taskbar pins must be installed before profile configuration |
| PowerShell | 5.1+ |

---

## Phase 1: Build the Reference Machine

### Step 1: Clean Install
Install Windows 11 Pro. Create a local account during OOBE (do not use a Microsoft account).

### Step 2: Install Applications
Install all applications. After installation, verify shortcuts exist in `C:\ProgramData\Microsoft\Windows\Start Menu\Programs`:

```powershell
Get-ChildItem "C:\ProgramData\Microsoft\Windows\Start Menu\Programs" -Filter "*.lnk" | Select-Object Name
```

Per-user apps (Slack, Teams, Webex) often install to `AppData\Local` and don't create All Users shortcuts. The taskbar layout XML needs shortcuts in the All Users path. Create them manually if missing:

```powershell
$shell = New-Object -ComObject WScript.Shell

# Adjust target paths to match actual install locations
$apps = @{
    "Slack" = "C:\Users\ImageAdmin\AppData\Local\slack\slack.exe"
    "Webex" = "C:\Users\ImageAdmin\AppData\Local\CiscoSpark\CiscoCollabHost.exe"
}

foreach ($name in $apps.Keys) {
    $shortcut = $shell.CreateShortcut("C:\ProgramData\Microsoft\Windows\Start Menu\Programs\$name.lnk")
    $shortcut.TargetPath = $apps[$name]
    $shortcut.Save()
}
```

### Step 3: Configure the Profile
Log in as the imaging admin and set up the baseline: wallpaper, lock screen, taskbar pins (in order), desktop icons, File Explorer preferences, profile picture.

### Step 4: Apply Local Security Policies
```powershell
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty $regPath -Name "DisableCAD" -Value 0 -Type DWord         # Require Ctrl+Alt+Del
Set-ItemProperty $regPath -Name "DontDisplayLastUserName" -Value 1 -Type DWord  # Hide last user
Set-ItemProperty $regPath -Name "LegalNoticeCaption" -Value "Notice" -Type String
Set-ItemProperty $regPath -Name "LegalNoticeText" -Value "Authorized use only." -Type String
```

Or let the mirror script handle this with `-ApplyPolicies`.

---

## Phase 2: Mirror the Profile

### Step 5: Log Off the Imaging Admin
NTUSER.DAT is locked while the user is logged in. Log off, then log in as a different local admin.

### Step 6: Run the Mirror Script

```powershell
.\Invoke-GoldenImageProfileMirror.ps1 `
    -SourceProfile "C:\Users\ImageAdmin" `
    -ApplyPolicies `
    -WallpaperSource "C:\Installers\wallpaper.jpg" `
    -Force
```

### Step 7: Validate
1. Create a test user: `net user TestUser P@ssw0rd /add`
2. Log in as TestUser.
3. Check: wallpaper, taskbar pins, desktop shortcuts, Ctrl+Alt+Del requirement, legal notice, hidden last user.
4. Delete the test account: `net user TestUser /delete`

### Rollback
```powershell
Remove-Item "C:\Users\Default" -Recurse -Force
Rename-Item "C:\Users\Default.backup_{timestamp}" "Default"
```

---

## Phase 3: Capture and Deploy

### Step 8: Sysprep
```cmd
C:\Windows\System32\Sysprep\sysprep.exe /oobe /generalize /shutdown
```
The Default profile mirror survives sysprep because Default is a system template.

### Step 9: Capture
Capture the image using your deployment tool (ManageEngine, SCCM, MDT, etc.).

### Step 10: Deploy
Deploy to target machines. Ensure the deployment tool generates new SIDs for each machine to avoid SID duplication.

---

## Switch Reference

| Switch | What it does |
|--------|-------------|
| -SourceProfile | Path to the admin profile to clone (required) |
| -ApplyPolicies | Sets Ctrl+Alt+Del, hides last user, adds legal notice |
| -LegalNoticeCaption | Custom login notice caption |
| -LegalNoticeText | Custom login notice body text |
| -WallpaperSource | Path to wallpaper image to stage system-wide |
| -LockScreenSource | Path to lock screen image |
| -SkipTaskbarLayout | Skip taskbar XML deployment |
| -TaskbarLayoutXml | Path to custom LayoutModification.xml |
| -SkipNtuser | Skip NTUSER.DAT copy (files only, no registry) |
| -Force | Skip confirmation prompt |

---

## Troubleshooting

**Taskbar pins not appearing:** Verify shortcuts exist in `C:\ProgramData\Microsoft\Windows\Start Menu\Programs`. Check that LayoutModification.xml paths match.

**NTUSER.DAT copy fails:** Source profile must be logged off. Log off the imaging admin before running the script.

**New profile gets empty desktop:** ACL issue. Run `icacls C:\Users\Default /reset /t /c`.

**Works on build machine, not on deployed machines:** Verify new SIDs are being generated during deployment.

**Future Windows updates break it:** This is an unsupported method. Test on one machine after every feature update. If it breaks, fall back to CopyProfile + provisioning packages.

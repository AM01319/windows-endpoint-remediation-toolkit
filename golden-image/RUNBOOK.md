# Golden Image - BuildAdmin Automation - Runbook

**Script:** `Set-GoldenImageProfile.ps1` (v14.0)
**Platform:** Windows 11 Pro (24H2 / 25H2)

> A formatted PDF version of this runbook is in this folder: `Golden-Image-Runbook.pdf`.

---

## What this is

This script automates the proven manual image-prep process. You still set up the
reference account by hand; the script automates the repetitive BuildAdmin work
(permissions, profile copy, owner reset) plus two settings that are easy to
forget (BitLocker, auto sign-in), and it verifies the result.

It is run ONCE, as Administrator, from a SECONDARY local admin account
("BuildAdmin") while the reference account ("TemplateUser") is fully signed out.

---

## Account roles

- **TemplateUser** - the first local admin, created at OOBE. You configure this
  one to look exactly how every imaged profile should look.
- **BuildAdmin** - a second local admin, left unconfigured. You only use it to
  run this script. Keep it clean.
- **TestUser** - a brand-new account used only to verify the result after imaging.

Never run the script from TemplateUser, and never test with TemplateUser or
BuildAdmin (they already have profiles; Default-profile changes only affect
profiles created afterward).

---

## What YOU do manually (before running the script)

### A. Out-of-Box Experience - create a LOCAL account (no Microsoft account)

1. Power on the blank laptop and proceed through the Out-of-Box Experience (OOBE)
   to the first setup screens.
2. Open a command prompt at OOBE (Shift+F10, or open CMD) and run:

   ```
   oobe\bypassnro
   ```

   The machine reboots back into OOBE.
3. Continue, and at the network step choose **"I don't have internet"**, then
   **"Continue with limited setup"**.
   - If the "I don't have internet" option does not appear, physically
     disconnect the machine from the internet (unplug Ethernet / turn off Wi-Fi)
     to force the option to show.
4. Create the first **local administrator** account: **TemplateUser**.
5. Do not let Windows Updates apply during setup.

### B. Configure TemplateUser exactly how every imaged profile should look

6. Log in as TemplateUser and set everything up:
   - Install and configure all applications.
   - Desktop icons and shortcuts.
   - Taskbar pins.
   - Any per-user appearance settings (colors, etc.).

7. Set the **local Group Policy** items (these are machine-level and survive
   imaging). Open `gpedit.msc`:
   - **Wallpaper** - User Configuration > Administrative Templates > Desktop >
     Desktop > **Desktop Wallpaper** > Enabled. Set the wallpaper path (a path
     that will exist on imaged machines) and the style. This GP method is the
     reliable one.
   - **Logon disclaimer title** and **disclaimer message** - Computer
     Configuration > Windows Settings > Security Settings > Local Policies >
     Security Options > "Interactive logon: Message title for users attempting to
     log on" and "Interactive logon: Message text for users attempting to log on".
   - **Require Ctrl+Alt+Del at logon** - same Security Options node >
     "Interactive logon: Do not require CTRL+ALT+DEL" > **Disabled**.
   - **Hide last signed-in user** - same Security Options node > "Interactive
     logon: Don't display last signed-in" > **Enabled**.
   - Any other individual local Group Policy settings you want in the image.

> Lock screen image and profile picture are intentionally NOT part of this
> process - they were unreliable and are not used.

### C. Create the build account and hand off to the script

8. Create a SECOND local administrator (**BuildAdmin**). Do **not** configure it.
9. Put `Set-GoldenImageProfile.ps1` in `C:\Scripts`.
10. **Sign out** of TemplateUser completely (Start > user icon > Sign out - not
    lock, not switch user).
11. Log in as **BuildAdmin** and run the script (next section).

> If your first admin is not named exactly `TemplateUser`, open the script and
> change the `$RefUser` line near the top to match the account name.

---

## How to run it

From BuildAdmin, open **PowerShell as Administrator**:

```powershell
Set-ExecutionPolicy Bypass -Scope Process
```

```powershell
cd C:\Scripts
```

```powershell
.\Set-GoldenImageProfile.ps1
```

Watch for **`=== COMPLETE - all steps finished ===`** and read the verification
lines above it. If you see **`=== ENDED EARLY ===`**, the red message says why.
The script can never hang - every external command is timeout-protected.

---

## What the script does (7 steps)

| Step | What happens |
|------|--------------|
| 1. Pre-flight | Confirms it is NOT running as TemplateUser, that TemplateUser exists and is signed out, and that Default exists. Warns if TemplateUser still has a session (locked files would be skipped). |
| 2. BitLocker | Turns BitLocker off on C: (decrypts). Required for the image to deploy. Decryption finishes in the background. |
| 3. Auto sign-in | Disables AutoAdminLogon, the automatic restart sign-on policy, and Fast Startup, so imaged machines always show a clean logon screen. |
| 4. Ownership | Takes ownership of `C:\Users\Default` for Administrators, grants Full Control, replaces child entries, enables inheritance. |
| 5. Copy | Copies the ENTIRE TemplateUser profile into Default - everything, including NTUSER.DAT - replacing what it can and skipping anything locked (no retries, no hang). |
| 6. Reset owner | Resets the Default profile owner back to SYSTEM (required so Windows clones it cleanly for new users). |
| 7. Verify | Confirms NTUSER.DAT landed, desktop shortcuts copied, file counts, SYSTEM owns Default, auto sign-in and Fast Startup are off, and BitLocker status. Prints PASS/WARN. |

The script does NOT set wallpaper, the disclaimer, Ctrl+Alt+Del, or hide-user.
You set those in Group Policy on TemplateUser; the profile copy and local Group
Policy carry them to new profiles. Keeping the script out of those settings is
deliberate - it avoids disturbing policy that is already working.

---

## After it completes

1. Let BitLocker finish decrypting: `manage-bde -status C:` (wait for Fully Decrypted).
2. **Reboot.**
3. Optional spot-check: create a brand-new local user and log in to confirm the
   look before imaging.
4. Capture the image with **ManageEngine Endpoint Central** and deploy with
   **OS Deployer**.

---

## Verification, explained

The step-7 report is your proof the run worked:

- **NTUSER.DAT present in Default** - the reference registry hive copied (this is
  what carries colors, Explorer, and per-user settings to new profiles).
- **Desktop shortcuts copied (src/dst counts)** - the visible desktop matches.
- **Default file count vs source** - bulk copy landed.
- **Default owned by SYSTEM** - permissions correctly reset for cloning.
- **AutoAdminLogon disabled / Fast startup disabled** - clean logon screen.
- **BitLocker off/decrypting** - ready to image.

---

## If something is wrong

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| "running as TemplateUser" abort | You launched it from the wrong account | Sign out of TemplateUser, log in as BuildAdmin, re-run. |
| "Reference profile not found" | First admin is not named `TemplateUser` | Set `$RefUser` at the top of the script to the real account name. |
| WARN: TemplateUser still has a session | It was locked, not signed out | Fully sign out TemplateUser (Start - user icon - Sign out), re-run. |
| Many files skipped | TemplateUser session still active, files locked | Sign it out and re-run; locked files copy when the profile is idle. |
| Login still shows last user after imaging | The hide-user local GP was not set on TemplateUser | Set it in gpedit on TemplateUser before imaging (this is a manual step, not the script's job). |

---

## Why this approach

Earlier versions tried to have the script set wallpaper, the disclaimer, and the
logon policies itself, through several mechanisms. On 24H2/25H2 those either were
not enforced or disturbed working policy. The reliable approach, proven on the
bench, is: set those by hand in Group Policy on TemplateUser (where they are
enforced and survive imaging), and let the script automate the mechanical work -
permissions, the full profile copy, the owner reset - plus BitLocker and auto
sign-in, with verification. That division is what makes it work consistently.

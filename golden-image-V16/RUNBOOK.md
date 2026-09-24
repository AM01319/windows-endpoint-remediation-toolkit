# Golden Image - Single-Profile Automation - Runbook

**Script:** `Set-GoldenImageProfile.ps1` (v16.0)
**Author:** Adrian Melendez
**Platform:** Windows 11 Pro (24H2 / 25H2), hybrid Entra (Azure AD) join

> A formatted PDF version of this runbook is in this folder: `Golden-Image-Runbook.pdf`.

---

## What this is

One script, run from ONE profile, that turns a configured reference machine into a
clean golden image. You set the machine up by hand; the script mirrors your logged-in
profile into the Default profile so every new user inherits the look, then (on your
final pass) strips the machine's cloud identity and caches so every deployed clone
joins Entra and pulls policy without conflict.

There is no second "build" account anymore. You run the script from the same admin
profile you configured. Proven working: images deploy with the correct look and join
Azure/Entra with no duplicate-identity errors.

---

## The full process, in order

### Phase 1 - Sysprep the clean base (manual)

1. Start from a blank machine. Sysprep-generalize the clean base image FIRST, before
   installing the heavy applications. (Generalizing after a full app load is what makes
   Sysprep fail, so generalize first, then install.)

### Phase 2 - OOBE and create a LOCAL admin (manual)

2. Proceed through OOBE. At the first setup screen, open a command prompt (Shift+F10 or
   CMD) and run:

   ```
   oobe\bypassnro
   ```

   The machine reboots into OOBE.
3. Continue, and at the network step choose **"I don't have internet"**, then
   **"Continue with limited setup"**.
   - If that option does not appear, physically disconnect from the internet
     (unplug Ethernet / turn off Wi-Fi) to force it.
4. Create your local administrator account (any name - the script auto-detects it).
5. Do not let Windows Updates apply during setup.

### Phase 3 - Configure the reference profile (manual)

6. Log in and set everything up the way every imaged profile should look:
   - Install and configure all applications.
   - Desktop shortcuts. Put shared app shortcuts on the **Public desktop**
     (`C:\Users\Public\Desktop`) so every profile shows them automatically.
   - Taskbar pins.
   - Any per-user appearance (colors, etc.).
7. Set the local Group Policy items in **gpedit.msc** (machine-level; they survive imaging):
   - **Wallpaper** - User Config > Administrative Templates > Desktop > Desktop >
     Desktop Wallpaper > Enabled; set the image path and style.
   - **Disclaimer title & text** - Computer Config > Windows Settings > Security Settings >
     Local Policies > Security Options > "Message title / Message text for users attempting
     to log on".
   - **Require Ctrl+Alt+Del** - same node > "Do not require CTRL+ALT+DEL" > Disabled.
   - **Hide last signed-in user** - same node > "Don't display last signed-in" > Enabled.
   - Any other local Group Policy you want in the image.

> Lock screen image and profile picture are intentionally NOT part of this process.
> On Windows 11 Pro the "force lock screen image" policy is Enterprise/Education only,
> so it does not apply reliably here. These were dropped.

### Phase 4 - Run the script (from the same profile you just configured)

8. Put `Set-GoldenImageProfile.ps1` in `C:\Scripts`.
9. Open **PowerShell as Administrator** and run:

   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process
   ```

   ```powershell
   cd C:\Scripts
   ```

   ```powershell
   .\Set-GoldenImageProfile.ps1
   ```

10. The mirror runs (8 steps). Watch for all `[PASS]` lines.
11. At the end it asks: **"Run pre-capture cleanup? (y/N)"**
    - On an **iterative / test run**, answer **n** - your Azure identity stays intact.
    - On your **final run before capture**, answer **y** - it removes this machine's
      Entra registration and clears the caches.

### Phase 5 - Capture (manual)

12. If cleanup ran: in the Entra/Azure portal, delete this device's stale object
    (the script clears the LOCAL side; the cloud object is yours to remove).
13. Confirm the machine is OFF-domain.
14. Reboot once (flushes cached tokens), then capture the image with your deployment tool (MDT, SCCM, ManageEngine, etc.)
    and deploy it.

---

## What the script does (8 mirror steps, then optional cleanup)

| Step | What happens |
|------|--------------|
| 1. Pre-flight | Auto-detects the profile you are running from (no hardcoded name). Confirms Default exists and warns if the machine is domain-joined. |
| 2. BitLocker | Turns BitLocker off on C: (decrypts). |
| 3. Auto sign-in | Disables AutoAdminLogon, the automatic restart sign-on policy, and Fast Startup. |
| 4. Ownership | Takes ownership of C:\Users\Default for Administrators, Full Control, replaces child entries, enables inheritance. |
| 5. Copy | Copies your profile into Default, skipping anything locked (your live NTUSER.DAT and parts of AppData). |
| 6. Hive capture | Exports your loaded registry hive with `reg save HKCU` and writes it as Default\NTUSER.DAT - this carries the look (including taskbar pins) that the locked-file copy cannot. |
| 7. Reset owner | Resets the Default owner back to SYSTEM so Windows clones it cleanly. |
| 8. Verify | Confirms the hive is populated, desktop shortcuts (user or Public), SYSTEM owns Default, auto sign-in and Fast Startup off, BitLocker status. |
| Prompt | Asks whether to run the pre-capture cleanup (identity wipe + cache clear). Default is no. |

**Pre-capture cleanup (only if you answer y):** `dsregcmd /leave` to remove the Entra
device registration, reports `dsregcmd /status`, warns if domain-joined, and clears
Windows Update / Delivery Optimization / Temp / Prefetch / Windows Error Reporting
caches and flushes DNS.

The script does not set wallpaper or logon policies - you do those in Group Policy in
Phase 3. It never touches the component store, driver store, certificate stores wholesale,
or activation.

---

## Verification, explained

The step-8 report is your proof:

- **NTUSER.DAT present / populated (KB)** - the reference hive was captured (carries colors,
  Explorer settings, and taskbar pins). A healthy value is a few thousand KB.
- **Desktop shortcuts (user / public)** - the desktop is covered by the user's own Desktop
  or the Public desktop. A `public > 0` count means the shortcuts are machine-wide already.
- **Default owned by SYSTEM** - permissions correctly reset for cloning.
- **AutoAdminLogon / Fast startup disabled** - clean logon screen.
- **BitLocker off/decrypting** - ready to image.

---

## If something is not right

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| "Default profile not found" | Unexpected system state | Confirm C:\Users\Default exists; do not run on a non-standard OS install. |
| WARN: machine is domain-joined | You are still on the domain | Leave the domain (workgroup) before capture; images should be captured off-domain. |
| Taskbar pins missing on new profile | Pin data lived only in locked AppData | Re-run; the hive capture normally carries pins. If it recurs, a Volume Shadow Copy copy of AppData is the next step. |
| Deployed machine fails to join Entra | Old identity captured in the image | Answer **y** to the cleanup prompt on the capture run, and delete the stale device object in the Entra portal. |
| Desktop shortcuts missing | They were only in the old user's Desktop | Put shared shortcuts on the Public desktop so every profile shows them. |

---

## Why single-profile works (and why there is no second account)

The old approach used a second "build" admin so the reference profile could be signed
out, which let its NTUSER.DAT copy as a plain file. Running in one profile locks that
file - so the script instead exports the live hive with `reg save HKCU`, which is the
supported way to capture a loaded hive and carries the same look. Proven on the bench:
images deploy correctly and join Entra cleanly. Wallpaper and logon policy stay in Group
Policy because those are enforced there and survive imaging; the script owns the
mechanical profile copy, permissions, identity wipe, and cache clear.

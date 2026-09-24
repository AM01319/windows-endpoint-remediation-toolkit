# Windows Update Repair

**Covers:** Update scan failures, "Can't connect to update service," endless "Please wait," stuck downloads, update loop after reboot, post-feature-upgrade hangs.

---

## Decision Tree

```
Windows Update not working
├── Shows "Please wait" indefinitely
│   ├── Recently upgraded (feature update)? → SCENARIO C
│   └── No recent upgrade → SCENARIO A
├── "Can't connect to the update service"
│   ├── Can you reach the internet? (ping 8.8.8.8)
│   │   ├── NO → Fix network first
│   │   └── YES → Can you resolve DNS? (nslookup update.microsoft.com)
│   │       ├── NO → Flush DNS, check DNS server config
│   │       └── YES → WSUS residue or proxy issue → SCENARIO B
├── Update downloads but fails, retries every reboot → SCENARIO D
└── Specific error code displayed → Search the code before running generic fixes
```

---

## SCENARIO A: Standard Reset

**Orchestrator:**
```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -RepairWindowsUpdate
```

**Manual (PowerShell):**
```powershell
Stop-Service wuauserv, bits, cryptsvc, msiserver -Force
Rename-Item "C:\Windows\SoftwareDistribution" "SoftwareDistribution.old" -Force
Rename-Item "C:\Windows\System32\catroot2" "catroot2.old" -Force
Start-Service cryptsvc, bits, wuauserv, msiserver
(New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()   # reliable scan trigger; UsoClient is undocumented and unreliable on 24H2
```

**Manual (CMD):**
```cmd
net stop wuauserv
net stop bits
net stop cryptsvc
net stop msiserver
ren "%systemroot%\SoftwareDistribution" SoftwareDistribution.old
ren "%systemroot%\System32\catroot2" catroot2.old
net start cryptsvc
net start bits
net start wuauserv
net start msiserver
:: trigger a scan (equivalent COM call via PowerShell one-liner)
powershell -NoProfile -Command "(New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()"
```

Check after 2-3 minutes. Still broken -> Scenario B.

> Note (Windows 11 24H2+): if component repair keeps failing, Settings > System >
> Recovery > "Fix problems using Windows Update" reinstalls the current build
> in place while keeping apps, files, and settings. This is Microsoft's supported
> last-resort repair before an in-place upgrade from ISO.

---

## SCENARIO B: WSUS Residue / Proxy

Machines previously managed by WSUS often retain registry keys pointing to a dead server.

**Orchestrator:**
```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -RepairWindowsUpdate -ClearLegacyWsusPolicy -ResetWindowsUpdateWinHttpProxy
```

**Manual (PowerShell):**
```powershell
Remove-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUServer" -ErrorAction SilentlyContinue
Remove-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUStatusServer" -ErrorAction SilentlyContinue
Remove-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "UseWUServer" -ErrorAction SilentlyContinue
netsh winhttp reset proxy
Restart-Service wuauserv
(New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()   # reliable scan trigger; UsoClient is undocumented and unreliable on 24H2
```

**Manual (CMD):**
```cmd
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /f
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /f
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /f
netsh winhttp reset proxy
net stop wuauserv & net start wuauserv
powershell -NoProfile -Command "(New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()"
```
(`reg delete` returns an error if the value is already absent - that is harmless here.)

---

## SCENARIO C: Post-Feature-Update Hang

1. Run Scenario A first.
2. Check for pending reboot:
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing" -Name "RebootPending" -ErrorAction SilentlyContinue
```
CMD:
```cmd
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
:: "ERROR: The system was unable to find..." = no reboot pending (good)
```
3. If pending, reboot first, then retry.
4. Still stuck → Run Windows Update troubleshooter from Settings.

---

## SCENARIO D: Failed Update Retries Every Reboot

1. Identify the failing update:
```powershell
Get-WindowsUpdateLog
```
2. Hide the problematic update:
```powershell
Install-Module PSWindowsUpdate -Force
Hide-WindowsUpdate -KBArticleID "KB5XXXXXX" -Confirm:$false
```
3. If it's a required security update, download manually from catalog.update.microsoft.com and install:
```cmd
wusa.exe C:\path\to\update.msu /quiet /norestart
```

---

## Escalation

If Scenarios A-D fail:
- `DISM /Online /Cleanup-Image /RestoreHealth`
- `sfc /scannow`
- In-place upgrade (mount ISO, run setup.exe, select "Keep everything")
- Reimage as last resort

---
*Windows Endpoint Remediation Toolkit — Author: Adrian Melendez*

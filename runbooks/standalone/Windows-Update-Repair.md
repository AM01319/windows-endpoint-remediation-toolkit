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

**Manual:**
```powershell
Stop-Service wuauserv, bits, cryptsvc, msiserver -Force
Rename-Item "C:\Windows\SoftwareDistribution" "SoftwareDistribution.old" -Force
Rename-Item "C:\Windows\System32\catroot2" "catroot2.old" -Force
Start-Service cryptsvc, bits, wuauserv, msiserver
UsoClient.exe StartScan
```

Check after 2-3 minutes. Still broken → Scenario B.

---

## SCENARIO B: WSUS Residue / Proxy

Machines previously managed by WSUS often retain registry keys pointing to a dead server.

**Orchestrator:**
```powershell
.\Invoke-HelpDeskOrchestrator.ps1 -RepairWindowsUpdate -ClearLegacyWsusPolicy -ResetWindowsUpdateWinHttpProxy
```

**Manual:**
```powershell
Remove-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUServer" -ErrorAction SilentlyContinue
Remove-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUStatusServer" -ErrorAction SilentlyContinue
Remove-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "UseWUServer" -ErrorAction SilentlyContinue
netsh winhttp reset proxy
Restart-Service wuauserv
UsoClient.exe StartScan
```

---

## SCENARIO C: Post-Feature-Update Hang

1. Run Scenario A first.
2. Check for pending reboot:
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing" -Name "RebootPending" -ErrorAction SilentlyContinue
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

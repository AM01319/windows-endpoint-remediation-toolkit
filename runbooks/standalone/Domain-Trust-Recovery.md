# Domain Trust Recovery

**Issue:** Cannot log in. "The trust relationship between this workstation and the primary domain has failed." No local admin access available.

---

## Decision Tree

```
User cannot log in → domain trust error displayed?
├── YES → Do you have local admin credentials for this machine?
│   ├── YES → Log in as local admin → FIX A
│   ├── NO → Can you boot to Safe Mode with Networking?
│   │   ├── YES → Try domain login in Safe Mode (cached creds may work)
│   │   │   ├── WORKS → Open elevated PowerShell → FIX A
│   │   │   └── FAILS → OFFLINE FIX
│   │   └── NO → OFFLINE FIX
│   └── UNKNOWN → Try .\Administrator with blank password or last-known local admin
└── NO → Not a trust issue. Check network, DNS, DC reachability first.
```

---

## FIX A: Reset Trust (requires local admin or cached domain login)

**Option 1 — PowerShell (fastest):**
```powershell
Test-ComputerSecureChannel -Repair -Credential (Get-Credential)
```
Enter domain admin credentials when prompted. If it returns `True`, reboot and test.

**Option 2 — netdom:**
```cmd
netdom resetpwd /server:DC01.domain.local /userd:DOMAIN\AdminAccount /passwordd:*
```

**Option 3 — Re-join domain (last resort before reimage):**
```powershell
Remove-Computer -UnjoinDomainCredential (Get-Credential) -Force -Restart
# After reboot:
Add-Computer -DomainName "domain.local" -Credential (Get-Credential) -Restart
```

---

## OFFLINE FIX: No local admin, Safe Mode fails

1. Boot from Windows PE or USB recovery media.
2. Enable the built-in Administrator account via offline registry editing.
3. Reboot, log in as built-in Administrator, use FIX A.

**Alternative:** If you have remote management tools (SCCM, Intune, ManageEngine) that work outside of user login, push a script to reset the secure channel or re-enable a local admin account.

---

## Prevention

- Ensure machine account password renewal is not blocked by GPO.
- Machines off-network for 30+ days risk machine account password expiration (60-day default).
- Maintain a standardized local admin or LAPS break-glass account on all endpoints.

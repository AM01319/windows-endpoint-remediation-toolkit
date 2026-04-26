# ManageEngine Endpoint Central Cloud — Security Edition
## Windows Operations SOP

**Scope:** Windows 10 / Windows 11 endpoints  
**Edition:** Cloud + Security Edition  
**Version:** 2.0

---

## 1. Admin

### Console Access
1. Open Edge or Chrome. Navigate to the Endpoint Central Cloud console.
2. Authenticate (SSO or local account with MFA).
3. Verify dashboard loads with correct tenant.

### Role-Based Access
Assign roles using least-privilege:
- **Super Admin:** Full access. Limit to 2-3 users maximum.
- **Admin:** Manage agents, configurations, patches.
- **Technician:** View inventory, deploy software, remote control.
- **Auditor:** Read-only for compliance.

To add a user: Admin → User Administration → Add User → assign role and scope.

### Hardening
- Enable MFA for all admin accounts.
- Remove inactive admins quarterly.
- Enable audit logging.
- Set session timeout to 15-30 minutes.

---

## 2. Agent (Windows)

### Installation

**Manual:** Download agent from Agent → Download Agent (Windows, x64). Run as Administrator.

**Automated:**
```cmd
msiexec /i ManageEngineAgent.msi /qn SERVERIP=<CLOUD_URL> SERVERPORT=443
```

**Via imaging:** Include in golden image post-sysprep or deploy via OS Deployment task sequence.

### Health Validation
1. On endpoint: Services → ManageEngine Endpoint Central Agent → Running.
2. In console: Agent → Computers → last contact < 30 minutes.
3. Offline > 24 hours → see Troubleshooting (Section 16).

---

## 3. Inventory

1. Navigate to Inventory → Computers. Select a device.
2. View: OS version, installed software, hardware, logged-in users.
3. On-demand scan: Select device → Actions → Scan Now.
4. Dynamic groups: Inventory → Custom Groups → define criteria (e.g., OS build < threshold).

---

## 4. Configurations

1. Navigate to Configurations → Add Configuration.
2. Select type (Security / System / User), configure settings.
3. Name using a standard convention (e.g., `SEC-DisableUSB-v1`).
4. Deploy to target devices or groups. Set schedule (Immediate / Maintenance Window).
5. Monitor: Configurations → Deployment Status.

---

## 5. Threats & Patches

### Patch Scan
Navigate to Threats & Patches → Scan Systems. Filter results by severity.

### Deployment
1. Select missing patches → Deploy.
2. Use a staged approach: test ring first (48-hour soak), then production.
3. Schedule during maintenance windows when possible.
4. Monitor: Deployment Status.

### Third-Party Patching
Threats & Patches → Third-Party Updates. Same staged deployment approach.

### Declining Patches
Select patch → Decline. Document the reason. Review declined patches monthly.

---

## 6. Software Deployment

1. Software Deployment → Add Package (EXE, MSI, or Script).
2. Upload installer and configure silent switches.
3. Deploy to targets. Monitor status.

---

## 7. OS Deployment

1. Build reference machine (see Golden Image Runbook).
2. Sysprep and shut down.
3. Capture via OS Deployment → Capture Image.
4. Deploy: select image, target machines, enable new SID generation, configure post-deploy tasks.

---

## 8. Mobile Device Management (Windows)

1. Enrollment: MDM → Enrollment → Windows → generate enrollment URL.
2. On device: Settings → Accounts → Access work or school → Enroll.
3. Compliance policies: encryption, PIN requirements, OS version minimums.

---

## 9. Browsers

1. Browsers → Managed Browsers → view installed browsers and versions.
2. Set policies: homepage, default search, extension allow/block lists.

---

## 10. BitLocker Management

1. Enable: BitLocker → Manage Encryption → select targets → Enable.
2. Choose protector: TPM only / TPM + PIN.
3. Recovery: BitLocker → Recovery Keys → search by hostname.

---

## 11. Application Control

1. Application Control → Policies → create Allow List or Block List.
2. Add apps by name, hash, publisher, or path.
3. Privilege management: elevate specific apps without granting admin rights.

---

## 12. Device Control

1. Device Control → Policies → Block / Read-Only / Allow for removable storage.
2. Add exceptions by device serial number if needed.

---

## 13. Tools

- **Remote Control:** Tools → Remote Control → select device → View/Control/File Transfer.
- **System Manager:** View services, processes, event logs remotely without interrupting the user.

---

## 14. Reports

- Standard reports: patch compliance, software inventory, agent health, security posture.
- Schedule reports: Daily / Weekly / Monthly delivery via email.
- Custom reports: select data source, filters, columns.

---

## 15. Support

- ManageEngine portal, phone, and email support.
- Internal escalation tiers should be defined per organization.

---

## 16. Decision-Tree Troubleshooting

### Agent Offline

```
Agent offline in console
├── Device powered on and on network?
│   ├── NO → Power on / connect → wait 30 min
│   └── YES → Agent service running?
│       ├── NO → Start service manually
│       │   ├── Starts → Wait 15 min
│       │   └── Fails → Check Event Viewer → reinstall agent
│       └── YES (running but offline)
│           ├── Can device reach console URL on port 443?
│           │   ├── NO → Firewall/proxy blocking → whitelist URLs
│           │   └── YES → Is system clock accurate?
│           │       ├── NO → Sync time → restart agent
│           │       └── YES → Uninstall and reinstall agent
```

### Patch Deployment Failure

```
Patch shows "Failed"
├── Check failure reason
│   ├── "Insufficient disk space" → Free space → retry
│   ├── "Reboot pending" → Reboot → retry
│   ├── "Download failed" → Check network/proxy → retry
│   ├── "Installation failed" → Check CBS.log
│   │   ├── Known bad patch → Decline and document
│   │   └── Endpoint issue → DISM /RestoreHealth → retry
│   └── "Agent offline" → Fix agent first → retry
```

### Software Deployment Failure

```
Package shows "Failed"
├── Installer downloaded to endpoint?
│   ├── NO → Network/bandwidth issue → retry off-hours
│   └── YES → Check exit code
│       ├── 1603 → Permissions, locked files, or missing prerequisites
│       ├── 1618 → Another install in progress → wait and retry
│       ├── 3010 → Success, reboot required
│       └── Other → Check vendor docs for exit code
```

### Configuration Not Applying

```
Config deployed but not effective
├── Assigned to correct group/device?
│   ├── NO → Reassign
│   └── YES → Agent communicating?
│       ├── NO → Fix agent first
│       └── YES → Conflicting GPO?
│           ├── YES → GPO wins → resolve conflict
│           └── NO → Force refresh → Agent → Refresh Configurations
```

### OS Deployment Failure

```
Image deployment fails
├── PXE boots successfully?
│   ├── NO → Check BIOS PXE setting, network cable, DHCP
│   └── YES → Image downloads?
│       ├── NO → Check server connectivity and image availability
│       └── YES → Fails during apply?
│           ├── Driver issue → Add driver pack for hardware model
│           ├── Disk partition error → Check disk health
│           └── Post-deploy task fails → Check task sequence logs
```

### BitLocker Failure

```
BitLocker won't enable
├── TPM present?
│   ├── NO → Enable in BIOS or use USB key protector
│   └── YES → TPM ready? (tpm.msc)
│       ├── NO → Clear and re-initialize TPM
│       └── YES → Drive partially encrypted?
│           ├── YES → Resume or decrypt fully and re-enable
│           └── NO → Check GPO conflicts → manage-bde -status C:
```

---

## 17. Maintenance Schedule

| Task | Frequency |
|------|-----------|
| Patch scan | Weekly (automated) |
| Critical patch deployment | Within 72 hours of release |
| Agent health review | Weekly |
| Inventory audit | Monthly |
| Configuration review | Monthly |
| RBAC / access review | Quarterly |
| Image refresh | Quarterly or after major OS update |
| Compliance report | Monthly |

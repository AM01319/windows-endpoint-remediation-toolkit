# Changelog

## v3.0 — June 2026

### Golden Image Toolkit (method change)
- Replaced the profile-mirror script with Set-GoldenImageProfile.ps1, which uses the
  capture-and-deploy method. It captures the real Windows 11 LayoutModification.json
  from the configured admin taskbar and deploys that exact file, instead of generating
  XML pin definitions. This is the reliable way to carry taskbar pins on Windows 11
  22H2 and newer, where the old XML pin format is ignored.
- Deploys taskbar layout to both the provisioning folder and the Default profile.
- Added local security policies: require Ctrl+Alt+Del, hide last user, legal notice.
- Added machine lock screen policy and browser startup policy.
- Loads/writes/unloads the Default user hive with stale-hive handling.
- Removed the robocopy profile-mirror approach (hit junction-point loops on
  AppData\Local\Application Data and did not reliably carry pins).

## v2.0 — April 2026

### Orchestrator
- Full rebuild with Get-Help compatible documentation
- Added: prerequisites, log format examples, rollback matrix, partial failure handling
- Added: post-audit remediation guide for ProfileHealth findings
- Added: data-loss descriptions for all irreversible actions
- Consolidated prior runbook versions into single canonical document

### Golden Image Toolkit
- Rebuilt profile mirror script with safe exclusion list, automatic taskbar layout generation, wallpaper/lock screen staging, and local policy application
- Created 4-phase runbook: Build → Mirror → Capture → Deploy
- Documented per-user app shortcut problem (chat/collaboration apps)

### ManageEngine Endpoint Central SOP
- 15-section operational manual with step-by-step procedures
- Decision-tree troubleshooting for 6 common failure scenarios
- Removed screenshot placeholders for version-agnostic maintenance

### Standalone Runbooks
- Decision-tree format for all runbooks
- Coverage: domain trust, Windows Update, profile errors, CHKDSK loops, disk space
- Cross-references to orchestrator where applicable

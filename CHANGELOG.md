# Changelog

## v3.0 — June 2026

### Golden Image Toolkit (method change)
- Replaced all earlier approaches with Set-GoldenImageProfile.ps1 v14.0, which
  automates the proven manual "BuildAdmin" image-prep workflow instead of trying
  to set per-user visuals itself.
- The script is run from a clean SECONDARY local admin (BuildAdmin) while the
  configured reference account (TemplateUser) is fully signed out.
- What the script does: pre-flight checks, disable BitLocker, disable auto
  sign-in / restart sign-on / fast startup, take ownership of C:\Users\Default
  for Administrators, copy the ENTIRE TemplateUser profile into Default
  (including NTUSER.DAT, skipping anything locked), reset the Default owner back
  to SYSTEM, and verify the copy and permissions.
- Wallpaper, the logon disclaimer, require-Ctrl+Alt+Del, and hide-last-user are
  set BY HAND in local Group Policy on TemplateUser. The script deliberately does
  not touch them, because on 24H2/25H2 those are enforced by Group Policy / the
  Security engine and survive imaging when set there, but were unreliable when the
  script wrote them directly.
- Lock screen image and profile picture were dropped (unreliable, not needed).
- Why the change: on Windows 11 24H2/25H2, Microsoft deprecated personalization
  roaming and changed how per-user settings clone from the Default profile, so the
  older hive-edit / LayoutModification.json / Active Setup approaches did not
  reliably carry. The current split — manual Group Policy for enforced settings,
  scripted automation for the mechanical profile copy and permissions — is what
  works consistently on the bench.
- Cannot-hang design: every external command runs under a timeout and the run
  always ends with a clear COMPLETE or ENDED EARLY banner plus a verification report.

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

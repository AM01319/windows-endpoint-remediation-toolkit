# Changelog

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
- Documented per-user app shortcut problem (Slack/Teams/Webex)

### ManageEngine Endpoint Central SOP
- 15-section operational manual with step-by-step procedures
- Decision-tree troubleshooting for 6 common failure scenarios
- Removed screenshot placeholders for version-agnostic maintenance

### Standalone Runbooks
- Decision-tree format for all runbooks
- Coverage: domain trust, Windows Update, profile errors, CHKDSK loops, disk space
- Cross-references to orchestrator where applicable

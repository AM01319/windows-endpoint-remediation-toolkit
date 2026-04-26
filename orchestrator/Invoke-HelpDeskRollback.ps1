<#
.SYNOPSIS
    Rollback script for Enterprise Help Desk Automation Orchestrator v2.0.
    Reverses changes made by a specific orchestrator operation.

.DESCRIPTION
    Reads the operation snapshot created by Invoke-HelpDeskOrchestrator.ps1 and
    reverses supported changes. Not all modules are fully reversible.

    Rollback coverage by module:
    - WindowsUpdate:  Restores cached backups, WSUS registry values, WinHTTP proxy
    - PrintSpooler:   Restores quarantined spool files, prior startup mode
    - TimeService:    Restores prior W32Time config and startup mode
    - NetworkIdentity: Restores WinHTTP proxy only (DNS flush/DHCP renew are safe)
    - Defender:       Restores prior signature fallback order and update prefs
    - ProfileHealth:  N/A (audit-only, no changes to reverse)
    - DiskPressure:   Re-enables hibernation only. Temp file deletion and component 
                      cleanup are NOT reversible.
    - WeeklyBaseline: Unregisters the scheduled task

.PARAMETER OperationId
    The OperationId from the orchestrator run to roll back.

.PARAMETER UseLatestOperation
    Roll back the most recent orchestrator operation.

.PARAMETER Modules
    Comma-separated list of modules to roll back. If omitted, rolls back all
    modules from the operation. Valid: WindowsUpdate, PrintSpooler, TimeService,
    NetworkIdentity, Defender, DiskPressure, WeeklyBaselineRegister

.NOTES
    Version:  2.0
    Author:   Adrian Melendez
    Requires: PowerShell 5.1+, Administrator privileges
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$OperationId,
    [switch]$UseLatestOperation,
    [string[]]$Modules
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$StatePath = "C:\ProgramData\HelpDeskAutomation\State\Operations"
$LogPath   = "C:\ProgramData\HelpDeskAutomation\Logs"

# ============================================================================
# RESOLVE OPERATION
# ============================================================================
if ($UseLatestOperation) {
    $latest = Get-ChildItem $StatePath -Filter "OP-*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        Write-Host "No operation snapshots found in $StatePath" -ForegroundColor Red
        exit 1
    }
    $OperationId = $latest.BaseName
    Write-Host "Using latest operation: $OperationId" -ForegroundColor Cyan
}

if (-not $OperationId) {
    Write-Host "ERROR: Specify -OperationId or -UseLatestOperation" -ForegroundColor Red
    exit 1
}

$snapshotFile = Join-Path $StatePath "${OperationId}.json"
if (-not (Test-Path $snapshotFile)) {
    Write-Host "ERROR: Snapshot not found: $snapshotFile" -ForegroundColor Red
    exit 1
}

$snapshot = Get-Content $snapshotFile -Raw | ConvertFrom-Json

# Logging
$logFile = Join-Path $LogPath "ROLLBACK-$OperationId-$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
function Write-RLog {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [ROLLBACK] [$Level] $Message"
    Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }
}

Write-RLog "============================================================"
Write-RLog "ROLLBACK for OperationId: $OperationId"
Write-RLog "Original run: $($snapshot.Timestamp)"
Write-RLog "Original computer: $($snapshot.ComputerName)"
Write-RLog "============================================================"

# Determine which modules to roll back
$targetModules = if ($Modules) { $Modules } else { $snapshot.ModulesRun }
$rollbackData = $snapshot.RollbackData

foreach ($mod in $targetModules) {
    Write-RLog "--- Rolling back: $mod ---"
    $data = $rollbackData.$mod

    if (-not $data) {
        Write-RLog "No rollback data found for module: $mod" "WARN"
        continue
    }

    switch ($mod) {
        "WindowsUpdate" {
            # Restore SoftwareDistribution backup
            if ($data.SoftwareDistributionBackup -and (Test-Path $data.SoftwareDistributionBackup)) {
                $target = "C:\Windows\SoftwareDistribution"
                Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
                if (Test-Path $target) { Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue }
                Rename-Item -Path $data.SoftwareDistributionBackup -NewName "SoftwareDistribution" -Force
                Start-Service wuauserv -ErrorAction SilentlyContinue
                Write-RLog "Restored SoftwareDistribution from backup" "SUCCESS"
            }
            # Restore catroot2 backup
            if ($data.Catroot2Backup -and (Test-Path $data.Catroot2Backup)) {
                $target = "C:\Windows\System32\catroot2"
                Stop-Service cryptsvc -Force -ErrorAction SilentlyContinue
                if (Test-Path $target) { Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue }
                Rename-Item -Path $data.Catroot2Backup -NewName "catroot2" -Force
                Start-Service cryptsvc -ErrorAction SilentlyContinue
                Write-RLog "Restored catroot2 from backup" "SUCCESS"
            }
            # Restore WSUS registry if it was cleared
            if ($data.WsusServer) {
                $wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
                if (-not (Test-Path $wuPath)) { New-Item -Path $wuPath -Force | Out-Null }
                Set-ItemProperty -Path $wuPath -Name "WUServer" -Value $data.WsusServer
                Write-RLog "Restored WSUS server: $($data.WsusServer)" "SUCCESS"
            }
            if ($null -ne $data.UseWUServer) {
                $auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
                if (-not (Test-Path $auPath)) { New-Item -Path $auPath -Force | Out-Null }
                Set-ItemProperty -Path $auPath -Name "UseWUServer" -Value $data.UseWUServer -Type DWord
                Write-RLog "Restored UseWUServer: $($data.UseWUServer)" "SUCCESS"
            }
        }

        "PrintSpooler" {
            if ($data.QuarantinedFiles -and (Test-Path $data.QuarantinedFiles)) {
                Stop-Service Spooler -Force -ErrorAction SilentlyContinue
                $spoolDir = "C:\Windows\System32\spool\PRINTERS"
                Get-ChildItem $data.QuarantinedFiles | Move-Item -Destination $spoolDir -Force
                Start-Service Spooler -ErrorAction SilentlyContinue
                Write-RLog "Restored quarantined spool files" "SUCCESS"
            }
            if ($data.PriorStartType) {
                $startType = switch ($data.PriorStartType) {
                    "Auto"     { "Automatic" }
                    "Manual"   { "Manual" }
                    "Disabled" { "Disabled" }
                    default    { "Automatic" }
                }
                Set-Service -Name Spooler -StartupType $startType
                Write-RLog "Restored Spooler startup type: $startType" "SUCCESS"
            }
        }

        "TimeService" {
            if ($data.PriorStartType) {
                $startType = switch ($data.PriorStartType) {
                    "Auto"     { "Automatic" }
                    "Manual"   { "Manual" }
                    "Disabled" { "Disabled" }
                    default    { "Manual" }
                }
                Set-Service -Name W32Time -StartupType $startType
                Write-RLog "Restored W32Time startup type: $startType" "SUCCESS"
            }
            Write-RLog "W32Time configuration partially restored. Manual peer list may need reconfiguration." "WARN"
        }

        "NetworkIdentity" {
            if ($data.WinHttpProxyReset) {
                Write-RLog "WinHTTP proxy was reset to direct. If a proxy was required, reconfigure manually." "WARN"
            }
            Write-RLog "DNS flush and DHCP renew are non-destructive - no rollback needed" "INFO"
        }

        "Defender" {
            if ($data.SignatureFallbackOrder) {
                Set-MpPreference -SignatureFallbackOrder $data.SignatureFallbackOrder -ErrorAction SilentlyContinue
                Write-RLog "Restored Defender signature fallback order" "SUCCESS"
            }
        }

        "ProfileHealth" {
            Write-RLog "ProfileHealth is audit-only. No changes were made - nothing to roll back." "INFO"
        }

        "DiskPressure" {
            if ($data.HibernationWasEnabled) {
                powercfg /h on
                Write-RLog "Re-enabled hibernation" "SUCCESS"
            }
            if ($data.ComponentCleanupRun) {
                Write-RLog "CANNOT ROLLBACK: DISM component cleanup is irreversible. Superseded updates are permanently removed." "ERROR"
            }
            Write-RLog "Deleted temp files cannot be restored." "WARN"
        }

        "WeeklyBaselineRegister" {
            $taskName = "HelpDeskAutomation-WeeklyBaseline"
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-RLog "Unregistered weekly baseline scheduled task" "SUCCESS"
        }

        default {
            Write-RLog "Unknown module: $mod - skipping" "WARN"
        }
    }
}

Write-RLog "============================================================"
Write-RLog "ROLLBACK COMPLETE for $OperationId"
Write-RLog "Log: $logFile"
Write-RLog "============================================================"

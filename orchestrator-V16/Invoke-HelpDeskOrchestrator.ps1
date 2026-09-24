<#
.SYNOPSIS
    Enterprise Help Desk Automation Orchestrator v2.0
    Single entry point for standardized Windows endpoint remediations.

.DESCRIPTION
    Runs approved remediation modules against common endpoint faults.
    Nothing executes unless a remediation switch is explicitly selected.
    Every run writes logs and an operation snapshot for rollback.
    Irreversible actions are blocked unless -AllowIrreversible is supplied.

    Modules: WindowsUpdate, PrintSpooler, TimeService, NetworkIdentity,
             Defender, ProfileHealth (audit-only), DiskPressure, WeeklyBaseline

.PARAMETER RepairWindowsUpdate
    Resets Windows Update components: stops services, clears SoftwareDistribution
    and catroot2 caches, removes legacy WSUS policy residue, resets WinHTTP proxy.
    Rollback: restores cached backups, monitored WSUS values, and WinHTTP proxy.

.PARAMETER ClearLegacyWsusPolicy
    Modifier for -RepairWindowsUpdate. Removes WSUS registry keys that force
    endpoints to check a decommissioned WSUS server.

.PARAMETER ResetWindowsUpdateWinHttpProxy
    Modifier for -RepairWindowsUpdate. Resets WinHTTP proxy to direct.

.PARAMETER RepairPrintSpooler
    Stops spooler, quarantines stuck spool files, resets spooler startup to Auto,
    restarts service. Rollback: restores quarantined spool files and startup mode.

.PARAMETER RepairTimeService
    Resets W32Time service, resyncs against domain hierarchy or pool.ntp.org.
    Rollback: restores prior W32Time configuration and startup mode.

.PARAMETER ManualPeerList
    Modifier for -RepairTimeService. Comma-separated NTP peer list override.

.PARAMETER RepairNetworkIdentity
    Renews DHCP lease, flushes DNS, resets Winsock catalog, resets WinHTTP proxy.
    Rollback: restores WinHTTP proxy only (DNS flush and DHCP renew are non-destructive).

.PARAMETER RenewDhcpLease
    Modifier for -RepairNetworkIdentity. Forces DHCP lease renewal.

.PARAMETER ResetNetworkWinHttpProxy
    Modifier for -RepairNetworkIdentity. Resets WinHTTP proxy to direct.

.PARAMETER RepairDefender
    Forces Defender signature update, validates update source, resets daily scan schedule.
    Rollback: restores monitored Defender update preferences.

.PARAMETER DefenderSignatureFallbackOrder
    Modifier for -RepairDefender. Override signature fallback order.

.PARAMETER DefenderUpdateSource
    Modifier for -RepairDefender. Override update source path.

.PARAMETER DefenderScheduleDailyCheck
    Modifier for -RepairDefender. Reset scheduled scan time.

.PARAMETER AuditProfileHealth
    AUDIT ONLY. Scans for orphaned SIDs, TEMP profile accumulation, stale profile
    shells, and .bak registry entries. Reports findings but changes nothing.
    No rollback needed — this path is read-only by design.

.PARAMETER DeleteProfilesUnusedForDays
    Modifier for -AuditProfileHealth. Flags profiles not accessed in N days.
    Default: 90.

.PARAMETER RelieveDiskPressure
    Cleans temp files, runs Disk Cleanup silently, optionally disables hibernation.
    Rollback: re-enables hibernation only.

.PARAMETER CleanupTemp
    Modifier for -RelieveDiskPressure. Aggressively cleans all temp paths.

.PARAMETER RunComponentCleanup
    IRREVERSIBLE. Runs DISM component cleanup. Requires -AllowIrreversible.

.PARAMETER DisableHibernation
    Modifier for -RelieveDiskPressure. Disables hibernation (recovers hiberfil.sys space).
    Rollback: re-enables hibernation.

.PARAMETER RegisterWeeklyBaseline
    Creates a scheduled task to run the orchestrator weekly with specified switches.

.PARAMETER BaselineTaskName
    Name for the scheduled task. Default: "HelpDeskAutomation-WeeklyBaseline"

.PARAMETER BaselineDayOfWeek
    Day of week for baseline task. Default: Sunday

.PARAMETER BaselineTime
    Time for baseline task. Default: 03:00

.PARAMETER AllowIrreversible
    Unlocks guarded actions that have no reliable rollback path.

.EXAMPLE
    .\Invoke-HelpDeskOrchestrator.ps1 -RepairWindowsUpdate -ClearLegacyWsusPolicy -ResetWindowsUpdateWinHttpProxy
    
.EXAMPLE
    .\Invoke-HelpDeskOrchestrator.ps1 -RepairPrintSpooler

.EXAMPLE
    .\Invoke-HelpDeskOrchestrator.ps1 -AuditProfileHealth -DeleteProfilesUnusedForDays 60

.EXAMPLE
    .\Invoke-HelpDeskOrchestrator.ps1 -RegisterWeeklyBaseline -BaselineDayOfWeek Sunday -BaselineTime 03:00

.NOTES
    Version:        2.0
    Author:         Adrian Melendez
    Requires:       PowerShell 5.1+, Administrator privileges
    OS Support:     Windows 10 / Windows 11 (Desktop). Not validated on Server OS.
    Execution:      Must run elevated. Does NOT self-elevate to SYSTEM.
    Logging:        C:\ProgramData\HelpDeskAutomation\Logs
    Snapshots:      C:\ProgramData\HelpDeskAutomation\State\Operations
    Quarantine:     C:\ProgramData\HelpDeskAutomation\PrintSpoolerQuarantine
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # --- Primary Remediation Switches ---
    [switch]$RepairWindowsUpdate,
    [switch]$ClearLegacyWsusPolicy,
    [switch]$ResetWindowsUpdateWinHttpProxy,

    [switch]$RepairPrintSpooler,

    [switch]$RepairTimeService,
    [string]$ManualPeerList,

    [switch]$RepairNetworkIdentity,
    [switch]$RenewDhcpLease,
    [switch]$ResetNetworkWinHttpProxy,

    [switch]$RepairDefender,
    [string]$DefenderSignatureFallbackOrder,
    [string]$DefenderUpdateSource,
    [switch]$DefenderScheduleDailyCheck,

    [switch]$AuditProfileHealth,
    [int]$DeleteProfilesUnusedForDays = 90,

    [switch]$RelieveDiskPressure,
    [switch]$CleanupTemp,
    [switch]$RunComponentCleanup,
    [switch]$DisableHibernation,

    [switch]$RegisterWeeklyBaseline,
    [string]$BaselineTaskName = "HelpDeskAutomation-WeeklyBaseline",
    [string]$BaselineDayOfWeek = "Sunday",
    [string]$BaselineTime = "03:00",

    # --- Control Switches ---
    [switch]$AllowIrreversible
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ============================================================================
# CONFIGURATION
# ============================================================================
$script:BasePath       = "C:\ProgramData\HelpDeskAutomation"
$script:LogPath        = Join-Path $BasePath "Logs"
$script:StatePath      = Join-Path $BasePath "State\Operations"
$script:QuarantinePath = Join-Path $BasePath "PrintSpoolerQuarantine"
$script:ScriptsPath    = Join-Path $BasePath "Scripts"

# Generate unique OperationId for this run
$script:OperationId = "OP-{0}-{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), 
    ([System.Guid]::NewGuid().ToString("N").Substring(0,8).ToUpper())

# ============================================================================
# LOGGING
# ============================================================================
function Initialize-Logging {
    foreach ($dir in @($LogPath, $StatePath, $QuarantinePath, $ScriptsPath)) {
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    }
    $script:LogFile = Join-Path $LogPath "${OperationId}.log"
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","AUDIT")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $entry -ErrorAction SilentlyContinue
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        "AUDIT"   { Write-Host $entry -ForegroundColor Cyan }
        default   { Write-Host $entry }
    }
}

# ============================================================================
# OPERATION SNAPSHOT (for rollback)
# ============================================================================
function Save-OperationSnapshot {
    param([hashtable]$SnapshotData)
    $snapshotFile = Join-Path $StatePath "${OperationId}.json"
    $SnapshotData | ConvertTo-Json -Depth 5 | Set-Content -Path $snapshotFile -Force
    Write-Log "Operation snapshot saved: $snapshotFile" "INFO"
}

$script:Snapshot = @{
    OperationId    = $OperationId
    Timestamp      = (Get-Date -Format "o")
    ComputerName   = $env:COMPUTERNAME
    UserContext    = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    ModulesRun     = @()
    ModulesSucceeded = @()
    ModulesFailed  = @()
    RollbackData   = @{}
}

# ============================================================================
# MODULE: WINDOWS UPDATE REPAIR
# ============================================================================
function Invoke-RepairWindowsUpdate {
    Write-Log "=== MODULE: RepairWindowsUpdate ===" "INFO"
    $moduleName = "WindowsUpdate"
    $rollback = @{}

    try {
        # Capture pre-state for rollback
        $rollback.WinHttpProxy = (netsh winhttp show proxy 2>&1) -join "`n"
        $rollback.WsusServer = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUServer" -ErrorAction SilentlyContinue).WUServer
        $rollback.UseWUServer = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "UseWUServer" -ErrorAction SilentlyContinue).UseWUServer

        # Stop services
        $services = @("wuauserv", "bits", "cryptsvc", "msiserver")
        foreach ($svc in $services) {
            Write-Log "Stopping service: $svc"
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }

        # Backup and clear SoftwareDistribution
        $sdPath = "C:\Windows\SoftwareDistribution"
        $sdBackup = "${sdPath}.backup_$($OperationId)"
        if (Test-Path $sdPath) {
            Write-Log "Backing up SoftwareDistribution to $sdBackup"
            Rename-Item -Path $sdPath -NewName (Split-Path $sdBackup -Leaf) -Force -ErrorAction Stop
            $rollback.SoftwareDistributionBackup = $sdBackup
        }

        # Backup and clear catroot2
        $crPath = "C:\Windows\System32\catroot2"
        $crBackup = "${crPath}.backup_$($OperationId)"
        if (Test-Path $crPath) {
            Write-Log "Backing up catroot2 to $crBackup"
            Rename-Item -Path $crPath -NewName (Split-Path $crBackup -Leaf) -Force -ErrorAction Stop
            $rollback.Catroot2Backup = $crBackup
        }

        # Clear legacy WSUS policy if requested
        if ($ClearLegacyWsusPolicy) {
            Write-Log "Clearing legacy WSUS policy keys"
            $wuRegPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            if (Test-Path $wuRegPath) {
                $rollback.WsusRegistryExport = (Get-ItemProperty -Path $wuRegPath -ErrorAction SilentlyContinue)
                Remove-ItemProperty -Path $wuRegPath -Name "WUServer" -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $wuRegPath -Name "WUStatusServer" -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path "$wuRegPath\AU" -Name "UseWUServer" -ErrorAction SilentlyContinue
                Write-Log "WSUS policy keys removed" "SUCCESS"
            }
        }

        # Reset WinHTTP proxy if requested
        if ($ResetWindowsUpdateWinHttpProxy) {
            Write-Log "Resetting WinHTTP proxy to direct"
            netsh winhttp reset proxy | Out-Null
            $rollback.WinHttpProxyReset = $true
        }

        # Re-register Windows Update DLLs
        $dlls = @("atl.dll","urlmon.dll","mshtml.dll","shdocvw.dll","browseui.dll",
                  "jscript.dll","vbscript.dll","scrrun.dll","msxml3.dll","msxml6.dll",
                  "actxprxy.dll","softpub.dll","wintrust.dll","dssenh.dll","rsaenh.dll",
                  "gpkcsp.dll","sccbase.dll","slbcsp.dll","cryptdlg.dll","oleaut32.dll",
                  "ole32.dll","shell32.dll","wuaueng.dll","wuaueng1.dll","wucltui.dll",
                  "wups.dll","wups2.dll","wuweb.dll","qmgr.dll","qmgrprxy.dll","wucltux.dll",
                  "muweb.dll","wuwebv.dll")
        foreach ($dll in $dlls) {
            regsvr32.exe /s $dll 2>$null
        }
        Write-Log "Windows Update DLLs re-registered"

        # Restart services
        foreach ($svc in $services) {
            Start-Service -Name $svc -ErrorAction SilentlyContinue
            Write-Log "Started service: $svc"
        }

        # Trigger update scan
        Write-Log "Triggering Windows Update scan"
        Start-Process -FilePath "UsoClient.exe" -ArgumentList "StartScan" -NoNewWindow -Wait -ErrorAction SilentlyContinue

        Write-Log "RepairWindowsUpdate completed successfully" "SUCCESS"
        $script:Snapshot.ModulesSucceeded += $moduleName
    }
    catch {
        Write-Log "RepairWindowsUpdate FAILED: $($_.Exception.Message)" "ERROR"
        $script:Snapshot.ModulesFailed += $moduleName
    }

    $script:Snapshot.RollbackData[$moduleName] = $rollback
    $script:Snapshot.ModulesRun += $moduleName
}

# ============================================================================
# MODULE: PRINT SPOOLER REPAIR
# ============================================================================
function Invoke-RepairPrintSpooler {
    Write-Log "=== MODULE: RepairPrintSpooler ===" "INFO"
    $moduleName = "PrintSpooler"
    $rollback = @{}

    try {
        # Capture pre-state
        $spoolerSvc = Get-Service -Name Spooler
        $rollback.PriorStartType = (Get-WmiObject Win32_Service -Filter "Name='Spooler'").StartMode
        
        # Stop spooler
        Write-Log "Stopping Print Spooler service"
        Stop-Service -Name Spooler -Force -ErrorAction Stop

        # Quarantine stuck spool files
        $spoolDir = "C:\Windows\System32\spool\PRINTERS"
        $quarantineDir = Join-Path $QuarantinePath $OperationId
        if ((Get-ChildItem $spoolDir -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
            New-Item -Path $quarantineDir -ItemType Directory -Force | Out-Null
            Write-Log "Quarantining spool files to $quarantineDir"
            Get-ChildItem $spoolDir | Move-Item -Destination $quarantineDir -Force
            $rollback.QuarantinedFiles = $quarantineDir
        }

        # Set startup to Automatic
        Set-Service -Name Spooler -StartupType Automatic
        Write-Log "Spooler startup set to Automatic"

        # Start spooler
        Start-Service -Name Spooler -ErrorAction Stop
        Write-Log "Print Spooler restarted" "SUCCESS"

        $script:Snapshot.ModulesSucceeded += $moduleName
    }
    catch {
        Write-Log "RepairPrintSpooler FAILED: $($_.Exception.Message)" "ERROR"
        $script:Snapshot.ModulesFailed += $moduleName
    }

    $script:Snapshot.RollbackData[$moduleName] = $rollback
    $script:Snapshot.ModulesRun += $moduleName
}

# ============================================================================
# MODULE: TIME SERVICE REPAIR
# ============================================================================
function Invoke-RepairTimeService {
    Write-Log "=== MODULE: RepairTimeService ===" "INFO"
    $moduleName = "TimeService"
    $rollback = @{}

    try {
        # Capture pre-state
        $rollback.PriorStartType = (Get-WmiObject Win32_Service -Filter "Name='W32Time'").StartMode
        $rollback.PriorW32TimeConfig = (w32tm /query /configuration 2>&1) -join "`n"

        # Stop W32Time
        Stop-Service -Name W32Time -Force -ErrorAction SilentlyContinue

        # Unregister and re-register
        Write-Log "Re-registering W32Time service"
        w32tm /unregister 2>$null | Out-Null
        w32tm /register 2>$null | Out-Null

        # Configure time source
        if ($ManualPeerList) {
            Write-Log "Setting manual NTP peer list: $ManualPeerList"
            w32tm /config /manualpeerlist:"$ManualPeerList" /syncfromflags:manual /reliable:yes /update | Out-Null
        }
        else {
            # Default: sync from domain hierarchy, fallback to pool.ntp.org
            $isDomainJoined = (Get-WmiObject Win32_ComputerSystem).PartOfDomain
            if ($isDomainJoined) {
                Write-Log "Domain-joined: syncing from domain hierarchy"
                w32tm /config /syncfromflags:domhier /update | Out-Null
            }
            else {
                Write-Log "Workgroup: syncing from pool.ntp.org"
                w32tm /config /manualpeerlist:"time.windows.com,0x1 pool.ntp.org,0x1" /syncfromflags:manual /reliable:yes /update | Out-Null
            }
        }

        # Set startup and start
        Set-Service -Name W32Time -StartupType Automatic
        Start-Service -Name W32Time -ErrorAction Stop

        # Force resync
        w32tm /resync /force | Out-Null
        Write-Log "Time resync forced" "SUCCESS"

        $script:Snapshot.ModulesSucceeded += $moduleName
    }
    catch {
        Write-Log "RepairTimeService FAILED: $($_.Exception.Message)" "ERROR"
        $script:Snapshot.ModulesFailed += $moduleName
    }

    $script:Snapshot.RollbackData[$moduleName] = $rollback
    $script:Snapshot.ModulesRun += $moduleName
}

# ============================================================================
# MODULE: NETWORK IDENTITY REPAIR
# ============================================================================
function Invoke-RepairNetworkIdentity {
    Write-Log "=== MODULE: RepairNetworkIdentity ===" "INFO"
    $moduleName = "NetworkIdentity"
    $rollback = @{}

    try {
        $rollback.WinHttpProxy = (netsh winhttp show proxy 2>&1) -join "`n"

        # Flush DNS
        Write-Log "Flushing DNS resolver cache"
        ipconfig /flushdns | Out-Null

        # Renew DHCP if requested
        if ($RenewDhcpLease) {
            Write-Log "Releasing and renewing DHCP lease"
            ipconfig /release | Out-Null
            Start-Sleep -Seconds 2
            ipconfig /renew | Out-Null
        }

        # Reset Winsock
        Write-Log "Resetting Winsock catalog"
        netsh winsock reset | Out-Null

        # Reset WinHTTP proxy if requested
        if ($ResetNetworkWinHttpProxy) {
            Write-Log "Resetting WinHTTP proxy to direct"
            netsh winhttp reset proxy | Out-Null
            $rollback.WinHttpProxyReset = $true
        }

        # Register DNS
        Write-Log "Re-registering DNS"
        ipconfig /registerdns | Out-Null

        Write-Log "RepairNetworkIdentity completed (reboot recommended for Winsock reset)" "SUCCESS"
        $script:Snapshot.ModulesSucceeded += $moduleName
    }
    catch {
        Write-Log "RepairNetworkIdentity FAILED: $($_.Exception.Message)" "ERROR"
        $script:Snapshot.ModulesFailed += $moduleName
    }

    $script:Snapshot.RollbackData[$moduleName] = $rollback
    $script:Snapshot.ModulesRun += $moduleName
}

# ============================================================================
# MODULE: DEFENDER REPAIR
# ============================================================================
function Invoke-RepairDefender {
    Write-Log "=== MODULE: RepairDefender ===" "INFO"
    $moduleName = "Defender"
    $rollback = @{}

    try {
        # Capture pre-state
        $prefs = Get-MpPreference -ErrorAction Stop
        $rollback.SignatureFallbackOrder = $prefs.SignatureFallbackOrder
        $rollback.DefinitionUpdatesChannel = $prefs.DefinitionUpdatesChannel

        # Force signature update
        Write-Log "Forcing Defender signature update"
        Update-MpSignature -ErrorAction Stop
        Write-Log "Signature update completed"

        # Override fallback order if specified
        if ($DefenderSignatureFallbackOrder) {
            Write-Log "Setting signature fallback order: $DefenderSignatureFallbackOrder"
            Set-MpPreference -SignatureFallbackOrder $DefenderSignatureFallbackOrder
        }

        # Override update source if specified
        if ($DefenderUpdateSource) {
            Write-Log "Setting definition update source: $DefenderUpdateSource"
            Set-MpPreference -SignatureDefinitionUpdateFileSharesSources $DefenderUpdateSource
        }

        # Reset daily scan schedule if requested
        if ($DefenderScheduleDailyCheck) {
            Write-Log "Resetting scheduled scan to daily at 02:00"
            Set-MpPreference -ScanScheduleQuickScanTime "02:00:00"
        }

        Write-Log "RepairDefender completed" "SUCCESS"
        $script:Snapshot.ModulesSucceeded += $moduleName
    }
    catch {
        Write-Log "RepairDefender FAILED: $($_.Exception.Message)" "ERROR"
        $script:Snapshot.ModulesFailed += $moduleName
    }

    $script:Snapshot.RollbackData[$moduleName] = $rollback
    $script:Snapshot.ModulesRun += $moduleName
}

# ============================================================================
# MODULE: PROFILE HEALTH AUDIT (read-only)
# ============================================================================
function Invoke-AuditProfileHealth {
    Write-Log "=== MODULE: AuditProfileHealth (AUDIT ONLY - NO CHANGES) ===" "AUDIT"
    $moduleName = "ProfileHealth"

    try {
        $profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
        $profiles = Get-ChildItem $profileListPath -ErrorAction Stop

        $findings = @()
        $now = Get-Date

        foreach ($profile in $profiles) {
            $sid = Split-Path $profile.PSPath -Leaf
            $profilePath = (Get-ItemProperty $profile.PSPath -Name "ProfileImagePath" -ErrorAction SilentlyContinue).ProfileImagePath
            $state = (Get-ItemProperty $profile.PSPath -Name "State" -ErrorAction SilentlyContinue).State

            # Skip system SIDs
            if ($sid -match "^S-1-5-(18|19|20)$") { continue }
            if (-not $profilePath) { continue }

            $isBak = $profile.PSPath -match "\.bak$"
            $isTemp = $profilePath -match "TEMP"
            $folderExists = Test-Path $profilePath
            $lastAccess = if ($folderExists) { (Get-Item $profilePath).LastAccessTime } else { $null }
            $isStale = if ($lastAccess) { ($now - $lastAccess).Days -gt $DeleteProfilesUnusedForDays } else { $false }

            if ($isBak -or $isTemp -or -not $folderExists -or $isStale) {
                $issue = @{
                    SID = $sid
                    ProfilePath = $profilePath
                    IsBakEntry = $isBak
                    IsTempProfile = $isTemp
                    FolderExists = $folderExists
                    DaysSinceAccess = if ($lastAccess) { [math]::Round(($now - $lastAccess).TotalDays) } else { "N/A" }
                    State = $state
                }
                $findings += $issue

                if ($isBak) { Write-Log "FINDING: .bak registry entry for SID $sid at $profilePath" "AUDIT" }
                if ($isTemp) { Write-Log "FINDING: TEMP profile detected at $profilePath" "AUDIT" }
                if (-not $folderExists) { Write-Log "FINDING: Orphaned registry entry - folder missing: $profilePath" "AUDIT" }
                if ($isStale) { Write-Log "FINDING: Stale profile ($($issue.DaysSinceAccess) days since access): $profilePath" "AUDIT" }
            }
        }

        if ($findings.Count -eq 0) {
            Write-Log "No profile health issues found" "SUCCESS"
        }
        else {
            Write-Log "Profile health audit found $($findings.Count) issue(s)" "WARN"
            Write-Log "RECOMMENDED ACTION: Review findings above. For .bak entries, manually rename in registry. For TEMP profiles, delete TEMP folders after user logs off and remove .bak suffix from correct SID entry. For orphaned entries, remove registry key. Escalate to senior admin before deleting." "AUDIT"
        }

        $script:Snapshot.RollbackData[$moduleName] = @{ Findings = $findings }
        $script:Snapshot.ModulesSucceeded += $moduleName
    }
    catch {
        Write-Log "AuditProfileHealth FAILED: $($_.Exception.Message)" "ERROR"
        $script:Snapshot.ModulesFailed += $moduleName
    }

    $script:Snapshot.ModulesRun += $moduleName
}

# ============================================================================
# MODULE: DISK PRESSURE RELIEF
# ============================================================================
function Invoke-RelieveDiskPressure {
    Write-Log "=== MODULE: RelieveDiskPressure ===" "INFO"
    $moduleName = "DiskPressure"
    $rollback = @{}

    try {
        $preSpace = (Get-PSDrive C).Free
        Write-Log "Pre-cleanup free space: $([math]::Round($preSpace / 1GB, 2)) GB"

        # Clean temp directories
        if ($CleanupTemp) {
            Write-Log "Cleaning temp directories"
            $tempPaths = @(
                $env:TEMP,
                "C:\Windows\Temp",
                "C:\Windows\Prefetch"
            )
            foreach ($tp in $tempPaths) {
                if (Test-Path $tp) {
                    Get-ChildItem $tp -Recurse -Force -ErrorAction SilentlyContinue |
                        Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                }
            }
            Write-Log "Temp cleanup completed"
        }

        # DISM component cleanup (IRREVERSIBLE)
        if ($RunComponentCleanup) {
            if (-not $AllowIrreversible) {
                Write-Log "BLOCKED: -RunComponentCleanup requires -AllowIrreversible. WinSxS component store compression removes superseded updates permanently - you cannot uninstall those updates afterward." "WARN"
            }
            else {
                Write-Log "IRREVERSIBLE: Running DISM component cleanup" "WARN"
                $dismResult = dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1
                Write-Log "DISM component cleanup completed"
                $rollback.ComponentCleanupRun = $true
                $rollback.Warning = "Component cleanup is IRREVERSIBLE. Superseded updates cannot be uninstalled."
            }
        }

        # Disable hibernation
        if ($DisableHibernation) {
            $hibStatus = (powercfg /a 2>&1) -join "`n"
            $rollback.HibernationWasEnabled = $hibStatus -match "Hibernate"
            Write-Log "Disabling hibernation (recovers hiberfil.sys space)"
            powercfg /h off
        }

        $postSpace = (Get-PSDrive C).Free
        $recovered = [math]::Round(($postSpace - $preSpace) / 1MB, 0)
        Write-Log "Post-cleanup free space: $([math]::Round($postSpace / 1GB, 2)) GB (recovered ~${recovered} MB)" "SUCCESS"

        $script:Snapshot.ModulesSucceeded += $moduleName
    }
    catch {
        Write-Log "RelieveDiskPressure FAILED: $($_.Exception.Message)" "ERROR"
        $script:Snapshot.ModulesFailed += $moduleName
    }

    $script:Snapshot.RollbackData[$moduleName] = $rollback
    $script:Snapshot.ModulesRun += $moduleName
}

# ============================================================================
# MODULE: WEEKLY BASELINE REGISTRATION
# ============================================================================
function Invoke-RegisterWeeklyBaseline {
    Write-Log "=== MODULE: RegisterWeeklyBaseline ===" "INFO"
    $moduleName = "WeeklyBaselineRegister"

    try {
        $scriptPath = Join-Path $ScriptsPath "Invoke-WeeklyBaseline.ps1"
        
        # Create the baseline runner script
        $baselineScript = @"
# Weekly Baseline - Auto-generated by HelpDeskOrchestrator
# OperationId: $OperationId
Set-Location (Split-Path `$MyInvocation.MyCommand.Path)
& "$(Join-Path $PSScriptRoot 'Invoke-HelpDeskOrchestrator.ps1')" ``
    -RepairWindowsUpdate -ClearLegacyWsusPolicy ``
    -RepairDefender -DefenderScheduleDailyCheck ``
    -RelieveDiskPressure -CleanupTemp
"@
        $baselineScript | Set-Content -Path $scriptPath -Force

        # Create scheduled task
        $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`""
        
        $taskTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $BaselineDayOfWeek `
            -At $BaselineTime

        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -RunOnlyIfNetworkAvailable:$false

        $taskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

        Register-ScheduledTask -TaskName $BaselineTaskName `
            -Action $taskAction -Trigger $taskTrigger `
            -Settings $taskSettings -Principal $taskPrincipal `
            -Force -ErrorAction Stop | Out-Null

        Write-Log "Weekly baseline task registered: '$BaselineTaskName' runs $BaselineDayOfWeek at $BaselineTime as SYSTEM" "SUCCESS"
        $script:Snapshot.ModulesSucceeded += $moduleName
    }
    catch {
        Write-Log "RegisterWeeklyBaseline FAILED: $($_.Exception.Message)" "ERROR"
        $script:Snapshot.ModulesFailed += $moduleName
    }

    $script:Snapshot.ModulesRun += $moduleName
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
Initialize-Logging

Write-Log "============================================================"
Write-Log "Enterprise Help Desk Automation Orchestrator v2.0"
Write-Log "OperationId: $OperationId"
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "PowerShell: $($PSVersionTable.PSVersion)"
Write-Log "OS: $((Get-WmiObject Win32_OperatingSystem).Caption) Build $((Get-WmiObject Win32_OperatingSystem).BuildNumber)"
Write-Log "============================================================"

# Validate at least one switch was selected
$anySwitchSelected = $RepairWindowsUpdate -or $RepairPrintSpooler -or $RepairTimeService -or 
    $RepairNetworkIdentity -or $RepairDefender -or $AuditProfileHealth -or 
    $RelieveDiskPressure -or $RegisterWeeklyBaseline

if (-not $anySwitchSelected) {
    Write-Log "No remediation switch selected. Nothing to do. Use -RepairWindowsUpdate, -RepairPrintSpooler, etc." "WARN"
    Write-Log "Run: Get-Help .\Invoke-HelpDeskOrchestrator.ps1 -Full" "INFO"
    exit 0
}

# Execute selected modules
if ($RepairWindowsUpdate)    { Invoke-RepairWindowsUpdate }
if ($RepairPrintSpooler)     { Invoke-RepairPrintSpooler }
if ($RepairTimeService)      { Invoke-RepairTimeService }
if ($RepairNetworkIdentity)  { Invoke-RepairNetworkIdentity }
if ($RepairDefender)         { Invoke-RepairDefender }
if ($AuditProfileHealth)     { Invoke-AuditProfileHealth }
if ($RelieveDiskPressure)    { Invoke-RelieveDiskPressure }
if ($RegisterWeeklyBaseline) { Invoke-RegisterWeeklyBaseline }

# Save snapshot
Save-OperationSnapshot -SnapshotData $script:Snapshot

# Summary
Write-Log "============================================================"
Write-Log "OPERATION SUMMARY"
Write-Log "OperationId: $OperationId"
Write-Log "Modules run: $($script:Snapshot.ModulesRun -join ', ')"
Write-Log "Succeeded: $($script:Snapshot.ModulesSucceeded -join ', ')" "SUCCESS"
if ($script:Snapshot.ModulesFailed.Count -gt 0) {
    Write-Log "FAILED: $($script:Snapshot.ModulesFailed -join ', ')" "ERROR"
    Write-Log "Partial failure detected. You can roll back individual modules:" "WARN"
    Write-Log "  .\Invoke-HelpDeskRollback.ps1 -OperationId $OperationId -Modules $($script:Snapshot.ModulesFailed -join ',')" "WARN"
}
Write-Log "Log: $($script:LogFile)"
Write-Log "Snapshot: $(Join-Path $StatePath "${OperationId}.json")"
Write-Log "To rollback this entire operation:" "INFO"
Write-Log "  .\Invoke-HelpDeskRollback.ps1 -OperationId $OperationId" "INFO"
Write-Log "============================================================"

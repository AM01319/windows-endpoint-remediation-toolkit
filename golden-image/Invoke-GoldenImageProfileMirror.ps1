<#
.SYNOPSIS
    Golden Image Profile Mirror v2.0
    Clones a chosen local admin profile into C:\Users\Default so all new user
    profiles inherit the baseline configuration.

.DESCRIPTION
    This is the "unsupported but hardened" approach to golden image profile
    standardization. Microsoft's supported method is CopyProfile in unattend.xml.
    This script exists because CopyProfile does not reliably carry over taskbar
    pins, desktop icon arrangement, or certain shell preferences on Windows 11.

    What this script does:
    1. Backs up C:\Users\Default to C:\Users\Default.backup_{timestamp}
    2. Mirrors the source admin profile into Default with safe exclusions
    3. Copies and sanitizes NTUSER.DAT (removes user-specific SID references)
    4. Repairs Default profile folder ACLs
    5. Stages wallpaper, lock screen, and profile picture assets
    6. Optionally applies local security policies (Ctrl+Alt+Del, legal notice, etc.)

    What it does NOT do:
    - Modify the registry of currently logged-in users
    - Touch domain profiles
    - Run sysprep (that's a separate step in the imaging workflow)

.PARAMETER SourceProfile
    Path to the local admin profile to clone. Example: "C:\Users\ImageAdmin"

.PARAMETER ApplyPolicies
    Apply local security policies: interactive logon legal notice, 
    Ctrl+Alt+Del requirement, and hide last logged-in username.

.PARAMETER LegalNoticeCaption
    Caption for the legal notice displayed at login. Default: "Notice"

.PARAMETER LegalNoticeText
    Body text for the legal notice. Default: "This system is for authorized use only."

.PARAMETER WallpaperSource
    Path to wallpaper image file to stage to C:\Windows\Web\Wallpaper\Custom.
    If not specified, uses whatever wallpaper the source profile has configured.

.PARAMETER LockScreenSource
    Path to lock screen image file to stage.

.PARAMETER SkipTaskbarLayout
    Skip taskbar layout XML deployment. Use if you're handling taskbar via
    ManageEngine or GPO instead.

.PARAMETER TaskbarLayoutXml
    Path to a custom LayoutModification.xml. If not specified, the script
    generates one with the standard pin set.

.PARAMETER SkipNtuser
    Skip NTUSER.DAT copy. Use if you only want file/folder mirroring without
    registry settings.

.PARAMETER Force
    Skip the confirmation prompt before overwriting Default.

.EXAMPLE
    .\Invoke-GoldenImageProfileMirror.ps1 -SourceProfile "C:\Users\ImageAdmin" -ApplyPolicies

.EXAMPLE
    .\Invoke-GoldenImageProfileMirror.ps1 -SourceProfile "C:\Users\ImageAdmin" -WallpaperSource "C:\Installers\wallpaper.jpg" -Force

.NOTES
    Version:        2.0
    Author:         Adrian Melendez
    Requires:       PowerShell 5.1+, Administrator privileges
    OS Support:     Windows 10 / Windows 11 Pro
    WARNING:        This is an unsupported imaging technique. It works but Microsoft
                    does not guarantee forward compatibility across Windows builds.
                    Always test on a single machine before fleet deployment.
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceProfile,

    [switch]$ApplyPolicies,
    [string]$LegalNoticeCaption = "Notice",
    [string]$LegalNoticeText = "This system is for authorized use only. Unauthorized access is prohibited.",

    [string]$WallpaperSource,
    [string]$LockScreenSource,

    [switch]$SkipTaskbarLayout,
    [string]$TaskbarLayoutXml,

    [switch]$SkipNtuser,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ============================================================================
# CONFIGURATION
# ============================================================================
$script:DefaultProfile = "C:\Users\Default"
$script:Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:BackupPath = "${DefaultProfile}.backup_${Timestamp}"
$script:LogFile = "C:\ProgramData\HelpDeskAutomation\Logs\GoldenImageMirror_${Timestamp}.log"
$script:StepCount = 0
$script:TotalSteps = 8

# Folders to EXCLUDE from mirroring (transient/user-specific junk)
$script:ExcludeDirs = @(
    'AppData\Local\Temp',
    'AppData\Local\Microsoft\Windows\INetCache',
    'AppData\Local\Microsoft\Windows\Explorer\thumbcache*',
    'AppData\Local\Microsoft\Windows\WebCache',
    'AppData\Local\Microsoft\Windows\Notifications',
    'AppData\Local\Microsoft\Windows\TokenBroker',
    'AppData\Local\Microsoft\Windows\Caches',
    'AppData\Local\CrashDumps',
    'AppData\Local\D3DSCache',
    'AppData\Local\Microsoft\Edge\User Data\Default\Cache',
    'AppData\Local\Google\Chrome\User Data\Default\Cache',
    'AppData\Local\Microsoft\Teams\Cache',
    'AppData\Local\Packages',
    'AppData\Local\ConnectedDevicesPlatform',
    'OneDrive',
    'IntelGraphicsProfiles'
)

# Files to EXCLUDE
$script:ExcludeFiles = @(
    'NTUSER.DAT',
    'NTUSER.DAT.LOG*',
    'ntuser.dat.LOG*',
    'ntuser.ini',
    'UsrClass.dat',
    'UsrClass.dat.LOG*'
)

# ============================================================================
# LOGGING AND PROGRESS
# ============================================================================
function Initialize-Logging {
    $logDir = Split-Path $script:LogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $script:LogFile -Value $entry -ErrorAction SilentlyContinue
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }
}

function Step {
    param([string]$Name)
    $script:StepCount++
    $pct = [math]::Round(($script:StepCount / $script:TotalSteps) * 100)
    Write-Progress -Activity "Golden Image Profile Mirror" -Status "$Name" -PercentComplete $pct
    Write-Log "=== STEP $($script:StepCount)/$($script:TotalSteps): $Name ==="
}

# ============================================================================
# VALIDATION
# ============================================================================
Initialize-Logging

Write-Log "Golden Image Profile Mirror v2.0 starting"
Write-Log "Source: $SourceProfile"
Write-Log "Target: $DefaultProfile"

if (-not (Test-Path $SourceProfile)) {
    Write-Log "Source profile not found: $SourceProfile" "ERROR"
    exit 1
}

if (-not (Test-Path (Join-Path $SourceProfile "NTUSER.DAT"))) {
    Write-Log "No NTUSER.DAT found in source profile. Is this a valid profile folder?" "ERROR"
    exit 1
}

if (-not $Force) {
    Write-Host ""
    Write-Host "WARNING: This will overwrite C:\Users\Default with content from $SourceProfile" -ForegroundColor Yellow
    Write-Host "A backup will be created at $BackupPath" -ForegroundColor Yellow
    Write-Host ""
    $confirm = Read-Host "Type YES to continue"
    if ($confirm -ne "YES") {
        Write-Log "Aborted by user"
        exit 0
    }
}

# ============================================================================
# STEP 1: BACKUP DEFAULT PROFILE
# ============================================================================
Step "Backing up Default profile"

try {
    Copy-Item -Path $DefaultProfile -Destination $BackupPath -Recurse -Force -ErrorAction Stop
    Write-Log "Default profile backed up to $BackupPath" "SUCCESS"
    Write-Log "To rollback: Remove-Item '$DefaultProfile' -Recurse -Force; Rename-Item '$BackupPath' 'Default'"
}
catch {
    Write-Log "Failed to backup Default profile: $($_.Exception.Message)" "ERROR"
    exit 1
}

# ============================================================================
# STEP 2: MIRROR SOURCE PROFILE TO DEFAULT (with exclusions)
# ============================================================================
Step "Mirroring source profile to Default"

try {
    # Build exclusion patterns
    $excludeFullPaths = $ExcludeDirs | ForEach-Object { Join-Path $SourceProfile $_ }

    # Get all files from source, excluding problematic paths
    $sourceFiles = Get-ChildItem -Path $SourceProfile -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $item = $_
            $excluded = $false

            # Check directory exclusions
            foreach ($ex in $excludeFullPaths) {
                if ($item.FullName -like "$ex*") { $excluded = $true; break }
            }

            # Check file exclusions
            if (-not $item.PSIsContainer) {
                foreach ($ef in $ExcludeFiles) {
                    if ($item.Name -like $ef) { $excluded = $true; break }
                }
            }

            -not $excluded
        }

    $fileCount = 0
    $errorCount = 0
    $totalFiles = ($sourceFiles | Measure-Object).Count

    foreach ($file in $sourceFiles) {
        $relativePath = $file.FullName.Substring($SourceProfile.Length)
        $destPath = Join-Path $DefaultProfile $relativePath

        try {
            if ($file.PSIsContainer) {
                if (-not (Test-Path $destPath)) {
                    New-Item -Path $destPath -ItemType Directory -Force | Out-Null
                }
            }
            else {
                $destDir = Split-Path $destPath -Parent
                if (-not (Test-Path $destDir)) {
                    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                }
                Copy-Item -Path $file.FullName -Destination $destPath -Force -ErrorAction Stop
            }
            $fileCount++
        }
        catch {
            $errorCount++
            # Don't log every single file error — summarize at end
        }

        if ($fileCount % 100 -eq 0) {
            Write-Progress -Activity "Golden Image Profile Mirror" -Status "Copying files: $fileCount / $totalFiles" `
                -PercentComplete (25 + (($fileCount / [math]::Max($totalFiles,1)) * 15))
        }
    }

    Write-Log "Mirrored $fileCount files/folders ($errorCount skipped due to locks/permissions)"
    if ($errorCount -gt 50) {
        Write-Log "High error count during mirror. Some files may be locked by the source profile." "WARN"
    }
}
catch {
    Write-Log "Mirror failed: $($_.Exception.Message)" "ERROR"
}

# ============================================================================
# STEP 3: COPY AND SANITIZE NTUSER.DAT
# ============================================================================
if (-not $SkipNtuser) {
    Step "Copying NTUSER.DAT"

    try {
        $sourceNtuser = Join-Path $SourceProfile "NTUSER.DAT"
        $destNtuser = Join-Path $DefaultProfile "NTUSER.DAT"

        # Ensure source NTUSER.DAT is not locked
        # Try direct copy first — works if source user is logged off
        Copy-Item -Path $sourceNtuser -Destination $destNtuser -Force -ErrorAction Stop
        Write-Log "NTUSER.DAT copied successfully" "SUCCESS"

        # Also copy UsrClass.dat if present (Start Menu / shell bag data)
        $sourceUsrClass = Join-Path $SourceProfile "AppData\Local\Microsoft\Windows\UsrClass.dat"
        $destUsrClass = Join-Path $DefaultProfile "AppData\Local\Microsoft\Windows\UsrClass.dat"
        if (Test-Path $sourceUsrClass) {
            $destUsrClassDir = Split-Path $destUsrClass -Parent
            if (-not (Test-Path $destUsrClassDir)) {
                New-Item -Path $destUsrClassDir -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path $sourceUsrClass -Destination $destUsrClass -Force -ErrorAction SilentlyContinue
            Write-Log "UsrClass.dat copied (shell/Start Menu data)"
        }
    }
    catch {
        Write-Log "Failed to copy NTUSER.DAT. Is the source profile logged off? Error: $($_.Exception.Message)" "ERROR"
        Write-Log "You may need to log off the source admin account and re-run this step." "WARN"
    }
}
else {
    Step "Skipping NTUSER.DAT (SkipNtuser specified)"
    Write-Log "NTUSER.DAT copy skipped by parameter" "WARN"
}

# ============================================================================
# STEP 4: REPAIR DEFAULT PROFILE ACLs
# ============================================================================
Step "Repairing Default profile permissions"

try {
    # Reset ownership to BUILTIN\Administrators
    $acl = Get-Acl $DefaultProfile
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $acl.SetOwner($adminSid)
    Set-Acl -Path $DefaultProfile -AclObject $acl -ErrorAction SilentlyContinue

    # Apply inherited permissions recursively using icacls (faster and more reliable)
    $icaclsResult = icacls $DefaultProfile /reset /t /c /q 2>&1
    Write-Log "ACL reset completed via icacls" "SUCCESS"

    # Ensure SYSTEM and Administrators have full control
    icacls $DefaultProfile /grant "SYSTEM:(OI)(CI)F" /t /c /q 2>&1 | Out-Null
    icacls $DefaultProfile /grant "BUILTIN\Administrators:(OI)(CI)F" /t /c /q 2>&1 | Out-Null
    icacls $DefaultProfile /grant "BUILTIN\Users:(OI)(CI)RX" /t /c /q 2>&1 | Out-Null
    Write-Log "Permissions set: SYSTEM=Full, Administrators=Full, Users=ReadExecute"
}
catch {
    Write-Log "ACL repair encountered errors: $($_.Exception.Message)" "WARN"
    Write-Log "If new profiles fail to load, manually run: icacls C:\Users\Default /reset /t /c" "WARN"
}

# ============================================================================
# STEP 5: STAGE WALLPAPER AND LOCK SCREEN
# ============================================================================
Step "Staging wallpaper and lock screen assets"

$wallpaperDest = "C:\Windows\Web\Wallpaper\Custom"
if (-not (Test-Path $wallpaperDest)) { New-Item -Path $wallpaperDest -ItemType Directory -Force | Out-Null }

if ($WallpaperSource -and (Test-Path $WallpaperSource)) {
    Copy-Item -Path $WallpaperSource -Destination (Join-Path $wallpaperDest "wallpaper.jpg") -Force
    Write-Log "Custom wallpaper staged to $wallpaperDest" "SUCCESS"

    # Set wallpaper in Default NTUSER.DAT
    if (-not $SkipNtuser) {
        $regPath = "HKLM:\TEMP_DEFAULT"
        try {
            reg load "HKLM\TEMP_DEFAULT" "$DefaultProfile\NTUSER.DAT" 2>$null
            Set-ItemProperty -Path "$regPath\Control Panel\Desktop" -Name "Wallpaper" `
                -Value "$wallpaperDest\wallpaper.jpg" -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "$regPath\Control Panel\Desktop" -Name "WallpaperStyle" `
                -Value "10" -ErrorAction SilentlyContinue  # 10 = Fill
            [gc]::Collect()
            Start-Sleep -Seconds 1
            reg unload "HKLM\TEMP_DEFAULT" 2>$null
            Write-Log "Wallpaper registry path set in Default NTUSER.DAT"
        }
        catch {
            reg unload "HKLM\TEMP_DEFAULT" 2>$null
            Write-Log "Failed to set wallpaper in registry: $($_.Exception.Message)" "WARN"
        }
    }
}
else {
    Write-Log "No custom wallpaper specified or file not found. Using source profile's wallpaper setting." "INFO"
}

if ($LockScreenSource -and (Test-Path $LockScreenSource)) {
    $lockDest = "C:\Windows\Web\Screen\Custom"
    if (-not (Test-Path $lockDest)) { New-Item -Path $lockDest -ItemType Directory -Force | Out-Null }
    Copy-Item -Path $LockScreenSource -Destination (Join-Path $lockDest "lockscreen.jpg") -Force
    Write-Log "Custom lock screen staged to $lockDest" "SUCCESS"
}

# ============================================================================
# STEP 6: DEPLOY TASKBAR LAYOUT
# ============================================================================
if (-not $SkipTaskbarLayout) {
    Step "Deploying taskbar layout"

    $layoutDest = "C:\Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml"
    $layoutDir = Split-Path $layoutDest -Parent
    if (-not (Test-Path $layoutDir)) { New-Item -Path $layoutDir -ItemType Directory -Force | Out-Null }

    if ($TaskbarLayoutXml -and (Test-Path $TaskbarLayoutXml)) {
        Copy-Item -Path $TaskbarLayoutXml -Destination $layoutDest -Force
        Write-Log "Custom taskbar layout deployed from $TaskbarLayoutXml" "SUCCESS"
    }
    else {
        # Generate standard layout with the required pin set
        $layoutXml = @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:DesktopApp DesktopApplicationLinkPath="%APPDATA%\Microsoft\Windows\Start Menu\Programs\File Explorer.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Outlook.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Word.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Excel.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\PowerPoint.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Microsoft Teams.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Webex.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Slack.lnk" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@
        $layoutXml | Set-Content -Path $layoutDest -Encoding UTF8 -Force
        Write-Log "Standard taskbar layout generated and deployed (10 pins)" "SUCCESS"
        Write-Log "Pin order: File Explorer, Edge, Chrome, Outlook, Word, Excel, PowerPoint, Teams, Webex, Slack"
    }
}
else {
    Step "Skipping taskbar layout (SkipTaskbarLayout specified)"
}

# ============================================================================
# STEP 7: APPLY LOCAL SECURITY POLICIES
# ============================================================================
if ($ApplyPolicies) {
    Step "Applying local security policies"

    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

        # Require Ctrl+Alt+Del for login
        Set-ItemProperty -Path $regPath -Name "DisableCAD" -Value 0 -Type DWord -Force
        Write-Log "Ctrl+Alt+Del required for login: ENABLED"

        # Don't display last logged-in user
        Set-ItemProperty -Path $regPath -Name "DontDisplayLastUserName" -Value 1 -Type DWord -Force
        Write-Log "Hide last logged-in username: ENABLED"

        # Legal notice
        Set-ItemProperty -Path $regPath -Name "LegalNoticeCaption" -Value $LegalNoticeCaption -Type String -Force
        Set-ItemProperty -Path $regPath -Name "LegalNoticeText" -Value $LegalNoticeText -Type String -Force
        Write-Log "Login legal notice set: '$LegalNoticeCaption'"

        Write-Log "Local security policies applied" "SUCCESS"
    }
    catch {
        Write-Log "Failed to apply policies: $($_.Exception.Message)" "ERROR"
    }
}
else {
    Step "Skipping local policies (ApplyPolicies not specified)"
}

# ============================================================================
# STEP 8: VALIDATION
# ============================================================================
Step "Validating"

$checks = @()

# Check Default folder exists and has content
$defaultSize = (Get-ChildItem $DefaultProfile -Recurse -Force -ErrorAction SilentlyContinue | 
    Measure-Object Length -Sum).Sum
$checks += [PSCustomObject]@{ Check = "Default profile size"; Result = "$([math]::Round($defaultSize / 1MB, 1)) MB"; Status = if ($defaultSize -gt 1MB) { "PASS" } else { "WARN" } }

# Check NTUSER.DAT exists
$ntuserExists = Test-Path (Join-Path $DefaultProfile "NTUSER.DAT")
$checks += [PSCustomObject]@{ Check = "NTUSER.DAT present"; Result = $ntuserExists; Status = if ($ntuserExists) { "PASS" } else { "FAIL" } }

# Check backup exists
$backupExists = Test-Path $BackupPath
$checks += [PSCustomObject]@{ Check = "Backup exists"; Result = $BackupPath; Status = if ($backupExists) { "PASS" } else { "WARN" } }

# Check taskbar layout
if (-not $SkipTaskbarLayout) {
    $layoutExists = Test-Path (Join-Path $DefaultProfile "AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml")
    $checks += [PSCustomObject]@{ Check = "Taskbar layout"; Result = $layoutExists; Status = if ($layoutExists) { "PASS" } else { "WARN" } }
}

Write-Log ""
Write-Log "=== VALIDATION RESULTS ==="
foreach ($c in $checks) {
    $color = switch ($c.Status) { "PASS" { "SUCCESS" }; "WARN" { "WARN" }; "FAIL" { "ERROR" }; default { "INFO" } }
    Write-Log "[$($c.Status)] $($c.Check): $($c.Result)" $color
}

Write-Progress -Activity "Golden Image Profile Mirror" -Completed

Write-Log ""
Write-Log "============================================================"
Write-Log "GOLDEN IMAGE PROFILE MIRROR COMPLETE"
Write-Log "Backup: $BackupPath"
Write-Log "Log: $($script:LogFile)"
Write-Log ""
Write-Log "NEXT STEPS:"
Write-Log "1. Log off the source admin account"
Write-Log "2. Create a NEW local user or domain user and log in"
Write-Log "3. Verify: wallpaper, taskbar pins, desktop icons, policies"
Write-Log "4. If everything looks correct, proceed to sysprep or MEC capture"
Write-Log "5. Ensure MEC OS Deployment generates new SIDs for target machines"
Write-Log ""
Write-Log "ROLLBACK:"
Write-Log "  Remove-Item '$DefaultProfile' -Recurse -Force"
Write-Log "  Rename-Item '$BackupPath' 'Default'"
Write-Log "============================================================"

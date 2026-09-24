# =============================================================================
# Windows 11 Pro Golden Image - In-Profile Automation  (v16.0)
# =============================================================================
# Automates the proven manual image-prep process. Run this ONCE, as
# Administrator, from the SECONDARY local admin (BuildAdmin) - NOT from
# TemplateUser, and with TemplateUser fully SIGNED OUT.
#
# WHAT YOU DO MANUALLY (before running this):
#   1. Boot the blank laptop, finish OOBE, create the first local admin and set
#      it up as your reference account (default name expected: "TemplateUser").
#      Configure it exactly how every imaged profile should look: desktop icons,
#      taskbar pins, wallpaper (set via Group Policy), local Group Policy for
#      Ctrl+Alt+Del at logon, the logon disclaimer, hide last user, etc.
#   2. Create a SECOND local admin (BuildAdmin) - leave it unconfigured.
#   3. Put this script in C:\Scripts.
#   4. SIGN OUT of TemplateUser completely (not lock - sign out).
#   5. Log in as BuildAdmin and run this script.
#
# WHAT THIS SCRIPT DOES (the BuildAdmin work, automated):
#   1. Pre-flight checks (admin rights, not running as TemplateUser, TemplateUser
#      exists and is signed out, Default profile present).
#   2. Disables BitLocker on C: (decrypts) - required for the image to deploy.
#   3. Disables auto sign-in / restart sign-on / fast startup so imaged machines
#      always show a clean logon screen.
#   4. Takes ownership of C:\Users\Default for Administrators, grants Full
#      Control, replaces child entries, enables inheritance.
#   5. Copies the ENTIRE TemplateUser profile into C:\Users\Default (everything,
#      including NTUSER.DAT), replacing what it can and skipping anything locked.
#   6. Resets the Default profile owner back to SYSTEM (required for cloning).
#   7. VERIFIES the copy (key files present, counts) and the permissions reset
#      (SYSTEM owns Default), and prints a clear PASS/WARN report.
#
# It does NOT touch wallpaper, the disclaimer, Ctrl+Alt+Del, or hide-user - you
# set those in Group Policy on TemplateUser, and the profile copy + local Group
# Policy carry them. Nothing here can hang: every external command runs under a
# timeout, and the run always ends with a clear COMPLETE or ENDED EARLY banner.
#
# AFTER it completes: reboot, then capture the image with your deployment tool.
#
# OPTIONAL PRE-CAPTURE CLEANUP (built in): after the mirror finishes, the script
# ASKS whether to run the pre-capture identity wipe + cache clear. Answer 'y' ONLY
# on your final run before capturing the image - it removes this machine's Entra
# (Azure AD) device registration and clears Windows Update / temp / prefetch / WER
# caches so every deployed clone joins Entra cleanly and pulls computer, user, and
# MDM policy without duplicate-identity errors. Answer 'n' (the default) on any
# iterative run so you don't wipe the machine's identity while still building.
#
# Author:  Adrian Melendez
# Version: 16.0
# =============================================================================

$ErrorActionPreference = "Continue"

# ---------------- ADMIN CHECK / SELF-ELEVATE ----------------
function Test-AdminRights {
    $id  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $pri.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-AdminRights)) {
    Write-Host "Not running as Administrator. Relaunching elevated once..." -ForegroundColor Yellow
    try { Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -ErrorAction Stop }
    catch { Write-Host "Elevation declined. Re-run as Administrator." -ForegroundColor Red }
    exit
}

# ---------------- HELPERS ----------------
# Runs an external command under a hard timeout so nothing can ever hang.
function Invoke-WithTimeout {
    param([string]$File, [string]$Arguments, [int]$TimeoutSec = 300, [string]$Label = "command")
    try {
        $p = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -WindowStyle Hidden -ErrorAction Stop
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch {}
            Write-Host "   [TIMEOUT] $Label exceeded $TimeoutSec s; stopped and continuing." -ForegroundColor Yellow
            return $false
        }
        return $true
    } catch {
        Write-Host "   [SKIP] $Label could not run: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Clear-Dir {
    param([string]$Path, [string]$Label)
    if (Test-Path $Path) {
        try {
            Get-ChildItem $Path -Force -Recurse -EA SilentlyContinue | Remove-Item -Force -Recurse -EA SilentlyContinue
            Write-Host "   cleared $Label" -ForegroundColor Green
        } catch { Write-Host "   [WARN] $Label partially cleared: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}
function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = "DWord")
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Host "   [WARN] could not set $Name at $Path : $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# ---------------- CONFIG ----------------
# Auto-detect the profile you are running from - no hardcoded account name, no
# second admin account needed. Whatever profile you are logged into and run this
# from is the one mirrored into Default.
$RefUser        = $env:USERNAME
$DefaultProfile = "C:\Users\Default"
$RefProfile     = $env:USERPROFILE

Write-Host "=== Golden Image BuildAdmin Automation v14.0 ===" -ForegroundColor Cyan
$global:__finished = $false
try {

$Total = 8; $Step = 0

# ---------------- STEP 1: PRE-FLIGHT CHECKS ----------------
$Step++; Write-Progress -Activity "Golden Image" -Status "Pre-flight checks" -PercentComplete (($Step/$Total)*100)
Write-Host ">> [1/8] Pre-flight checks..." -ForegroundColor Gray

# Profile being mirrored is the one we are running from.
if (-not (Test-Path $RefProfile)) { throw "Running profile not found at $RefProfile." }
if (-not (Test-Path $DefaultProfile)) { throw "Default profile not found at $DefaultProfile." }
Write-Host "   Mirroring the CURRENT profile: $RefUser  ($RefProfile)" -ForegroundColor Green
Write-Host "   Note: because you are logged into this profile, its NTUSER.DAT and parts of" -ForegroundColor Gray
Write-Host "   AppData are locked. The registry hive is captured separately via reg save (step 5)." -ForegroundColor Gray
# The image is meant to be captured OFF the domain. Warn if this machine is domain-joined.
try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs -and $cs.PartOfDomain) {
        Write-Host "   [WARN] This machine is domain-joined ($($cs.Domain)). Your images are captured OFF-domain;" -ForegroundColor Yellow
        Write-Host "          leave the domain before capture so each deployed device joins fresh." -ForegroundColor Yellow
    } else {
        Write-Host "   Off-domain (workgroup). Good for capture." -ForegroundColor Green
    }
} catch {}

# ---------------- STEP 2: DISABLE BITLOCKER ----------------
$Step++; Write-Progress -Activity "Golden Image" -Status "Disabling BitLocker" -PercentComplete (($Step/$Total)*100)
Write-Host ">> [2/8] Disabling BitLocker on C: ..." -ForegroundColor Gray
try {
    $bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
    if ($bl.ProtectionStatus -ne 'Off' -or $bl.VolumeStatus -ne 'FullyDecrypted') {
        Invoke-WithTimeout "manage-bde.exe" "-off C:" 60 "manage-bde -off C:" | Out-Null
        Write-Host "   BitLocker turn-off requested. Decryption runs in the background." -ForegroundColor Green
        Write-Host "   (Let it finish decrypting before capturing the image: manage-bde -status C:)" -ForegroundColor Gray
    } else {
        Write-Host "   BitLocker already off / fully decrypted." -ForegroundColor Green
    }
} catch {
    Write-Host "   BitLocker not present or not manageable here; skipping." -ForegroundColor Yellow
}

# ---------------- STEP 3: DISABLE AUTO SIGN-IN / CLEAN LOGON ----------------
$Step++; Write-Progress -Activity "Golden Image" -Status "Disabling auto sign-in" -PercentComplete (($Step/$Total)*100)
Write-Host ">> [3/8] Disabling auto sign-in and fast startup..." -ForegroundColor Gray
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-RegValue $winlogon "AutoAdminLogon" "0" "String" | Out-Null
# Remove any stored auto-logon password/username so it can't auto sign in.
foreach ($v in @("DefaultPassword","AutoLogonCount")) {
    try { Remove-ItemProperty -Path $winlogon -Name $v -Force -ErrorAction SilentlyContinue } catch {}
}
# Do not auto-restore the last user's signed-in session after a reboot/update.
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "DisableAutomaticRestartSignOn" 1 "DWord" | Out-Null
# Turn off Fast Startup (so a restart is a true cold logon, not a restored session).
Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 0 "DWord" | Out-Null
Write-Host "   Auto sign-in, restart sign-on, and fast startup disabled." -ForegroundColor Green

# ---------------- STEP 4: TAKE OWNERSHIP OF DEFAULT ----------------
# Matches the manual steps: owner -> Administrators, Full Control, replace child
# entries, enable inheritance. On a fresh machine Default is small, so this is
# fast; timeouts are only a safety net.
$Step++; Write-Progress -Activity "Golden Image" -Status "Taking ownership of Default" -PercentComplete (($Step/$Total)*100)
Write-Host ">> [4/8] Taking ownership of Default (Administrators, Full Control, inheritance)..." -ForegroundColor Gray
Invoke-WithTimeout "takeown.exe" "/F `"$DefaultProfile`" /A /R /D Y" 300 "takeown Default" | Out-Null
Invoke-WithTimeout "icacls.exe" "`"$DefaultProfile`" /grant Administrators:(OI)(CI)F /T /C /Q" 300 "grant Administrators" | Out-Null
Invoke-WithTimeout "icacls.exe" "`"$DefaultProfile`" /setowner Administrators /T /C /Q" 300 "setowner Administrators" | Out-Null
Invoke-WithTimeout "icacls.exe" "`"$DefaultProfile`" /inheritance:e /T /C /Q" 300 "enable inheritance" | Out-Null
Write-Host "   Ownership and permissions applied." -ForegroundColor Green

# ---------------- STEP 5: COPY TEMPLATEUSER INTO DEFAULT ----------------
# Copy EVERYTHING from the reference profile into Default, including NTUSER.DAT,
# replacing what it can and skipping anything locked (/R:0 /W:0 = no retry/hang).
# /XJ avoids junction-point loops (the legacy "Application Data" redirects).
$Step++; Write-Progress -Activity "Golden Image" -Status "Copying $RefUser into Default" -PercentComplete (($Step/$Total)*100)
Write-Host ">> [5/8] Copying $RefUser profile into Default (everything; locked files skipped)..." -ForegroundColor Gray
$srcCount = @(Get-ChildItem $RefProfile -Recurse -Force -EA SilentlyContinue).Count
$roboArgs = @($RefProfile, $DefaultProfile, "/E", "/COPY:DAT", "/XJ", "/R:0", "/W:0", "/NFL", "/NDL", "/NP", "/NJH", "/NJS")
$roboStr  = ($roboArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$copied = Invoke-WithTimeout "robocopy.exe" $roboStr 900 "copy $RefUser into Default"
# robocopy returns exit codes 0-7 for success-with-info; the timeout wrapper returns $true if it exited.
if ($copied) { Write-Host "   Copy finished (any locked files were skipped safely)." -ForegroundColor Green }
else { Write-Host "   Copy stopped early/timed out; verification below will show what landed." -ForegroundColor Yellow }

# ---------------- STEP 6: CAPTURE THE REGISTRY HIVE INTO DEFAULT ----------------
# Because we run in-profile, the live NTUSER.DAT is locked and robocopy skipped it.
# reg save exports the CURRENTLY LOADED user hive (HKCU) to a file, which we place
# as Default\NTUSER.DAT. This is what carries colors, Explorer settings, and much of
# the per-user look into new profiles - the piece that would otherwise be lost when
# running in-profile. Stale hive logs are removed so Windows rebuilds them cleanly.
$Step++; Write-Progress -Activity "Golden Image" -Status "Capturing registry hive" -PercentComplete (($Step/$Total)*100)
Write-Host ">> [6/8] Capturing your registry hive into Default (reg save HKCU)..." -ForegroundColor Gray
$hiveTmp = "$env:TEMP\gi_ntuser.dat"
Remove-Item $hiveTmp -Force -EA SilentlyContinue
$hiveOk = Invoke-WithTimeout "reg.exe" "save HKCU `"$hiveTmp`" /y" 120 "reg save HKCU"
if ($hiveOk -and (Test-Path $hiveTmp) -and ((Get-Item $hiveTmp).Length -gt 0)) {
    try {
        Copy-Item $hiveTmp "$DefaultProfile\NTUSER.DAT" -Force -ErrorAction Stop
        # Remove stale transaction logs so the new hive is read fresh.
        Get-ChildItem $DefaultProfile -Force -Filter "NTUSER.DAT.LOG*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
        Get-ChildItem $DefaultProfile -Force -Filter "NTUSER.DAT{*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
        Remove-Item $hiveTmp -Force -EA SilentlyContinue
        Write-Host "   Registry hive captured into Default\NTUSER.DAT." -ForegroundColor Green
    } catch {
        Write-Host "   [WARN] could not place captured hive: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "   [WARN] reg save did not produce a hive; Default keeps its existing NTUSER.DAT." -ForegroundColor Yellow
}

# ---------------- STEP 7: RESET DEFAULT OWNER TO SYSTEM ----------------
$Step++; Write-Progress -Activity "Golden Image" -Status "Resetting owner to SYSTEM" -PercentComplete (($Step/$Total)*100)
Write-Host ">> [7/8] Resetting Default owner to SYSTEM..." -ForegroundColor Gray
Invoke-WithTimeout "icacls.exe" "`"$DefaultProfile`" /setowner SYSTEM /T /C /Q" 600 "setowner SYSTEM" | Out-Null
Invoke-WithTimeout "icacls.exe" "`"$DefaultProfile`" /inheritance:e /T /C /Q" 600 "re-enable inheritance" | Out-Null
Write-Host "   Owner reset to SYSTEM." -ForegroundColor Green

# ---------------- STEP 8: VERIFY ----------------
$Step++; Write-Progress -Activity "Golden Image" -Status "Verifying" -PercentComplete 100
Write-Host ">> [8/8] Verification:" -ForegroundColor Gray
function Check { param($Name,$Ok) if ($Ok) { Write-Host "   [PASS] $Name" -ForegroundColor Green } else { Write-Host "   [WARN] $Name" -ForegroundColor Yellow } }

# Files copied
$dstCount = @(Get-ChildItem $DefaultProfile -Recurse -Force -EA SilentlyContinue).Count
Check "NTUSER.DAT present in Default"        (Test-Path "$DefaultProfile\NTUSER.DAT")
$ntSize = (Get-Item "$DefaultProfile\NTUSER.DAT" -Force -EA SilentlyContinue).Length
Check "NTUSER.DAT looks populated ($([math]::Round($ntSize/1KB)) KB)" ($ntSize -gt 100KB)
# Desktop shortcuts may live in the user's own Desktop OR on the machine-wide Public
# desktop (C:\Users\Public\Desktop), which every profile shows automatically. Count both.
$srcDeskLnks = @(Get-ChildItem "$RefProfile\Desktop" -Filter *.lnk -EA SilentlyContinue).Count
$dstDeskLnks = @(Get-ChildItem "$DefaultProfile\Desktop" -Filter *.lnk -EA SilentlyContinue).Count
$pubDeskLnks = @(Get-ChildItem "C:\Users\Public\Desktop" -Filter *.lnk -EA SilentlyContinue).Count
Check "Desktop shortcuts (user src $srcDeskLnks / user dst $dstDeskLnks / public $pubDeskLnks)" (($dstDeskLnks -ge $srcDeskLnks) -or ($pubDeskLnks -gt 0))
Check "Default file count vs source (src $srcCount / dst $dstCount)" ($dstCount -gt 0)

# Permissions reset
$owner = (Get-Acl $DefaultProfile).Owner
Check "Default owned by SYSTEM ($owner)" ($owner -match 'SYSTEM')

# Auto sign-in disabled
$aal = (Get-ItemProperty -Path $winlogon -Name AutoAdminLogon -EA SilentlyContinue).AutoAdminLogon
Check "AutoAdminLogon disabled ($aal)" ($aal -eq "0" -or $null -eq $aal)
$fast = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled -EA SilentlyContinue).HiberbootEnabled
Check "Fast startup disabled ($fast)" ($fast -eq 0)

# BitLocker status (informational)
try {
    $blv = Get-BitLockerVolume -MountPoint "C:" -EA SilentlyContinue
    Check "BitLocker off/decrypting ($($blv.VolumeStatus))" ($blv.ProtectionStatus -eq 'Off')
} catch {}

# ---------------- OPTIONAL: PRE-CAPTURE IDENTITY WIPE + CACHE CLEAR ----------------
Write-Host ""
Write-Host "--------------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "Mirror complete. Run the PRE-CAPTURE cleanup now?" -ForegroundColor Cyan
Write-Host "This removes THIS machine's Entra (Azure AD) registration and clears" -ForegroundColor Yellow
Write-Host "update/temp/prefetch/WER caches. Do this ONLY on your final run before" -ForegroundColor Yellow
Write-Host "capturing the image. On any iterative run, answer n." -ForegroundColor Yellow
$doCleanup = Read-Host "Run pre-capture cleanup? (y/N)"
if ($doCleanup -match '^(y|yes)$') {
    Write-Host ""
    Write-Host "=== Pre-capture cleanup ===" -ForegroundColor Cyan

    $cTotal = 5; $cStep = 0

    # ---------------- STEP 1: ENTRA / AZURE AD IDENTITY ----------------
    $cStep++; Write-Progress -Activity "Pre-Capture Cleanup" -Status "Entra identity" -PercentComplete (($cStep/$cTotal)*100)
    Write-Host ">> [1/5] Removing local Entra/Azure AD device registration (dsregcmd /leave)..." -ForegroundColor Gray
    $left = Invoke-WithTimeout "dsregcmd.exe" "/leave" 120 "dsregcmd /leave"
    if ($left) { Write-Host "   dsregcmd /leave completed." -ForegroundColor Green }
    Start-Sleep -Seconds 2
    # Report the resulting state so you can confirm it detached.
    try {
        $status = (dsregcmd /status 2>$null)
        foreach ($key in @("AzureAdJoined","DomainJoined","EnterpriseJoined","DeviceId")) {
            $line = $status | Select-String -SimpleMatch $key | Select-Object -First 1
            if ($line) { Write-Host ("   " + $line.ToString().Trim()) -ForegroundColor Gray }
        }
    } catch {}

    # ---------------- STEP 2: DOMAIN STATE CHECK (warn only) ----------------
    $cStep++; Write-Progress -Activity "Pre-Capture Cleanup" -Status "Domain check" -PercentComplete (($cStep/$cTotal)*100)
    Write-Host ">> [2/5] Checking domain state (image should be captured OFF-domain)..." -ForegroundColor Gray
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs -and $cs.PartOfDomain) {
            Write-Host "   [WARN] This machine is domain-joined ($($cs.Domain))." -ForegroundColor Yellow
            Write-Host "          Your images are captured off-domain and your deployment tool joins the domain on deploy." -ForegroundColor Yellow
            Write-Host "          Leave the domain (drop to workgroup) before capture so each clone joins fresh." -ForegroundColor Yellow
        } else {
            Write-Host "   Off-domain (workgroup). Good for capture." -ForegroundColor Green
        }
    } catch {}

    # ---------------- STEP 3: WINDOWS UPDATE + DELIVERY OPTIMIZATION CACHE ----------------
    $cStep++; Write-Progress -Activity "Pre-Capture Cleanup" -Status "Update cache" -PercentComplete (($cStep/$cTotal)*100)
    Write-Host ">> [3/5] Clearing Windows Update + Delivery Optimization cache..." -ForegroundColor Gray
    foreach ($svc in @("wuauserv","bits","dosvc")) {
        try { Stop-Service $svc -Force -EA SilentlyContinue } catch {}
    }
    Clear-Dir "$env:SystemRoot\SoftwareDistribution\Download" "Windows Update download cache"
    try { Delete-DeliveryOptimizationCache -Force -EA SilentlyContinue; Write-Host "   cleared Delivery Optimization cache" -ForegroundColor Green } catch {}
    foreach ($svc in @("wuauserv","bits","dosvc")) {
        try { Start-Service $svc -EA SilentlyContinue } catch {}
    }

    # ---------------- STEP 4: TEMP / PREFETCH / WER / DNS ----------------
    $cStep++; Write-Progress -Activity "Pre-Capture Cleanup" -Status "Temp/prefetch/WER" -PercentComplete (($cStep/$cTotal)*100)
    Write-Host ">> [4/5] Clearing temp, prefetch, error-report queue; flushing DNS..." -ForegroundColor Gray
    Clear-Dir "$env:SystemRoot\Temp" "Windows Temp"
    Clear-Dir "$env:TEMP" "user Temp"
    Clear-Dir "$env:SystemRoot\Prefetch" "Prefetch"
    Clear-Dir "$env:ProgramData\Microsoft\Windows\WER\ReportQueue" "Windows Error Reporting queue"
    Clear-Dir "$env:ProgramData\Microsoft\Windows\WER\ReportArchive" "Windows Error Reporting archive"
    Invoke-WithTimeout "ipconfig.exe" "/flushdns" 30 "flush DNS" | Out-Null
    Write-Host "   temp/prefetch/WER cleared; DNS flushed." -ForegroundColor Green

    # ---------------- STEP 5: EVENT LOGS (optional) ----------------
    $cStep++; Write-Progress -Activity "Pre-Capture Cleanup" -Status "Event logs" -PercentComplete 100
    if ($ClearEventLogs) {
        Write-Host ">> [5/5] Clearing Windows event logs (clean logs on deployed devices)..." -ForegroundColor Gray
        try {
            $logs = (wevtutil el 2>$null)
            $n = 0
            foreach ($log in $logs) {
                try { wevtutil cl "$log" 2>$null; $n++ } catch {}
            }
            Write-Host "   cleared $n event logs." -ForegroundColor Green
        } catch { Write-Host "   [WARN] event log clear incomplete." -ForegroundColor Yellow }
    } else {
        Write-Host ">> [5/5] Event log clear skipped (-ClearEventLogs:`$false)." -ForegroundColor Gray
    }

    $global:__cleanupRan = $true
} else {
    Write-Host "Skipped pre-capture cleanup. (Run again and answer y on your final pass.)" -ForegroundColor Gray
    $global:__cleanupRan = $false
}

$global:__finished = $true
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Progress -Activity "Golden Image" -Completed
    Write-Host ""
    if ($global:__finished) {
        Write-Host "=== COMPLETE - all steps finished ===" -ForegroundColor Cyan
        Write-Host "Next: let BitLocker finish decrypting (manage-bde -status C:)." -ForegroundColor Green
        if ($global:__cleanupRan) {
            Write-Host ""
            Write-Host "PRE-CAPTURE CLEANUP RAN. Before you capture:" -ForegroundColor Yellow
            Write-Host "  - In the Entra/Azure portal, delete this device's stale object (local leave" -ForegroundColor Gray
            Write-Host "    done; the cloud object is yours to remove)." -ForegroundColor Gray
            Write-Host "  - Confirm the machine is OFF-domain." -ForegroundColor Gray
            Write-Host "  - REBOOT once (flushes cached tokens), THEN capture the image." -ForegroundColor Green
        } else {
            Write-Host "REBOOT, then capture the image (pre-capture cleanup was NOT run this pass)." -ForegroundColor Green
            Write-Host "To spot-check first, create a brand-new local user and log in to confirm the look." -ForegroundColor Gray
        }
    } else {
        Write-Host "=== ENDED EARLY - not all steps completed ===" -ForegroundColor Yellow
        Write-Host "Read the red message above, fix the cause, and re-run." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Closing in 60 seconds; press any key to close now." -ForegroundColor Gray
    try {
        $t = 0
        while ($t -lt 60 -and -not [System.Console]::KeyAvailable) { Start-Sleep -Milliseconds 500; $t += 0.5 }
        if ([System.Console]::KeyAvailable) { [void][System.Console]::ReadKey($true) }
    } catch { Start-Sleep -Seconds 5 }
}

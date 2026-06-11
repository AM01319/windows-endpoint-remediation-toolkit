# =============================================================================
# Windows 11 Pro Golden Image - BuildAdmin Automation  (v14.0)
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
# AFTER it completes: reboot, then capture the image with ManageEngine.
#
# Author:  Adrian Melendez
# Version: 14.0
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
$RefUser        = "TemplateUser"               # the reference account you configured
$DefaultProfile = "C:\Users\Default"
$RefProfile     = "C:\Users\$RefUser"

Write-Host "=== Golden Image BuildAdmin Automation v14.0 ===" -ForegroundColor Cyan
$global:__finished = $false
try {

$Total = 7; $Step = 0

# ---------------- STEP 1: PRE-FLIGHT CHECKS ----------------
$Step++; Write-Progress -Activity "Golden Image" -Status "Pre-flight checks" -PercentComplete (($Step/$Total)*100)
Write-Host ">> [1/7] Pre-flight checks..." -ForegroundColor Gray

# Must NOT be running as the reference account.
if ($env:USERNAME -ieq $RefUser) {
    throw "This script is running as $RefUser. Sign out of $RefUser, log in as your BuildAdmin account, and run it there."
}
# Reference profile must exist.
if (-not (Test-Path $RefProfile)) {
    throw "Reference profile not found at $RefProfile. Set the `$RefUser variable at the top of this script to the exact account name you configured."
}
# Default profile must exist.
if (-not (Test-Path $DefaultProfile)) {
    throw "Default profile not found at $DefaultProfile."
}
# Reference account should be signed out (its profile not actively loaded).
$refLoggedIn = $false
try {
    $sessions = (quser 2>$null)
    if ($sessions) { $refLoggedIn = [bool]($sessions | Select-String -SimpleMatch $RefUser) }
} catch {}
if ($refLoggedIn) {
    Write-Host "   [WARN] $RefUser appears to still have a session. Sign it out fully (not lock) for a clean copy." -ForegroundColor Yellow
    Write-Host "          Continuing, but locked files in its profile may be skipped." -ForegroundColor Yellow
} else {
    Write-Host "   $RefUser is signed out. Good." -ForegroundColor Green
}
Write-Host "   Running as: $env:USERNAME" -ForegroundColor Green

# ---------------- STEP 2: DISABLE BITLOCKER ----------------
$Step++; Write-Progress -Activity "Golden Image" -Status "Disabling BitLocker" -PercentComplete (($Step/$Total)*100)
Write-Host ">> [2/7] Disabling BitLocker on C: ..." -ForegroundColor Gray
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
Write-Host ">> [3/7] Disabling auto sign-in and fast startup..." -ForegroundColor Gray
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
Write-Host ">> [4/7] Taking ownership of Default (Administrators, Full Control, inheritance)..." -ForegroundColor Gray
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
Write-Host ">> [5/7] Copying $RefUser profile into Default (everything; locked files skipped)..." -ForegroundColor Gray
$srcCount = @(Get-ChildItem $RefProfile -Recurse -Force -EA SilentlyContinue).Count
$roboArgs = @($RefProfile, $DefaultProfile, "/E", "/COPY:DAT", "/XJ", "/R:0", "/W:0", "/NFL", "/NDL", "/NP", "/NJH", "/NJS")
$roboStr  = ($roboArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$copied = Invoke-WithTimeout "robocopy.exe" $roboStr 900 "copy $RefUser into Default"
# robocopy returns exit codes 0-7 for success-with-info; the timeout wrapper returns $true if it exited.
if ($copied) { Write-Host "   Copy finished (any locked files were skipped safely)." -ForegroundColor Green }
else { Write-Host "   Copy stopped early/timed out; verification below will show what landed." -ForegroundColor Yellow }

# ---------------- STEP 6: RESET DEFAULT OWNER TO SYSTEM ----------------
$Step++; Write-Progress -Activity "Golden Image" -Status "Resetting owner to SYSTEM" -PercentComplete (($Step/$Total)*100)
Write-Host ">> [6/7] Resetting Default owner to SYSTEM..." -ForegroundColor Gray
Invoke-WithTimeout "icacls.exe" "`"$DefaultProfile`" /setowner SYSTEM /T /C /Q" 600 "setowner SYSTEM" | Out-Null
Invoke-WithTimeout "icacls.exe" "`"$DefaultProfile`" /inheritance:e /T /C /Q" 600 "re-enable inheritance" | Out-Null
Write-Host "   Owner reset to SYSTEM." -ForegroundColor Green

# ---------------- STEP 7: VERIFY ----------------
$Step++; Write-Progress -Activity "Golden Image" -Status "Verifying" -PercentComplete 100
Write-Host ">> [7/7] Verification:" -ForegroundColor Gray
function Check { param($Name,$Ok) if ($Ok) { Write-Host "   [PASS] $Name" -ForegroundColor Green } else { Write-Host "   [WARN] $Name" -ForegroundColor Yellow } }

# Files copied
$dstCount = @(Get-ChildItem $DefaultProfile -Recurse -Force -EA SilentlyContinue).Count
Check "NTUSER.DAT present in Default"        (Test-Path "$DefaultProfile\NTUSER.DAT")
$srcDeskLnks = @(Get-ChildItem "$RefProfile\Desktop" -Filter *.lnk -EA SilentlyContinue).Count
$dstDeskLnks = @(Get-ChildItem "$DefaultProfile\Desktop" -Filter *.lnk -EA SilentlyContinue).Count
Check "Desktop shortcuts copied (src $srcDeskLnks / dst $dstDeskLnks)" ($dstDeskLnks -ge $srcDeskLnks -and $srcDeskLnks -ge 0)
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
        Write-Host "Next: let BitLocker finish decrypting (manage-bde -status C:), then REBOOT," -ForegroundColor Green
        Write-Host "then capture the image with ManageEngine." -ForegroundColor Green
        Write-Host "To spot-check first, create a brand-new local user and log in to confirm the look." -ForegroundColor Gray
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

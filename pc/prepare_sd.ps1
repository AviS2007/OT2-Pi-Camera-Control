<#
.SYNOPSIS
  Prepare the camera Pi's microSD card from this PC: no monitor, keyboard or network needed.

.DESCRIPTION
  1. Shut the Pi down, pull its microSD card, put it in this PC's card reader.
  2. Run this script. It finds the 'bootfs' partition and:
       - copies pi/* + boot/* to <bootfs>\ot2cam\
       - writes ot2cam\ot2cam.env from the parameters below (Wi-Fi, Tailscale, user...)
       - adds firstrun.sh and the systemd.run hook to cmdline.txt
       - adds dtoverlay=dwc2,dr_mode=peripheral to config.txt (USB-C networking)
       - creates the 'ssh' flag file
  3. Put the card back, power the Pi, wait ~2 minutes (it reboots once by itself).
  4. Plug USB-C into this PC and run pc\find_pi.ps1.

.EXAMPLE
  .\prepare_sd.ps1
  .\prepare_sd.ps1 -WifiSsid "LabRouter" -WifiPsk "secret" -TailscaleAuthKey "tskey-auth-..."
  .\prepare_sd.ps1 -PiUser ot2 -PiPassword "changeme" -EduroamId "utorid@utoronto.ca" -EduroamPassword "..."
#>
[CmdletBinding()]
param(
  [string]$Drive,                      # e.g. "E:" ; auto-detected when omitted
  [string]$PiUser = "",
  [string]$PiPassword = "",
  [string]$Hostname = "ot2-cam-pi",
  [string]$WifiSsid = "",
  [string]$WifiPsk = "",
  [string]$WifiCountry = "CA",
  [string]$EduroamId = "",
  [string]$EduroamPassword = "",
  [string]$TailscaleAuthKey = "",
  [string]$HotspotSsid = "OT2-Cam-Pi",   # fallback AP the Pi broadcasts when no known Wi-Fi is in range ("" = off)
  [string]$HotspotPsk = "ot2camera",
  [string]$FirstRun = ""                 # alternative first-boot script (default boot\firstrun.sh); e.g. boot\firstrun-diag.sh
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# ---- locate bootfs
if (-not $Drive) {
  $vol = Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystemLabel -eq "bootfs" } | Select-Object -First 1
  if (-not $vol) {
    $vol = Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\config.txt") -and (Test-Path "$($_.DriveLetter):\cmdline.txt") } | Select-Object -First 1
  }
  if (-not $vol) { throw "No Pi boot partition found. Insert the microSD card (partition label 'bootfs')." }
  $Drive = "$($vol.DriveLetter):"
}
if (-not (Test-Path "$Drive\config.txt")) { throw "$Drive has no config.txt - not a Pi boot partition." }
Write-Host "Boot partition: $Drive  (label: $((Get-Volume -DriveLetter $Drive[0]).FileSystemLabel))"

function Write-LF([string]$Path, [string]$Text) {
  # Pi scripts must have LF endings and no BOM
  $Text = $Text -replace "`r`n", "`n"
  [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

# ---- copy bundle
$dst = Join-Path $Drive "ot2cam"
New-Item -ItemType Directory -Force $dst | Out-Null
foreach ($f in (Get-ChildItem "$Root\pi\*" -File) + (Get-ChildItem "$Root\boot\*" -File)) {
  if ($f.Name -like "*.example") { continue }
  Write-LF (Join-Path $dst $f.Name) (Get-Content $f.FullName -Raw)
}
$fr = if ($FirstRun) { (Resolve-Path $FirstRun).Path } else { "$Root\boot\firstrun.sh" }
Write-LF (Join-Path $Drive "firstrun.sh") (Get-Content $fr -Raw)
Write-Host "first-boot script: $fr"

# ---- env file for first boot
$env_ = @"
PI_USER=$PiUser
PI_PASSWORD=$PiPassword
HOSTNAME_NEW=$Hostname
WIFI_SSID=$WifiSsid
WIFI_PSK=$WifiPsk
WIFI_COUNTRY=$WifiCountry
EDUROAM_ID=$EduroamId
EDUROAM_PASSWORD=$EduroamPassword
TAILSCALE_AUTHKEY=$TailscaleAuthKey
HOTSPOT_SSID=$HotspotSsid
HOTSPOT_PSK=$HotspotPsk

"@
Write-LF (Join-Path $dst "ot2cam.env") $env_

# ---- ssh flag
if (-not (Test-Path "$Drive\ssh")) { New-Item -ItemType File "$Drive\ssh" | Out-Null }

# ---- config.txt: USB gadget overlay
$cfg = Get-Content "$Drive\config.txt" -Raw
if ($cfg -notmatch "(?m)^dtoverlay=dwc2,dr_mode=peripheral") {
  # the [all] section is last in the stock file, so appending lands in [all]
  if ($cfg -notmatch "(?m)^\[all\]") { $cfg = $cfg.TrimEnd() + "`n`n[all]`n" }
  $cfg = $cfg.TrimEnd() + "`n`n# OT-2 camera Pi: USB-C port as a USB device (network + serial)`ndtoverlay=dwc2,dr_mode=peripheral`n"
  Write-LF "$Drive\config.txt" $cfg
  Write-Host "config.txt: added dtoverlay=dwc2,dr_mode=peripheral"
}

# ---- cmdline.txt: one-shot firstrun hook
$cmd = (Get-Content "$Drive\cmdline.txt" -Raw).Trim()
if ($cmd -notmatch "systemd\.run=") {
  $cmd += " systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target"
  Write-LF "$Drive\cmdline.txt" ($cmd + "`n")
  Write-Host "cmdline.txt: added firstrun hook"
} else {
  Write-Host "cmdline.txt: firstrun hook already present"
}

Write-Host ""
Write-Host "Done. Eject $Drive, put the card in the Pi, power it, wait ~2 min (it reboots once)."
Write-Host "Then connect USB-C to this PC and run:  pc\find_pi.ps1"
Write-Host "First-boot log will appear on the card as ot2cam-firstrun.log if you need to debug."

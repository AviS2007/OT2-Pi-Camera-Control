<#
.SYNOPSIS
  Find the camera Pi from this PC (USB-C gadget link, mDNS, or Tailscale) and print how to reach it.
.EXAMPLE
  .\find_pi.ps1              # probe everything
  .\find_pi.ps1 -Open        # also open the live view in the browser
#>
param([switch]$Open, [string]$Hostname = "ot2-cam-pi")
$key = "$env:USERPROFILE\.ssh\ot2cam_ed25519"
$found = @()

Write-Host "== USB network adapters"
$usb = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "NCM|RNDIS|USB Ethernet|Gadget|Composite" }
if ($usb) {
  $usb | Format-Table Name, InterfaceDescription, Status, LinkSpeed -AutoSize
  foreach ($a in $usb) {
    $ip = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ip) { Write-Host ("   {0} has {1}" -f $a.Name, ($ip.IPAddress -join ", ")) }
  }
} else {
  Write-Host "   none. (Pi not booted / gadget not configured / cable is power-only)"
}

Write-Host "== USB serial ports (Pi console shows up as 'USB Serial Device')"
Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue | Select-Object Status, FriendlyName | Format-Table -AutoSize

Write-Host "== probing candidates"
$cands = @("10.55.0.1", "$Hostname.local", $Hostname)
if (Get-Command tailscale -ErrorAction SilentlyContinue) {
  $ts = tailscale status 2>$null | Select-String -Pattern "\s$Hostname\s" | ForEach-Object { ($_ -split "\s+")[0] }
  if ($ts) { $cands += $ts }
}
foreach ($c in $cands) {
  $ssh = Test-NetConnection $c -Port 22 -WarningAction SilentlyContinue -InformationLevel Quiet
  $web = Test-NetConnection $c -Port 8080 -WarningAction SilentlyContinue -InformationLevel Quiet
  Write-Host ("   {0,-22} ssh:{1,-5} camserver:{2}" -f $c, $ssh, $web)
  if ($ssh -or $web) { $found += $c }
}

if (-not $found) {
  Write-Host ""
  Write-Host "Pi not reachable. Checklist:"
  Write-Host "  - Is the Pi booting (green LED blinking)? A laptop USB-C port may not supply enough power."
  Write-Host "    The USB-C port is shared between power and data, so for USB-C data from this PC power the"
  Write-Host "    Pi via the GPIO 5V pins or a PoE+ HAT, or use Wi-Fi + Tailscale instead (see README)."
  Write-Host "  - Was the SD card prepared with pc\prepare_sd.ps1 and did the Pi finish its first boot (2 min)?"
  Write-Host "  - USB adapter present but with a 169.254.x.x address? The Pi's DHCP is not up; as admin run:"
  Write-Host "      New-NetIPAddress -InterfaceAlias '<adapter name>' -IPAddress 10.55.0.2 -PrefixLength 24"
  exit 1
}

$h = $found[0]
Write-Host ""
Write-Host "Pi reachable at $h"
Write-Host "  live view / record:   http://$h:8080/"
Write-Host "  ssh:                  ssh -i `"$key`" <user>@$h"
Write-Host "  pull recordings:      pc\pull_videos.ps1 -PiHost $h -User <user>"
if ($Open) { Start-Process "http://$h:8080/" }

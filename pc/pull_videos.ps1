<#
.SYNOPSIS
  Copy new recordings from the Pi into .\recordings (skips files already present).
.EXAMPLE
  .\pull_videos.ps1 -User pi
  .\pull_videos.ps1 -PiHost ot2-cam-pi.local -User ot2 -Remux
#>
param(
  [string]$PiHost = "10.55.0.1",
  [Parameter(Mandatory = $true)][string]$User,
  [string]$RemoteDir = "recordings",
  [switch]$Remux          # convert raw .h264 to .mp4 locally (needs ffmpeg on PATH)
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dst = Join-Path $Root "recordings"
New-Item -ItemType Directory -Force $dst | Out-Null
$key = "$env:USERPROFILE\.ssh\ot2cam_ed25519"
$sshOpts = @("-i", $key, "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=8")

$remote = ssh @sshOpts "$User@$PiHost" "ls -1 $RemoteDir 2>/dev/null"
if (-not $remote) { Write-Host "No recordings on the Pi."; exit 0 }

$n = 0
foreach ($f in $remote) {
  $f = $f.Trim(); if (-not $f) { continue }
  $local = Join-Path $dst $f
  if (Test-Path $local) { continue }
  Write-Host "pulling $f"
  scp @sshOpts "$User@${PiHost}:$RemoteDir/$f" $local
  $n++
  if ($Remux -and $f -like "*.h264" -and (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    $mp4 = [IO.Path]::ChangeExtension($local, ".mp4")
    ffmpeg -loglevel error -y -framerate 30 -i $local -c copy $mp4
    Write-Host "  remuxed -> $(Split-Path -Leaf $mp4)"
  }
}
Write-Host "$n new file(s) in $dst"

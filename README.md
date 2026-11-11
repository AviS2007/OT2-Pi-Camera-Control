# OT-2 Pi 5 dual camera: record + stream

Pi 5 with a Camera Module 2 (IMX219) on CAM0 and a Camera Module 3 Wide (IMX708) on CAM1.
This folder sets the Pi up so it records both cameras to video files and streams a live view
over the network, and gets the Pi reachable from this PC over USB-C and over Wi-Fi/Tailscale.

## Why nothing worked over the USB-C cable yet

The Pi 5's USB-C port is its **power input**. A Pi only shows up as a USB device if its OS is
configured for "gadget" mode (`dtoverlay=dwc2,dr_mode=peripheral` plus a gadget service). A stock
Raspberry Pi OS card does not do this, so the PC sees nothing: no network adapter, no serial port.
The bundle here turns that on. Two hardware caveats:

- **Power.** A laptop USB-C port supplies at best 15 W, often less. The Pi 5 wants 27 W. It will
  boot off a laptop port with a low-power warning (the CSI cameras are fine, they draw little), but
  some ports deliver too little and the Pi boot-loops. If the Pi's green LED is not blinking it is
  not booting.
- **One port.** You cannot use the official PSU *and* a data cable at the same time, because both
  want the single USB-C port. Options: power through the GPIO header 5 V pins (bench supply, 5 V 5 A),
  a PoE+ HAT, or skip USB-C data entirely and use Wi-Fi + Tailscale (recommended long term).

## Daily use (bench, laptop as uplink)

1. Laptop on UofT Wi-Fi. Settings > Network & internet > Mobile hotspot > **On**
   (name `OT2-Uplink`, password `ot2uplink1`, band 2.4 GHz, power saving off; already configured).
   **Turn the hotspot on before powering the Pi**: the Pi picks its network once at boot.
2. Power the Pi with its own supply. Within ~1 min it joins the hotspot. Check the Pi's address in the
   hotspot's device list (usually 192.168.137.212). If the hotspot was off at boot, the Pi broadcasts
   `OT2-Cam-Pi` instead; reboot it with the hotspot on to get it back on the laptop link.
3. Open `http://192.168.137.212:8080/` for both live previews. **Record all** / **Stop** buttons record
   both cameras to the Pi. From code: `GET /record/start?name=<tag>` and `GET /record/stop`.
4. Copy recordings to this folder: `.\pc\pull_videos.ps1 -PiHost 192.168.137.212 -User ot2`
5. Shut the Pi down cleanly before unplugging: `ssh -i ~/.ssh/ot2cam_ed25519 ot2@192.168.137.212 sudo poweroff`

No laptop hotspot? The Pi broadcasts `OT2-Cam-Pi` (password `ot2camera`) instead; join it and use
`http://10.56.0.1:8080/`. Your laptop has no internet while on it.

## Current state of the lab Pi (2026-11-10)

- Pi boots, both cameras work: camera 0 = V2 (imx219, CAM1 connector), camera 1 = Module 3 Wide
  (imx708, CAM0 connector). Login `ot2` / `ot2cam`, hostname `ot2-cam-pi`. picamera2 0.3.31 and ffmpeg
  are installed; `camserver` runs on boot; H.264 .mp4 recording from both cameras verified.
- Both cameras are mounted upside down on the OT-2, so the service runs with `--rotate180 0,1` and
  `ot2-record` defaults to the same. The 180° transform is done in libcamera, so streams, snapshots
  and recordings are all upright. `--rotate180 ""` for none, `--rotate180 1` for one camera;
  `/status` reports `rotate180` per camera.
- Quality is set to the maximum that still gives 30 fps with the full field of view (2026-11-11):
  `--size auto --quality very_high`. auto picks the largest *uncropped* sensor mode that reaches
  `--fps`: V2 1640x1232, Module 3 Wide 2304x1296 (the V2's 1920x1080 mode is a centre crop and is
  skipped; the full 8/12 MP modes only do 21/14 fps). very_high lets picamera2 derive the H.264
  bitrate from the resolution (measured 15 and 18 Mbit/s), so a minute of both cameras is ~250 MB.
  The live preview has its own `--preview-quality` (default medium, ~3.7 Mbit/s per camera over the
  hotspot; very_high was 8.5 Mbit/s per camera and made the page stall). It never affects the files.
- **Thermal:** the Pi has no fan and idles at ~77 °C in its mount. Recording both cameras at these
  settings pushes it to 86 °C within 15 s, the CPU throttles from 2.4 to 1.5 GHz, and over 90 s the
  wide camera dropped ~1.5 % of frames (V2 none). Fit the official Pi 5 Active Cooler (fan header is
  next to the Ethernet jack) or give the enclosure airflow. Until then, if dropped frames matter more
  than resolution, use the lighter setting in `camserver.service`:
  `--size 1280x720 --quality high` (verified ~15 % CPU per camera, no throttling).
- **Silent hotspot drops (seen 2026-11-11 13:00):** the Windows hotspot logged "Wireless security
  stopped" for the Pi and stopped forwarding, but never sent a deauth, so the Pi believed it was
  connected for 4 minutes until it was power-cycled. Two countermeasures are installed: Wi-Fi power
  saving is off (`/etc/NetworkManager/conf.d/20-wifi-powersave.conf`), and `wifi-watchdog.service`
  probes the gateway every 30 s and re-joins the current profile after 3 misses (it ignores the
  Pi's own `ot2-hotspot` AP mode). It judges the link by ARP reachability, not ping replies: the
  laptop's firewall treats the hotspot as a Public network and drops ICMP echo, so `ping
  192.168.137.1` from the Pi always fails even when the link is fine (use `ip neigh` instead).
  Check the watchdog with `journalctl -t wifi-watchdog`.
- **How the Pi gets network today:** the laptop's Windows Mobile Hotspot, SSID `OT2-Uplink`, password
  `ot2uplink1` (Settings > Network & internet > Mobile hotspot, sharing the UofT Wi-Fi). The Pi joins it
  automatically (profile priority 20), gets internet through the laptop, and the laptop reaches it at
  192.168.137.x (check the hotspot's client list; it has been .212). Live view:
  `http://192.168.137.212:8080/`.
- When no known network is in range at boot the Pi broadcasts its own `OT2-Cam-Pi` (password
  `ot2camera`, Pi = 10.56.0.1). Joining it from the laptop cuts the laptop's internet, so only use it in
  a scripted hop (join, ssh, rejoin UofT in one command). NetworkManager chooses once at boot;
  `wifi-fallback.timer` (periodic re-selection) exists but is **disabled** on the lab Pi because it
  caused join/drop loops. Enable with `sudo systemctl enable --now wifi-fallback.timer` if wanted.
  `wifi-watchdog.service` (enabled) only re-joins the *current* profile when its gateway goes quiet;
  it never switches networks, so it cannot loop the way the timer did.
- Saved lab Wi-Fi `AC-IoT-NOKIA` exists on the Pi but is out of range at this bench; autoconnect is off
  (`sudo nmcli con modify AC-IoT-NOKIA connection.autoconnect yes` to re-enable).
- USB-C gadget is bound and NetworkManager manages `usb0` (10.55.0.1), but it has never enumerated on
  the laptop: needs a data-capable cable in the Pi's **USB-C** port (USB-A ports are host-only).
- Permanent remote access still needs a Tailscale auth key: `sudo ot2-wifi tailscale tskey-auth-...`.

Gotchas learned the hard way:
- `rpicam-apps-lite` has **no H.264 encoder** on a Pi 5 (no hardware encoder, no libav in the lite build),
  only `--codec mjpeg`. picamera2's `H264Encoder` works (software libav).
- picamera2's `FfmpegOutput` spawns ffmpeg with `PR_SET_PDEATHSIG`, which Linux ties to the *thread*
  that forked it. Starting a recording from a per-request HTTP handler thread kills ffmpeg the moment
  the handler returns and no file is written. `camserver.py` therefore runs all encoder start/stop calls
  on one long-lived worker thread per camera.
- NetworkManager leaves USB gadget interfaces unmanaged by default; `install.sh` adds a conf.d override.
  A malformed file in `/etc/NetworkManager/conf.d/` makes NetworkManager **refuse to start at all**
  (no Wi-Fi, no hotspot, Pi invisible). If the Pi ever disappears from every network after a reboot,
  that directory is the first place to look (`boot/firstrun-diag.sh` dumps the logs to the card).
- Windows 11 has no RNDIS driver; the gadget uses CDC-NCM.

## Quick start (no monitor or keyboard needed)

1. Power the Pi off, take out the microSD card, put it in this PC's card reader.
2. In PowerShell, from this folder:
   ```powershell
   .\pc\prepare_sd.ps1 -WifiSsid "LabRouter" -WifiPsk "secret" -TailscaleAuthKey "tskey-auth-..."
   ```
   All parameters are optional. Use `-PiUser`/`-PiPassword` to create a login if you don't know the
   card's existing one, `-EduroamId "utorid@utoronto.ca" -EduroamPassword "..."` for eduroam.
   See `boot\ot2cam.env.example` for everything it can set.
3. Card back in the Pi, power on. First boot runs `firstrun.sh` (installs everything offline),
   reboots, then finishes the online part (apt packages, Tailscale) once it has network.
   Allow about 2 minutes, or 5 if Wi-Fi/apt is involved.
4. Connect USB-C to the PC and run:
   ```powershell
   .\pc\find_pi.ps1 -Open
   ```
   The PC gets a "UsbNcm" network adapter with a 10.55.0.x address; the Pi is **10.55.0.1**.
   Live view and record buttons: <http://10.55.0.1:8080/>. SSH: `ssh -i ~/.ssh/ot2cam_ed25519 <user>@10.55.0.1`
   (the key in `boot\authorized_keys` was generated on this PC and installed on the Pi by firstrun).
   A "USB Serial Device (COMx)" also appears: a 115200 baud console into the Pi as a fallback.

If you already have SSH access to the Pi, skip the SD card step:
```bash
scp -r pi/ boot/authorized_keys <user>@<pi>:~/ot2cam/   # authorized_keys goes inside pi/
ssh <user>@<pi> 'sudo ~/ot2cam/install.sh && sudo reboot'
```

## Recording and streaming

`camserver.py` runs as a systemd service (`camserver.service`) on port 8080, opens both cameras,
and does both jobs at once: MJPEG preview from a small 640x360 stream, H.264 1280x720@30 recording
from the main stream. Streaming never degrades the recorded file.

| URL | Does |
|---|---|
| `/` | page with both live previews and Record / Stop buttons |
| `/cam/0.mjpg`, `/cam/1.mjpg` | raw MJPEG streams (open in a browser, VLC, OpenCV, OBS) |
| `/cam/0.jpg` | single snapshot |
| `/record/start?name=run7` | start recording **both** cameras |
| `/record/stop` | stop |
| `/status`, `/files` | JSON (status includes size, fps, quality and `rotate180` per camera) |

Files go to `~/recordings/<timestamp>_<name>_cam<n>_<CamV2|CamV3Wide>.mp4`. From Python on the PC
(for OT-2 protocol integration) it is just `requests.get("http://10.55.0.1:8080/record/start?name=step3")`.

Headless CLI alternative on the Pi (stop `camserver` first, both can't own the cameras at once):
```bash
sudo systemctl stop camserver
ot2-record -d 60 -n run7              # 60 s, both cameras, auto size, very_high quality
ot2-record --size 1280x720 --quality high   # lighter, until Ctrl-C
```
Pure rpicam one-liners if Python ever misbehaves:
```bash
rpicam-hello --list-cameras
rpicam-vid --camera 0 -t 60000 --width 1280 --height 720 -o cam0.mp4 &
rpicam-vid --camera 1 -t 60000 --width 1280 --height 720 -o cam1.mp4
```
Tuning: edit `/etc/systemd/system/camserver.service` (`--size`, `--fps`, `--bitrate`) then
`sudo systemctl daemon-reload && sudo systemctl restart camserver`. The Pi 5 has no hardware H.264
encoder; two 1080p30 software encodes are borderline, 720p30 x2 is comfortable.

Pull recordings to `.\recordings\`:
```powershell
.\pc\pull_videos.ps1 -User <user>                       # over USB
.\pc\pull_videos.ps1 -PiHost ot2-cam-pi -User <user>    # over Tailscale
```

## Wi-Fi and remote streaming

**No credentials needed:** the Pi broadcasts its own hotspot `OT2-Cam-Pi` (password `ot2camera`)
whenever none of its known Wi-Fi networks is in range. Join it from the laptop and the Pi is
**10.56.0.1**: live view at <http://10.56.0.1:8080/>, `ssh -i ~/.ssh/ot2cam_ed25519 ot2@10.56.0.1`.
The laptop has no internet while joined. Once a real network is added below, the Pi prefers it and
the hotspot only comes back when that network disappears.

On the Pi (`ot2-wifi` = `/opt/ot2cam/wifi.sh`):
```bash
sudo ot2-wifi psk "SSID" "password"                       # lab router / phone hotspot
sudo ot2-wifi eduroam "utorid@utoronto.ca" "password"     # WPA2-Enterprise
sudo ot2-wifi tailscale tskey-auth-XXXX ot2-cam-pi        # join the lab tailnet
sudo ot2-wifi status
```
This PC is on eduroam, and eduroam isolates clients, so the PC cannot talk to the Pi directly over it.
The lab already runs its Pis on Tailscale (sdl1wb-*-pi), so do the same: make an auth key at
<https://login.tailscale.com/admin/settings/keys> (reusable, tagged like the other Pis), and the
stream is then at `http://ot2-cam-pi:8080/` from any machine on the tailnet, including off-site.

## Files

```
pi/camserver.py        dual-camera MJPEG stream + H.264 record HTTP server (systemd: camserver.service)
pi/record.py           headless CLI recorder (ot2-record)
pi/usb-gadget.sh       USB-C -> NCM network + ACM serial gadget (systemd: usb-gadget.service)
pi/wifi.sh             nmcli / tailscale helpers (ot2-wifi)
pi/wifi-watchdog.sh    re-joins Wi-Fi when the gateway stops answering (systemd: wifi-watchdog.service)
pi/wifi-boot-fallback.service  45 s after boot: start the Pi's own hotspot if nothing joined
pi/install.sh          installer; --offline and --online-only used by first boot
boot/firstrun.sh       first-boot hook (runs install.sh --offline, removes itself, reboots)
boot/authorized_keys   this PC's public key (~/.ssh/ot2cam_ed25519.pub)
boot/ot2cam.env.example  all first-boot settings
pc/prepare_sd.ps1      write the bundle + hooks onto the SD card's bootfs partition
pc/find_pi.ps1         locate the Pi over USB / mDNS / Tailscale
pc/pull_videos.ps1     copy recordings to .\recordings
```

## Troubleshooting

- `rpicam-hello --list-cameras` shows fewer than 2 cameras: reseat the ribbon cables (contacts
  towards the board on the Pi 5's mini connectors). If still missing, in `/boot/firmware/config.txt`
  set `camera_auto_detect=0` and uncomment `dtoverlay=imx219,cam0` / `dtoverlay=imx708,cam1`.
- No USB adapter on the PC: check `ot2cam-firstrun.log` on the card, `systemctl status usb-gadget`
  on the Pi, and that `dtoverlay=dwc2,dr_mode=peripheral` is in config.txt. Try another cable
  (some USB-C cables are charge-only).
- Recordings are `.h264` not `.mp4`: ffmpeg is not installed yet (`sudo apt install ffmpeg`), or
  use `pull_videos.ps1 -Remux`.
- Service logs: `journalctl -u camserver -f`.

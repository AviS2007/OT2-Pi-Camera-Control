#!/bin/bash
# Recovery/diagnostic first-boot hook. Installed by: pc\prepare_sd.ps1 -FirstRun boot\firstrun-diag.sh
# 1. Dumps the previous boot's NetworkManager / wifi-fallback / kernel Wi-Fi logs to the FAT partition
#    (readable from Windows as ot2cam-diag.log).
# 2. Makes Wi-Fi behaviour deterministic: NetworkManager autoconnects the best known network at boot
#    (laptop hotspot OT2-Uplink first, then the Pi's own hotspot). The periodic wifi-fallback timer is
#    disabled. Daily use: turn the laptop hotspot on BEFORE powering the Pi.
# 3. Re-applies the normal install (idempotent) and reboots.
set +e
BOOT=/boot/firmware
LOG=$BOOT/ot2cam-firstrun.log
DIAG=$BOOT/ot2cam-diag.log
exec > >(tee -a "$LOG") 2>&1
echo "=== ot2cam firstrun-diag $(date) ==="

{
  echo "=== previous boot: NetworkManager (wlan0 / OT2-Uplink / hotspot)"
  journalctl -b -1 -u NetworkManager --no-pager -o short 2>&1 | grep -iE "wlan0|OT2|hotspot|supplicant|dhcp4" | tail -120
  echo; echo "=== previous boot: wifi-fallback"
  journalctl -b -1 -u wifi-fallback -t wifi-fallback --no-pager -o short 2>&1 | tail -60
  echo; echo "=== previous boot: kernel wifi"
  journalctl -b -1 -k --no-pager 2>&1 | grep -iE "brcmfmac|wlan0|ieee80211|regulatory" | tail -40
  echo; echo "=== previous boot: wifi-fallback timer / camserver state"
  journalctl -b -1 -u wifi-fallback.timer -u camserver --no-pager -o short 2>&1 | tail -20
  echo; echo "=== rfkill"; rfkill list 2>&1
  echo; echo "=== NM profiles"
  for f in /etc/NetworkManager/system-connections/*.nmconnection; do echo "--- $f"; grep -vE "psk=|password=" "$f"; done
  echo; echo "=== journald storage"; grep -E "^Storage" /etc/systemd/journald.conf 2>/dev/null; ls -d /var/log/journal 2>&1
} > "$DIAG" 2>&1

echo "== deterministic Wi-Fi: disable periodic switching, let NM autoconnect at boot"
systemctl disable --now wifi-fallback.timer 2>/dev/null
NMDIR=/etc/NetworkManager/system-connections
sed -i 's/^autoconnect=false/autoconnect=true/' "$NMDIR/ot2-hotspot.nmconnection" 2>/dev/null
# saved lab/old networks stay off until deliberately enabled
rfkill unblock wifi 2>/dev/null

echo "== re-apply install (idempotent)"
SRC=$BOOT/ot2cam
[ -f "$SRC/ot2cam.env" ] && { set -a; . "$SRC/ot2cam.env"; set +a; }
export PI_USER=${PI_USER:-ot2}
WORK=/root/ot2cam-install; rm -rf "$WORK"; mkdir -p "$WORK"; cp "$SRC"/* "$WORK"/
sed -i 's/\r$//' "$WORK"/*.sh "$WORK"/*.py "$WORK"/*.service "$WORK"/*.timer 2>/dev/null
chmod +x "$WORK"/*.sh "$WORK"/*.py
bash "$WORK/install.sh" --offline
systemctl disable wifi-fallback.timer 2>/dev/null   # install.sh re-enables it; keep it off
rm -f "$SRC/ot2cam.env"
sed -i 's| systemd.run=[^ ]*||; s| systemd.run_success_action=[^ ]*||; s| systemd.run_failure_action=[^ ]*||; s| systemd.unit=kernel-command-line.target||' "$BOOT/cmdline.txt"
rm -f "$BOOT/firstrun.sh"
echo "=== firstrun-diag finished; rebooting ==="
exit 0

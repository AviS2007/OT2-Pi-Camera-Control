#!/bin/bash
# First-boot hook for the OT-2 camera Pi. Placed on the SD card's bootfs partition by pc/prepare_sd.ps1,
# which also adds to cmdline.txt:
#   systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target
# It runs once as root very early in boot (no network yet), installs the camera stack from
# /boot/firmware/ot2cam, then removes itself and reboots.
set +e
BOOT=/boot/firmware
LOG=$BOOT/ot2cam-firstrun.log
exec > >(tee -a "$LOG") 2>&1
echo "=== ot2cam firstrun $(date) ==="

SRC=$BOOT/ot2cam
[ -f "$SRC/ot2cam.env" ] && { set -a; . "$SRC/ot2cam.env"; set +a; }

# Optional new user (only if it does not exist yet)
if [ -n "$PI_USER" ] && ! id "$PI_USER" >/dev/null 2>&1; then
    echo "== creating user $PI_USER"
    useradd -m -s /bin/bash -G adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,input,render,netdev,gpio,i2c,spi "$PI_USER" 2>/dev/null \
      || useradd -m -s /bin/bash -G sudo,video,plugdev,netdev "$PI_USER"
    [ -n "$PI_PASSWORD" ] && echo "$PI_USER:$PI_PASSWORD" | chpasswd
fi
export PI_USER=${PI_USER:-$(getent passwd 1000 | cut -d: -f1)}

# Work from a copy on the root filesystem (FAT has no exec bit)
WORK=/root/ot2cam-install
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$SRC"/* "$WORK"/
sed -i 's/\r$//' "$WORK"/*.sh "$WORK"/*.py "$WORK"/*.service 2>/dev/null
chmod +x "$WORK"/*.sh "$WORK"/*.py

bash "$WORK/install.sh" --offline
rc=$?

# Clean up: secrets off the FAT partition, remove ourselves and the cmdline hook
rm -f "$SRC/ot2cam.env"
sed -i 's| systemd.run=[^ ]*||; s| systemd.run_success_action=[^ ]*||; s| systemd.run_failure_action=[^ ]*||; s| systemd.unit=kernel-command-line.target||' "$BOOT/cmdline.txt"
rm -f "$BOOT/firstrun.sh"
echo "=== firstrun finished rc=$rc; rebooting ==="
exit 0

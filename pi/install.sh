#!/bin/bash
# Install the OT-2 camera stack on the Pi (Raspberry Pi OS Bookworm or newer, Pi 5).
#
#   sudo ./install.sh                 # full install over SSH (needs internet for apt)
#   sudo ./install.sh --offline       # used by boot/firstrun.sh: everything that needs no network,
#                                     # plus a one-shot service that finishes the online part later
#   sudo ./install.sh --online-only   # the apt / tailscale part (run by that one-shot service)
#
# Optional environment (firstrun.sh exports these from ot2cam.env):
#   PI_USER WIFI_SSID WIFI_PSK EDUROAM_ID EDUROAM_PASSWORD WIFI_COUNTRY TAILSCALE_AUTHKEY HOSTNAME_NEW
#   HOTSPOT_SSID HOTSPOT_PSK   (fallback access point the Pi broadcasts when no known Wi-Fi is in range)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-full}
USER_NAME=${PI_USER:-$(getent passwd 1000 | cut -d: -f1)}
[ -n "$USER_NAME" ] || { echo "cannot determine user; set PI_USER"; exit 1; }
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
CFG=/boot/firmware/config.txt
NMDIR=/etc/NetworkManager/system-connections
uuid() { cat /proc/sys/kernel/random/uuid; }

# ---------------------------------------------------------------- online part
online_part() {
    echo "== packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y -qq python3-picamera2 ffmpeg avahi-daemon dnsmasq-base curl >/dev/null
    command -v rpicam-hello >/dev/null || apt-get install -y -qq rpicam-apps-lite >/dev/null
    if [ -n "$TAILSCALE_AUTHKEY" ]; then
        echo "== tailscale"
        command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
        tailscale up --auth-key="$TAILSCALE_AUTHKEY" --hostname="$(hostname)" --ssh --accept-dns=false || true
    fi
    systemctl restart camserver.service 2>/dev/null || true
}

if [ "$MODE" = "--online-only" ]; then
    # env file written by the offline step
    [ -f /etc/ot2cam.env ] && . /etc/ot2cam.env
    online_part
    systemctl disable ot2cam-online-setup.service 2>/dev/null || true
    rm -f /etc/ot2cam.env
    exit 0
fi

# ---------------------------------------------------------------- offline part
echo "== installing for user $USER_NAME ($HOME_DIR)"

echo "== camera + USB gadget settings in $CFG"
grep -q '^camera_auto_detect=' "$CFG" && sed -i 's/^camera_auto_detect=.*/camera_auto_detect=1/' "$CFG" \
                                       || echo 'camera_auto_detect=1' >> "$CFG"
if ! grep -q '^dtoverlay=dwc2,dr_mode=peripheral' "$CFG"; then
grep -q '^\[all\]' "$CFG" || printf '\n[all]\n' >> "$CFG"
cat >> "$CFG" <<'TXT'

# --- OT-2 camera Pi (added by install.sh) ---
# USB-C port as a USB device: network + serial console to the PC
dtoverlay=dwc2,dr_mode=peripheral
# If camera auto-detect ever fails, set camera_auto_detect=0 and uncomment:
#dtoverlay=imx219,cam0
#dtoverlay=imx708,cam1
TXT
fi

echo "== files -> /opt/ot2cam"
install -d /opt/ot2cam
install -m 755 "$HERE/camserver.py" "$HERE/record.py" "$HERE/usb-gadget.sh" "$HERE/wifi.sh" "$HERE/wifi-fallback.sh" "$HERE/install.sh" /opt/ot2cam/
ln -sf /opt/ot2cam/record.py /usr/local/bin/ot2-record
ln -sf /opt/ot2cam/wifi.sh   /usr/local/bin/ot2-wifi
install -d -o "$USER_NAME" -g "$USER_NAME" "$HOME_DIR/recordings"

echo "== systemd units"
install -m 644 "$HERE/usb-gadget.service" /etc/systemd/system/usb-gadget.service
sed "s/__USER__/$USER_NAME/g" "$HERE/camserver.service" > /etc/systemd/system/camserver.service
install -m 644 "$HERE/wifi-fallback.service" "$HERE/wifi-fallback.timer" "$HERE/wifi-boot-fallback.service" /etc/systemd/system/
# wifi-boot-fallback: one-shot at boot (hotspot only if nothing joined). wifi-fallback.timer (periodic
# re-selection) is installed but left disabled; enable by hand if wanted.
systemctl enable usb-gadget.service camserver.service wifi-boot-fallback.service serial-getty@ttyGS0.service ssh >/dev/null 2>&1 || true

echo "== NetworkManager: usb0 = 10.55.0.1/24, DHCP for the PC"
install -d -m 755 "$NMDIR" /etc/NetworkManager/conf.d
# NM leaves USB gadget interfaces unmanaged by default; take usb0 over explicitly
printf '[device-usb-gadget]\nmatch-device=interface-name:usb0\nmanaged=1\n' > /etc/NetworkManager/conf.d/10-usb-gadget.conf
if [ ! -f "$NMDIR/usb-gadget.nmconnection" ]; then
cat > "$NMDIR/usb-gadget.nmconnection" <<TXT
[connection]
id=usb-gadget
uuid=$(uuid)
type=ethernet
interface-name=usb0
autoconnect=true
autoconnect-priority=10

[ethernet]

[ipv4]
method=shared
address1=10.55.0.1/24

[ipv6]
method=ignore
TXT
chmod 600 "$NMDIR/usb-gadget.nmconnection"
fi

if [ -n "$WIFI_COUNTRY" ] && command -v raspi-config >/dev/null; then
    raspi-config nonint do_wifi_country "$WIFI_COUNTRY" >/dev/null 2>&1 || true
fi
rfkill unblock wifi 2>/dev/null || true

if [ -n "$WIFI_SSID" ]; then
    echo "== Wi-Fi profile: $WIFI_SSID"
cat > "$NMDIR/$WIFI_SSID.nmconnection" <<TXT
[connection]
id=$WIFI_SSID
uuid=$(uuid)
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PSK

[ipv4]
method=auto

[ipv6]
method=auto
TXT
chmod 600 "$NMDIR/$WIFI_SSID.nmconnection"
fi

if [ -n "$EDUROAM_ID" ]; then
    echo "== Wi-Fi profile: eduroam ($EDUROAM_ID)"
cat > "$NMDIR/eduroam.nmconnection" <<TXT
[connection]
id=eduroam
uuid=$(uuid)
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=eduroam

[wifi-security]
key-mgmt=wpa-eap

[802-1x]
eap=peap;
identity=$EDUROAM_ID
password=$EDUROAM_PASSWORD
phase2-auth=mschapv2
anonymous-identity=anonymous@${EDUROAM_ID#*@}
system-ca-certs=true

[ipv4]
method=auto

[ipv6]
method=auto
TXT
chmod 600 "$NMDIR/eduroam.nmconnection"
fi

if [ -n "$HOTSPOT_SSID" ]; then
    echo "== Wi-Fi fallback hotspot: $HOTSPOT_SSID (used only when no known network is in range)"
cat > "$NMDIR/ot2-hotspot.nmconnection" <<TXT
[connection]
id=ot2-hotspot
uuid=$(uuid)
type=wifi
autoconnect=false
autoconnect-priority=-10

[wifi]
mode=ap
ssid=$HOTSPOT_SSID
band=bg
channel=6

[wifi-security]
key-mgmt=wpa-psk
psk=$HOTSPOT_PSK
proto=rsn
pairwise=ccmp
group=ccmp

[ipv4]
method=shared
address1=10.56.0.1/24

[ipv6]
method=ignore
TXT
chmod 600 "$NMDIR/ot2-hotspot.nmconnection"
fi

if [ -n "$HOSTNAME_NEW" ] && [ "$HOSTNAME_NEW" != "$(hostname)" ]; then
    echo "== hostname -> $HOSTNAME_NEW"
    old=$(hostname)
    echo "$HOSTNAME_NEW" > /etc/hostname
    sed -i "s/127\.0\.1\.1.*$old/127.0.1.1\t$HOSTNAME_NEW/" /etc/hosts
    grep -q "$HOSTNAME_NEW" /etc/hosts || printf '127.0.1.1\t%s\n' "$HOSTNAME_NEW" >> /etc/hosts
fi

echo "== ssh keys"
if [ -f "$HERE/authorized_keys" ]; then
    install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$HOME_DIR/.ssh"
    touch "$HOME_DIR/.ssh/authorized_keys"
    while read -r key; do
        [ -n "$key" ] && ! grep -qF "$key" "$HOME_DIR/.ssh/authorized_keys" && echo "$key" >> "$HOME_DIR/.ssh/authorized_keys"
    done < "$HERE/authorized_keys"
    chmod 600 "$HOME_DIR/.ssh/authorized_keys"; chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh"
fi

if [ "$MODE" = "--offline" ]; then
    echo "== scheduling online setup (apt, tailscale) for the next boot with network"
    { echo "PI_USER=$USER_NAME"; echo "TAILSCALE_AUTHKEY=$TAILSCALE_AUTHKEY"; } > /etc/ot2cam.env
    chmod 600 /etc/ot2cam.env
cat > /etc/systemd/system/ot2cam-online-setup.service <<'TXT'
[Unit]
Description=OT-2 camera Pi: one-time online setup (apt packages, tailscale)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/ot2cam.env

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do getent hosts deb.debian.org && exit 0; sleep 5; done; exit 0'
ExecStart=/opt/ot2cam/install.sh --online-only
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
TXT
    systemctl enable ot2cam-online-setup.service >/dev/null 2>&1 || true
    echo "== offline install done"
    exit 0
fi

systemctl daemon-reload
online_part
echo "== done. Reboot to activate the USB gadget, then open http://10.55.0.1:8080/ on the PC."
echo "   cameras:"; rpicam-hello --list-cameras 2>/dev/null | grep -E '^[0-9]+ :' || echo "   (none listed yet; check after reboot)"

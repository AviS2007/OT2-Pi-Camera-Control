#!/bin/bash
# Wi-Fi + remote access helpers for the camera Pi (Raspberry Pi OS Bookworm, NetworkManager).
#
#   sudo ./wifi.sh psk      "SSID" "password"                 # ordinary WPA2 network / phone hotspot / lab router
#   sudo ./wifi.sh eduroam  "utorid@utoronto.ca" "password"   # WPA2-Enterprise (PEAP/MSCHAPv2)
#   sudo ./wifi.sh tailscale tskey-auth-XXXX [hostname]       # join the lab tailnet (works through eduroam isolation)
#   sudo ./wifi.sh status
set -e
cmd=${1:-status}

case "$cmd" in
  psk)
    nmcli radio wifi on
    nmcli dev wifi rescan || true
    nmcli con delete "$2" 2>/dev/null || true
    nmcli con add type wifi ifname wlan0 con-name "$2" ssid "$2" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$3" connection.autoconnect yes
    nmcli con up "$2"
    ;;
  eduroam)
    nmcli radio wifi on
    nmcli con delete eduroam 2>/dev/null || true
    nmcli con add type wifi ifname wlan0 con-name eduroam ssid eduroam \
        wifi-sec.key-mgmt wpa-eap \
        802-1x.eap peap 802-1x.phase2-auth mschapv2 \
        802-1x.identity "$2" 802-1x.password "$3" \
        802-1x.anonymous-identity "anonymous@${2#*@}" \
        802-1x.system-ca-certs yes connection.autoconnect yes
    nmcli con up eduroam
    echo "NOTE: eduroam usually isolates clients from each other; use tailscale for PC<->Pi access."
    ;;
  tailscale)
    if ! command -v tailscale >/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    tailscale up --auth-key="$2" --hostname="${3:-ot2-cam-pi}" --ssh --accept-dns=false
    tailscale status
    ;;
  status)
    nmcli -f DEVICE,TYPE,STATE,CONNECTION dev status
    echo
    nmcli -f IP4.ADDRESS dev show 2>/dev/null | grep -v '^$' || true
    command -v tailscale >/dev/null && tailscale ip -4 2>/dev/null | sed 's/^/tailscale: /'
    ;;
  *)
    sed -n '2,8p' "$0"; exit 1 ;;
esac

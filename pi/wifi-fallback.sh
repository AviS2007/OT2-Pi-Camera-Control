#!/bin/bash
# Keep the Pi on the best available Wi-Fi: a known infrastructure network if one is in range,
# otherwise its own hotspot (NM profile "ot2-hotspot"). Run by wifi-fallback.timer every 2 min.
# NetworkManager cannot scan while in AP mode, so this script does the switching explicitly.
HOT=ot2-hotspot
IF=wlan0
LOG="logger -t wifi-fallback"

active_con() { nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$IF" '$2==d{print $1}'; }
has_ip()     { ip -4 -o addr show dev "$IF" scope global | grep -q inet; }

active=$(active_con)

if [ -n "$active" ] && [ "$active" != "$HOT" ]; then
    has_ip && exit 0                         # on a real network with an address: nothing to do
    $LOG "on $active but no IPv4 address; re-evaluating"
    nmcli con down "$active" >/dev/null 2>&1
fi

if [ "$active" = "$HOT" ]; then
    n=$(iw dev "$IF" station dump 2>/dev/null | grep -c '^Station')
    [ "$n" -gt 0 ] && exit 0                 # someone is using the hotspot: leave it alone
    nmcli con down "$HOT" >/dev/null 2>&1
fi

# Let NM's own autoconnect run first (it kicks in right after the hotspot goes down)
sleep 12
active=$(active_con)
if [ -n "$active" ] && [ "$active" != "$HOT" ] && has_ip; then
    $LOG "NM autoconnected to $active"
    exit 0
fi

nmcli dev wifi rescan >/dev/null 2>&1
sleep 6
visible=$(nmcli -t -f SSID dev wifi list 2>/dev/null | sort -u)

joined=""
while IFS=: read -r name prio; do
    [ -z "$name" ] && continue
    [ "$(nmcli -g 802-11-wireless.mode con show "$name" 2>/dev/null)" = "ap" ] && continue
    ssid=$(nmcli -g 802-11-wireless.ssid con show "$name" 2>/dev/null)
    hidden=$(nmcli -g 802-11-wireless.hidden con show "$name" 2>/dev/null)
    if [ "$hidden" = "yes" ] || echo "$visible" | grep -qxF "$ssid"; then
        [ "$(active_con)" = "$name" ] || nmcli con up "$name" >/dev/null 2>&1
        # a join only counts if it holds and yields an address
        for i in $(seq 1 15); do
            sleep 2
            [ "$(active_con)" = "$name" ] && has_ip && { joined=$name; break; }
        done
        if [ -n "$joined" ]; then
            $LOG "joined $ssid ($(ip -4 -o addr show dev $IF scope global | awk '{print $4}'))"
            break
        fi
        $LOG "join to $ssid did not hold"
        nmcli con down "$name" >/dev/null 2>&1
    fi
done < <(nmcli -t -f NAME,TYPE,AUTOCONNECT con show | awk -F: '$2=="802-11-wireless" && $3=="yes"{print $1}' | while read -r n; do
            echo "$n:$(nmcli -g connection.autoconnect-priority con show "$n" 2>/dev/null)"
         done | sort -t: -k2 -nr)

[ -n "$joined" ] && exit 0

nmcli -g connection.id con show "$HOT" >/dev/null 2>&1 || exit 0
nmcli con up "$HOT" >/dev/null 2>&1 && $LOG "no usable network in range; hotspot up"

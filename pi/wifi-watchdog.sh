#!/bin/sh
# Wi-Fi link watchdog. The Windows Mobile Hotspot can silently drop a client ("Wireless security
# stopped" in its log) without sending a deauth; the Pi then believes it is still connected until
# someone reboots it. If wlan0 is on a client connection (not our own ot2-hotspot AP) and the
# default gateway stops answering pings for ~90 s, bounce the connection.
fails=0
while :; do
  sleep 30
  con=$(nmcli -t -f GENERAL.CONNECTION dev show wlan0 2>/dev/null | cut -d: -f2-)
  if [ -z "$con" ] || [ "$con" = "ot2-hotspot" ]; then fails=0; continue; fi
  gw=$(ip -4 route show default dev wlan0 2>/dev/null | awk '{print $3; exit}')
  if [ -z "$gw" ]; then fails=0; continue; fi      # still coming up; NetworkManager owns that
  if ping -c 2 -W 2 -I wlan0 "$gw" >/dev/null 2>&1; then fails=0; continue; fi
  # No ICMP reply. Windows may just be filtering echo requests, so look at layer 2: the pings made
  # the kernel ARP for the gateway, and the neighbour entry only goes FAILED/INCOMPLETE (or vanishes)
  # when nothing answers at all. That is the real "link is dead" signal.
  sleep 3
  st=$(ip -4 neigh show "$gw" dev wlan0 2>/dev/null | awk '{print $NF}')
  case "$st" in
    REACHABLE|STALE|DELAY|PROBE|PERMANENT) fails=0; continue ;;
  esac
  fails=$((fails + 1))
  logger -t wifi-watchdog "gateway $gw unreachable, arp=${st:-none} ($fails/3) on '$con'"
  if [ "$fails" -ge 3 ]; then
    logger -t wifi-watchdog "reconnecting '$con'"
    nmcli con down "$con" >/dev/null 2>&1
    sleep 2
    nmcli con up "$con" >/dev/null 2>&1 || nmcli dev wifi rescan >/dev/null 2>&1
    fails=0
    sleep 30
  fi
done

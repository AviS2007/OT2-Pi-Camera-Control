#!/bin/bash
# Bring up the Pi 5 USB-C port as a USB network adapter (CDC-NCM) plus a USB serial console (CDC-ACM).
# Windows 11 and macOS/Linux all have built-in NCM drivers; RNDIS is NOT used because Windows 11
# removed its RNDIS driver.
#
# Requires in /boot/firmware/config.txt:   dtoverlay=dwc2,dr_mode=peripheral
# Run by usb-gadget.service at boot. Idempotent: safe to re-run, re-binds the UDC if needed.
set -e

G=/sys/kernel/config/usb_gadget/pi5
SERIAL=$(cut -c9- /proc/device-tree/serial-number 2>/dev/null | tr -d '\0' || echo 0000000000000000)
# Stable, locally administered MACs derived from the board serial.
HOST_MAC="02:$(echo "$SERIAL" | sed 's/\(..\)/\1:/g' | cut -c1-14 | sed 's/:$//')"
DEV_MAC="06:$(echo "$SERIAL" | sed 's/\(..\)/\1:/g' | cut -c1-14 | sed 's/:$//')"

modprobe libcomposite
modprobe dwc2 2>/dev/null || true
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

# Wait for the USB device controller (dwc2 probes a little after early boot)
UDC=""
for i in $(seq 1 30); do
    UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)
    [ -n "$UDC" ] && break
    sleep 0.5
done
if [ -z "$UDC" ]; then
    echo "No UDC found after 15 s. Is 'dtoverlay=dwc2,dr_mode=peripheral' in /boot/firmware/config.txt?" >&2
    exit 1
fi

if [ ! -d "$G" ]; then
    mkdir -p "$G"
    cd "$G"
    echo 0x1d6b > idVendor          # Linux Foundation
    echo 0x0104 > idProduct         # Multifunction Composite Gadget
    echo 0x0100 > bcdDevice
    echo 0x0200 > bcdUSB

    mkdir -p strings/0x409
    echo "$SERIAL"          > strings/0x409/serialnumber
    echo "Raspberry Pi"     > strings/0x409/manufacturer
    echo "Pi 5 OT-2 Camera" > strings/0x409/product

    mkdir -p configs/c.1/strings/0x409
    echo "NCM network + ACM serial" > configs/c.1/strings/0x409/configuration
    echo 250 > configs/c.1/MaxPower

    # Network function
    mkdir -p functions/ncm.usb0
    echo "$HOST_MAC" > functions/ncm.usb0/host_addr
    echo "$DEV_MAC"  > functions/ncm.usb0/dev_addr
    ln -s functions/ncm.usb0 configs/c.1/

    # Serial console function (login via COM port on the PC as a fallback)
    mkdir -p functions/acm.usb0
    ln -s functions/acm.usb0 configs/c.1/
fi

cd "$G"
if [ -z "$(cat UDC 2>/dev/null)" ]; then
    echo "$UDC" > UDC
    echo "gadget attached to $UDC (usb0 host_mac=$HOST_MAC)"
else
    echo "gadget already attached to $(cat UDC)"
fi

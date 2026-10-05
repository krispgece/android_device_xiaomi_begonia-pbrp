#!/system/bin/sh
# Started by init.recovery.usb.rc whenever adb, sideload or fastbootd binds the
# gadget. The smb1351 charger driver can leave the USB data lines on its
# charger-detection switch: sometimes after a warm reboot from the recovery,
# and, going by the charger code, on every attach of a USB-C host that offers
# 1.5 A without USB-PD. The host then never enumerates the phone until a
# replug. If the gadget is not configured 15 s into the same USB mode and is
# then 'not attached' with no bus reset (speed UNKNOWN) while a USB host is on
# the cable, do the software equivalent of a replug: cmode 0 (CHRG_ONLY) takes
# the mtu3 controller out of device mode (PHY off, D+ low), cmode 1 (NORMAL)
# brings it back with a fresh PHY init and the D+ pull-up. At most two kicks;
# each USB mode is watched for 60 s.
udc=/sys/class/udc/musb-hdrc
cmode=$udc/device/cmode
psy=/sys/class/power_supply/usb
log=/tmp/begonia-usb-kick.log

# /tmp only: this kernel drops userspace writes to /dev/kmsg
note() {
    echo "$(cut -d' ' -f1 /proc/uptime) $*" >> $log
}

# A USB host: online for SDP/CDP. An SDP host that never enumerates is turned
# into a floating charger (type USB_FLOAT, online 0) 1 s after detection, so
# that counts too. Wall chargers (DCP, QC, PD) are left alone: cmode 1 would
# pull D+ up on them.
usb_host() {
    [ "$(cat $psy/present 2>/dev/null)" = 1 ] || return 1
    [ "$(cat $psy/online 2>/dev/null)" = 1 ] || [ "$(cat $psy/type 2>/dev/null)" = USB_FLOAT ]
}

# After a USB-PD data-role swap (a hub with pass-through charging) the
# controller is a USB host: a kick would drop everything on the hub.
host_mode() {
    grep -q '^USB-HOST=1$' /sys/class/extcon/extcon*/state 2>/dev/null
}

# nothing else writes cmode: if an earlier run was cut off, put it back
[ "$(cat $cmode 2>/dev/null)" = 0 ] && { echo 1 > $cmode; note "cmode was 0, restored"; }

kicks=0 cycles=0 n=0 same=0 last=
while [ $n -lt 60 ]; do
    sleep 1
    n=$((n + 1))
    state=$(getprop sys.usb.state)
    case "$state" in adb|sideload|fastboot) ;; *) exit 0 ;; esac
    [ "$state" = "$last" ] && same=$((same + 1)) || { same=1; n=1; last=$state; }
    [ "$(cat $udc/state 2>/dev/null)" = configured ] && exit 0
    [ $same -ge 15 ] || continue
    [ "$(cat $udc/state 2>/dev/null)" = "not attached" ] || continue
    [ "$(cat $udc/current_speed 2>/dev/null)" = UNKNOWN ] || continue
    usb_host && ! host_mode || continue
    [ -w $cmode ] && [ "$(getprop sys.usb.state)" = "$state" ] || continue
    kicks=$((kicks + 1))
    cycles=$((cycles + 1))
    note "$state gadget not configured after ${same}s, not attached, on $(cat $psy/type 2>/dev/null): re-init the PHY ($kicks)"
    trap 'echo 1 > $cmode' EXIT
    trap 'echo 1 > $cmode; exit 1' HUP INT TERM
    echo 0 > $cmode
    sleep 1
    echo 1 > $cmode
    trap - EXIT HUP INT TERM
    same=0
    # Unplugged during the kick: cmode 1 has put the controller in device mode
    # without a cable, so the next plug-in will not re-init the PHY. This kick
    # does not count, and the next attach gets a full watch.
    if [ "$(cat $psy/present 2>/dev/null)" != 1 ]; then
        note "cable went away during the kick, watching the next attach"
        kicks=$((kicks - 1))
        n=0
    fi
    [ $kicks -ge 2 ] && exit 0
    [ $cycles -ge 4 ] && exit 0
done

#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Conservative boot-time tuning for the phone VM profile.
#
# The guest runs on an emulated CPU, so every avoided service, disk seek and
# console line costs more than it would on real hardware. This script is run
# once while the image is provisioned (scripts/prepare_phosh.sh) and is safe to
# run again: every step checks first and ignores missing packages/services.
set -eu

log() { echo "tune-boot: $*"; }

# ---------------------------------------------------------------------------
# 1. Drop services that have no hardware to drive in this VM.
#    Networking, dbus, seatd and the display stack are left untouched.
# ---------------------------------------------------------------------------
for svc in bluetooth modemmanager wpa_supplicant chronyd crond sshd \
           avahi-daemon cupsd saned; do
    for runlevel in boot default; do
        if rc-update del "$svc" "$runlevel" 2>/dev/null; then
            log "removed $svc from $runlevel"
        fi
    done
done

# ---------------------------------------------------------------------------
# 2. Quiet kernel console and skip work that only matters on real hardware.
#    Alpine's UEFI cloud image boots through GRUB; extlinux is handled as a
#    fallback for images built with a different bootloader.
# ---------------------------------------------------------------------------
EXTRA_ARGS="quiet loglevel=3 nowatchdog mitigations=off"

add_args() {
    # $1: current argument list, prints the merged list
    case " $1 " in
        *" quiet "*) echo "$1" ;;
        *) echo "$1 $EXTRA_ARGS" ;;
    esac
}

if [ -f /etc/default/grub ]; then
    if ! grep -q 'nowatchdog' /etc/default/grub; then
        # shellcheck disable=SC1091
        . /etc/default/grub
        merged="$(add_args "${GRUB_CMDLINE_LINUX_DEFAULT:-}")"
        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
            sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$merged\"|" /etc/default/grub
        else
            printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$merged" >> /etc/default/grub
        fi
        if command -v grub-mkconfig >/dev/null 2>&1; then
            grub-mkconfig -o /boot/grub/grub.cfg
            log "kernel command line updated through GRUB"
        else
            log "GRUB config edited; grub-mkconfig is not installed"
        fi
    fi
elif [ -f /boot/extlinux/extlinux.conf ]; then
    if ! grep -q 'nowatchdog' /boot/extlinux/extlinux.conf; then
        sed -i "s|^\\([[:space:]]*append[[:space:]].*\\)$|\\1 $EXTRA_ARGS|" /boot/extlinux/extlinux.conf
        log "kernel command line updated through extlinux"
    fi
else
    log "no GRUB/extlinux configuration found; kernel command line left unchanged"
fi

# ---------------------------------------------------------------------------
# 3. Mount the root filesystem with noatime. Writes are expensive on the
#    emulated NVMe device and nothing in this image relies on access times.
# ---------------------------------------------------------------------------
if [ -f /etc/fstab ] && ! grep -qE '[[:space:]]noatime([,[:space:]]|$)' /etc/fstab; then
    sed -i -E 's|^([^#][^[:space:]]*[[:space:]]+/[[:space:]]+[^[:space:]]+[[:space:]]+)([^[:space:]]+)|\1\2,noatime|' /etc/fstab
    log "root filesystem mounted with noatime"
fi

log "done"

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
umask 077
downloadable=false
if [[ "${1:-}" == --downloadable ]]; then
    downloadable=true
    shift
fi
MACHINE="${1:-work/PostmarketOS-Native}"
mkdir -p work
SETUP="$(mktemp work/prepare-phosh.XXXXXX)"
trap 'rm -f "$SETUP"' EXIT
if $downloadable; then
    printf 'ALPINEIOS_DOWNLOADABLE=1\n' > "$SETUP"
fi
cat scripts/guest/install_phosh.sh scripts/guest/enable_native_display.sh scripts/guest/tune_boot.sh >> "$SETUP"
if $downloadable; then
    cat scripts/guest/enable_app_installer.sh >> "$SETUP"
fi
# QEMU provisions the disk. The display starts after reboot in the phone VM.
printf '\nrc-update -u\necho PMOS_PROVISIONED\n' >> "$SETUP"
python3 scripts/provision_alpine.py --guest-setup "$SETUP" --poweroff --output "$MACHINE"
qemu-system-aarch64 -machine virt,gic-version=3 -accel hvf -cpu host -smp 2 -m 2048 \
    -display none -monitor none -serial stdio -device virtio-gpu-pci \
    -drive "if=pflash,format=raw,readonly=on,file=$MACHINE/code.fd" \
    -drive "if=pflash,format=raw,file=$MACHINE/vars.fd" \
    -drive "if=none,format=raw,file=$MACHINE/alpine.img,id=os" \
    -device nvme,drive=os,serial=PMOS \
    -drive "if=none,format=raw,readonly=on,file=$MACHINE/seed.img,id=seed" \
    -device nvme,drive=seed,serial=SEED \
    -netdev user,id=net -device virtio-net-pci,netdev=net \
    2>&1 | tee "$MACHINE/setup.log"
grep -q '^PMOS_PROVISIONED' "$MACHINE/setup.log" || { echo "Phosh setup failed; inspect setup.log" >&2; exit 1; }
cp /opt/homebrew/share/qemu/edk2-arm-vars.fd "$MACHINE/vars.fd"
make build/hvsparse
./build/hvsparse pack "$MACHINE/alpine.img" "$MACHINE/alpine.hvsparse"
if $downloadable; then
    touch "$MACHINE/.downloadable"
    echo "Prepared $MACHINE. Run scripts/publish_phosh_image.py to stage the downloadable assets."
else
    sed -i '' 's/^Local console login: alpine$/Local console login: user/' "$MACHINE/login.txt"
    echo "Prepared $MACHINE. Console credentials are in login.txt."
fi

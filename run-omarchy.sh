#!/usr/bin/env bash
# Boots the Linux kernel with egg-firecracker on the Omarchy VM (VMware Fusion,
# nested VT-x) and prints its boot log. Run it on the Mac:
#
#     ./run-omarchy.sh                 # default kernel command line
#     ./run-omarchy.sh "console=ttyS0 reboot=k panic=1 pci=off loglevel=8"
#     ./run-omarchy.sh --initramfs     # into a busybox shell (tools/mkinitramfs.sh); ^A x stops
#
# Overrides: OMARCHY_HOST (default femto@192.168.109.129), EGG_DIR (the Egg
# compiler checkout, default ../egg), KERNEL (path on Omarchy).
set -euo pipefail

HOST="${OMARCHY_HOST:-femto@192.168.109.129}"
HERE="$(cd "$(dirname "$0")" && pwd)"
EGG_DIR="${EGG_DIR:-$HERE/../egg}"
KERNEL="${KERNEL:-fc/vmlinux-6.18.62}"   # relative to the home directory on Omarchy
INITRAMFS=0
if [ "${1:-}" = "--initramfs" ]; then
    INITRAMFS=1
    shift
fi

echo "==> checking $HOST"
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true; then
    echo "cannot ssh to $HOST: is Omarchy running in VMware Fusion?" >&2
    exit 1
fi
ssh "$HOST" "test -r /dev/kvm -a -w /dev/kvm" || {
    echo "/dev/kvm is not readable and writable on $HOST (nested VT-x off?)" >&2
    exit 1
}
ssh "$HOST" "test -f ~/$KERNEL" || {
    echo "no kernel at ~/$KERNEL on $HOST" >&2
    exit 1
}

echo "==> syncing the Egg compiler and egg-firecracker"
rsync -az --delete --exclude .git --exclude build "$EGG_DIR/" "$HOST:egg/"
rsync -az --delete --exclude .git --exclude build "$HERE/" "$HOST:egg-firecracker/"

echo "==> building"
ssh "$HOST" 'cd ~/egg-firecracker && ~/egg/bin/eggc build --release src/main.egg -o build/firecracker'

remote="cd ~/egg-firecracker && ./build/firecracker ~/$KERNEL"
if [ "$INITRAMFS" = 1 ]; then
    echo "==> building the initramfs"
    # A busybox on the PATH, else one unpacked from Arch's package into ~/fc/busybox.
    ssh "$HOST" 'cd ~/egg-firecracker && BUSYBOX="$(command -v busybox || echo ~/fc/busybox/usr/bin/busybox)" tools/mkinitramfs.sh build/initramfs.cpio'
    remote="$remote --initrd build/initramfs.cpio"
fi

echo "==> booting ~/$KERNEL"
if [ $# -gt 0 ]; then
    remote="$remote $(printf '%q' "$1")"
fi
# -t so Ctrl-C stops the VM on Omarchy too.
if [ -t 0 ]; then
    ssh -t "$HOST" "$remote"
else
    ssh "$HOST" "$remote"
fi

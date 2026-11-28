#!/usr/bin/env bash
# Boots the Linux kernel with egg-firecracker on the Omarchy VM (VMware Fusion,
# nested VT-x) and prints its boot log. Run it on the Mac:
#
#     ./run-omarchy.sh                 # default kernel command line
#     ./run-omarchy.sh "console=ttyS0 reboot=k panic=1 pci=off loglevel=8"
#     ./run-omarchy.sh --initramfs     # into a busybox shell (tools/mkinitramfs.sh); ^A x stops
#     ./run-omarchy.sh --ubuntu        # Ubuntu from ~/fc/ubuntu-24.04.ext4 on virtio-blk
#
# --ubuntu boots a copy of the image, ~/fc/ubuntu-24.04.egg.ext4, made once
# (sparse) and kept, so the guest's writes never reach the original.
#
# Overrides: OMARCHY_HOST (default femto@192.168.109.129), EGG_DIR (the Egg
# compiler checkout, default ../egg), KERNEL (path on Omarchy).
set -euo pipefail

HOST="${OMARCHY_HOST:-femto@192.168.109.129}"
HERE="$(cd "$(dirname "$0")" && pwd)"
EGG_DIR="${EGG_DIR:-$HERE/../egg}"
KERNEL="${KERNEL:-fc/vmlinux-6.18.62}"   # relative to the home directory on Omarchy
INITRAMFS=0
UBUNTU=0
if [ "${1:-}" = "--initramfs" ]; then
    INITRAMFS=1
    shift
elif [ "${1:-}" = "--ubuntu" ]; then
    UBUNTU=1
    shift
fi

echo "==> checking $HOST"
if ! ssh -n -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true; then
    echo "cannot ssh to $HOST: is Omarchy running in VMware Fusion?" >&2
    exit 1
fi
ssh -n "$HOST" "test -r /dev/kvm -a -w /dev/kvm" || {
    echo "/dev/kvm is not readable and writable on $HOST (nested VT-x off?)" >&2
    exit 1
}
ssh -n "$HOST" "test -f ~/$KERNEL" || {
    echo "no kernel at ~/$KERNEL on $HOST" >&2
    exit 1
}

# Only the boot session reads standard input: the others take -n or
# /dev/null, so commands piped into this script reach the guest.
echo "==> syncing the Egg compiler and egg-firecracker"
rsync -az --delete --exclude .git --exclude build "$EGG_DIR/" "$HOST:egg/" </dev/null
rsync -az --delete --exclude .git --exclude build "$HERE/" "$HOST:egg-firecracker/" </dev/null

echo "==> building"
ssh -n "$HOST" 'cd ~/egg-firecracker && ~/egg/bin/eggc build --release src/main.egg -o build/firecracker'

remote="cd ~/egg-firecracker && ./build/firecracker ~/$KERNEL"
if [ "$INITRAMFS" = 1 ]; then
    echo "==> building the initramfs"
    # A busybox on the PATH, else one unpacked from Arch's package into ~/fc/busybox.
    ssh -n "$HOST" 'cd ~/egg-firecracker && BUSYBOX="$(command -v busybox || echo ~/fc/busybox/usr/bin/busybox)" tools/mkinitramfs.sh build/initramfs.cpio'
    remote="$remote --initrd build/initramfs.cpio"
fi
if [ "$UBUNTU" = 1 ]; then
    echo "==> preparing the root file system"
    # Copied to a temporary name and renamed when whole, so an interrupted
    # copy is never booted; under a lock of its own, so two runs started
    # together copy once (the second finds the image when it gets the lock).
    ssh -n "$HOST" 'cd ~/fc && flock ubuntu-24.04.egg.ext4.lock sh -c "test -f ubuntu-24.04.egg.ext4 || { cp --sparse=always ubuntu-24.04.ext4 ubuntu-24.04.egg.ext4.part && mv ubuntu-24.04.egg.ext4.part ubuntu-24.04.egg.ext4; }"'
    remote="$remote --drive ~/fc/ubuntu-24.04.egg.ext4"
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

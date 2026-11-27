#!/usr/bin/env bash
# Builds a busybox initramfs (an uncompressed newc cpio) whose /init prints
# what it finds and reboots: the serial port takes no input yet, so there
# is no shell to type into. Runs on Linux and needs a static busybox
# (Arch: pacman -S busybox) and cpio or bsdtar.
#
#     tools/mkinitramfs.sh [OUT]        # default build/initramfs.cpio
set -euo pipefail

OUT="${1:-build/initramfs.cpio}"
BUSYBOX="${BUSYBOX:-$(command -v busybox || true)}"
if [ -z "$BUSYBOX" ]; then
    echo "no busybox: install it (pacman -S busybox) or set BUSYBOX" >&2
    exit 1
fi
if ldd "$BUSYBOX" >/dev/null 2>&1; then
    echo "$BUSYBOX is dynamically linked; the initramfs has no libc" >&2
    exit 1
fi

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root"/{bin,sbin,usr/bin,usr/sbin,dev,proc,sys,tmp}
cp "$BUSYBOX" "$root/bin/busybox"

cat > "$root/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox --install -s
# The cpio has no device nodes (making them needs root), so the kernel
# started /init without a console: mount devtmpfs and take it from there.
mount -t devtmpfs dev /dev
exec </dev/console >/dev/console 2>&1
mount -t proc proc /proc
mount -t sysfs sys /sys

echo
echo "=== initramfs: /init is running (pid $$) ==="
uname -a
echo "cmdline: $(cat /proc/cmdline)"
grep -m1 'model name' /proc/cpuinfo
free -m
echo "/:" $(ls /)
echo "uptime: $(cut -d' ' -f1 /proc/uptime) s"
echo "=== no serial input yet: rebooting ==="
reboot -f
INIT
chmod +x "$root/init"

mkdir -p "$(dirname "$OUT")"
out="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
if command -v cpio >/dev/null; then
    (cd "$root" && find . -print0 | cpio --null -o -H newc --quiet --owner 0:0) > "$out"
else
    (cd "$root" && find . -print0 | bsdtar --null -cf - --format newc --uid 0 --gid 0 -T -) > "$out"
fi
echo "$out: $(wc -c < "$out") bytes"

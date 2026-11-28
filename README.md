# egg-firecracker

A microVM monitor in [Egg](https://github.com/femto/egg), after
[Firecracker](https://github.com/firecracker-microvm/firecracker): it drives
Linux KVM through `/dev/kvm` to run guests.

It boots Ubuntu 24.04 from a disk image on virtio-blk to a root shell on
the serial console.

`src/kvm.egg` is the only `allow unsafe` file. It wraps `open`, `ioctl`,
`mmap`, file I/O and the terminal, and gives the rest of the VMM guest memory
and the vCPU's `kvm_run` page through bounds-checked methods, so device code
reading guest-controlled offsets and lengths panics or fails instead of
corrupting memory.

## Status

Stage 1: boots a Linux `vmlinux` (6.18, from Firecracker's CI) on one vCPU with
512 MiB to its serial console, as Firecracker does: the ELF at its physical
addresses, a zero page with the command line and e820 map, identity-mapped
page tables, and the vCPU already in long mode. KVM keeps the PIC, IOAPIC,
local APIC and PIT; this handles the exits for an 8250 UART at 0x3f8 and the
i8042 reset. With no disk yet, the kernel prints its boot log, panics for
want of a root file system and resets the machine:

```
$ firecracker vmlinux-6.18.62
[    0.000000] Linux version 6.18.62+ ...
[    0.000000] Hypervisor detected: KVM
[    1.798948] serial8250: ttyS0 at I/O 0x3f8 (irq = 4, base_baud = 115200) is a 16450
[    3.212700] Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
[vmm] the guest reset the machine (i8042) after 4848 ms and 47526 VM exits
```

With `--initrd`, the initramfs goes at the top of guest memory, as in
Firecracker, and the kernel runs its `/init`. The UART raises its
transmitter-empty and received-data interrupts on IRQ 4, and standard input
reaches it: a thread reads it and sends the bytes over a channel, and the
vCPU thread moves them into the UART's FIFO. On a terminal, input is raw
(^C goes to the guest) and ^A x stops the VMM. `tools/mkinitramfs.sh`
builds a busybox initramfs whose `/init` starts a shell on the console:

```
$ firecracker vmlinux-6.18.62 --initrd initramfs.cpio
[vmm] the console takes the keyboard: ^A x stops
...
=== busybox sh on ttyS0; exit reboots ===
~ # echo hello from $(uname -r)
hello from 6.18.62+
~ # grep ttyS /proc/interrupts
 24:        150  IO-APIC   4-edge      ttyS0
~ # exit
[vmm] the guest reset the machine (i8042) after 9492 ms and 48617 VM exits
```

With `--drive`, a disk image becomes `/dev/vda`, a virtio block device on
the virtio-mmio transport (version 2) at 0xc0000000 on IRQ 5, Firecracker's
place for its first device. Firecracker's CI kernels find virtio-mmio
devices through ACPI, not `virtio_mmio.device=` on the command line, so the
VMM writes the tables Firecracker writes (`src/acpi.egg`): an RSDP at
0xe0000, an XSDT, a hardware-reduced FADT, a MADT for the local APIC and
IOAPIC, and a DSDT whose AML describes COM1, the i8042 and the virtio device.
The queue is served when the guest writes QueueNotify, with `pread` and
`pwrite` straight between the image and guest memory; every descriptor,
length and index from the guest is checked, and a malformed request fails
alone. The image is locked (`flock`), so a second VMM on it is refused.
With no CMDLINE, `root=/dev/vda rw` is added:

```
$ firecracker vmlinux-6.18.62 --drive ubuntu-24.04.ext4
[    0.004460] ACPI: RSDP 0x00000000000E0000 000024 (v02 EGGVMM)
[    1.487871] virtio_blk virtio0: [vda] 2097152 512-byte logical blocks (1.07 GB/1.00 GiB)
[    2.937423] EXT4-fs (vda): mounted filesystem ... r/w with ordered data mode.
Welcome to Ubuntu 24.04.5 LTS!
...
ubuntu-fc-uvm login: root (automatic login)
root@ubuntu-fc-uvm:~# grep -E "virtio|ttyS" /proc/interrupts
 24:        902  IO-APIC   5-edge      virtio0
 25:        555  IO-APIC   4-edge      ttyS0
root@ubuntu-fc-uvm:~# reboot
...
[vmm] the guest reset the machine (i8042) after 32494 ms and 129066 VM exits
```

As with Firecracker, `reboot` stops the VMM; there is no guest power
management, so `poweroff` leaves the vCPU halted.

`test/real_mode.egg` is stage 0: a vCPU running 12 bytes of real-mode code.

Next: virtio-net on a TAP device.

## Running

Needs x86_64 Linux with KVM (`/dev/kvm` readable and writable) and a C
compiler. Nested virtualization works, e.g. a Linux VM in VMware Fusion with
"Enable hypervisor applications in this virtual machine".

```bash
eggc build --release src/main.egg -o build/firecracker
./build/firecracker vmlinux [--initrd FILE] [--drive FILE] [CMDLINE]
tools/mkinitramfs.sh build/initramfs.cpio   # a busybox initramfs for --initrd
eggc run test/real_mode.egg --pkg firecracker=src
```

`test/console.egg`, `test/initrd.egg`, `test/serial.egg`,
`test/virtio_blk.egg` and `test/acpi.egg` need no KVM: the last two drive
the block device as Linux's drivers do, on a buffer as guest memory and a
temporary file as the disk, and follow the ACPI tables from the RSDP.
`run-omarchy.sh [--initramfs | --ubuntu]` syncs this and the Egg compiler
to a Linux VM over ssh, builds there and boots; `--ubuntu` boots a copy of
Firecracker's `ubuntu-24.04.ext4`, so the guest's writes never reach the
original.

## Notes

Egg has no C struct layout yet, so the KVM structs are byte buffers with
fields at their offsets from `<linux/kvm.h>`. `ioctl` is variadic in C; it is
declared with one fixed integer argument, which x86_64 passes the same way.
The kernel is read with `open` and `mmap` rather than the `fs` capability:
using `fs` makes the generated C include `<fcntl.h>`, whose variadic `open`
clashes with the `extern fn open` here. For the same reason a temporary disk
for tests is made with `creat`, not `mkstemp`, which `<stdlib.h>` declares
with a `char *`.

# egg-firecracker

A microVM monitor in [Egg](https://github.com/femto/egg), after
[Firecracker](https://github.com/firecracker-microvm/firecracker): it drives
Linux KVM through `/dev/kvm` to run guests.

`src/kvm.egg` is the only `allow unsafe` file. It wraps `open`, `ioctl` and
`mmap`, and gives the rest of the VMM guest memory and the vCPU's `kvm_run`
page through bounds-checked methods, so device code reading guest-controlled
offsets and lengths panics or fails instead of corrupting memory.

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
transmitter-empty interrupt on IRQ 4, which the tty driver needs to send
what user space writes. `tools/mkinitramfs.sh` builds a busybox initramfs
whose `/init` prints what it finds and reboots, since the UART takes no
input yet:

```
$ firecracker vmlinux-6.18.62 --initrd initramfs.cpio
=== initramfs: /init is running (pid 1) ===
Linux (none) 6.18.62+ #1 SMP PREEMPT_DYNAMIC ... x86_64 GNU/Linux
...
=== no serial input yet: rebooting ===
[vmm] the guest reset the machine (i8042) after 3903 ms and 47029 VM exits
```

`test/real_mode.egg` is stage 0: a vCPU running 12 bytes of real-mode code.

Next: virtio block, to mount a root file system, and serial input, to reach
a shell.

## Running

Needs x86_64 Linux with KVM (`/dev/kvm` readable and writable) and a C
compiler. Nested virtualization works, e.g. a Linux VM in VMware Fusion with
"Enable hypervisor applications in this virtual machine".

```bash
eggc build --release src/main.egg -o build/firecracker
./build/firecracker vmlinux [--initrd FILE] [CMDLINE]
tools/mkinitramfs.sh build/initramfs.cpio   # a busybox initramfs for --initrd
eggc run test/real_mode.egg --pkg firecracker=src
```

`test/console.egg`, `test/initrd.egg` and `test/serial.egg` need no KVM.
`run-omarchy.sh [--initramfs]` syncs this and the Egg compiler to a Linux
VM over ssh, builds there and boots.

## Notes

Egg has no C struct layout yet, so the KVM structs are byte buffers with
fields at their offsets from `<linux/kvm.h>`. `ioctl` is variadic in C; it is
declared with one fixed integer argument, which x86_64 passes the same way.
The kernel is read with `open` and `mmap` rather than the `fs` capability:
using `fs` makes the generated C include `<fcntl.h>`, whose variadic `open`
clashes with the `extern fn open` here.

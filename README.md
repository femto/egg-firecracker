# egg-firecracker

A microVM monitor in [Egg](https://github.com/femto/egg), after
[Firecracker](https://github.com/firecracker-microvm/firecracker): it drives
Linux KVM through `/dev/kvm` to run guests.

`src/kvm.egg` is the only `allow unsafe` file. It wraps `open`, `ioctl` and
`mmap`, and gives the rest of the VMM guest memory and the vCPU's `kvm_run`
page through bounds-checked methods, so device code reading guest-controlled
offsets and lengths panics or fails instead of corrupting memory.

## Status

Stage 0: a vCPU runs 12 bytes of real-mode code, which add two registers the
host set and write the sum to the serial port; each `out` is a VM exit the
host prints.

```
$ eggc run src/main.egg
guest: 5
guest halted
```

Next: boot a Linux kernel (`vmlinux`) to its serial console, then virtio
block and net.

## Running

Needs x86_64 Linux with KVM (`/dev/kvm` readable and writable) and a C
compiler. Nested virtualization works, e.g. a Linux VM in VMware Fusion with
"Enable hypervisor applications in this virtual machine".

```bash
eggc run src/main.egg
```

## Notes

Egg has no C struct layout yet, so the KVM structs are byte buffers with
fields at their offsets from `<linux/kvm.h>`. `ioctl` is variadic in C; it is
declared with one fixed integer argument, which x86_64 passes the same way.

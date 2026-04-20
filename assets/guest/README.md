Place a Linux `bzImage` here as `assets/guest/linux-bzImage`.

Automated Download:
The fastest way to get a compatible kernel is to use the provided download script for a minimal Alpine Linux kernel:
```sh
./dev/download_linux.sh
```

What `bzImage` means:
It is the standard x86 Linux bootable kernel image produced by the Linux kernel build system at `arch/x86/boot/bzImage`.

Fastest way to get one:
If you already have a Linux system or WSL distro, the easiest source is usually the kernel your distro already boots.

Example on Debian, Ubuntu, or WSL:
```sh
cp /boot/vmlinuz-$(uname -r) /path/to/nornir/assets/guest/linux-bzImage
file /path/to/nornir/assets/guest/linux-bzImage
```

That `vmlinuz` file is normally already in the `bzImage` boot format on x86.

Build your own from source:
```sh
git clone --depth=1 https://github.com/torvalds/linux.git
cd linux
make x86_64_defconfig
scripts/config --enable CONFIG_SERIAL_8250
scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
scripts/config --disable CONFIG_DEBUG_INFO
make -j$(nproc) bzImage
cp arch/x86/boot/bzImage /path/to/nornir/assets/guest/linux-bzImage
file /path/to/nornir/assets/guest/linux-bzImage
```

Notes:
- Use an x86_64 kernel image.
- Keep the image reasonably small so bring-up and smoke runs stay fast.
- The VMX guest currently boots with the embedded initramfs at [initramfs.cpio.gz](initramfs.cpio.gz).
- Rebuild that initramfs with `./dev/rebuild_guest_initramfs.sh` after changing [guest_init.c](../../guest_init.c) or [rootfs_init.c](rootfs_init.c).
- That rebuild script expects a working `cc`, `fakeroot`, `cpio`, and `gzip` on the host.
- The rebuilt initramfs includes a minimal embedded OCI-style rootfs at `/mnt/container` with `/sbin/init`, `/bin/sh`, and `/usr/bin/env` provided by [rootfs_init.c](rootfs_init.c).
- The embedded rootfs also ships a small `/etc/os-release` and standard top-level directories so guest handoff exercises a more realistic filesystem layout.
- Catenary OS currently validates and stages the image, then boots Linux with the embedded guest init path and demo rootfs workload.
- Validate the direct guest path with `SMOKE_PROFILE=vmx-linux ./test_qemu.sh`.
- Validate the services-owned launch path with `SMOKE_PROFILE=vmx-linux-services ./test_qemu.sh`.

After placing the file here:
```sh
zig build
```

The build detects the file automatically. During VMX bring-up, the kernel validates the Linux boot header and reports the parsed metadata over serial.
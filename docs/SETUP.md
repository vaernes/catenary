# Setup & Build Notes

This document complements README.md with the current build flags, smoke profiles, and guest-image workflow used in this repo.

## Prerequisites

- Zig toolchain
- QEMU (`qemu-system-x86_64`)
- `xorriso` for ISO creation
- KVM access (`/dev/kvm`) is strongly recommended for VMX validation
- `cc`, `fakeroot`, `cpio`, and `gzip` if you rebuild the embedded guest initramfs

## Common Commands

```sh
# Build everything
zig build

# Run with serial output to your terminal
./run_qemu.sh

# Default smoke test (core boot + Ring 3 service milestones)
./test_qemu.sh

# Direct VMX/Linux smoke test
SMOKE_PROFILE=vmx-linux ./test_qemu.sh

# Services-owned VMX/Linux smoke test
SMOKE_PROFILE=vmx-linux-services ./test_qemu.sh

# Rebuild the embedded guest initramfs after guest handoff/rootfs changes
./dev/rebuild_guest_initramfs.sh
```

## Current Build Options

To see the current build options exposed by the repo:

```sh
zig build -Dhelp
```

The options currently used by the documented workflows are:

- `-Dos_version_str=...` overrides the boot banner version string.
- `-Dservices_active=true|false` enables or disables Ring-3 service boot and auto-launch.
- `-Dvmm_active=true|false` enables or disables the VMX/HVM subsystem.
- `-Dvmm_launch_linux=true|false` stages and launches the embedded Linux MicroVM flow when VMX is enabled.

Examples:

```sh
# Build the direct Linux guest path without Ring-3 services
zig build -Dvmm_active=true -Dvmm_launch_linux=true -Dservices_active=false

# Build the integrated services-owned Linux MicroVM path
zig build -Dvmm_active=true -Dvmm_launch_linux=true
```

## Passing Flags To Scripts

`./run_qemu.sh` and `./test_qemu.sh` invoke `zig build` internally. Pass extra build flags through `ZIG_BUILD_ARGS`.

```sh
ZIG_BUILD_ARGS='-Dvmm_active=true -Dvmm_launch_linux=true -Dservices_active=false' ./run_qemu.sh

ZIG_BUILD_ARGS='-Dvmm_active=true -Dvmm_launch_linux=true' \
SMOKE_PROFILE=vmx-linux-services \
./test_qemu.sh
```

Useful smoke-test environment knobs:

- `SMOKE_PROFILE=default|vmx-linux|vmx-linux-services`
- `TIMEOUT_SECS=...` to raise or lower the smoke timeout
- `REQUIRE_KVM=0` to allow best-effort TCG execution when `/dev/kvm` is unavailable

## Guest Kernel And Initramfs Workflow

The VMX/Linux path expects a guest kernel image at `assets/guest/linux-bzImage`.

```sh
# Download a compatible bzImage
./dev/download_linux.sh

# Rebuild the embedded initramfs after guest handoff or rootfs edits
./dev/rebuild_guest_initramfs.sh
```

Rebuild the initramfs after changing either of these files:

- `guest_init.c`
- `assets/guest/rootfs_init.c`

The rebuilt initramfs embeds the current guest handoff path plus a small OCI-style demo rootfs under `/mnt/container`.
That rootfs currently provides `/sbin/init`, `/bin/sh`, `/usr/bin/env`, and `/etc/os-release` for early guest validation.

## Validation Notes

- `SMOKE_PROFILE=vmx-linux` validates the direct Linux guest boot path.
- `SMOKE_PROFILE=vmx-linux-services` validates the services-owned launch path through `clusterd` and `kernel_control`.
- Smoke runs generate `catenary.iso`, `qemu_serial.log`, `qemu.pid`, and `test_disk.img` in the repo root.
- If VMX bring-up fails early, inspect `qemu_serial.log` first; it is the primary source of truth for boot and guest milestones.

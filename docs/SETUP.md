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

# Exercise local vNIC binding rejection, update, and detach through the UI
SMOKE_PROFILE=vnic-bind ./test_qemu.sh

# Verify storage fails closed when no NVMe device is present
SMOKE_PROFILE=no-nvme ./test_qemu.sh

# Verify corrupted partition metadata blocks allocation and writes
SMOKE_PROFILE=corrupt-metadata ./test_qemu.sh

# Verify a corrupted journal blocks metadata recovery and writes
SMOKE_PROFILE=corrupt-journal ./test_qemu.sh

# Seed a valid partition journal intent and verify startup replay
SMOKE_PROFILE=journal-recovery ./test_qemu.sh

# Seed an intent plus its already-written header and verify idempotent replay
SMOKE_PROFILE=journal-commit-recovery ./test_qemu.sh

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

- `SMOKE_PROFILE=default|vmx-linux|vmx-linux-services|ui-phase8|vnic-bind|phase9|no-nvme|corrupt-metadata|corrupt-journal|journal-recovery|journal-commit-recovery`
- `TIMEOUT_SECS=...` to raise or lower the smoke timeout
- `REQUIRE_KVM=0` to allow best-effort TCG execution when `/dev/kvm` is unavailable
- `NVME_DISK_IMAGE=/path/to/disk.img` to choose a persistent smoke-test NVMe image; reuse it to exercise startup metadata scanning across runs. Without this setting, the runner uses a fresh temporary image.

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

- In the native Varde shell, `vnic-bind <vm-id> <ipv4-or-> <ipv6-or->` replaces a running VM's allowed host-side address bindings. For example, `vnic-bind 2 10.77.0.2 fd00::2` sets one address of each family; `vnic-bind 2 - -` clears them. The command does not configure the guest OS, and each successful replacement clears firewall allow rules and leaves the port default-deny. The bindings are not persistent. A timeout means the result is unknown; a later retry re-queries the port and, if accepted, clears its rules again. Binding readback is not yet exposed in the UI.
- `SMOKE_PROFILE=vnic-bind` tests invalid and valid binding requests and vNIC detach through the UI, `configd` and `netd`; it does not demonstrate guest-to-guest network traffic.
- `test_qemu_cluster.sh` uses two CPUs per node by default; `SMP` can override that setting.
- `SMOKE_PROFILE=vmx-linux` validates the direct Linux guest boot path.
- `SMOKE_PROFILE=vmx-linux-services` validates the services-owned launch path through `clusterd` and `kernel_control`.
- `SMOKE_PROFILE=no-nvme` checks that storage reports missing hardware and that a block write is not reported as successful.
- `SMOKE_PROFILE=corrupt-metadata` seeds a nonzero invalid metadata sector and requires containerd to stop without writing or reusing the slot.
- `SMOKE_PROFILE=corrupt-journal` seeds a nonzero invalid journal sector and requires containerd to stop before metadata recovery or writes.
- `SMOKE_PROFILE=journal-recovery` seeds a checksummed write-ahead intent and verifies idempotent header replay, metadata scanning, a new journaled write, readback, and journal clear. This simulates restart recovery from a prepared intent; it is not a physical power-cut test.
- `SMOKE_PROFILE=journal-commit-recovery` seeds both a valid intent and its already-written header, then verifies idempotent replay and journal clear for the post-header/pre-clear restart state.
- Smoke runs generate `catenary.iso`, `qemu_serial.log`, and `qemu.pid` in the repo root. The default profile reserves a new partition slot on each successful run; its temporary disk is removed after the run. Supply `NVME_DISK_IMAGE` to preserve an image for recovery or capacity-exhaustion tests.
- If VMX bring-up fails early, inspect `qemu_serial.log` first; it is the primary source of truth for boot and guest milestones.

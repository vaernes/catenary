#!/bin/bash
set -euo pipefail

echo "[+] Building Catenary OS..."
zig build ${ZIG_BUILD_ARGS:-}

echo "[+] Preparing ISO..."
mkdir -p iso_root/boot
mkdir -p iso_root/modules
cp zig-out/bin/kernel.elf iso_root/boot/
cp zig-out/bin/netd iso_root/modules/netd.elf
cp zig-out/bin/storaged iso_root/modules/storaged.elf
cp zig-out/bin/dashd iso_root/modules/dashd.elf
cp zig-out/bin/containerd iso_root/modules/containerd.elf
cp zig-out/bin/clusterd iso_root/modules/clusterd.elf
cp zig-out/bin/inputd iso_root/modules/inputd.elf
cp zig-out/bin/windowd iso_root/modules/windowd.elf
cp zig-out/bin/configd iso_root/modules/configd.elf
cp limine.conf iso_root/
cp limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin iso_root/

echo "[+] Generating catenary.iso..."
xorriso -as mkisofs -b limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    iso_root -o catenary.iso 2>/dev/null

./limine/limine bios-install catenary.iso

ACCEL="tcg"
CPU="max,vmx=on"
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL="kvm"
    CPU="host,vmx=on"
else
    echo "[!] /dev/kvm is unavailable; falling back to TCG (slow)."
fi

echo "[+] Starting QEMU (Interactive Mode - Ctrl+A, X to exit)..."
# Create a dummy disk if it doesn't exist
if [ ! -f test_disk.img ]; then
    dd if=/dev/zero of=test_disk.img bs=1M count=64 status=none
fi

qemu-system-x86_64 \
    -M q35 -m 1G \
    -cpu "${CPU}" -accel "${ACCEL}" \
    -cdrom catenary.iso -boot d \
    -serial stdio -serial telnet:127.0.0.1:4444,server,nowait \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile= \
    -device nvme,serial=deadbeef,drive=nvm -drive file=test_disk.img,format=raw,if=none,id=nvm

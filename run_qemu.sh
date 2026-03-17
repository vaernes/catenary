#!/bin/bash
set -e

echo "[+] Building Catenary OS..."
zig build ${ZIG_BUILD_ARGS:-} -p /tmp/zig-out --cache-dir /tmp/zig-local-cache --global-cache-dir /tmp/zig-global-cache

echo "[+] Preparing ISO directory..."
mkdir -p iso_root/boot
mkdir -p iso_root/modules
cp /tmp/zig-out/bin/kernel.elf iso_root/boot/
cp /tmp/zig-out/bin/netd iso_root/modules/netd.elf
cp /tmp/zig-out/bin/storaged iso_root/modules/storaged.elf
cp /tmp/zig-out/bin/dashd iso_root/modules/dashd.elf
cp /tmp/zig-out/bin/containerd iso_root/modules/containerd.elf
cp /tmp/zig-out/bin/clusterd iso_root/modules/clusterd.elf
cp /tmp/zig-out/bin/inputd iso_root/modules/inputd.elf
cp /tmp/zig-out/bin/windowd iso_root/modules/windowd.elf
cp /tmp/zig-out/bin/configd iso_root/modules/configd.elf
cp limine.conf iso_root/

if [ ! -d "limine" ]; then
    echo "[+] Downloading Limine..."
    git clone https://github.com/limine-bootloader/limine.git --branch v10.8.5-binary --depth=1
    rm -rf limine/.git
    (cd limine && make )
fi

echo "[+] Copying Limine binaries..."
cp limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin iso_root/

echo "[+] Generating catenary.iso..."
xorriso -as mkisofs -b limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    iso_root -o catenary.iso

echo "[+] Installing Limine to ISO..."
./limine/limine bios-install catenary.iso

echo "[+] Running QEMU..."
# Serial for main kernel log + Serial for guest/varde bridge
GTK_PATH= qemu-system-x86_64 -enable-kvm -M q35 -m 256M -cpu host,vmx=on -cdrom catenary.iso -boot d -serial stdio -serial telnet:127.0.0.1:4444,server,nowait \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile= \
    -drive file=/dev/null,format=raw,if=none,id=nvm \
    -device nvme,serial=deadbeef,drive=nvm

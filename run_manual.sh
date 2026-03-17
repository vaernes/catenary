#!/usr/bin/env bash
set -euo pipefail

BUILD_FLAGS="${BUILD_FLAGS:--Dservices_active=true}"
QEMU_MEM="${QEMU_MEM:-256M}"

echo "[+] Building Catenary OS..."
zig build ${ZIG_BUILD_ARGS:-} ${BUILD_FLAGS}

echo "[+] Preparing ISO directory..."
mkdir -p iso_root/boot
cp zig-out/bin/kernel.elf iso_root/boot/
cp limine.conf iso_root/

if [ ! -d "limine" ]; then
  echo "[+] Downloading Limine..."
  git clone https://github.com/limine-bootloader/limine.git --branch v10.8.5-binary --depth=1
  rm -rf limine/.git
fi

if [ ! -x "limine/limine" ]; then
  echo "[+] Building Limine binaries..."
  make -C limine
fi

xorriso -V >/dev/null 2>&1 || (echo "Please install xorriso" && exit 1)

echo "[+] Copying Limine binaries..."
cp limine/limine-bios.sys limine/limine-bios-cd.bin limine/limine-uefi-cd.bin iso_root/

echo "[+] Generating catenary.iso..."
rm -f catenary.iso
xorriso -as mkisofs -b limine-bios-cd.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  --efi-boot limine-uefi-cd.bin \
  -efi-boot-part --efi-boot-image --protective-msdos-label \
  iso_root -o catenary.iso

echo "[+] Installing Limine to ISO..."
./limine/limine bios-install catenary.iso

echo "[+] Running QEMU..."
GTK_PATH= qemu-system-x86_64 \
  -enable-kvm -M q35 -m "${QEMU_MEM}" -cpu host,vmx=on \
  -cdrom catenary.iso -boot d \
  -serial stdio -display none

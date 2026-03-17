#!/usr/bin/env bash
set -euo pipefail

SERIAL_MODE="${SERIAL_MODE:-stdio}"      # stdio | tcp
SERIAL_TCP_PORT="${SERIAL_TCP_PORT:-4444}"
SERIAL_TCP_WAIT="${SERIAL_TCP_WAIT:-on}" # on waits for nc before boot; off uses nowait

echo "[+] Building Catenary OS..."
zig build ${ZIG_BUILD_ARGS:-} -p /tmp/zig-out --cache-dir /tmp/zig-local-cache --global-cache-dir /tmp/zig-global-cache

echo "[+] Preparing ISO directory..."
mkdir -p iso_root/boot
mkdir -p iso_root/modules
cp /tmp/zig-out/bin/kernel.elf iso_root/boot/
cp /tmp/zig-out/bin/netd iso_root/modules/netd.elf
cp /tmp/zig-out/bin/storaged iso_root/modules/storaged.elf
cp limine.conf iso_root/

if [ ! -d "limine" ]; then
    echo "[+] Downloading Limine..."
    git clone https://github.com/limine-bootloader/limine.git --branch v10.8.5-binary --depth=1
    rm -rf limine/.git
    (cd limine && make)
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

case "${SERIAL_MODE}" in
    stdio)
        SERIAL_ARGS=(-serial stdio)
        echo "[+] COM1 -> current terminal (stdio)"
        ;;
    tcp)
        if [ "${SERIAL_TCP_WAIT}" = "on" ]; then
            SERIAL_ARGS=(-serial "tcp:127.0.0.1:${SERIAL_TCP_PORT},server,wait=on")
            echo "[+] COM1 -> tcp 127.0.0.1:${SERIAL_TCP_PORT} (wait for client)"
        else
            SERIAL_ARGS=(-serial "tcp:127.0.0.1:${SERIAL_TCP_PORT},server,nowait")
            echo "[+] COM1 -> tcp 127.0.0.1:${SERIAL_TCP_PORT} (nowait)"
        fi
        echo "[+] COM1 -> tcp 127.0.0.1:${SERIAL_TCP_PORT}"
        echo "[+] Connect with: nc 127.0.0.1 ${SERIAL_TCP_PORT}"
        ;;
    *)
        echo "[-] Invalid SERIAL_MODE=${SERIAL_MODE}. Use stdio or tcp."
        exit 1
        ;;
esac

echo "[+] Running QEMU..."
GTK_PATH= qemu-system-x86_64 \
    -enable-kvm -M q35 -m 256M -cpu host,vmx=on \
    -cdrom catenary.iso -boot d \
    "${SERIAL_ARGS[@]}"
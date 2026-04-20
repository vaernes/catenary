#!/bin/bash
set -euo pipefail

# Catenary OS cluster smoke test:
# - boots two Catenary OS nodes under QEMU connected via a socket
# - verifies they discover each other via DIPC
# - verifies clusterd remote MicroVM launch occurs

TIMEOUT_SECS=${TIMEOUT_SECS:-120}
REQUIRE_KVM=${REQUIRE_KVM:-1}

ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=true -Dvmm_active=true -Dvmm_launch_linux=true"

# Rebuild
echo "[+] Building Catenary OS..."
zig build ${ZIG_BUILD_ARGS}

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

xorriso -as mkisofs -b limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    iso_root -o catenary.iso

./limine/limine bios-install catenary.iso

rm -f qemu_serial_A.log qemu_A.pid qemu_serial_B.log qemu_B.pid

ACCEL="tcg"
CPU="max,vmx=on"
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL="kvm"
    CPU="host,vmx=on"
elif [ "${REQUIRE_KVM}" -eq 1 ]; then
    echo "[!] /dev/kvm is unavailable; nested-VMX smoke test cannot run."
    exit 2
fi

echo "[+] Starting Node A (accel=${ACCEL})..."
GTK_PATH= qemu-system-x86_64 \
    -M q35 -m 1024 \
    -cpu "${CPU}" -accel "${ACCEL}" \
    -cdrom catenary.iso -boot d \
    -serial file:qemu_serial_A.log \
    -display none \
    -pidfile qemu_A.pid \
    -no-reboot \
    -daemonize \
    -netdev socket,id=net0,mcast=230.0.0.1:1234 -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56

echo "[+] Starting Node B (accel=${ACCEL})..."
GTK_PATH= qemu-system-x86_64 \
    -M q35 -m 1024 \
    -cpu "${CPU}" -accel "${ACCEL}" \
    -cdrom catenary.iso -boot d \
    -serial file:qemu_serial_B.log \
    -display none \
    -pidfile qemu_B.pid \
    -no-reboot \
    -daemonize \
    -netdev socket,id=net0,mcast=230.0.0.1:1234 -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:57

cleanup() {
    if [ -f qemu_A.pid ]; then kill "$(cat qemu_A.pid)" >/dev/null 2>&1 || true; fi
    if [ -f qemu_B.pid ]; then kill "$(cat qemu_B.pid)" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

echo "[+] Waiting for milestones (timeout ${TIMEOUT_SECS}s)..."

milestone1="clusterd: discovered remote node via registry_sync, requesting remote MicroVM launch"
milestone2="kernel_control: staged MicroVM launched via DIPC"

ok=0
for ((i=0; i<${TIMEOUT_SECS}; i++)); do
    a_ok=0
    b_ok=0
    if grep -Fq "$milestone1" qemu_serial_A.log 2>/dev/null && grep -Fq "$milestone2" qemu_serial_B.log 2>/dev/null; then
        ok=1
        echo "[+] PASS: Node A requested remote launch, Node B launched staged MicroVM via DIPC."
        break
    fi
    if grep -Fq "$milestone1" qemu_serial_B.log 2>/dev/null && grep -Fq "$milestone2" qemu_serial_A.log 2>/dev/null; then
        ok=1
        echo "[+] PASS: Node B requested remote launch, Node A launched staged MicroVM via DIPC."
        break
    fi
    sleep 1
done

if [ "$ok" -eq 0 ]; then
    echo "[!] FAIL: Did not see remote MicroVM launch milestones."
    echo "--- Node A tail ---"
    tail -n 30 qemu_serial_A.log || true
    echo "--- Node B tail ---"
    tail -n 30 qemu_serial_B.log || true
    exit 1
fi

exit 0
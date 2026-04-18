#!/bin/bash
set -euo pipefail

# Catenary OS smoke test:
# - boots Catenary OS under QEMU
# - launches the nested-VMX path
# - passes only if the Linux guest reaches an early serial milestone

TIMEOUT_SECS=${TIMEOUT_SECS:-30}
REQUIRE_KVM=${REQUIRE_KVM:-1}
CORE_PATTERNS=${CORE_PATTERNS:-"booting...;selftest: PASS paging.canonical;Timer initialized.;dashd: starting;containerd: starting;inputd: registered at endpoint 8;windowd: registered at endpoint 9;clusterd: requesting local MicroVM launch"}
VMX_EPT_PATTERNS=${VMX_EPT_PATTERNS:-""}
VMX_LINUX_PATTERNS=${VMX_LINUX_PATTERNS:-""}

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

xorriso -as mkisofs -b limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    iso_root -o catenary.iso

./limine/limine bios-install catenary.iso

rm -f qemu_serial.log qemu.pid

ACCEL="tcg"
CPU="max,vmx=on"
if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL="kvm"
    CPU="host,vmx=on"
elif [ "${REQUIRE_KVM}" -eq 1 ]; then
    echo "[!] /dev/kvm is unavailable; nested-VMX smoke test cannot run."
    echo "[!] To override (best-effort TCG), run: REQUIRE_KVM=0 ./test_qemu.sh"
    exit 2
fi

echo "[+] Starting QEMU (accel=${ACCEL}, timeout=${TIMEOUT_SECS}s)..."
# GTK_PATH= is required to prevent snap-related crashes in some environments
GTK_PATH= qemu-system-x86_64 \
    -M q35 -m 1G \
    -cpu "${CPU}" -accel "${ACCEL}" \
    -cdrom catenary.iso -boot d \
    -serial file:qemu_serial.log \
    -display none \
    -pidfile qemu.pid \
    -no-reboot \
    -daemonize \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile= \
    -device nvme,serial=deadbeef,drive=nvm -drive file=test_disk.img,format=raw,if=none,id=nvm

cleanup() {
    if [ -f qemu.pid ]; then
        kill "$(cat qemu.pid)" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "[+] Waiting for all milestones (timeout ${TIMEOUT_SECS}s)..."
ok=0
core_ok=1
IFS=';' read -r -a all_patterns <<< "${CORE_PATTERNS}"
for ((i=0; i<${TIMEOUT_SECS}; i++)); do
    if [ -f qemu_serial.log ]; then
        all_found=1
        for p in "${all_patterns[@]}"; do
            if ! grep -Fq "${p}" qemu_serial.log; then
                all_found=0
                break
            fi
        done
        if [ "${all_found}" -eq 1 ]; then
            ok=1
            break
        fi
    fi
    sleep 1
done

echo "[+] Serial log (tail):"
tail -n 200 qemu_serial.log || true

if [ "${ok}" -eq 1 ]; then
    if [ -n "${VMX_EPT_PATTERNS}" ]; then
        IFS=';' read -r -a vmx_patterns <<< "${VMX_EPT_PATTERNS}"
        for pattern in "${vmx_patterns[@]}"; do
            if ! grep -Fq "${pattern}" qemu_serial.log; then
                echo "[!] SMOKE FAIL: missing VMX/EPT milestone '${pattern}'"
                core_ok=0
            fi
        done
    fi
    if [ -n "${VMX_LINUX_PATTERNS}" ]; then
        IFS=';' read -r -a linux_patterns <<< "${VMX_LINUX_PATTERNS}"
        for pattern in "${linux_patterns[@]}"; do
            if ! grep -Fq "${pattern}" qemu_serial.log; then
                echo "[!] SMOKE FAIL: missing Linux guest milestone '${pattern}'"
                core_ok=0
            fi
        done
    fi
fi

if [ "${ok}" -eq 1 ] && [ "${core_ok}" -eq 1 ]; then
    echo "[+] SMOKE PASS: observed guest and core milestones"
    exit 0
fi

if [ "${ok}" -eq 0 ]; then
    echo "[!] SMOKE FAIL: not all milestones observed within ${TIMEOUT_SECS}s"
    for p in "${all_patterns[@]}"; do
        if ! grep -Fq "${p}" qemu_serial.log 2>/dev/null; then
            echo "[!]   missing: '${p}'"
        fi
    done
fi

echo "[!] Failure summary (last matching lines):"
grep -nE "VMXON failed|VMCLEAR failed|VMPTRLD failed|VMLAUNCH/VMRESUME failed|VMEXIT: VM-entry failure|VMEXIT: TRIPLE FAULT|VMEXIT: EPT Violation|VMEXIT: unexpected interrupt-like exit|VMEXIT: unhandled" qemu_serial.log 2>/dev/null | tail -n 50 || true

if grep -Fq "VMXON failed" qemu_serial.log 2>/dev/null; then
    echo "[!] Hint: this usually means nested virtualization is disabled on the host."
fi
exit 1

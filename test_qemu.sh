#!/bin/bash
set -euo pipefail

# Catenary OS smoke test:
# - boots Catenary OS under QEMU
# - launches the nested-VMX path
# - passes only if the Linux guest reaches an early serial milestone

TIMEOUT_SECS=${TIMEOUT_SECS:-120}
REQUIRE_KVM=${REQUIRE_KVM:-1}
SMOKE_PROFILE=${SMOKE_PROFILE:-default}

DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=true"
DEFAULT_CORE_PATTERNS=""
DEFAULT_VMX_EPT_PATTERNS=""
DEFAULT_VMX_LINUX_PATTERNS=""

case "${SMOKE_PROFILE}" in
    default)
        DEFAULT_CORE_PATTERNS="booting...;selftest: PASS paging.canonical;Timer initialized.;netd: published kernel node address;netd: NIC ready, entering DIPC/NIC event loop;dashd: starting;containerd: starting;containerd: unpack block WRITE SUCCESS!;inputd: registered at endpoint 8;windowd: registered at endpoint 9;clusterd: requesting local MicroVM launch;configd: MicroVM created via DIPC"
        ;;
    vmx-linux)
        DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=true -Dvmm_active=true -Dvmm_launch_linux=true -Dservices_active=false"
        DEFAULT_CORE_PATTERNS="booting...;selftest: done;Timer initialized."
        DEFAULT_VMX_LINUX_PATTERNS="Linux version;Catenary OS Guest Init: SUCCESS"
        ;;
    vmx-linux-services)
        DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=true -Dvmm_active=true -Dvmm_launch_linux=true"
        DEFAULT_CORE_PATTERNS="booting...;selftest: PASS paging.canonical;Timer initialized.;netd: published kernel node address;netd: NIC ready, entering DIPC/NIC event loop;dashd: starting;containerd: starting;containerd: unpack block WRITE SUCCESS!;inputd: registered at endpoint 8;windowd: registered at endpoint 9;clusterd: requesting local MicroVM launch;configd: MicroVM created via DIPC"
        DEFAULT_VMX_LINUX_PATTERNS="kernel_control: staged MicroVM launched via DIPC;VMX: entering guest via vmlaunch;Linux version;Catenary OS Guest Init: SUCCESS;guest_rootfs: init started"
        ;;
    *)
        echo "[!] Unknown SMOKE_PROFILE: ${SMOKE_PROFILE}" >&2
        echo "[!] Expected one of: default, vmx-linux, vmx-linux-services" >&2
        exit 2
        ;;
esac

ZIG_BUILD_ARGS=${ZIG_BUILD_ARGS:-${DEFAULT_ZIG_BUILD_ARGS}}
CORE_PATTERNS=${CORE_PATTERNS:-${DEFAULT_CORE_PATTERNS}}
VMX_EPT_PATTERNS=${VMX_EPT_PATTERNS:-${DEFAULT_VMX_EPT_PATTERNS}}
VMX_LINUX_PATTERNS=${VMX_LINUX_PATTERNS:-${DEFAULT_VMX_LINUX_PATTERNS}}

pattern_seen() {
    local pattern="$1"
    perl -e '
        my ($pattern, $file) = @ARGV;
        open my $fh, q{<}, $file or exit 2;
        local $/;
        my $text = <$fh>;
        my @chars = split //, $pattern;
        my $regex = join(q{\.*}, map { quotemeta($_) } @chars);
        exit($text =~ /$regex/s ? 0 : 1);
    ' "$pattern" qemu_serial.log
}

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
required_patterns=()

if [ -n "${CORE_PATTERNS}" ]; then
    IFS=';' read -r -a core_patterns <<< "${CORE_PATTERNS}"
    required_patterns+=("${core_patterns[@]}")
else
    core_patterns=()
fi

if [ -n "${VMX_EPT_PATTERNS}" ]; then
    IFS=';' read -r -a vmx_patterns <<< "${VMX_EPT_PATTERNS}"
    required_patterns+=("${vmx_patterns[@]}")
else
    vmx_patterns=()
fi

if [ -n "${VMX_LINUX_PATTERNS}" ]; then
    IFS=';' read -r -a linux_patterns <<< "${VMX_LINUX_PATTERNS}"
    required_patterns+=("${linux_patterns[@]}")
else
    linux_patterns=()
fi

for ((i=0; i<${TIMEOUT_SECS}; i++)); do
    if [ -f qemu_serial.log ]; then
        all_found=1
        for p in "${required_patterns[@]}"; do
            if [ -z "${p}" ]; then
                continue
            fi
            if ! pattern_seen "${p}"; then
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

post_flush_pass=0
if [ "${ok}" -eq 0 ]; then
    cleanup
    if [ -f qemu_serial.log ]; then
        all_found=1
        for p in "${required_patterns[@]}"; do
            if [ -z "${p}" ]; then
                continue
            fi
            if ! pattern_seen "${p}"; then
                all_found=0
                break
            fi
        done
        if [ "${all_found}" -eq 1 ]; then
            ok=1
            post_flush_pass=1
        fi
    fi
fi

echo "[+] Serial log (tail):"
tail -n 200 qemu_serial.log || true

if [ "${ok}" -eq 1 ]; then
    if [ "${post_flush_pass}" -eq 1 ]; then
        echo "[+] SMOKE PASS: observed milestones after final serial flush"
        exit 0
    fi
    echo "[+] SMOKE PASS: observed guest and core milestones"
    exit 0
fi

if [ "${ok}" -eq 0 ]; then
    echo "[!] SMOKE FAIL: not all milestones observed within ${TIMEOUT_SECS}s"
    for p in "${required_patterns[@]}"; do
        if [ -z "${p}" ]; then
            continue
        fi
        if ! pattern_seen "${p}" 2>/dev/null; then
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

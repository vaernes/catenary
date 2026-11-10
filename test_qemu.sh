#!/bin/bash
set -euo pipefail

if ! command -v zig >/dev/null 2>&1; then
    for version in 0.17.1 0.17.0; do
        zig_dir="${HOME}/.config/Code/User/globalStorage/ziglang.vscode-zig/zig/x86_64-linux-${version}"
        if [ -x "${zig_dir}/zig" ]; then
            export PATH="${zig_dir}:$PATH"
            break
        fi
    done
fi

# Catenary OS smoke test; the selected profile defines the required milestones.

TIMEOUT_SECS=${TIMEOUT_SECS:-120}
REQUIRE_KVM=${REQUIRE_KVM:-1}
SMOKE_PROFILE=${SMOKE_PROFILE:-default}
NVME_DISK_IMAGE=${NVME_DISK_IMAGE:-}
NVME_DISK_TEMP=0
CORRUPT_METADATA=0
CORRUPT_JOURNAL=0
JOURNAL_RECOVERY=0
JOURNAL_HEADER_PRESENT=0

DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=false"
DEFAULT_CORE_PATTERNS=""
DEFAULT_VMX_EPT_PATTERNS=""
DEFAULT_VMX_LINUX_PATTERNS=""
NVME_DEVICE_ARGS=()

case "${SMOKE_PROFILE}" in
    default)
        if [ "${SMP:-2}" -eq 1 ]; then
            DEFAULT_CORE_PATTERNS="booting...;selftest: PASS paging.canonical;Timer initialized.;netd: published kernel node address;netd: NIC ready, entering DIPC/NIC event loop;dashd: starting;containerd: starting;containerd: partition metadata scan complete;storaged: FUA write+flush completed;containerd: smoke block WRITE SUCCESS!;containerd: partition header verified after flush;inputd: registered at endpoint 8;windowd: registered at endpoint 9;clusterd: requesting local MicroVM launch;configd: MicroVM created via DIPC"
        else
            DEFAULT_CORE_PATTERNS="booting...;smp: AP core;selftest: PASS paging.canonical;Timer initialized.;netd: published kernel node address;netd: NIC ready, entering DIPC/NIC event loop;dashd: starting;containerd: starting;containerd: partition metadata scan complete;storaged: FUA write+flush completed;containerd: smoke block WRITE SUCCESS!;containerd: partition header verified after flush;inputd: registered at endpoint 8;windowd: registered at endpoint 9;clusterd: requesting local MicroVM launch;configd: MicroVM created via DIPC"
        fi
        ;;
    vmx-linux)
        DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=false -Dvmm_active=true -Dvmm_launch_linux=true -Dservices_active=false"
        DEFAULT_CORE_PATTERNS="booting...;selftest: done;Timer initialized."
        DEFAULT_VMX_LINUX_PATTERNS="Linux version;Catenary OS Guest Init: SUCCESS"
        ;;
    vmx-linux-services)
        DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=false -Dvmm_active=true -Dvmm_launch_linux=true"
        DEFAULT_CORE_PATTERNS="booting...;selftest: PASS paging.canonical;Timer initialized.;netd: published kernel node address;netd: NIC ready, entering DIPC/NIC event loop;dashd: starting;containerd: starting;containerd: partition metadata scan complete;storaged: FUA write+flush completed;containerd: smoke block WRITE SUCCESS!;containerd: partition header verified after flush;inputd: registered at endpoint 8;windowd: registered at endpoint 9;clusterd: requesting local MicroVM launch"
        DEFAULT_VMX_LINUX_PATTERNS="kernel_control: staged MicroVM launched via DIPC;VMX: entering guest via vmlaunch;Linux version;Catenary OS Guest Init: SUCCESS;guest_rootfs: init started"
        ;;
    ui-phase8)
        DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=false"
        DEFAULT_CORE_PATTERNS="booting...;selftest: PASS paging.canonical;Timer initialized.;inputd: registered at endpoint 8;windowd: registered at endpoint 9;windowd: input event received;[UI] MicroVM provisioned: alpine-node-01;configd: host-assigned vNIC attached (default-deny);configd: vNIC detached;varde_shell: executed 'ps';varde_shell: executed 'vmlist';varde_shell: executed 'cluster';varde_shell: executed 'net-stat';varde_shell: executed 'storage-stat'"
        ;;
    vnic-bind)
        DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=false"
        DEFAULT_CORE_PATTERNS="booting...;inputd: registered at endpoint 8;windowd: registered at endpoint 9;[UI] MicroVM provisioned: alpine-node-01;configd: host-assigned vNIC attached (default-deny);[UI] vNIC binding rejected;configd: vNIC address bindings updated (default-deny);[UI] vNIC bindings updated (default-deny);configd: vNIC detached"
        ;;
    phase9)
        if [ "${SMP:-2}" -lt 2 ]; then
            SMP=2
        fi
        DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=false -Dvmm_active=true -Dvmm_launch_linux=true"
        DEFAULT_CORE_PATTERNS="booting...;smp: AP core;selftest: PASS paging.canonical;Timer initialized.;inputd: registered at endpoint 8;windowd: registered at endpoint 9;[UI] MicroVM provisioned: alpine-node-01;[UI] Switched console to MicroVM #2"
        DEFAULT_VMX_EPT_PATTERNS="VMX: initialized EPT root for VM 1;VMX: initialized EPT root for VM 2"
        DEFAULT_VMX_LINUX_PATTERNS="VMX: launching VM 1 on core 0;VMX: launching VM 2 on core 1;[vm1] Catenary OS Guest Init: SUCCESS;[vm1] guest_rootfs: init started;[vm1] guest_rootfs: shell ready;[vm2] Catenary OS Guest Init: SUCCESS;[vm2] guest_rootfs: init started;[vm2] guest_rootfs: shell ready;[UI] Switched console to MicroVM #1;[vm1] help env os-release exit;[UI] Switched console to MicroVM #2;[vm2] help env os-release exit"
        ;;
    no-nvme)
        NVME_DEVICE_ARGS=()
        DEFAULT_CORE_PATTERNS="booting...;selftest: PASS paging.canonical;Timer initialized.;storaged: no NVMe found; block requests will fail;containerd: block I/O FAILED"
        ;;
    corrupt-metadata)
        CORRUPT_METADATA=1
        DEFAULT_CORE_PATTERNS="booting...;containerd: invalid partition metadata; refusing slot reuse"
        ;;
    corrupt-journal)
        CORRUPT_JOURNAL=1
        DEFAULT_CORE_PATTERNS="booting...;containerd: invalid partition journal; refusing metadata recovery"
        ;;
    journal-recovery)
        JOURNAL_RECOVERY=1
        if [ "${SMP:-2}" -lt 2 ]; then
            SMP=2
        fi
        DEFAULT_CORE_PATTERNS="booting...;smp: AP core;selftest: PASS paging.canonical;Timer initialized.;netd: published kernel node address;netd: NIC ready, entering DIPC/NIC event loop;dashd: starting;containerd: starting;containerd: journal recovery replayed slot 0;containerd: journal recovery complete;containerd: partition metadata scan complete;storaged: FUA write+flush completed;containerd: smoke block WRITE SUCCESS!;containerd: partition header verified after flush;containerd: partition journal cleared;inputd: registered at endpoint 8;windowd: registered at endpoint 9"
        ;;
    journal-commit-recovery)
        JOURNAL_RECOVERY=1
        JOURNAL_HEADER_PRESENT=1
        if [ "${SMP:-2}" -lt 2 ]; then
            SMP=2
        fi
        DEFAULT_CORE_PATTERNS="booting...;smp: AP core;selftest: PASS paging.canonical;Timer initialized.;netd: published kernel node address;netd: NIC ready, entering DIPC/NIC event loop;dashd: starting;containerd: starting;containerd: journal recovery replayed slot 0;containerd: journal recovery complete;containerd: recovered partition metadata;containerd: partition metadata scan complete;storaged: FUA write+flush completed;containerd: smoke block WRITE SUCCESS!;containerd: partition header verified after flush;containerd: partition journal cleared;inputd: registered at endpoint 8;windowd: registered at endpoint 9"
        ;;
    *)
        echo "[!] Unknown SMOKE_PROFILE: ${SMOKE_PROFILE}" >&2
        echo "[!] Expected one of: default, vmx-linux, vmx-linux-services, ui-phase8, vnic-bind, phase9, no-nvme, corrupt-metadata, corrupt-journal, journal-recovery, journal-commit-recovery" >&2
        exit 2
        ;;
esac

if [ "${SMOKE_PROFILE}" != "no-nvme" ]; then
    if [ -z "${NVME_DISK_IMAGE}" ]; then
        NVME_DISK_IMAGE=$(mktemp /tmp/catenary-qemu-disk.XXXXXX)
        NVME_DISK_TEMP=1
    fi
    NVME_DEVICE_ARGS=(-device nvme,serial=deadbeef,drive=nvm -drive "file=${NVME_DISK_IMAGE},format=raw,if=none,id=nvm")
fi

cleanup_temporary_disk() {
    if [ "${NVME_DISK_TEMP}" -eq 1 ]; then
        rm -f "${NVME_DISK_IMAGE}"
    fi
}
trap cleanup_temporary_disk EXIT

ZIG_BUILD_ARGS=${ZIG_BUILD_ARGS:-${DEFAULT_ZIG_BUILD_ARGS}}
CORE_PATTERNS=${CORE_PATTERNS:-${DEFAULT_CORE_PATTERNS}}
VMX_EPT_PATTERNS=${VMX_EPT_PATTERNS:-${DEFAULT_VMX_EPT_PATTERNS}}
VMX_LINUX_PATTERNS=${VMX_LINUX_PATTERNS:-${DEFAULT_VMX_LINUX_PATTERNS}}
if [ "${JOURNAL_HEADER_PRESENT}" -eq 1 ]; then
    CORE_PATTERNS="${CORE_PATTERNS};containerd: recovered partition metadata"
fi

pattern_seen() {
    grep -Fq -- "$1" qemu_serial.log
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

rm -f qemu_serial.log qemu.pid /tmp/catenary_qemu_mon.sock

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

if [ "${SMOKE_PROFILE}" != "no-nvme" ] &&
    { [ ! -f "${NVME_DISK_IMAGE}" ] || [ ! -s "${NVME_DISK_IMAGE}" ]; }; then
    dd if=/dev/zero of="${NVME_DISK_IMAGE}" bs=1M count=64 status=none
fi
if [ "${CORRUPT_METADATA}" -eq 1 ]; then
    printf '\231' | dd of="${NVME_DISK_IMAGE}" bs=1 seek=$((8192 * 512)) conv=notrunc status=none
fi
if [ "${CORRUPT_JOURNAL}" -eq 1 ]; then
    printf '\231' | dd of="${NVME_DISK_IMAGE}" bs=1 seek=$((8191 * 512)) conv=notrunc status=none
fi
if [ "${JOURNAL_RECOVERY}" -eq 1 ]; then
    python3 - "${NVME_DISK_IMAGE}" "${JOURNAL_HEADER_PRESENT}" <<'PY'
import struct
import sys
import zlib

def checksum(data):
    return zlib.crc32(data) & 0xFFFFFFFF

header = bytearray(64)
struct.pack_into("<QIIQQI", header, 0,
                 0x32524150524E524E, 0, 2, 8192, 2048, 0)
header[36:42] = b"rootfs"
struct.pack_into("<I", header, 32, checksum(header))

record = bytearray(96)
struct.pack_into("<QIIQ", record, 0,
                 0x314C4E4A524E524E, 1, 0, 1)
record[24:88] = header
struct.pack_into("<I", record, 88, checksum(record))

with open(sys.argv[1], "r+b") as disk:
    disk.seek(8191 * 512)
    disk.write(record + bytes(512 - len(record)))
    if sys.argv[2] == "1":
        disk.seek(8192 * 512)
        disk.write(header + bytes(512 - len(header)))
PY
fi

echo "[+] Starting QEMU (accel=${ACCEL}, timeout=${TIMEOUT_SECS}s)..."
# GTK_PATH= is required to prevent snap-related crashes in some environments
GTK_PATH= qemu-system-x86_64 \
    -M q35 -m 1G \
    -cpu "${CPU}" -accel "${ACCEL}" \
    -smp "${SMP:-2}" \
    -cdrom catenary.iso -boot d \
    -chardev file,id=s0,path=qemu_serial.log \
    -serial chardev:s0 \
    -monitor unix:/tmp/catenary_qemu_mon.sock,server,nowait \
    -display none \
    -pidfile qemu.pid \
    -no-reboot \
    -daemonize \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile= \
    "${NVME_DEVICE_ARGS[@]}"

cleanup() {
    if [ -f qemu.pid ]; then
        kill "$(cat qemu.pid)" >/dev/null 2>&1 || true
    fi
    rm -f /tmp/catenary_qemu_mon.sock
    cleanup_temporary_disk
}
trap cleanup EXIT

ui_keys_injected=0
inject_ui_phase8_keys() {
    python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect("/tmp/catenary_qemu_mon.sock")
time.sleep(0.2)
def send_keys(keys, delay=0.12):
    for k in keys:
        s.sendall(f"sendkey {k}\n".encode())
        time.sleep(delay)

# 1. Step through MicroVM Provisioning Form fields (name -> vcpus -> memory -> kernel -> rootfs -> create_btn) and trigger CREATE & LAUNCH
send_keys(["ret", "ret", "ret", "ret", "ret", "ret"], 0.15)
time.sleep(0.3)

# 2. Switch to Varde Shell pane (F4) and execute Phase 8 shell commands
send_keys(["f4"], 0.2)
for cmd in ["ps", "vmlist", "cluster", "net-stat", "storage-stat"]:
    keys = ["minus" if ch == "-" else ch for ch in cmd] + ["ret"]
    send_keys(keys, 0.08)
    time.sleep(0.2)

if sys.argv[1] == "vnic-bind":
    def send_command(command):
        special = {" ": "spc", "-": "minus", ".": "dot", ":": "shift-semicolon"}
        send_keys([special.get(ch, ch) for ch in command] + ["ret"], 0.08)

    def wait_for(marker):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            with open("qemu_serial.log", "r", errors="replace") as log:
                if marker in log.read():
                    return
            time.sleep(0.25)
        raise SystemExit("Missing vNIC milestone: " + marker)

    wait_for("configd: host-assigned vNIC attached (default-deny)")
    send_command("vnic-bind 2 224.0.0.1 -")
    wait_for("[UI] vNIC binding rejected")
    send_command("vnic-bind 2 10.77.0.2 fd00::2")
    wait_for("[UI] vNIC bindings updated (default-deny)")

# The cluster service creates VM 1 in the background; the UI-created running
# VM is therefore VM 2. Stop it and require configd to detach its vNIC.
send_keys(["v", "m", "minus", "s", "t", "o", "p", "spc", "2", "ret"], 0.1)
deadline = time.monotonic() + 20
while time.monotonic() < deadline:
    with open("qemu_serial.log", "r", errors="replace") as log:
        if "configd: vNIC detached" in log.read():
            break
    time.sleep(0.25)
else:
    raise SystemExit("Stopped VM vNIC was not detached")
s.close()
' "${SMOKE_PROFILE}"
}

inject_ui_phase9_keys() {
    python3 -c '
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect("/tmp/catenary_qemu_mon.sock")
time.sleep(0.2)
def send_keys(keys, delay=0.12):
    for k in keys:
        s.sendall(f"sendkey {k}\n".encode())
        time.sleep(delay)

# 1. Advance to memory, select 128 MB for the Linux guest, then create and launch MicroVM 2
send_keys(["ret", "ret"], 0.15)
send_keys(["right", "right"], 0.15)
send_keys(["ret", "ret", "ret", "ret"], 0.15)
time.sleep(0.4)

# 2. Switch to MicroVM 2 and wait until both guest shells can accept input
send_keys(["f6"], 0.2)
send_keys(["f8"], 0.2)

deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    with open("qemu_serial.log", "r", errors="replace") as log:
        output = log.read()
        if "[vm1] guest_rootfs: shell ready" in output and "[vm2] guest_rootfs: shell ready" in output:
            break
    time.sleep(0.25)
else:
    raise SystemExit("Both guest shells did not become ready")

# 3. Exercise input/output on VM 2, switch back to VM 1, and exercise it there too
send_keys(["h", "e", "l", "p", "ret"], 0.1)
deadline = time.monotonic() + 20
while time.monotonic() < deadline:
    with open("qemu_serial.log", "r", errors="replace") as log:
        if "[vm2] help env os-release exit" in log.read():
            break
    time.sleep(0.25)
else:
    raise SystemExit("MicroVM 2 did not answer help")

send_keys(["f7"], 0.2)
send_keys(["h", "e", "l", "p", "ret"], 0.1)
s.close()
'
}

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
        if { [ "${SMOKE_PROFILE}" = "ui-phase8" ] || [ "${SMOKE_PROFILE}" = "vnic-bind" ]; } && [ "${ui_keys_injected}" -eq 0 ]; then
            if pattern_seen "windowd: registered at endpoint 9" && pattern_seen "inputd: registered at endpoint 8" && pattern_seen "configd: MicroVM created via DIPC"; then
                echo "[+] Injecting Phase 8 UI & Varde Shell keystrokes via QEMU monitor..."
                inject_ui_phase8_keys
                ui_keys_injected=1
            fi
        fi
        if [ "${SMOKE_PROFILE}" = "phase9" ] && [ "${ui_keys_injected}" -eq 0 ]; then
            if pattern_seen "windowd: registered at endpoint 9" && pattern_seen "inputd: registered at endpoint 8" && pattern_seen "kernel_control: staged MicroVM launched via DIPC"; then
                echo "[+] Injecting Phase 9 Multi-VM & Guest Console keystrokes via QEMU monitor..."
                inject_ui_phase9_keys
                ui_keys_injected=1
            fi
        fi
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
    if [ "${CORRUPT_METADATA}" -eq 1 ] &&
        grep -Eq "containerd: (smoke block WRITE SUCCESS!|partition header write requested)" qemu_serial.log; then
        echo "[!] SMOKE FAIL: storage writes continued after corrupt metadata"
        exit 1
    fi
    if [ "${CORRUPT_JOURNAL}" -eq 1 ] &&
        grep -Eq "containerd: (smoke block WRITE SUCCESS!|partition journal intent write requested)" qemu_serial.log; then
        echo "[!] SMOKE FAIL: storage writes continued after corrupt journal"
        exit 1
    fi
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

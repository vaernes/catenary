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

DEFAULT_TIMEOUT_SECS=120
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
        DEFAULT_CORE_PATTERNS="booting...;inputd: registered at endpoint 8;windowd: registered at endpoint 9;[UI] MicroVM provisioned: alpine-node-01;configd: host-assigned vNIC attached (default-deny);[UI] vNIC binding rejected;configd: vNIC address bindings updated (default-deny);[UI] vNIC bindings updated (default-deny);[UI] vNIC rule added;[UI] vNIC rule rejected;[UI] vNIC rules cleared (default-deny);configd: vNIC firewall rule applied (default-deny);netd: vswitch rule updated;configd: vNIC detached"
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
    phase10)
        if [ "${SMP:-2}" -lt 2 ]; then
            SMP=2
        fi
        DEFAULT_TIMEOUT_SECS=180
        DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=false -Dvmm_active=true -Dvmm_launch_linux=true"
        DEFAULT_CORE_PATTERNS="booting...;smp: AP core;selftest: PASS paging.canonical;Timer initialized.;inputd: registered at endpoint 8;windowd: registered at endpoint 9;[UI] MicroVM provisioned: alpine-node-01;configd: per-VM disk attached;storaged: per-VM disk attached;configd: host-assigned vNIC attached (default-deny);configd: vNIC address bindings updated (default-deny);[UI] vNIC bindings updated (default-deny);netd: vswitch drop vm1 egress_denied total=1;netd: vswitch drop vm1 spoofed_mac total=1;netd: vswitch drop vm1 unauthorized_source_address total=1;[UI] vNIC rule added;configd: vNIC firewall rule applied (default-deny);netd: vswitch rule updated;netd: vswitch forward vm1 -> vm2 len=58;netd: vswitch forward vm1 -> vm2 len=79;[UI] vNIC rules cleared (default-deny);netd: vswitch drop vm1 egress_denied total=2;configd: per-VM disk detached;storaged: per-VM disk detached;configd: vNIC detached;varde_shell: MicroVM deleted"
        DEFAULT_VMX_EPT_PATTERNS="VMX: initialized EPT root for VM 1;VMX: initialized EPT root for VM 2"
        DEFAULT_VMX_LINUX_PATTERNS="VMX: launching VM 1 on core 0;VMX: launching VM 2 on core 1;[vm1] Catenary OS Guest Init: SUCCESS;[vm1] guest_rootfs: shell ready;[vm2] Catenary OS Guest Init: SUCCESS;[vm2] guest_rootfs: shell ready;[vm2] guest_blk: out-of-bounds sector rejected;[vm2] guest_blk: extent isolated;[vm2] guest_blk: FUA write+flush+readback OK tag=CATENARY-VM2-DISK;[vm1] guest_blk: out-of-bounds sector rejected;[vm1] guest_blk: extent isolated;[vm1] guest_blk: FUA write+flush+readback OK tag=CATENARY-VM1-DISK;[vm1] guest_net: ready mac=02:ca:00:00:00:01 vmid=1;[vm2] guest_net: ready mac=02:ca:00:00:00:02 vmid=2;[vm1] guest_net: spoof probes sent;[vm2] guest_net: rx arp from 10.77.0.1;[vm2] guest_net: rx udp4 payload=CATENARY-UDP4-OK;[vm2] guest_net: rx icmp6 payload=CATENARY-ICMP6-OK;[vm2] guest_net: rx total=0"
        ;;
    phase11)
        if [ "${SMP:-2}" -lt 2 ]; then
            SMP=2
        fi
        DEFAULT_TIMEOUT_SECS=180
        DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=false -Dvmm_active=true -Dvmm_launch_linux=true"
        DEFAULT_CORE_PATTERNS="booting...;smp: AP core;selftest: PASS paging.canonical;Timer initialized.;inputd: registered at endpoint 8;windowd: registered at endpoint 9;varde_shell: vm-create-full rejected profile=win11-26h2 reason=missing-installer-media;varde_shell: vm-create-full rejected profile=uefi-revoked reason=secure-boot-dbx-revoked;varde_shell: vm-create-full admitted profile=uefi-test;VMX: staged UEFI Full-VM for VM 2 warm_reboot=0;uefi_vm: ACPI RSDP+XSDT+FACP+APIC+MCFG+TPM2 verified;uefi_vm: PCI bus enumerated devs=4 (host,gop,net,blk);uefi_vm: GOP framebuffer 1024x768x32 active;uefi_vm: TPM 2.0 startup+selftest+PCR0+seal+unseal OK;uefi_vm: TPM 2.0 PCR mismatch unseal rejected;uefi_vm: EFI vars persisted boot_count=1;uefi_vm: ready;uefi_vm: disk FUA write+flush OK tag=CATENARY-UEFI-PERSIST;varde_shell: vm-reboot requested;VMX: staged UEFI Full-VM for VM 2 warm_reboot=1;VMX: warm reboot completed for VM 2;uefi_vm: EFI vars recovered boot_count=2;uefi_vm: disk readback after reboot OK tag=CATENARY-UEFI-PERSIST"
        DEFAULT_VMX_EPT_PATTERNS="VMX: initialized EPT root for VM 1;VMX: initialized EPT root for VM 2"
        DEFAULT_VMX_LINUX_PATTERNS="VMX: launching VM 1 on core 0;VMX: launching VM 2 on core 1"
        ;;
    phase12)
        if [ "${SMP:-2}" -lt 2 ]; then
            SMP=2
        fi
        DEFAULT_TIMEOUT_SECS=180
        DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=false -Dvmm_active=true -Dvmm_launch_linux=true"
        DEFAULT_CORE_PATTERNS="booting...;smp: AP core;selftest: PASS paging.canonical;Timer initialized.;inputd: registered at endpoint 8;windowd: registered at endpoint 9;varde_shell: vm-create-full admitted profile=uefi-test;VMX: staged UEFI Full-VM for VM 2 warm_reboot=0;uefi_vm: ready;uefi_vm: disk FUA write+flush OK tag=CATENARY-UEFI-PERSIST;varde_shell: vm-snapshot created;varde_shell: vm-restore completed;uefi_vm: disk readback after reboot OK tag=CATENARY-UEFI-PERSIST"
        DEFAULT_VMX_EPT_PATTERNS="VMX: initialized EPT root for VM 1;VMX: initialized EPT root for VM 2"
        DEFAULT_VMX_LINUX_PATTERNS="VMX: launching VM 1 on core 0;VMX: launching VM 2 on core 1"
        ;;
    phase13)
        if [ "${SMP:-2}" -lt 2 ]; then
            SMP=2
        fi
        DEFAULT_TIMEOUT_SECS=180
        DEFAULT_ZIG_BUILD_ARGS="-Dserial_syscall_keepalive=false -Dvmm_active=true -Dvmm_launch_linux=true"
        DEFAULT_CORE_PATTERNS="booting...;smp: AP core;selftest: PASS paging.canonical;Timer initialized.;inputd: registered at endpoint 8;windowd: registered at endpoint 9;varde_shell: vm-create-full admitted profile=uefi-test;VMX: staged UEFI Full-VM for VM 2 warm_reboot=0;uefi_vm: ready;varde_shell: nested VMX L0 state machine validated"
        DEFAULT_VMX_EPT_PATTERNS="VMX: initialized EPT root for VM 1;VMX: initialized EPT root for VM 2"
        DEFAULT_VMX_LINUX_PATTERNS="VMX: launching VM 1 on core 0;VMX: launching VM 2 on core 1"
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
        echo "[!] Expected one of: default, vmx-linux, vmx-linux-services, ui-phase8, vnic-bind, phase9, phase10, phase11, no-nvme, corrupt-metadata, corrupt-journal, journal-recovery, journal-commit-recovery" >&2
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

TIMEOUT_SECS=${TIMEOUT_SECS:-${DEFAULT_TIMEOUT_SECS}}
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

    def wait_for(marker, count=1):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            with open("qemu_serial.log", "r", errors="replace") as log:
                if log.read().count(marker) >= count:
                    return
            time.sleep(0.25)
        raise SystemExit("Missing vNIC milestone: " + marker)

    wait_for("configd: host-assigned vNIC attached (default-deny)")
    send_command("vnic-bind 2 224.0.0.1 -")
    wait_for("[UI] vNIC binding rejected")
    send_command("vnic-bind 2 10.77.0.2 fd00::2")
    wait_for("[UI] vNIC bindings updated (default-deny)")
    # Operator firewall controls: add rules, reject a duplicate, then clear (default-deny).
    send_command("vnic-allow 2 out udp 10.77.0.1 5001")
    wait_for("[UI] vNIC rule added")
    send_command("vnic-allow 2 out udp 10.77.0.1 5001")
    wait_for("[UI] vNIC rule rejected")
    send_command("vnic-allow 2 in icmp fd00::2")
    wait_for("[UI] vNIC rule added", 2)
    send_command("vnic-clear 2")
    wait_for("[UI] vNIC rules cleared (default-deny)")

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

inject_ui_phase10_keys() {
    python3 -c '
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect("/tmp/catenary_qemu_mon.sock")
time.sleep(0.2)

def send_keys(keys, delay=0.10):
    for k in keys:
        s.sendall(f"sendkey {k}\n".encode())
        time.sleep(delay)

def send_command(command, delay=0.07):
    special = {" ": "spc", "-": "minus", ".": "dot", ":": "shift-semicolon"}
    send_keys([special.get(ch, ch) for ch in command] + ["ret"], delay)

def wait_for(marker, count=1, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with open("qemu_serial.log", "r", errors="replace") as log:
            if log.read().count(marker) >= count:
                return
        time.sleep(0.25)
    raise SystemExit(f"Missing Phase 10 milestone ({count}x): {marker}")

# 1. Advance to memory, select 128 MB for the Linux guest, then create and launch MicroVM 2
send_keys(["ret", "ret"], 0.15)
send_keys(["right", "right"], 0.15)
send_keys(["ret", "ret", "ret", "ret"], 0.15)
time.sleep(0.4)

# 2. Switch to Guest Console (F6), select MicroVM 2 (F8), and wait until both guest shells and device attachments are ready
send_keys(["f6"], 0.2)
send_keys(["f8"], 0.2)
wait_for("[vm1] guest_rootfs: shell ready", 1, 60)
wait_for("[vm2] guest_rootfs: shell ready", 1, 60)
wait_for("storaged: per-VM disk attached", 2, 30)
wait_for("configd: host-assigned vNIC attached (default-deny)", 2, 30)

# 3. Exercise per-VM disk extent isolation, out-of-bounds rejection, and FUA write+flush+readback
send_command("blk-test")
wait_for("[vm2] guest_blk: FUA write+flush+readback OK tag=CATENARY-VM2-DISK")

send_keys(["f7"], 0.2)
wait_for("[UI] Switched console to MicroVM #1")
send_command("blk-test")
wait_for("[vm1] guest_blk: FUA write+flush+readback OK tag=CATENARY-VM1-DISK")

# 4. Initialize virtio-net on both guests
send_command("net-init")
wait_for("[vm1] guest_net: ready mac=02:ca:00:00:00:01 vmid=1")

send_keys(["f8"], 0.2)
wait_for("[UI] Switched console to MicroVM #2")
send_command("net-init")
wait_for("[vm2] guest_net: ready mac=02:ca:00:00:00:02 vmid=2")

# 5. Bind dual-stack addresses on both vNICs via Varde Shell (F4)
send_keys(["f4"], 0.2)
send_command("vnic-bind 1 10.77.0.1 fd00::1")
wait_for("[UI] vNIC bindings updated (default-deny)", 1)
send_command("vnic-bind 2 10.77.0.2 fd00::2")
wait_for("[UI] vNIC bindings updated (default-deny)", 2)

# 6. Verify default-deny blocking and anti-spoof rejection before any allow rules exist
send_keys(["f6"], 0.2)
send_keys(["f7"], 0.2)
send_command("net-tx-v4")
wait_for("[vm1] guest_net: udp4 sent", 1)
send_command("net-spoof")
wait_for("[vm1] guest_net: spoof probes sent", 1)

send_keys(["f8"], 0.2)
send_command("net-rx")
wait_for("[vm2] guest_net: rx total=0", 1)

# 7. Add explicit firewall rules for IPv4 UDP (port 5001) and IPv6 ICMPv6 between VM 1 and VM 2
send_keys(["f4"], 0.2)
send_command("vnic-allow 1 out udp 10.77.0.2 5001")
wait_for("[UI] vNIC rule added", 1)
send_command("vnic-allow 2 in udp 10.77.0.2 5001")
wait_for("[UI] vNIC rule added", 2)
send_command("vnic-allow 1 out icmp fd00::2")
wait_for("[UI] vNIC rule added", 3)
send_command("vnic-allow 2 in icmp fd00::2")
wait_for("[UI] vNIC rule added", 4)

# 8. Send ARP, IPv4 UDP, and IPv6 ICMPv6 from VM 1 and verify reception on VM 2
send_keys(["f6"], 0.2)
send_keys(["f7"], 0.2)
send_command("net-arp")
wait_for("[vm1] guest_net: arp sent", 1)
send_command("net-tx-v4")
wait_for("[vm1] guest_net: udp4 sent", 2)
send_command("net-tx-v6")
wait_for("[vm1] guest_net: icmp6 sent", 1)

send_keys(["f8"], 0.2)
send_command("net-rx")
wait_for("[vm2] guest_net: rx arp from 10.77.0.1", 1)
wait_for("[vm2] guest_net: rx udp4 payload=CATENARY-UDP4-OK", 1)
wait_for("[vm2] guest_net: rx icmp6 payload=CATENARY-ICMP6-OK", 1)

# 9. Revoke VM 1 rules (vnic-clear 1) and verify subsequent traffic is blocked again
send_keys(["f4"], 0.2)
send_command("vnic-clear 1")
wait_for("[UI] vNIC rules cleared (default-deny)", 1)

send_keys(["f6"], 0.2)
send_keys(["f7"], 0.2)
send_command("net-tx-v4")
wait_for("[vm1] guest_net: udp4 sent", 3)

send_keys(["f8"], 0.2)
send_command("net-rx")
wait_for("[vm2] guest_net: rx total=0", 2)

# 10. Stop and delete MicroVM 2 via Varde Shell and require disk + vNIC detach and VM deletion
send_keys(["f4"], 0.2)
send_command("vm-stop 2")
wait_for("configd: per-VM disk detached", 1)
wait_for("configd: vNIC detached", 1)
send_command("vm-delete 2")
wait_for("varde_shell: MicroVM deleted", 1)
s.close()
'
}

inject_ui_phase11_keys() {
    python3 -c '
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect("/tmp/catenary_qemu_mon.sock")
time.sleep(0.2)

def send_keys(keys, delay=0.08):
    for k in keys:
        s.sendall(f"sendkey {k}\n".encode())
        time.sleep(delay)

def send_command(command, delay=0.05):
    special = {" ": "spc", "-": "minus", ".": "dot", ":": "shift-semicolon"}
    send_keys([special.get(ch, ch) for ch in command] + ["ret"], delay)

def wait_for(marker, count=1, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with open("qemu_serial.log", "r", errors="replace") as log:
            if log.read().count(marker) >= count:
                return
        time.sleep(0.25)
    raise SystemExit(f"Missing Phase 11 milestone ({count}x): {marker}")

# 1. Switch to Varde Shell (F4)
send_keys(["f4"], 0.2)

# 2. Test Full-VM prerequisite admission rejection (win11-26h2 missing ISO)
send_command("vm-create-full win11-26h2")
wait_for("varde_shell: vm-create-full rejected profile=win11-26h2 reason=missing-installer-media", 1)

# 3. Test Secure Boot dbx revocation rejection (uefi-revoked)
send_command("vm-create-full uefi-revoked")
wait_for("varde_shell: vm-create-full rejected profile=uefi-revoked reason=secure-boot-dbx-revoked", 1)

# 4. Create and launch direct UEFI Full-VM (uefi-test)
send_command("vm-create-full uefi-test")
wait_for("varde_shell: vm-create-full admitted profile=uefi-test", 1)
wait_for("uefi_vm: ready", 1, 60)
wait_for("storaged: per-VM disk attached", 2, 30)

# 5. Send disk-write command to VM 2 via vm-send
send_command("vm-send 2 disk-write")
wait_for("uefi_vm: disk FUA write+flush OK tag=CATENARY-UEFI-PERSIST", 1, 30)

# 6. Trigger warm reboot of VM 2 via vm-reboot
send_command("vm-reboot 2")
wait_for("varde_shell: vm-reboot requested", 1)
wait_for("VMX: warm reboot completed for VM 2", 1, 30)
wait_for("uefi_vm: EFI vars recovered boot_count=2", 1, 30)
wait_for("uefi_vm: ready", 2, 30)

# 7. Send disk-verify command to VM 2 to verify NVMe disk extent persistence across reboot
send_command("vm-send 2 disk-verify")
wait_for("uefi_vm: disk readback after reboot OK tag=CATENARY-UEFI-PERSIST", 1, 30)

s.close()
'
}

inject_ui_phase12_keys() {
    python3 -c '
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect("/tmp/catenary_qemu_mon.sock")
time.sleep(0.2)

def send_keys(keys, delay=0.08):
    for k in keys:
        s.sendall(f"sendkey {k}\n".encode())
        time.sleep(delay)

def send_command(command, delay=0.05):
    special = {" ": "spc", "-": "minus", ".": "dot", ":": "shift-semicolon"}
    send_keys([special.get(ch, ch) for ch in command] + ["ret"], delay)

def wait_for(marker, count=1, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with open("qemu_serial.log", "r", errors="replace") as log:
            if log.read().count(marker) >= count:
                return
        time.sleep(0.25)
    raise SystemExit(f"Missing Phase 12 milestone ({count}x): {marker}")

# 1. Switch to Varde Shell (F4)
send_keys(["f4"], 0.2)

# 2. Create and launch direct UEFI Full-VM (uefi-test)
send_command("vm-create-full uefi-test")
wait_for("varde_shell: vm-create-full admitted profile=uefi-test", 1)
wait_for("uefi_vm: ready", 1, 60)
wait_for("storaged: per-VM disk attached", 2, 30)

# 3. Send disk-write command to VM 2 via vm-send
send_command("vm-send 2 disk-write")
wait_for("uefi_vm: disk FUA write+flush OK tag=CATENARY-UEFI-PERSIST", 1, 30)

# 4. Create coordinated snapshot 1 for VM 2
send_command("vm-snapshot 2 snap-phase12")
wait_for("varde_shell: vm-snapshot created", 1, 30)

# 5. Restore VM 2 to generation 1
send_command("vm-restore 2 1")
wait_for("varde_shell: vm-restore completed", 1, 30)
wait_for("uefi_vm: ready", 2, 30)

# 6. Verify NVMe disk extent and registers after restore
send_command("vm-send 2 disk-verify")
wait_for("uefi_vm: disk readback after reboot OK tag=CATENARY-UEFI-PERSIST", 1, 30)

s.close()
'
}

inject_ui_phase13_keys() {
    python3 -c '
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect("/tmp/catenary_qemu_mon.sock")
time.sleep(0.2)

def send_keys(keys, delay=0.08):
    for k in keys:
        s.sendall(f"sendkey {k}\n".encode())
        time.sleep(delay)

def send_command(command, delay=0.05):
    special = {" ": "spc", "-": "minus", ".": "dot", ":": "shift-semicolon"}
    send_keys([special.get(ch, ch) for ch in command] + ["ret"], delay)

def wait_for(marker, count=1, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with open("qemu_serial.log", "r", errors="replace") as log:
            if log.read().count(marker) >= count:
                return
        time.sleep(0.25)
    raise SystemExit(f"Missing Phase 13 milestone ({count}x): {marker}")

# 1. Switch to Varde Shell (F4)
send_keys(["f4"], 0.2)

# 2. Create and launch direct UEFI Full-VM (uefi-test)
send_command("vm-create-full uefi-test")
wait_for("varde_shell: vm-create-full admitted profile=uefi-test", 1)
wait_for("uefi_vm: ready", 1, 60)

# 3. Test nested VMX L0 capability
send_command("vm-nested-test 2")
wait_for("varde_shell: nested VMX L0 state machine validated", 1, 30)

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
        if [ "${SMOKE_PROFILE}" = "phase10" ] && [ "${ui_keys_injected}" -eq 0 ]; then
            if pattern_seen "windowd: registered at endpoint 9" && pattern_seen "inputd: registered at endpoint 8" && pattern_seen "kernel_control: staged MicroVM launched via DIPC"; then
                echo "[+] Injecting Phase 10 Storage, Networking & Lifecycle keystrokes via QEMU monitor..."
                inject_ui_phase10_keys
                ui_keys_injected=1
            fi
        fi
        if [ "${SMOKE_PROFILE}" = "phase11" ] && [ "${ui_keys_injected}" -eq 0 ]; then
            if pattern_seen "windowd: registered at endpoint 9" && pattern_seen "inputd: registered at endpoint 8" && pattern_seen "kernel_control: staged MicroVM launched via DIPC"; then
                echo "[+] Injecting Phase 11 Full-VM Admission, Secure Boot & Warm Reboot keystrokes via QEMU monitor..."
                inject_ui_phase11_keys
                ui_keys_injected=1
            fi
        fi
        if [ "${SMOKE_PROFILE}" = "phase12" ] && [ "${ui_keys_injected}" -eq 0 ]; then
            if pattern_seen "windowd: registered at endpoint 9" && pattern_seen "inputd: registered at endpoint 8" && pattern_seen "kernel_control: staged MicroVM launched via DIPC"; then
                echo "[+] Injecting Phase 12 Coordinated VM Snapshot & Restore keystrokes via QEMU monitor..."
                inject_ui_phase12_keys
                ui_keys_injected=1
            fi
        fi
        if [ "${SMOKE_PROFILE}" = "phase13" ] && [ "${ui_keys_injected}" -eq 0 ]; then
            if pattern_seen "windowd: registered at endpoint 9" && pattern_seen "inputd: registered at endpoint 8" && pattern_seen "kernel_control: staged MicroVM launched via DIPC"; then
                echo "[+] Injecting Phase 13 Nested VMX L0 Keystrokes via QEMU monitor..."
                inject_ui_phase13_keys
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

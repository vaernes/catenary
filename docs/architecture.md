# Catenary OS Architecture

Catenary OS is a hobby project pushing the limits of AI-assisted systems programming, built as a distributed microkernel and Type-1 hypervisor designed to orchestrate isolated MicroVMs across an IPv6 fabric. It follows an **Exokernel** philosophy, minimizing Ring 0 responsibilities while delegating complex system logic to Ring 3 services.

---

## 1. Kernel Architecture (Ring 0)

The kernel is a minimal, preemptive microkernel written in **Zig**. It manages critical hardware abstractions and provides the execution environment for system services and virtual machines.

### 1.1 Core Components
- **Physical Memory Manager (PMM):** A bitmap-based page-frame allocator (4KB pages). It implements **Guarded Regions** with unmapped guard pages to trap memory corruption at the source.
- **Scheduler:** A preemptive round-robin scheduler. It manages `Thread` objects and executes architecture-specific context switches (`switch_context.S`).
- **Paging:** Implements a **Higher-Half Direct Map (HHDM)**. The entire physical memory is mapped into the kernel's virtual address space (starting at `0xFFFF800000000000`) for efficient access.
- **Boot Sequence:**
    1. **Limine:** The bootloader transitions the system to 64-bit Long Mode.
    2. **`entry.S`:** Minimal assembly to initialize the stack and enable **SSE** (required by the Zig compiler) before calling `_kernel_main`.
    3. **Initialization:** GDT, IDT, PMM, and Scheduler are brought up in sequence.
    4. **Service Manager:** Locates ELF modules (e.g., `netd`) and launches them as Ring 3 processes.

### 1.2 Security & Hardening
- **Baseline Protections:** Automatic enforcement of **NXE** (No-Execute), **SMEP** (Supervisor Mode Execution Prevention), and **SMAP** (Supervisor Mode Access Prevention, where supported).
- **Safe Stack:** Guard pages are allocated for both IRQ and user-trap kernel stacks to prevent overflows from corrupting adjacent structures.

---

## 2. DIPC (Distributed Inter-Process Communication)

DIPC is the unified communication fabric of Catenary OS. It provides location-transparent message passing between local threads, system services, and remote MicroVMs.

### 2.1 Addressing Model
- **Node:** A physical machine or MicroVM identified by a unique **IPv6 Address**.
- **Endpoint:** A 64-bit communication port within a node (`EndpointId`).
- **Identity:** A tuple of `{ Node, Endpoint }`. Endpoints `1-255` are [reserved](src/ipc/identity.zig) for system services (`netd`, `storaged`, `dashd`).

### 2.2 Protocol Design
- **Message Format:** 4KB page-based messages including a **DIPC Header** with source/destination addresses.
- **Authenticity:** Every message includes an 8-byte **Auth Tag** (SHA-256 folded), derived from the `KernelManifest` capability seed, to prevent spoofing.
- **Routing:** The [router](src/ipc/router.zig) determines if a message is local (delivered to a scheduler mailbox) or remote (passed to `netd` for transmission).

---

## 3. Service Model (Ring 3)

System functionality is implemented as isolated user-space daemons communicating via `int $0x80` traps.

- **`netd`**: Owns the IPv6 stack, routing tables, and physical/virtual network interfaces.
- **`storaged`**: Manages block devices (e.g., NVMe via Ring 3 PCI access) and file system logic.
- **`dashd`**: System observability and telemetry collector.
- **Service Trampoline**: The [user_mode.zig](src/arch/x86_64/user_mode.zig) bridge handles the transition from kernel-space to the entry point of Ring 3 services.

---

## 4. VMM / Hypervisor (MicroVMs)

Catenary OS acts as a Type-1 hypervisor using Intel **VMX** to run Linux MicroVMs as first-class citizens.

- **EPT (Extended Page Tables):** Provides memory isolation for guest VMs.
- **Virtio Bridge:** [virtio_net.zig](src/vmm/virtio_net.zig) and [virtio_blk.zig](src/vmm/virtio_blk.zig) emulate MMIO devices. Guest I/O triggers VM-exits, which are intercepted and bridged to DIPC endpoints (e.g., guest TX -> `netd`).
- **Resource Tracking:** TSC-based cycle counting and VM-exit telemetry are broadcast to `dashd` for monitoring.

---

## 5. Repository Philosophy

- **Exokernel Design**: The kernel only exports hardware; services define the abstractions.
- **IPv6-First**: All networking, internal and external, is native IPv6.
- **Safety**: Managed memory (PMM) and architectural hardening are non-negotiable.
- **No Legacy**: No BIOS/VGA/PIT dependency where UEFI/Limine/HPET/LAPIC alternatives exist.

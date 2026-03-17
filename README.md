<p align="center">
  <img src="assets/CatenaryOS.png" alt="Catenary OS Logo" width="320"/>
</p>

<h1 align="center">CATENARY OS</h1>

<p align="center">
  <em>A distributed microkernel & bare-metal Type-1 hypervisor, written in Zig.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/language-Zig-F7A41D?style=flat-square" alt="Zig"/>
  <img src="https://img.shields.io/badge/arch-x86__64-36454F?style=flat-square" alt="x86_64"/>
  <img src="https://img.shields.io/badge/bootloader-Limine-CD7F32?style=flat-square" alt="Limine"/>
  <img src="https://img.shields.io/badge/status-Phase%204-B87333?style=flat-square" alt="Phase 4"/>
</p>

---

## What is Catenary OS?

A **catenary** is the precise mathematical curve a cable forms under its own weight — a perfect load-bearing arc that distributes massive tension into pure compression across its span. Just as a catenary turns raw structural forces into elegant, predictable geometry, **Catenary OS** distributes the weight of isolated MicroVMs and containers across an IPv6 network of bare-metal nodes into a seamless, load-bearing orchestration fabric.

Catenary OS discards legacy monolithic designs and in-kernel POSIX compatibility. It natively orchestrates OCI (Docker) containers by running them inside hardware-isolated **MicroVMs**, interconnected via an **IPv6-first** distributed message-passing network — with zero-trust cryptographic identity baked in at the IPC layer.

---

## Architecture

### The Exokernel (Ring 0)

The kernel is stripped to the absolute minimum. It handles only:

- **Physical Memory Allocation** — page frame management via Zig's explicit allocators
- **CPU Scheduling & Context Switching** — assembly-backed task management with TCBs
- **Hardware Virtualization (Intel VT-x)** — initializing and managing hypervisor VMX state
- **Local IPC** — asynchronous message-passing queues between processes

### User Space (Ring 3)

Everything else lives in isolated user-space processes:

- Device drivers (via securely granted DMA/IOPL)
- The network stack
- Catenary routing and orchestration daemons

### Distributed IPC

Processes communicate via a unified message-passing API. The OS routes messages transparently whether the target lives on the local CPU or on another bare-metal node across the network — making cluster orchestration a **native OS capability**.

### IPv6-Native Networking

- Every isolated process, MicroVM, and node receives a unique `/128` IPv6 address
- Zero-trust: cryptographic identity and IPsec are baked into IPC messages at the network layer
- Legacy IPv4 handled by an isolated user-space NAT64/DNS64 gateway

### MicroVM Container Engine

Catenary OS acts as a **Type-1 hypervisor**, booting stripped-down Linux kernels (< 20 MB) inside MicroVMs to achieve full OCI (Docker) compatibility without emulating Linux syscalls in user space.

---

## Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Language | **Zig** (`x86_64-freestanding`) | Explicit allocators, no hidden control flow, `comptime` metaprogramming, seamless C-interop |
| Architecture | **x86_64** | Initial target; Intel VT-x for hardware virtualization |
| Bootloader | **Limine** | Skips legacy 16-bit BIOS; enters 64-bit Long Mode with a prepared memory map and framebuffer |
| Emulation | **QEMU** | `-serial stdio` for raw kernel serial output and hardware fault diagnosis |

---

## Development Roadmap

- [x] **Phase 1: Bare-Metal Foundation** — Bootloading, build system, and basic output.
- [x] **Phase 2: Core Abstractions** — CPU descriptors and physical memory management.
- [x] **Phase 3: Scheduling & IPC** — Task switching and local message passing.
- [ ] **Phase 4: Hypervisor & MicroVMs** (*Current*) — Intel VT-x integration and booting isolated Linux guest kernels.
- [ ] **Phase 5: Networking & Orchestration** — IPv6 networking, distributed IPC, and multi-node cluster orchestration.

---

## Building & Running

**Prerequisites:** Zig toolchain, QEMU with x86_64 support, and the Limine bootloader (included in `limine/`).

```sh
# Build the kernel
zig build

# Run in QEMU (serial output to stdout)
./run_qemu.sh

# Phase 4 smoke test (headless QEMU + serial milestone)
./test_qemu.sh
```

Additional build/run notes and bring-up options are documented in [docs/SETUP.md](docs/SETUP.md).

The smoke test looks for an early Linux guest serial line (by default it waits for `Linux version`).
If your environment cannot expose nested VMX to the Catenary OS guest, the smoke test will fail early.

---

## Design Philosophy

Catenary OS is built under three strict constraints:

1. **No "Vibe Coding" Ring 0** — No inventing memory management or scheduling paradigms that mimic Linux. All decisions derive from the microkernel blueprint.
2. **Interface-First** — Core Zig structs (`ThreadControlBlock`, IPC messages, etc.) are designed before any underlying plumbing is written.
3. **Debug via Serial** — Hardware faults are diagnosed from QEMU register state and serial dumps, never by guessing.

---

## 🧠 About This Project: A Hobby OS Built with AI

Welcome to my hobby project! Catenary OS is an operating system built from scratch from the ground up, heavily utilizing AI assistants like GitHub Copilot. The primary goal is not just to build an OS for fun and learning, but also to stress-test an AI's capacity for logical reasoning, architectural design, and bare-metal coding when dealing with complex, novel constraints.

To prevent the AI from simply regurgitating existing templates, the project enforces a strict set of "hard mode" constraints:

* **The Language Constraint (Zig):** Written entirely in Zig. Because Zig is a relatively new language with an actively evolving syntax, the AI has a much smaller pool of training data to rely on. This forces the synthesis of novel logic rather than copy-pasting C/C++ Stack Overflow answers.
* **No Linux/Unix DNA in the Kernel:** Ring 0 is strictly forbidden from referencing, copying, or emulating Linux kernel internals, Unix architecture, or POSIX standards. The microkernel design must be entirely original. (OCI/Docker compatibility is achieved the honest way: by running real Linux kernels inside hardware-isolated MicroVMs, not by reimplementing Linux semantics in the kernel.)
* **Freestanding Environment:** Built entirely from scratch on bare metal. No libc, no OS-level syscall wrappers, and no existing OS-level safety nets. Zig's standard library is used only for the OS-independent utilities it provides in freestanding mode (formatting, data structures, math) — everything requiring a host OS is off-limits.

This repository serves as both a functional custom hobby operating system and a documented log of how large language models handle novel architectures, low-level hardware interactions, and zero-dependency environments.

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).

See [CONSTITUTION.md](CONSTITUTION.md) for the full architectural blueprint.  
See [CONTRIBUTING.md](CONTRIBUTING.md) to contribute.

# Catenary OS: Architectural Blueprint & Master Plan

## 1. Project Identity & Vision

**Catenary OS** is a hobby project exploring the limits of AI-assisted bare-metal programming, structured as a modern, distributed microkernel and bare-metal Type-1 hypervisor. A catenary is the precise mathematical curve a cable forms under its own weight — a perfect load-bearing arc that distributes massive tension into pure compression. Catenary OS is designed to distribute the weight of isolated MicroVMs and containers across an IPv6 network of bare-metal nodes into a seamless, load-bearing orchestration fabric.

The project discards legacy monolithic designs and in-kernel POSIX compliance. Instead, it natively orchestrates OCI (Docker) containers by running them securely inside hardware-isolated MicroVMs, connected via an IPv6-first distributed message-passing network.

## 2. Core Architectural Pillars

### 2.1 The Exokernel Philosophy (Ring 0)

The kernel space is stripped down to the absolute minimum. It operates in x86_64 Long Mode and handles **only**:

* **Physical Memory Allocation:** Managing page frames using Zig’s explicit allocators.
* **CPU Scheduling & Context Switching:** Assembly-backed task management.
* **Hardware Virtualization (Intel VT-x):** Initializing and managing the hypervisor state.
* **Local Inter-Process Communication (IPC):** Asynchronous message-passing queues.

### 2.2 User Space (Ring 3)

Everything else operates in isolated user-space processes, including:

* Device Drivers (via securely granted DMA/IOPL).
* The Network Stack.
* The Catenary routing and orchestration daemons.

### 2.3 Distributed, Microkernel-Style IPC

Processes communicate via a unified message-passing API. The OS routes messages seamlessly, whether the target process lives on the local CPU or across the network on another bare-metal node. This makes cluster orchestration a native OS capability.

### 2.4 IPv6-Native Networking & Micro-segmentation

* **IPv6 Core:** The internal OS network speaks exclusively IPv6. Every isolated process, MicroVM, and node receives a unique `/128` address.
* **Zero-Trust:** Cryptographic identity and IPsec are baked into the IPC messages at the network layer.
* **Legacy IPv4:** Handled exclusively by an isolated user-space NAT64/DNS64 gateway to communicate with the outside internet.

### 2.5 The MicroVM Container Engine

To achieve 100% OCI (Docker) compatibility without the massive technical debt of emulating Linux syscalls in user space, Catenary OS acts as a Type-1 hypervisor. It boots highly optimized, stripped-down Linux kernels (under 20MB) inside MicroVMs.

## 3. Technology Stack

* **Primary Language:** **Zig** (`x86_64-freestanding`). Chosen for its explicit memory allocation, lack of hidden control flow, powerful `comptime` metaprogramming, and seamless C-interop.
* **Target Architecture:** **x86_64** (Initial).
* **Bootloader:** **Limine**. Bypasses legacy 16-bit BIOS constraints, pushing the CPU directly into 64-bit Long Mode with a prepared memory map and framebuffer.
* **Testing/Emulation:** **QEMU**, using `-serial stdio` to capture raw kernel serial output for debugging.

---

## 4. Development Roadmap

* [x] **Phase 1: Bare-Metal Foundation** — Bootloading, build system, and basic output.
* [x] **Phase 2: Core Abstractions** — CPU descriptors and physical memory management.
* [x] **Phase 3: Scheduling & IPC** — Task switching and local message passing.
* [x] **Phase 4: Hypervisor & MicroVMs** — Intel VT-x integration and booting isolated Linux guest kernels.
* [x] **Phase 5: Networking & Orchestration** (*Current*) — IPv6 networking, distributed IPC, and multi-node cluster orchestration.

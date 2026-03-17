# Ring-3 Storage Architecture

Catenary OS adheres to an exokernel philosophy. The Ring 0 kernel does not include block device drivers (SATA, NVMe, etc.) or a file system. Instead, storage is provided purely by user-space binaries.

## 1. Host-Level Block Service (`storaged`)
- **Responsibility**: A dedicated Ring-3 service (`src/user/storaged.zig`) handles physical block hardware (like NVMe queues via memory-mapped I/O in the future).
- **Communication**: Receives requests exclusively via DIPC messages. 

## 2. MicroVM Virtio-Blk Backend
- **Virtio Queues**: The hypervisor (`vmm/microvm_bridge.zig`) traps guest accesses to the `virtio-blk` PCI/MMIO address space.
- **DIPC Translation**: When a guest OS enqueues a sector read/write on the virtio ring and triggers a VM-Exit, the kernel bridge packages the descriptor boundary into a DIPC page message and sends it via exact-match routing to the `storaged` service.
- **DMA Translation**: `storaged` fulfills the block IO, writing the result directly into the VM's guest-physical memory via shared capability, then sends a DIPC response.
- **Interrupt Injection**: The kernel bridge receives the response and injects a virtual interrupt into the guest VM.

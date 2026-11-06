---
description: Catenary OS project rules and coding guidelines
---

# Catenary OS Project Instructions

This workspace builds a freestanding x86_64 operating system and Type-1 hypervisor in Zig. Treat [CONSTITUTION.md](../../CONSTITUTION.md) as the architectural source of truth. If code, notes, and the constitution disagree, prefer the constitution unless the user explicitly overrides it.

## Mission

- Build Catenary OS as a distributed microkernel and bare-metal Type-1 hypervisor, usable on one node or as a cluster, not as a monolithic Unix-like kernel.
- The target includes Linux MicroVMs and directly hosted full Linux and Windows VMs; virtual switches and VM microsegmentation; cluster-wide management; and local and distributed virtual block storage. These are goals, not claims that all exist today.
- Preserve the exokernel boundary: Ring 0 owns physical isolation and allocation, CPU scheduling/context switching, Intel VT-x/EPT, and local IPC, including the minimal hardware-adjacent mechanisms needed to enforce those boundaries.
- Keep device drivers and complex backends, network stacks and policy, storage, orchestration, UI, and compatibility layers in isolated Ring-3 services. Existing in-kernel device handling is a bring-up baseline, not a license to move additional policy there.
- Prefer direct virtualization for both VM profiles. An isolated support MicroVM and nested KVM are optional; boot, core services, storage recovery, quorum, and direct VMs must not depend on them.

## Independent Platform Development

- Independently author new Catenary hypervisor, VMM, device, network, storage, cluster, and UI implementations for the next phases. Do not copy, adapt, port, wrap, or substitute known platform implementations as Catenary components.
- Public hardware and protocol specifications, academic papers, and established algorithms are legitimate references. Cite the relevant contracts and independently implement them; originality must never be used to justify unsafe or unreviewed consensus or cryptography.
- Existing Catenary code, the Zig toolchain and standard library, Limine, and development/test tools remain part of the baseline. Approved guest operating systems, explicitly approved licensed guest firmware and drivers, and Linux/KVM in an optional support VM are exceptions. Record provenance, licensing, updates, and approval before adding such components. Any other new third-party runtime implementation needs explicit user approval.
- Use established, reviewed cryptographic primitives from the existing Zig standard library where appropriate; do not invent cryptographic algorithms or assert that a composition is globally novel or patentable without independent review.

## Core Principles & AI Guidelines

- Flexible AI Assistance: AI agents are encouraged to assist proactively across both Ring 0 kernel logic and Ring 3 user-space services, leveraging creative problem solving, rapid prototyping, and end-to-end feature implementations.
- Interface-First Development: Define or refine the Zig types, constants, memory layouts, and invariants alongside implementation plumbing for clear system contracts.
- Evidence-Driven Debugging: Diagnose hardware failures using serial logs, QEMU output, register state, and architectural invariants.
- Pragmatic & Iterative Changes: Move in clear, iterative steps when implementing kernel, hypervisor, or user-space features, testing changes against build and smoke outputs.
- Respect the user's requested scope. A documentation-only request must not change source, tests, build configuration, guest assets, or runtime behavior.

## Architecture Constraints

- Target is `x86_64-freestanding` Zig with no host OS assumptions, no libc dependency, and no hidden runtime requirements.
- Respect the higher-half kernel layout, Limine boot flow, linker script, and early-boot CPU state assumptions already encoded in the repo.
- Do not add POSIX-in-kernel abstractions, syscall-emulation layers, or Linux ABI compatibility inside Ring 0.
- OCI workloads are intended to run in Linux MicroVMs, not through Linux syscall emulation in the kernel; do not claim full OCI compatibility without a tested scope.
- Host and cluster control remain IPv6-first. Guest virtual segments must support both IPv4 and IPv6 through Ring-3 networking; do not impose an IPv4 or socket stack on Ring 0.
- Treat guest-provided identities, descriptors, and addresses as untrusted. Enforce scoped capabilities, bounded ownership and DMA, host-assigned vNIC identities, default-deny ingress/egress policy, and authenticated cross-node transport. Do not confuse the existing DIPC bridge with a guest switch or the shared cluster key with per-node identity.
- The initial distributed storage design uses three data nodes, a 2-of-3 metadata quorum, and two full copies on distinct nodes durably flushed before a write is acknowledged. Fencing, recovery, and backups are separate requirements; no-quorum or insufficient copies must fail closed.

## Zig And Low-Level Coding Expectations

- Keep memory ownership explicit. Avoid hidden allocation patterns and document allocator or frame ownership when it is not obvious.
- Prefer simple data structures with clear invariants over generic abstractions in early kernel code.
- Use `packed`, `extern`, inline assembly, and bitfields only when hardware layout requires them. Keep the unsafe surface as small as possible.
- Preserve existing coding style and naming. Do not refactor broadly unless the user asks for it or the change is required to make low-level behavior correct.
- Add comments only where hardware behavior, calling convention, or boot-time assumptions would otherwise be hard to recover from the code.

## Interrupts, Paging, And VMX

- Changes to GDT, IDT, TSS, paging, VMX controls, EPT, and boot state must be treated as high-risk. Verify related assumptions before and after editing.
- Do not enable CPU features speculatively. If a feature depends on control bits, MSRs, CPUID leaves, or sequencing, check them explicitly.
- When touching VMX code, preserve a known-good incremental path. Avoid replacing a working demo path with an incomplete Linux handoff path unless both are intentionally updated.
- Guest state, host state, and control fields must be derived from documented hardware requirements, not from analogy with other kernels or hypervisors.

## Current Project Context

- Consult [PROJECT.md](../../PROJECT.md) for phase status and dependencies, [architecture](../../docs/architecture.md) for the current/target split, and the linked subsystem plans for future contracts.
- The code contains experimental Linux direct-boot, VMX/EPT, virtio bridges, local NVMe, DIPC, and native UI paths. General UEFI-based Windows/Linux VM support, secure guest switching, quorum storage, and a common authenticated cluster UI are not established end to end.
- The storage path now fails requests when NVMe is unavailable and issues NVMe Flush when the controller reports a volatile write cache. Virtio FUA uses a write-then-flush fallback; QEMU does not establish physical power-loss durability or native NVMe FUA, so never infer those properties from smoke markers or immediate readback.
- QEMU with host KVM can test Catenary's existing VMX guest path; it does not demonstrate KVM inside a Catenary-hosted support VM. Nested VMX for that separate path is future work.

## Validation Workflow

- For build-affecting changes, run `zig build`.
- For boot-path or hypervisor changes, prefer the repo smoke path and inspect serial output.
- Use existing scripts and repo conventions before inventing new tooling.
- If a failure occurs, capture the exact symptom, the last serial lines, and the stage of bring-up before proposing a fix.
- Report model tests, live QEMU integration, and physical-host/guest testing separately. A model, expected marker, source symbol, or historical result is not proof of actual VM isolation, persistence, or a passing current run.
- For storage, policy, identity, and cluster changes, validate crash/partition and failure behavior as well as successful paths; see [TEST_INFRA.md](../../TEST_INFRA.md) and the subsystem plans for proposed gates.

## Repository Layout

- `dev/` contains internal development files: task tracking (`task.md`), the active fix tracker (`fixes.md`), and low-level research notes (`research_notes.md`). Put new development-internal files there, not in the repo root.
- `docs/` contains public-facing documentation (`SETUP.md`, `BRANDING.md`, `DIPC_OWNERSHIP.md`).
- `src/` contains all kernel and hypervisor source code.

## Collaboration Guidance For AI Agents

- AI agents are empowered to perform broad multi-file edits, prototype features, refactor code, and implement complete user requests across kernel and Ring 3 boundaries.
- Inspect relevant source files and architecture notes to maintain system coherence, but feel free to suggest improvements or alternative patterns when beneficial.
- Proactively handle error edge cases and plumbing alongside high-level abstractions.
- Update documentation and tests whenever architecture, interfaces, or build steps evolve.
- Communicate reasoning clearly and verify changes with available build and test tooling.

## What Good Contributions Look Like

- A change is small enough to reason about from serial output and source inspection.
- New structs, constants, and control flows map clearly to hardware manuals or the Catenary OS architecture.
- The kernel surface stays minimal, and user-space responsibilities do not leak into Ring 0.
- Verification steps are obvious, reproducible, and tied to the subsystem that changed.

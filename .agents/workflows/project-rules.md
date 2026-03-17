---
description: Catenary OS project rules and coding guidelines
---

# Catenary OS Project Instructions

This workspace builds a freestanding x86_64 operating system and Type-1 hypervisor in Zig. Treat [CONSTITUTION.md](../../CONSTITUTION.md) as the architectural source of truth. If code, notes, and the constitution disagree, prefer the constitution unless the user explicitly overrides it.

## Mission

- Build Catenary OS as a distributed microkernel plus bare-metal hypervisor, not as a monolithic Unix-like kernel.
- Preserve the exokernel boundary: Ring 0 is limited to physical memory allocation, CPU scheduling/context switching, Intel VT-x management, and local IPC.
- Keep device drivers, network stacks, orchestration services, and compatibility layers in user space unless the user explicitly changes the architecture.

## Non-Negotiable Rules

- No vibe coding in Ring 0. Do not invent Linux-like subsystems, scheduler behavior, or memory-management patterns because they feel familiar.
- Follow interface-first development. Define or refine the Zig types, constants, memory layouts, and invariants before writing plumbing.
- Debug hardware failures from evidence. Use serial logs, QEMU output, register state, and architectural invariants. Do not guess at triple faults, VMX failures, or page-fault causes.
- Prefer minimal, reversible changes. Kernel and hypervisor bring-up should move in small steps with one major variable changed at a time.

## Architecture Constraints

- Target is `x86_64-freestanding` Zig with no host OS assumptions, no libc dependency, and no hidden runtime requirements.
- Respect the higher-half kernel layout, Limine boot flow, linker script, and early-boot CPU state assumptions already encoded in the repo.
- Do not add POSIX-in-kernel abstractions, syscall-emulation layers, or Linux ABI compatibility inside Ring 0.
- OCI compatibility is expected to come from Linux guests inside MicroVMs, not from reimplementing Linux semantics in the kernel.
- IPv6-first distributed IPC remains the long-term direction. Avoid introducing IPv4-centric or socket-centric architecture into kernel code.

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

- The core exokernel is stable: PMM, scheduler, paging, GDT/IDT, Ring-3 service launch, and VMX baseline are all working.
- The focus is now on getting the full OS operational: end-to-end Linux MicroVM boot, Ring-3 service integration (netd, storaged, dashd), DIPC routing, and virtio device emulation.
- Full Linux handoff via VMX is the primary active goal. Completing EPT, virtio-net/blk, and the Linux boot protocol is appropriate scope.
- Ring-3 service bring-up (DIPC messaging, service registry, control protocol) should be pursued in parallel with the VMX path.
- KVM with nested VMX is the preferred validation path for VMX work.

## Validation Workflow

- For build-affecting changes, run `zig build`.
- For boot-path or hypervisor changes, prefer the repo smoke path and inspect serial output.
- Use existing scripts and repo conventions before inventing new tooling.
- If a failure occurs, capture the exact symptom, the last serial lines, and the stage of bring-up before proposing a fix.

## Repository Layout

- `dev/` contains internal development files: task tracking (`task.md`), the active fix tracker (`fixes.md`), and low-level research notes (`research_notes.md`). Put new development-internal files there, not in the repo root.
- `docs/` contains public-facing documentation (`SETUP.md`, `BRANDING.md`, `DIPC_OWNERSHIP.md`).
- `src/` contains all kernel and hypervisor source code.

## Collaboration Guidance For AI Agents

- Start by reading the relevant source files and nearby architecture notes before editing.
- State assumptions when hardware behavior or incomplete repo context leaves ambiguity.
- If the requested change conflicts with the constitution, call that out and propose the narrowest architecture-consistent alternative.
- Update documentation when architectural behavior, build steps, or bring-up expectations materially change.
- Do not silently paper over low-level failures with catch-all fallbacks, stub success paths, or logging that hides missing functionality.

## What Good Contributions Look Like

- A change is small enough to reason about from serial output and source inspection.
- New structs, constants, and control flows map clearly to hardware manuals or the Catenary OS architecture.
- The kernel surface stays minimal, and user-space responsibilities do not leak into Ring 0.
- Verification steps are obvious, reproducible, and tied to the subsystem that changed.

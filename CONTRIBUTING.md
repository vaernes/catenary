# Contributing to Catenary OS

Thank you for your interest in contributing to Catenary OS. This is a passion project and hobby OS primarily built to stress-test AI coding agents in a bare-metal environment. These guidelines keep contributions consistent with the project's architecture and bring-up discipline.

## Architecture Constraints

Catenary OS is a freestanding x86_64 microkernel and Type-1 hypervisor. All contributions must respect the boundaries defined in [CONSTITUTION.md](CONSTITUTION.md):

- **Ring 0** is limited to physical memory allocation, CPU scheduling, Intel VT-x management, and local IPC. Device drivers, network stacks, and POSIX abstractions belong in user space.
- **Interface-first**: define or refine Zig types, constants, and memory layout invariants before writing implementation code.
- **Minimal, reversible changes**: kernel and hypervisor work should move in small steps with one major variable changed at a time.
- **No guessing at hardware faults**: diagnose triple faults and VMX failures from serial output and QEMU register state, not by trial and error.

## Development Environment

See [docs/SETUP.md](docs/SETUP.md) for prerequisites and build instructions.

Quick start:

```sh
zig build          # build the kernel
./run_qemu.sh      # run with serial output to stdout
./test_qemu.sh     # headless smoke test
```

## Reporting Bugs

Open a GitHub issue and include:

- A description of the incorrect behaviour
- The last few lines of serial output before the failure
- The QEMU exit code or register dump if a triple fault occurred
- The exact `zig build` flags used

## Pull Requests

- Keep changes small and focused. One pull request, one concern.
- Run `zig build` before submitting.
- For boot-path or VMX changes, include serial output confirming the expected milestone is still reached.
- Document any hardware behaviour, calling convention, or boot-time assumption that is not obvious from the code.
- Do not add features, abstractions, or refactors beyond the stated scope of the change.

## Code Style

- Follow the naming and formatting conventions of the surrounding code.
- Keep the unsafe surface (`packed`, `extern`, inline assembly, bitfields) as small as possible.
- Memory ownership must be explicit. Document allocator or frame ownership where it is not obvious from context.

## Security Vulnerabilities

See [SECURITY.md](SECURITY.md) for the responsible disclosure process.

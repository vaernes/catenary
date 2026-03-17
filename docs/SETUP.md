# Setup & Build Notes

This document complements README.md with extra build/run knobs that are useful during bring-up.

## Prerequisites

- Zig toolchain (this repo targets freestanding x86_64)
- QEMU (`qemu-system-x86_64`)
- KVM access (`/dev/kvm`) is strongly recommended for Phase 4/VMX validation

## Common Commands

```sh
# Build
zig build

# Run with serial output to your terminal
./run_qemu.sh

# Phase 4 smoke test (headless QEMU; checks for an early Linux serial milestone)
./test_qemu.sh
```

## Build Options

To see all build options supported by this repo:

```sh
zig build -Dhelp
```

### `-Dservices_selftest=true`

Enables the Phase 5 **kernel_control** self-test during boot.

```sh
zig build -Dservices_selftest=true
```

**What it does**

- Constructs real page-backed DIPC messages targeting the reserved `kernel_control` endpoint.
- Exercises the control-plane handler ops:
  - `register_netd` (registers the reserved `netd` endpoint to a placeholder thread id)
  - `set_node_addr` (updates the kernel-local node IPv6 identity)
- Prints serial lines starting with `services:` before VMX/Linux guest bring-up.

**Notes about scripts**

- `./run_qemu.sh` and `./test_qemu.sh` both invoke `zig build` internally.
  - If you want the self-test enabled when using those scripts, add `-Dservices_selftest=true` to the `zig build ...` line inside the script.
  - Otherwise, the script will rebuild without the flag and the self-test will be disabled.

**Expected serial output**

You should see something like:

- `services: kernel_control selftest...`
- `services: netd endpoint -> ...`
- `services: local_node=...`
- `services: kernel_control selftest done.`

### `-Dservices_services=true`

Enables a minimal **in-kernel** Phase-5 bring-up service thread.

```sh
zig build -Dservices_services=true
```

**What it does**

- Spawns a kernel thread that owns the reserved `kernel_control` endpoint.
- Consumes page-backed DIPC messages sent to `kernel_control` and applies them via the control handler:
  - `register_netd`
  - `set_node_addr`

**Scope / guardrail**

This is a bring-up aid only. It is intentionally not a network stack and does not implement distributed routing in Ring 0.

### `-Dservices_router=true`

Enables an in-kernel Phase-5 router thread (bring-up only).

```sh
zig build -Dservices_services=true -Dservices_router=true
```

**What it does**

- Spawns a kernel thread bound to the reserved `router` endpoint.
- Accepts page-backed DIPC message handles (physical page addresses) and routes them:
  - If `dst.node` is local: delivers to a local thread endpoint via the endpoint table.
  - Otherwise: hands the page-handle to `netd` if it has been registered.

This keeps the distributed network stack and routing logic in user space; Ring 0 only provides a minimal dispatch boundary.

### `-Dservices_router_demo=true`

Runs a small local-delivery demo at boot (bring-up only).

```sh
zig build -Dservices_services=true -Dservices_router=true -Dservices_router_demo=true
```

**Expected serial output**

- `services: demo sent to router`
- `services: demo recv ok ...`

### `-Dservices_netd_stub=true`

Spawns a bring-up-only **in-kernel netd stub** thread.

```sh
zig build -Dservices_services=true -Dservices_router=true -Dservices_netd_stub=true
```

**What it does**

- Creates a thread that represents the future user-space `netd`.
- When the router hands it a page-backed DIPC message (remote `dst.node`), it logs the destination and frees the page.

This is strictly a boundary/ownership demo — no IPv6 stack exists in Ring 0.

### `-Dservices_netd_demo=true`

Runs a small remote-handoff demo at boot (bring-up only).

```sh
zig build -Dservices_services=true -Dservices_router=true -Dservices_netd_demo=true
```

**Expected serial output**

- `services: netdStub started.`
- `services: netd demo registered`
- `services: netd demo sent to router`
- `services: netdStub tx dst=... ep=... bytes=...`

### `-Dservices_netd_bootstrap_demo=true`

Prints and validates the future Ring-3 `netd` bootstrap descriptor during boot.

```sh
zig build -Dservices_netd_bootstrap_demo=true
```

**What it does**

- Constructs a stable `service_bootstrap.Descriptor` for the `netd` service.
- Carries explicit service runtime intent (`oneshot` vs `persistent`) as part of the ABI contract.
- Exposes the initial ABI surface a future user-space `netd` needs before a runtime control plane exists:
  - local node identity
  - reserved endpoint IDs
  - DIPC wire constants and max payload size
  - MicroVM ingress descriptor constants

**Expected serial output**

- `services: netd bootstrap demo...`
- `services: netd bootstrap node=... netd_ep=... ctrl_ep=... router_ep=... dipc_max=... mvq_magic=...`
- `services: netd bootstrap demo done.`

### `-Dservices_netd_launch_demo=true`

Prints and validates a concrete future Ring-3 `netd` launch descriptor during boot.

```sh
zig build -Dservices_netd_launch_demo=true
```

**What it does**

- Allocates a real bootstrap page containing `service_bootstrap.Descriptor`.
- Constructs a `service_launch.Descriptor` for a future user-space `netd` task.
- Validates the expected Ring-3 selectors derived from the existing GDT user segments.

**Expected serial output**

- `services: netd launch demo...`
- `services: netd launch rip=... rsp=... cs=... ds=... bootstrap=... bytes=...`
- `services: netd launch demo done.`

### `-Dservices_netd_usermode_demo=true`

Attempts a minimal Ring-3 entry/return demo for a future `netd` task.

```sh
zig build -Dservices_netd_usermode_demo=true
```

**What it does**

- Allocates low-memory code, stack, and bootstrap pages for a future user task.
- Uses the shared Phase-5 runtime service registry to reserve or relaunch the `netd` service slot, then threads that kernel-assigned service ID through the launch and bootstrap descriptors.
- Marks those pages user-accessible in the current host page tables.
- Installs temporary `#BP`, `#GP`, `#PF`, and user-callable trap handlers for the bring-up experiment.
- Attempts a CPL3 transfer via `iretq` using the validated `service_launch.Descriptor`.
- Runs a real user-mode payload that validates the `service_bootstrap.Descriptor` passed in `RDI`.
- Uses a minimal user-to-kernel trap ABI to request `register_netd_service`, which Ring 0 translates into a real `kernel_control` operation and records in the service registry.
- Marks the bring-up service slot `exited` or `faulted` after control returns from CPL3 so the slot can be reused on a later relaunch.
- Detaches the reserved `netd` endpoint when that service stops so local routing state does not keep pointing at a dead service handle.

**Expected serial output**

- `services: usermode demo enter rip=... arg0=...`
- `services: usermode demo registered netd via trap`
- `services: usermode demo service exited cleanly`

### `-Dservices_netd_relaunch_demo=true`

Runs two consecutive Ring-3 `netd` bring-up launches in a single boot to verify relaunch safety.

```sh
zig build -Dservices_netd_relaunch_demo=true
```

**What it does**

- Reuses the existing user-mode `netd` bring-up path twice in one boot.
- Verifies the same kernel-assigned `service_id` is reused across both launches.
- Requires the first launch to leave the service slot in `exited` state and the reserved `netd` endpoint detached before the second launch begins.
- Confirms the second launch can re-register and exit cleanly again.

**Expected serial output**

- `services: usermode relaunch first service_id=...`
- `services: usermode relaunch second launch service_id=...`
- `services: usermode relaunch demo passed`

### `-Dservices_netd_persistent_contract_demo=true`

Validates the persistent runtime-mode launch contract for a future long-lived `netd` without changing the current one-shot execution path.

```sh
zig build -Dservices_netd_persistent_contract_demo=true
```

**What it does**

- Allocates and validates a concrete `service_launch.Descriptor` backed by a real bootstrap page.
- Sets `service_bootstrap.Descriptor.runtime_mode` to `persistent` and verifies it survives descriptor validation.
- Verifies persistent-loop control ABI fields in the bootstrap contract (`persistent_trap_vector=0x80`, `persistent_heartbeat_op=1`, `persistent_stop_op=2`).
- Logs the contract mode and service ID as bring-up evidence for the next persistent userspace milestone.

**Expected serial output**

- `services: netd persistent contract demo...`
- `services: netd persistent contract mode=... service_id=... trap=... hb_op=... stop_op=...`
- `services: netd persistent contract demo done.`

### `-Dservices_netd_persistent_usermode_demo=true`

Runs a minimal persistent-mode Ring-3 `netd` lifecycle handshake demo using the trap ABI.

```sh
zig build -Dservices_netd_persistent_usermode_demo=true
```

**What it does**

- Executes three CPL3 launches for the same service slot to match the current trap return path:
  - heartbeat op (`1`)
  - register-netd-service op (`3`)
  - stop op (`2`)
- Uses trap argument payload semantics for stop reason (`arg1`): `0 = clean`, `1 = fault`.
- Uses the persistent launch/boostrap contract (`runtime_mode = persistent`) for each phase.
- Verifies registry and routing invariants after the stop phase:
  - heartbeat observed
  - registration observed
  - stop observed
  - final state `exited`
  - reserved `netd` endpoint detached

**Expected serial output**

- `services: persistent usermode demo enter rip=... arg0=... op=...`
- `services: persistent usermode demo heartbeat/register/stop ok`

### `-Dservices_microvm_demo=true`

Runs a small local-MicroVM handoff demo at boot (bring-up only).

```sh
zig build -Dservices_services=true -Dservices_router=true -Dservices_microvm_demo=true
```

**What it does**

- Registers a dynamic endpoint that maps to a local MicroVM handle rather than a thread.
- Sends a page-backed DIPC message to that endpoint through the router.
- Verifies the router hands ownership to the kernel-facing MicroVM ingress queue.
- Logs through the explicit `microvm_transport.IngressDescriptor` contract rather than reading queue internals directly.

**Expected serial output**

- `services: microvm demo sent to router`
- `services: microvm ingress queued vm=... ep=... bytes=...`

### `-Dservices_vmm_stub=true`

Spawns a bring-up-only **VMM stub** thread that consumes local MicroVM ingress descriptors.

```sh
zig build -Dservices_services=true -Dservices_router=true -Dservices_vmm_stub=true
```

**What it does**

- Drains the kernel-facing MicroVM ingress queue.
- Validates and consumes `microvm_transport.IngressDescriptor` values.
- Takes ownership of freeing the underlying DIPC page.

### `-Dservices_vmm_demo=true`

Runs a small VMM-consumer demo at boot (bring-up only).

```sh
zig build -Dservices_services=true -Dservices_router=true -Dservices_vmm_demo=true
```

**Expected serial output**

- `services: vmm demo sent to router`
- `services: vmmStub started.`
- `services: vmmStub rx vm=... src_ep=... dst_ep=... bytes=...`

## Passing build args to scripts

The scripts in this repo invoke `zig build` internally. If you want to pass flags like `-Dservices_router_demo=true`, you can run them like:

```sh
ZIG_BUILD_ARGS='-Dservices_services=true -Dservices_router=true -Dservices_router_demo=true' ./run_qemu.sh

# Netd handoff demo
ZIG_BUILD_ARGS='-Dservices_services=true -Dservices_router=true -Dservices_netd_demo=true' ./run_qemu.sh

# Netd bootstrap descriptor demo
ZIG_BUILD_ARGS='-Dservices_netd_bootstrap_demo=true' ./run_qemu.sh

# Netd launch descriptor demo
ZIG_BUILD_ARGS='-Dservices_netd_launch_demo=true' ./run_qemu.sh

# Netd Ring-3 entry experiment
ZIG_BUILD_ARGS='-Dservices_netd_usermode_demo=true' ./run_qemu.sh

# Netd Ring-3 relaunch smoke
ZIG_BUILD_ARGS='-Dservices_netd_relaunch_demo=true' ./run_qemu.sh

# Netd persistent runtime contract demo
ZIG_BUILD_ARGS='-Dservices_netd_persistent_contract_demo=true' ./run_qemu.sh

# Netd persistent Ring-3 lifecycle handshake demo
ZIG_BUILD_ARGS='-Dservices_netd_persistent_usermode_demo=true' ./run_qemu.sh

# Netd persistent Ring-3 fault reason demo
ZIG_BUILD_ARGS='-Dservices_netd_persistent_usermode_fault_demo=true' ./run_qemu.sh

# Local MicroVM endpoint demo
ZIG_BUILD_ARGS='-Dservices_services=true -Dservices_router=true -Dservices_microvm_demo=true' ./run_qemu.sh

# VMM consumer demo
ZIG_BUILD_ARGS='-Dservices_services=true -Dservices_router=true -Dservices_vmm_demo=true' ./run_qemu.sh
```

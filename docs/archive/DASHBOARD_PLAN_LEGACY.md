# [ARCHIVED] Catenary OS Web Dashboard Plan

> [!NOTE]
> **Status:** Archived concept.
> Out-of-band web dashboard concepts will build upon the Ring-3 network and telemetry services established in Phase 7/8. Primary interactive host management is handled by the on-metal TUI (`windowd` / `varde`) specified in [Phase 8 Roadmap](../PHASE_8_ROADMAP.md).

## Objective
Provide an out-of-band HTML/web-based dashboard to visualize and control the internal state of Catenary OS. This replaces the basic `varde` terminal for advanced operator workloads.

## Constraints (Exokernel Rule)
The Ring 0 hypervisor will *not* run a TCP/IP stack or HTTP server. 
Instead, the Web Dashboard will be implemented as a dedicated **User-Space Service** (`netd` / `dashboard_service`) that:
1. Receives a Virtio-Net network interface via the MicroVM Bridge.
2. Uses the DIPC (Distributed Inter-Process Communication) protocol to securely message the Kernel/Service Registry.
3. Serves the HTML frontend to external peers.

## Architecture
1. **Frontend**: Lightweight HTML/JS (No-build or minimal Vite) fetching JSON metrics.
2. **Backend**: A Zig user-mode process running inside a MicroVM or Service process.
3. **Transport**:
   - `netd`: Handles IPv4/IPv6 incoming HTTP requests.
   - `dipc_link`: Forwards authenticated requests to the kernel (e.g. `Command.GetVms`, `Command.KillTasks`).

## Implementation Triggers
This dashboard will be built directly on top of the local networking and discovery layers established in **Phase 10** and **Phase 11**, remaining fully decoupled from Ring 0.

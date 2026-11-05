# Catenary OS Copilot Instructions

Follow the shared [project rules](../.agents/workflows/project-rules.md) and the architectural [constitution](../CONSTITUTION.md). The current phase and future milestones are tracked in [PROJECT.md](../PROJECT.md).

- Independently author future Catenary platform components; do not copy, adapt, or substitute existing hypervisor, network, storage, or orchestration implementations. The project rules define the explicit exceptions, including guest software and approved firmware.
- Preserve the Ring-0 exokernel boundary. Put device backends, virtual networking, policy, storage, orchestration, and UI in isolated Ring-3 services; document current boundary violations as such.
- Direct Type-1 virtualization is the primary path. A support MicroVM and nested KVM are optional, not dependencies for normal VM operation or recovery.
- Treat host/cluster control as IPv6-first while allowing IPv4 and IPv6 inside guest networks. Design per-VM default-deny policies and fail closed on missing authority.
- For clustered storage, require a metadata majority and two full, independently durable copies before acknowledging writes. Do not equate synthetic I/O, a no-op flush, or replication with durability or backup.
- Respect the requested scope, including documentation-only work. Distinguish plans, models, actual integration tests, and hardware evidence; never claim an unverified feature or test passed.
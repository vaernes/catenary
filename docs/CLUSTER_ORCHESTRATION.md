# Phase 11: Cluster-Ready Orchestration

This document formalizes the Catenary OS architecture for scaling from a coherent single-node MicroVM host to a fully-meshed, multi-node compute cluster. Alignment with the exokernel boundary dictates that the Ring 0 kernel remains oblivious to high-level orchestration, instead serving cluster states purely via the user-space `netd` and robust DIPC routing.

## 1. Authenticated Node Bootstrap & Inter-Instance Trust Exchange
- **Root of Trust**: Relies on Phase 8's Boot Trust. A node booting into the cluster computes its local boot manifest and verifies it via UEFI Secure Boot / TPM.
- **Node Introduction**: The node generates a cryptographic identity (e.g., an ed25519 keypair) scoped within the `trust` service. 
- **Secret Exchange**: The local `netd` reaches out to a known cluster endpoint (gossiped or statically seeded via Limine). It exchanges public keys and a token verifying its local Boot Manifest.
- **Node Address Assignment**: Once trust is established, a cluster orchestrator replies with an assigned IPv6 Address block, which `netd` installs via `node_config.assignLocalNode()`. 

## 2. Remote Control-Plane Operations via DIPC
- **Transparent Location**: DIPC message passing abstracts physical locations. Messages addressed to off-node endpoints rely on exact-match routing. The kernel forwards unmapped destination packets to the `HandedToNetd` queue.
- **Netd Over-the-Wire**: The `netd` user service reads outbound DIPC packets, encapsulates them in UDP/TCP or a raw Ethernet frames using virtio-net, and transmits them across the physical wire.
- **Remote Dispatch**: The receiving node's `netd` intercepts the incoming network frame, decapsulates the DIPC payload, and injects it into the local kernel router, which flawlessly delivers it to the target service.
- **Control Op Mapping**: Control ops like `create_microvm` and `stop_microvm` automatically become remote control-plane operations if sent to a remote node's `kernel_control` endpoint ID.

## 3. Service Discovery, Remote Process Placement & Failover
- **Global Endpoint Registry**: Since endpoints inside a node are lightweight thread/service placeholders, cluster-wide IDs use larger deterministic hashing (e.g., `<Node-IPv6>:<Service-UUID>`).
- **Placement**: A user-space scheduling service (analogous to Kubelet, but optimized for MicroVMs) negotiates with other nodes' registry agents using DIPC control packets.
- **Failover Constraints**: The Ring 0 kernel does not mask failures. If a remote node goes offline, the local `netd` catches the DIPC timeout, converting it to a local delivery failure on the capability token. User-space service managers observe this fault and restart the workload elsewhere.

## 4. Gradual Integration Limits
- Consistent with the Constitution, multi-node networking and cluster membership mechanisms are STRICTLY confined to Ring 3. Until `netd`'s physical network stack implementation is complete (Phase 10 & 12), the DIPC protocol behaves identically using loopback and pseudo-interfaces.

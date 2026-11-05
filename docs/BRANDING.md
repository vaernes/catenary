# Catenary OS: Visual Identity & Branding Guidelines

## 1. Brand Concept: The Micro-segmented Arch

The visual identity of Catenary OS represents structural integrity and the goal of workload isolation. The arch and mesh symbolize MicroVMs and full VMs on a standalone node or cluster, with planned, default-deny microsegmentation. The visual metaphor is not a claim that the current experimental system provides absolute security.

## 2. The Emblem (The Icon)

The primary icon is an inverted catenary arch—the mathematically perfect curve that supports massive weight by converting all tension into compression.

* **The Structure (The Hypervisor):** The arch itself is not a solid form; it is entirely constructed from interconnected hexagonal cells or nodes. Each hexagon represents a MicroVM, full VM, or workload intended to be isolated by the bare-metal Type-1 hypervisor.
* **The Mesh (The Network):** The hexagonal grid evokes the planned virtual network fabric: IPv6-first host control with microsegmented IPv4 and IPv6 guest traffic.
* **The Core:** The central interlocking nodes subtly form a clean, stylized capital **'C'**, representing "Catenary."

## 3. Color Palette

The colors represent the structural components and the active energy within the distributed system.

* **Sea Gray (`#4A4E69`):** Used for the background or heavy text. It represents the unyielding bare-metal bedrock.
* **Terracotta (`#E2725B`):** The primary color of the arch and hexagonal mesh. It evokes the feel of warm, load-bearing construction (like brick or stone) but optimized for high-performance engineering.
* **Golden Yellow (`#FFC300`):** Used as a subtle accent to highlight active network nodes, representing data energy and live connectivity within the cluster.

## 4. Typography

* **Font Family:** Ubuntu or Open Sans (balanced, modern, slightly organic sans-serif).
* **Style:** Clean, uppercase logotype for stability, contrasting the intricate hexagonal mesh.

## 5. Usage Guidelines

* **The Full Logo:** The hexagonal arch emblem placed to the left of or above the "CATENARY OS" logotype. Used for boot screens, README headers, and official documentation.
* **The Icon:** The standalone circular medallion containing the hexagonal arch symbol (without text). Used for favicons, avatar images, or small UI elements where text would be unreadable.
### Varde: The Catenary OS Shell

**The Metaphor:** In the Norwegian mountains, a *varde* is a carefully constructed stone cairn used to mark the safe, proven trail through vast and unforgiving terrain. 

**The OS Connection:**
If Catenary OS is the landscape of nodes and isolated workloads, the `varde` shell is the operator's guide through it. The microkernel supplies isolation and local IPC, while user-space services own network routing and orchestration. `varde` provides visible markers for navigating the system; its full cluster-management capabilities remain a goal.

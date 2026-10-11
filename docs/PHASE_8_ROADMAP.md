# Phase 8: User Interface, TUI System, and Interactive OS Workflows

This document establishes the roadmap, architectural specification, and verification plan for **Phase 8** of Catenary OS. Phase 8 transitions Catenary OS from a cluster engine with a passive telemetry display into a fully interactive, operator-grade operating system with rich keyboard input, interactive forms, dynamic MicroVM lifecycle control, and an interactive Varde shell.

---

## 1. Executive Summary

In Phase 7, Catenary OS achieved Symmetric Multi-Processing (SMP), bare-metal Virtio-Net physical networking, a user-space TCP/IPv6 stack, distributed cluster orchestration, and remote MicroVM staging. However, direct human operator interaction with the running OS on bare-metal or in QEMU was limited to passive log viewing and static form placeholders.

**Phase 8 Focus:**
1. **Interactive TUI Widget Toolkit (`windowd`)**: Production-ready Text User Interface framework with focus management, editable inputs, scrollable lists, modal dialogs, and dirty-rect damage tracking.
2. **Interactive MicroVM Management**: Live form-based MicroVM configuration, validation, and launching directly from the display, plus selection and control actions (`Start`, `Stop`, `Kill`, `Inspect`).
3. **Interactive Varde Shell (`dashd` & `windowd`)**: Live command prompt (`catenary> `), editable command line with history (`Up`/`Down`), scrollback review (`PageUp`/`PageDown`), and expanded management commands.
4. **Enhanced Input Driver (`inputd`)**: Full PS/2 keyboard decoding with modifier state (Shift, Ctrl, Alt), navigation keys, function keys (`F1`-`F12`), and hotkey routing over DIPC.
5. **Brand & Visual Identity**: Strict implementation of the Catenary OS aesthetic ([docs/BRANDING.md](BRANDING.md)) using Sea Gray, Terracotta, Golden Yellow, and Highlight Cyan.

---

## 2. Architectural Design & Exokernel Boundaries

Following Catenary OS's core exokernel philosophy, the kernel (Ring 0) remains stripped to the bare minimum. **All UI rendering, widget state, input processing, and shell interpretation live strictly in Ring-3 user daemons.**

```
+-----------------------------------------------------------------------------------+
|                                  USER DISPLAY (Ring 3)                            |
|                                                                                   |
|  +--------------------+  +-----------------------------------------------------+  |
|  |     windowd        |  |                      dashd                          |  |
|  | (Display & TUI)    |  |        (Varde Shell & Telemetry Engine)             |  |
|  |                    |  |                                                     |  |
|  | - Widget Toolkit   |  | - Shell Command Parser (`ps`, `vmlist`, `vm-create`)|  |
|  | - Focus Manager    |  | - Command History & Output Formatting               |  |
|  | - VM Form / List   |  | - Cluster Telemetry Aggregation                     |  |
|  +---------^----------+  +--------------------------^--------------------------+  |
|            |                                        |                             |
|            | DIPC (Events & Form Submissions)       | DIPC (Shell Exec / Reply)   |
|            v                                        v                             |
|  +--------------------+                      +---------------------------------+  |
|  |      inputd        |                      |         kernel_control          |  |
|  | (PS/2 Keyboard)    |                      | (MicroVM Lifecycle & EPT State) |  |
|  | - Modifier states  |                      | - stage_microvm                 |  |
|  | - Keycode events   |                      | - launch_microvm                |  |
|  +---------^----------+                      | - kill_microvm                  |  |
|            |                                 +----------------^----------------+  |
+------------|--------------------------------------------------|-------------------+
             | (IRQ 1 / SYS_TRY_RECV)                           | (Syscall IPC)
+------------v--------------------------------------------------v-------------------+
|                                 RING 0 EXOKERNEL                                  |
|                                                                                   |
|  - Framebuffer Primitives: SYS_FB_GET_INFO, SYS_FB_FILL_RECT, SYS_FB_DRAW_COLORED |
|  - Memory Management: SYS_ALLOC_DMA, Guarded PMM, EPT Virtualization              |
|  - DIPC Message Router: Transparent local & cross-node page transfers             |
+-----------------------------------------------------------------------------------+
```

### 2.1 Syscall Contract (Ring 0 $\leftrightarrow$ Ring 3)
The Ring 0 kernel exports only hardware-adjacent graphics primitives:
- `SYS_FB_GET_INFO (20)`: Returns display width, height, pitch, and bpp.
- `SYS_FB_FILL_RECT (18)`: Fills a rectangle with an RGB color (`x, y, w, h, rgb`).
- `SYS_FB_DRAW_COLORED (17)`: Renders ASCII text buffer from DMA memory with foreground color and `(row, col)` coordinate.
- `SYS_ALLOC_DMA (12)`: Allocates contiguous physical frames for text/log rendering buffers.

---

## 3. UI Layout & Visual Identity

### 3.1 Color Palette
Per [docs/BRANDING.md](BRANDING.md):
- **Sea Gray (`#4A4E69` / `0x004A4E69`)**: Main window backgrounds, sidebar backdrop, inert panels.
- **Terracotta (`#E2725B` / `0x00E2725B`)**: Primary arch color, inactive panel header banners, decorative dividers.
- **Golden Yellow (`#FFC300` / `0x00FFC300`)**: Active cluster nodes, focus outlines, warnings, title highlights.
- **Highlight Cyan (`#5BC0EB` / `0x005BC0EB`)**: Focused panel headers, selected list items, text cursor.
- **Status Green (`#00CC44` / `0x0000CC44`)**: Running MicroVMs, healthy cluster peers, success banners.
- **Status Red (`#FF4444` / `0x00FF4444`)**: Stopped/killed VMs, input validation errors, dropped nodes.
- **Text White (`#FFFFFF` / `0x00FFFFFF`)**: Primary text content.
- **Text Dim (`#888888` / `0x00888888`)**: Field placeholders, disabled options, secondary metadata.

### 3.2 Standard Screen Geometry (800x600 resolution, 100x75 text cells)

```
0       10        20        30        40        50        60        70        80        90       100
+--------------------------------------------------------------------------------------------------+ 0
| [C] CATENARY OS | Node: fe80::1 | SMP: 2 Cores | RAM: 128 MB | Status: HEALTHY                   |
+-----------------------------+--------------------------------------------------------------------+ 2
| VM MANAGER (F1)             | NEW MICROVM (F2) [Form]                                            |
| > microvm-0     [RUNNING]   |  VM Name:   [ alpine-node-01        ]                              |
|   container-svc [CREATED]   |  vCPUs:     [ 2 ] (1-4)    Memory: [ 32 MB ]                       |
|   telemetry-worker [STOP]   |  Kernel:    [ Embedded Linux (6.6)  ] [v]                          |
|                             |  Rootfs:    [ In-Memory OCI Demo    ] [v]                          |
| [S]tart  [K]ill  [D]elete   |  Action:    < CREATE & LAUNCH >    < RESET >                       |
|-----------------------------|  Status:    Ready.                                                 |
| CLUSTER TOPOLOGY            +--------------------------------------------------------------------+ 25
| - Node 0: local   (2 VMs)   | VARDE SHELL (F3)                                                   |
| - Node 1: fe80::2 (1 VM)    | catenary> ps                                                       |
|                             | [PID 1] initd      [PID 2] netd       [PID 3] storaged             |
| CPU Load: [||||||....] 48%  | [PID 4] dashd      [PID 5] containerd [PID 9] windowd              |
| Memory:   [||||......] 32%  | catenary> vmlist                                                   |
|                             | ID 0: alpine-node-01 [RUNNING, 2 vCPUs, 32 MB, exits=1420]         |
|                             | catenary> _                                                        |
+-----------------------------+--------------------------------------------------------------------+ 72
| [Tab] Switch Pane | [F1] VM List | [F2] New VM | [F3] Shell | [F5] Redraw | [F10] Reboot | [?] Help| 74
+--------------------------------------------------------------------------------------------------+ 75
```

---

## 4. Technical Workstreams & Milestones

### Workstream 1: Input Subsystem & Keyboard Protocol (`inputd`)
*Goal: Provide full keyboard event dispatching with modifier states and non-printable keys.*

- [ ] **1.1 Extended Input Protocol (`src/user/protocols/inputd_protocol.zig`)**:
  - Add `KeyCode` enum: `None`, `Enter`, `Backspace`, `Tab`, `Escape`, `ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight`, `PageUp`, `PageDown`, `Home`, `End`, `Delete`, `F1`..`F12`.
  - Add bitflags for modifiers: `MOD_SHIFT = 0x01`, `MOD_CTRL = 0x02`, `MOD_ALT = 0x04`.
  - Update `InputEvent` payload to transmit `{ ascii: u8, key_code: KeyCode, modifiers: u8, scancode: u8 }`.
- [ ] **1.2 PS/2 Driver State Machine (`src/user/inputd.zig`)**:
  - Decode multi-byte extended scancodes (`0xE0` prefixes for arrow keys, Home, End, Delete, PgUp, PgDn).
  - Track Left/Right Shift, Ctrl, and Alt press/release (`break` codes `0x80+`).
  - Translate uppercase/symbols under Shift (e.g. `1` $\rightarrow$ `!`, `a` $\rightarrow$ `A`, `-` $\rightarrow$ `_`).
  - Dispatch events directly to `windowd` (ReservedEndpoint 9) over DIPC.

### Workstream 2: TUI Widget Framework (`windowd`)
*Goal: Build a modular, reusable Ring-3 widget library in Zig for UI construction.*

- [ ] **2.1 Component Abstractions (`src/user/tui/`)**:
  - `Panel`: Border drawing, title banner, focus state styling (Terracotta vs Highlight Cyan).
  - `TextInput`: String buffer, cursor position, horizontal scroll, backspace/typing handling, character limit.
  - `NumberSpinner`: Stepping numeric values within bounds `[min, max]` using left/right arrows.
  - `OptionSelect`: Cycle through predefined choices (e.g. Kernel types, rootfs types).
  - `ListView`: Row selection cursor, item hover/active background, vertical scroll for lists with $> N$ items.
  - `Button`: Action trigger with visual active/pressed feedback.
  - `ModalDialog`: Centered popup window with confirmation options (`[ OK ]`, `[ Cancel ]`).
- [ ] **2.2 Focus Navigation Manager**:
  - `Tab` / `Shift+Tab` cycles between top-level panels (Sidebar $\rightarrow$ Form $\rightarrow$ Shell).
  - Within a panel: `Up`/`Down` or `Tab` navigates between interactive fields and buttons.
  - Active focused element has distinct cursor visual (blinking block or Golden Yellow / Highlight Cyan accent).
- [ ] **2.3 Double Buffering & Damage Tracking**:
  - Minimize full-screen framebuffer redraws (`SYS_FB_FILL_RECT`) to prevent display flicker.
  - Implement dirty-rect tracking so only changed text rows or updated panels are repainted.

### Workstream 3: Interactive MicroVM Lifecycle Management
*Goal: Enable operators to configure, create, inspect, and kill MicroVMs through the UI.*

- [ ] **3.1 Live "New MicroVM" Form**:
  - Editable Name field (auto-generates default `vm-<id>`).
  - vCPU selector (stepper: 1, 2, 4 vCPUs).
  - Memory selector (16 MB, 32 MB, 64 MB, 128 MB).
  - Kernel & Rootfs selection (Embedded Linux vs Staged NVMe partition).
  - Form validation: Name must be non-empty and unique; vCPUs $\le$ host physical core count.
  - `< CREATE & LAUNCH >` Button: On trigger, formats and sends `stage_microvm` + `launch_microvm` DIPC command to `kernel_control`.
  - Displays inline status message: "Launching MicroVM...", "Launched (ID: 1)", or error banner.
- [ ] **3.2 Interactive VM Manager Sidebar**:
  - Navigate VM list with `Up` / `Down` arrow keys.
  - Display selected VM details pane or card:
    - ID, Name, vCPU count, Memory footprint, EPT page tables allocated.
    - Real-time exit counter and TSC cycle consumption.
  - Hotkeys:
    - `[S]` / `Enter`: Start / Resume selected VM.
    - `[K]`: Kill / Stop selected VM (sends `kill_microvm` to `kernel_control`).
    - `[D]`: Delete VM configuration.
- [ ] **3.3 MicroVM State Synchronization**:
  - `windowd` queries `kernel_control` for VM list on creation/kill events and throttled timer.
  - Smooth update of running status tags (`[RUNNING]`, `[STOPPED]`, `[ERROR]`).

### Workstream 4: Interactive Varde Shell Experience (`dashd` & `windowd`)
*Goal: Provide a full terminal CLI experience within the TUI workspace.*

- [ ] **4.1 Command Line Editor**:
  - Interactive prompt line: `catenary> ` with blinking cursor.
  - Character typing, Backspace, Delete, and Left/Right arrow cursor positioning.
  - Enter key dispatches command string to `dashd` via DIPC.
  - Command History buffer: `Up`/`Down` arrows recall previous commands (up to 16 commands).
- [ ] **4.2 Scrollback Log Buffer**:
  - Ring buffer of 1000 lines for kernel logs, service outputs, and shell history.
  - `PageUp` / `PageDown` (and `Shift+Up`/`Down`) scrolls the view up into history.
  - Auto-scroll lock: automatically returns to bottom on new output unless manually scrolled up.
- [ ] **4.3 Expanded Shell Command Suite in `dashd`**:
  - `help`: Comprehensive list of commands and keyboard shortcuts.
  - `ps`: Formatted table of Ring-3 services, PIDs, endpoints, and AP core affinity.
  - `vmlist`: Detailed table of all active MicroVMs and runtime telemetry.
  - `vm-create <name> [vcpus] [mem_mb]`: CLI command to stage and launch MicroVM.
  - `vm-kill <id>`: Terminate MicroVM by ID or name.
  - `cluster`: Multi-node cluster topology, peer IPv6 addresses, and aggregate loads.
  - `net-stat`: Virtio-Net network statistics, RX/TX packets, bytes, and NDP neighbors.
  - `storage-stat`: NVMe controller status, block partitions, and mount points.
  - `clear`: Clear the shell screen / scrollback view.

### Workstream 5: System Telemetry, Gauges & Visual Polish
*Goal: High-density system observability integrated seamlessly into the TUI.*

- [ ] **5.1 ASCII/Unicode Utilization Gauges**:
  - Compact horizontal bar meters for host CPU utilization and memory consumption.
  - Format: `CPU [||||||....] 48% | RAM [||||......] 32%`.
- [ ] **5.2 Cluster Node Topology Card**:
  - Sidebar widget displaying local and remote cluster nodes discovered via `clusterd`.
  - Node status markers: `●` (Green = Active, Yellow = Stale, Red = Unreachable).
- [ ] **5.3 Global Shortcut Bar & Help Modal**:
  - Bottom row of screen displays contextual function keys.
  - `[F1]` / `[?]` opens centered Help Modal explaining navigation, shortcuts, and concepts.

---

## 5. Implementation Roadmap & Milestones

| Milestone | Target Deliverable | Dependencies | Status |
|---|---|---|---|
| **M8.1** | Input subsystem upgrade: Extended `InputEvent` protocol with modifiers and special keys in `inputd` | `inputd_protocol.zig`, `inputd.zig` | Planned |
| **M8.2** | TUI widget engine: `TextInput`, `Panel`, `ListView`, and focus manager in `windowd` | M8.1 | Planned |
| **M8.3** | Interactive MicroVM creation form and lifecycle management actions | M8.2, `kernel_control` | Planned |
| **M8.4** | Full-featured interactive Varde shell: command editing, history, and expanded commands | M8.1, `dashd.zig` | Planned |
| **M8.5** | Visual telemetry gauges, cluster node topology, and brand styling polish | M8.2, M8.4 | Planned |
| **M8.6** | Comprehensive automated UI test suite and interactive QEMU verification | M8.1 - M8.5 | Planned |

---

## 6. Verification & Testing Strategy

### 6.1 Automated Smoke Tests (`test_qemu.sh`)
- Automated verification of `inputd` event injection and `windowd` response.
- Automated verification of shell command execution (`ps`, `vmlist`, `cluster`) via DIPC injection.
- Verification that `windowd` creates and launches a MicroVM from control commands without kernel panics.

### 6.2 Interactive Manual Testing Workflow
Run Catenary OS in interactive GTK/SDL display mode:
```sh
# Clean build with interactive UI services
zig build

# Launch interactive QEMU with GTK display and PS/2 keyboard enabled
qemu-system-x86_64 -cdrom catenary.iso -m 512M -smp 2 -enable-kvm -display gtk \
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
  -drive file=test_disk.img,format=raw,if=none,id=nvme0 -device nvme,serial=catenary-nvme,drive=nvme0
```

**Verification Checklist:**
1. [ ] Keyboard typing appears in active input fields without lag.
2. [ ] `Tab` moves focus cleanly through VM Manager, New VM Form, and Varde Shell.
3. [ ] Submitting the New VM form successfully provisions a running MicroVM.
4. [ ] Varde shell accepts typed commands, supports Backspace and history recall, and prints formatted output.
5. [ ] Bottom status bar accurately reflects available hotkeys.

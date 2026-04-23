/// Catenary OS Syscall ABI
///
/// All Ring-3 services invoke the kernel via `int $0x80`.
/// Calling convention (x86_64):
///   rax = op, rbx = arg0, rdx = arg1, r8 = capability_token
///   return value in rax
///
/// Op numbers are stable ABI. Add new ops at the end; never renumber.
/// Each op is individually allow-listed per service kind in service_bootstrap.zig.

// ---------------------------------------------------------------------------
// Service lifecycle
// ---------------------------------------------------------------------------

/// Mark this service as active in the kernel's service registry.
/// arg0/arg1 unused.  Returns 0.
pub const SYS_ACTIVATE: u64 = 1;

/// Register this service with the DIPC endpoint table.
/// arg0/arg1 unused.  Returns 0.
pub const SYS_REGISTER: u64 = 2;

/// Blocking receive: park the calling thread until a DIPC message arrives.
/// Returns the physical page address of the queued message.
pub const SYS_RECV: u64 = 3;

/// Non-blocking receive: return the next queued message without parking.
/// Returns physical page address, or 0 if no message is queued.
pub const SYS_TRY_RECV: u64 = 20;

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

/// Free a physical page, or unmap the DIPC receive window.
/// arg0 = physical address (page-aligned), or DIPC_RECV_VA to unmap the
///        receive window and release the underlying page.
/// Returns 0.
pub const SYS_FREE_PAGE: u64 = 4;

/// Allocate contiguous DMA pages and map them into the service DMA window
/// (base VA 0x7D00_0000_0000).
/// arg0 = num_pages (1..16), arg1 = window_slot_start (0..15).
/// Returns the physical base address of the allocation, or 0 on failure.
pub const SYS_ALLOC_DMA: u64 = 5;

/// Map a physical MMIO range into the service IO window (0x7E00_0000_0000).
/// arg0 = phys_base (page-aligned), arg1 = num_pages (1..256).
/// Returns IO_WINDOW_VA on success, 0 on failure.
/// Mapped with PWT|PCD (uncached) flags.
pub const SYS_MAP_MMIO: u64 = 7;

/// Map a received DIPC physical page into the service receive window at
/// VA 0x7F00_0000_0000.  Evicts any previous mapping first.
/// arg0 = page_phys.  Returns DIPC_RECV_VA or 0 on failure.
pub const SYS_MAP_RECV: u64 = 17;

// ---------------------------------------------------------------------------
// IPC
// ---------------------------------------------------------------------------

/// Send a DIPC page.
/// arg0 = physical address of a DMA page holding a DIPC-format message.
/// The kernel copies, re-signs, and routes the message.
/// Returns 0 on success, 1 on failure.
pub const SYS_SEND_PAGE: u64 = 6;

// ---------------------------------------------------------------------------
// Hardware I/O (restricted; allow-listed per service kind)
// ---------------------------------------------------------------------------

/// PCI configuration space read.
/// arg0 = (bus<<24)|(dev<<16)|(func<<8)|offset
/// arg1 = (size<<32)  where size ∈ {1, 2, 4}
/// Returns the value read (zero-extended to u64), or 0xFFFFFFFF on error.
pub const SYS_PCI_READ_CONFIG: u64 = 13;

/// PCI configuration space write.
/// arg0 = (bus<<24)|(dev<<16)|(func<<8)|offset
/// arg1 = (size<<32)|value  where size ∈ {1, 2, 4}
/// Returns 0.
pub const SYS_PCI_WRITE_CONFIG: u64 = 14;

/// Raw I/O port read.  Restricted to netd and storaged.
/// arg0 = port (u16), arg1 = (size<<32)  where size ∈ {1, 2, 4}
/// Returns the value read (zero-extended).
pub const SYS_PORT_IN: u64 = 22;

/// Raw I/O port write.  Restricted to netd and storaged.
/// arg0 = port (u16), arg1 = (size<<32)|value  where size ∈ {1, 2, 4}
/// Returns 0.
pub const SYS_PORT_OUT: u64 = 23;

/// Read a keyboard scancode.  Restricted to inputd.
/// Returns scancode byte, or 0xFFFFFFFF if no key is currently buffered.
pub const SYS_GET_KEY: u64 = 8;

// ---------------------------------------------------------------------------
// Scheduler
// ---------------------------------------------------------------------------

/// Cooperatively yield to the scheduler.
/// arg0/arg1 unused.  Returns 0.
pub const SYS_YIELD: u64 = 24;

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// Write bytes to the kernel serial port (COM1).
/// arg0 = user-space VA of buffer, arg1 = length (max 4096 bytes).
/// Executes with interrupts disabled, so output is non-interleaved.
/// Returns 0.
pub const SYS_SERIAL_WRITE: u64 = 9;

// ---------------------------------------------------------------------------
// Framebuffer (restricted to windowd / dashd)
// ---------------------------------------------------------------------------

/// Draw null-terminated text at (col, row) with default colors.
/// arg0 = DMA page phys holding text, arg1 = (row<<32)|col.
/// Returns 0.
pub const SYS_FB_DRAW: u64 = 16;

/// Draw null-terminated text at (col, row) with an explicit foreground color.
/// arg0 = DMA page phys holding text.
/// arg1 = ((row<<16|col)<<32) | fg_color (0x00RRGGBB).
/// Returns 0.
pub const SYS_FB_DRAW_COLORED: u64 = 18;

/// Fill a rectangle with a solid color.  Restricted to windowd.
/// arg0 = (x<<48)|(y<<32)|(w<<16)|h  (all fields 16-bit).
/// arg1 = color (0x00RRGGBB).
/// Returns 0.
pub const SYS_FB_FILL_RECT: u64 = 19;

/// Get framebuffer resolution.  Restricted to windowd.
/// Returns (width<<32)|height, or 0 if the framebuffer is unavailable.
pub const SYS_FB_GET_INFO: u64 = 26;

// ---------------------------------------------------------------------------
// Varde shell (restricted to windowd)
// ---------------------------------------------------------------------------

/// Read the varde shell history into a DMA page.
/// arg0 = physical address of destination page.
/// Returns number of bytes copied (capped at PAGE_SIZE).
pub const SYS_GET_VARDE_LOG: u64 = 21;

/// Inject a character into the varde shell input queue.
/// arg0 = char (u8).  Returns 0.
pub const SYS_VARDE_INJECT: u64 = 25;

// ---------------------------------------------------------------------------
// Threading
// ---------------------------------------------------------------------------

/// Spawn an additional Ring-3 thread for the calling service.
/// The new thread shares the caller's address space and capability token.
/// It is NOT eligible to receive inbound DIPC messages (use the primary
/// service thread for SYS_RECV / SYS_TRY_RECV).
/// arg0 = user-space entry RIP (must be below the canonical hole).
/// arg1 = user-space stack top VA (exclusive; must be 16-byte aligned).
/// Returns the kernel thread ID (u32, non-zero) on success, 0xFFFFFFFF on failure.
pub const SYS_SPAWN_THREAD: u64 = 27;

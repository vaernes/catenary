const std = @import("std");
const build_options = @import("build_options");
const gdt = @import("gdt.zig");
const host_paging = @import("paging.zig");
const idt = @import("idt.zig");
const cpu = @import("cpu.zig");
const pmm = @import("../../kernel/pmm.zig");
const scheduler = @import("../../kernel/scheduler.zig");
const service_bootstrap = @import("../../services/service_bootstrap.zig");
const service_registry = @import("../../services/service_registry.zig");

const endpoint_table = @import("../../ipc/endpoint_table.zig");
const task_loader = @import("../../services/task_loader.zig");
const dipc = @import("../../ipc/dipc.zig");
const router = @import("../../ipc/router.zig");

pub extern fn enterUserMode(entry_rip: u64, stack_top: u64, entry_arg0: u64, code_selector: u64, data_selector: u64) void;

pub export var user_mode_saved_kernel_rsp: u64 = 0;

pub export fn getKernelSavedRsp() u64 {
    return user_mode_saved_kernel_rsp;
}

pub export fn setKernelSavedRsp(rsp: u64) void {
    user_mode_saved_kernel_rsp = rsp;
}

pub const UserModeState = struct {
    demo_status: DemoStatus = .none,
    demo_error_code: u64 = 0,
    demo_fault_rip: u64 = 0,
    demo_cr2: u64 = 0,
    demo_syscall_status: u64 = 0,
};

pub var current_user_state: UserModeState = .{};

const DemoStatus = enum(u8) {
    none = 0,
    breakpoint = 1,
    general_protection = 2,
    page_fault = 3,
    syscall = 4,
};

var hhdm_offset: u64 = 0;
// No longer a single shared stack — each service thread gets its own
// kernel interrupt stack allocated in service_trampoline_bridge.

pub fn installHandlers(offset: u64) void {
    hhdm_offset = offset;
    idt.setGate(0x03, breakpointIsr, 0xEE);
    idt.setGate(0x0D, gpIsr, 0x8E);
    idt.setGate(0x0E, pfIsr, 0x8E);
    idt.setGate(0x80, syscallIsr, 0xEE);
}

pub fn ensureKernelEntryStack() !void {
    // No-op: per-service stacks are now allocated inside service_trampoline_bridge.
}

pub fn service_trampoline_bridge() callconv(.c) void {
    // This function is entered via `ret` from switchContext — SysV arg registers
    // (rdi/rsi/rdx) are NOT initialized here.  Look up entry/stack from the
    // service registry using the current thread's sid instead.
    const thread = scheduler.get_current_thread();
    const sid = thread.sid;
    const launch = service_registry.getLaunchDescriptor(sid) orelse {
        serialWrite("service_trampoline: missing launch descriptor sid=0x");
        printHex(sid);
        serialWrite("\n");
        while (true) {
            cpu.cli();
            cpu.hlt();
        }
    };

    // Set TSS.rsp0 to a fresh per-service kernel interrupt stack so that
    // Ring-3 timer/syscall traps for THIS service land on their own stack
    // rather than a shared one.  Also record both addresses in the Thread so
    // schedule() can restore them on every context switch.
    const region = pmm.allocGuardedRegion(16) orelse {
        serialWrite("service_trampoline: interrupt stack allocation failed sid=0x");
        printHex(sid);
        serialWrite("\n");
        while (true) {
            cpu.cli();
            cpu.hlt();
        }
    };
    const stack_top_virt = region.data_phys + @as(u64, region.n_pages) * 4096 + hhdm_offset;

    if (service_registry.getTaskBoundAddressSpace(sid)) |pml4_phys| {
        thread.user_pml4 = pml4_phys;
        cpu.writeCr3(pml4_phys);
    }
    thread.kernel_int_stack_top = stack_top_virt;
    gdt.setKernelRsp0(stack_top_virt);

    enterUserMode(launch.entry_rip, launch.stack_top, launch.bootstrap_page_phys, 0x18, 0x20);
}

fn outb(port: u16, val: u8) void {
    cpu.outb(port, val);
}

fn serialByte(c: u8) void {
    outb(0x3F8, c);
}

fn serialWrite(s: []const u8) void {
    for (s) |c| outb(0x3F8, c);
}

fn printHex(n: u64) void {
    const hex = "0123456789ABCDEF";
    var shift: u6 = 60;
    while (true) {
        const nibble: usize = @intCast((n >> shift) & 0xF);
        outb(0x3F8, hex[nibble]);
        if (shift == 0) break;
        shift -= 4;
    }
}

inline fn clearSmapAccessIfActive() void {
    if ((cpu.readCr4() & (1 << 21)) != 0) cpu.clac();
}

pub export fn userModeBreakpointBridge(status: u64, arg0: u64, rip: u64) void {
    _ = status;
    _ = arg0;
    serialWrite("\n[BP] rip=");
    printHex(rip);
    serialWrite("\n");
    current_user_state.demo_status = .breakpoint;
}

pub export fn userModeGpBridge(error_code: u64, rip: u64, cs: u64, flags: u64, rsp: u64, ss: u64) void {
    clearSmapAccessIfActive();
    const user_fault = (cs & 0x3) != 0;
    serialWrite("\n[GPF]");
    if (user_fault) {
        serialWrite(" sid=0x");
        printHex(scheduler.get_current_thread().sid);
    }
    serialWrite(" err=0x");
    printHex(error_code);
    serialWrite(" rip=0x");
    printHex(rip);
    serialWrite(" cs=0x");
    printHex(cs);
    serialWrite(" ss=0x");
    printHex(ss);
    serialWrite(" flags=0x");
    printHex(flags);
    serialWrite(" rsp=0x");
    printHex(rsp);
    if (user_fault) {
        serialWrite(" cr3=0x");
        printHex(cpu.readCr3());
    }
    serialWrite("\n");

    if ((cs & 0x3) == 0) {
        serialWrite("FATAL: kernel general protection fault\n");
        while (true) {
            cpu.cli();
            cpu.hlt();
        }
    }

    current_user_state.demo_status = .general_protection;
    current_user_state.demo_error_code = error_code;
    current_user_state.demo_fault_rip = rip;

    // Ring-3 fault: park the thread to prevent an infinite fault loop.
    const t_gp = scheduler.get_current_thread();
    t_gp.state = .Waiting;
    scheduler.schedule();
}

pub export fn userModePfBridge(error_code: u64, cr2: u64, rip: u64, cs: u64, flags: u64, rsp: u64, ss: u64) void {
    clearSmapAccessIfActive();
    _ = flags;
    _ = rsp;
    _ = ss;
    current_user_state.demo_status = .page_fault;
    current_user_state.demo_error_code = error_code;
    current_user_state.demo_cr2 = cr2;
    current_user_state.demo_fault_rip = rip;
    const user_fault = (cs & 0x3) != 0;
    serialWrite("\n[PF]");
    if (user_fault) {
        serialWrite(" sid=0x");
        printHex(scheduler.get_current_thread().sid);
    }
    serialWrite(" addr=0x");
    printHex(cr2);
    serialWrite(" err=0x");
    printHex(error_code);
    serialWrite(" rip=0x");
    printHex(rip);
    serialWrite("\n");

    // If Ring-3 fault, park the thread to prevent an infinite fault loop.
    if (user_fault) {
        const t_pf = scheduler.get_current_thread();
        t_pf.state = .Waiting;
        scheduler.schedule();
    }
}

pub export fn userModeSyscallBridge(op: u64, arg0: u64, arg1: u64, rip: u64, token: u64) u64 {
    _ = rip;

    // Emit one byte per syscall to keep the QEMU serial-file backend
    // flushing.  Without continuous UART activity the `-serial file:`
    // backend may buffer indefinitely and services 03-08 appear silent.
    if (build_options.serial_syscall_keepalive) {
        serialByte('.');
    }

    switch (op) {
        0x1000...0x1004 => {
            return 0;
        },
        1 => {
            const sid = service_registry.serviceIdForCapability(token) orelse return 0xFFFFFFFF;
            _ = service_registry.updateServiceState(sid, .active);
            return 0;
        },
        2 => {
            const sid = service_registry.serviceIdForCapability(token) orelse return 0xFFFFFFFF;
            const kind = service_registry.getServiceKind(sid) orelse return 0xFFFFFFFF;
            const table = @import("../../ipc/manager.zig").endpointTable();
            const identity = @import("../../ipc/identity.zig");
            switch (kind) {
                .netd => {
                    table.registerReservedNetdService(sid);
                },
                .storaged => table.registerReservedStoragedService(sid),
                .dashd => table.registerReservedDashdService(sid),
                .containerd => table.registerReservedContainerdService(sid),
                .clusterd => table.registerReservedClusterdService(sid),
                .inputd => table.registerReservedInputdService(sid),
                .windowd => table.registerReservedWindowdService(sid),
                .configd => table.registerReservedConfigdService(sid),
                else => return 0xFFFFFFFF,
            }
            _ = service_registry.updateServiceState(sid, .registered);

            // Broadcast registry state
            const hhdm_offset_local = hhdm_offset;

            const node_config = @import("../../ipc/node_config.zig");
            const control_protocol = @import("../../control/control_protocol.zig");

            const dst_node = dipc.Ipv6Addr{ .bytes = [_]u8{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } };
            const dst_addr = dipc.Address{
                .node = dst_node,
                .endpoint = @intFromEnum(identity.ReservedEndpoint.kernel_control),
            };
            const src_addr = dipc.Address{
                .node = node_config.getLocalNode(),
                .endpoint = @intFromEnum(identity.ReservedEndpoint.kernel_control),
            };

            var payload = control_protocol.ControlHeader{
                .op = .registry_sync,
                .payload_len = @sizeOf(control_protocol.RegistrySyncPayload),
            };
            var sync_payload = control_protocol.RegistrySyncPayload{
                .service_id = sid,
                .service_kind = @intFromEnum(kind),
                .state = @intFromEnum(@import("../../services/service_registry.zig").ServiceState.registered),
            };

            var combined_payload: [16]u8 = undefined;
            @memcpy(combined_payload[0..8], std.mem.asBytes(&payload)[0..8]);
            @memcpy(combined_payload[8..16], std.mem.asBytes(&sync_payload)[0..8]);

            const msg_page = dipc.allocPageMessage(hhdm_offset_local, src_addr, dst_addr, &combined_payload) catch 0;
            if (msg_page != 0) {
                _ = router.routePageWithLocalNode(hhdm_offset_local, table, msg_page) catch {};
            }

            const configd_addr = dipc.Address{
                .node = node_config.getLocalNode(),
                .endpoint = @intFromEnum(identity.ReservedEndpoint.configd),
            };
            const configd_page = dipc.allocPageMessage(hhdm_offset_local, src_addr, configd_addr, &combined_payload) catch 0;
            if (configd_page != 0) {
                _ = router.routePageWithLocalNode(hhdm_offset_local, table, configd_page) catch {};
            }

            const clusterd_addr = dipc.Address{
                .node = node_config.getLocalNode(),
                .endpoint = @intFromEnum(identity.ReservedEndpoint.clusterd),
            };
            const clusterd_page = dipc.allocPageMessage(hhdm_offset_local, src_addr, clusterd_addr, &combined_payload) catch 0;
            if (clusterd_page != 0) {
                _ = router.routePageWithLocalNode(hhdm_offset_local, table, clusterd_page) catch {};
            }

            return 0;
        },
        3 => {
            _ = service_registry.serviceIdForCapability(token) orelse return 0;
            const msg = scheduler.receive();
            if (msg) |m| return m;
            // No message yet. Park the service thread until a sender wakes it
            // through scheduler.send/sendToService rather than sleeping inside
            // the syscall handler on the kernel stack.
            scheduler.get_current_thread().state = .Waiting;
            scheduler.schedule();
            return 0;
        },
        4 => {
            // op=4: free page. If arg0 == DIPC_RECV_VA, unmap the receive window
            // and free the underlying physical page stored in service state.
            const RECV_VA: u64 = 0x0000_7F00_0000_0000;
            const sid4 = service_registry.serviceIdForCapability(token) orelse return 0;
            if (arg0 == RECV_VA) {
                const recv_phys = service_registry.clearRecvPage(sid4);
                if (recv_phys != 0) {
                    const pml4_4 = service_registry.getTaskBoundAddressSpace(sid4) orelse {
                        pmm.freePage(recv_phys);
                        return 0;
                    };
                    const old_cr3_4 = cpu.readCr3();
                    cpu.writeCr3(pml4_4);
                    host_paging.unmap(hhdm_offset, RECV_VA) catch {};
                    cpu.writeCr3(old_cr3_4);
                    pmm.freePage(recv_phys);
                }
            } else {
                pmm.freePage(arg0);
            }
            return 0;
        },
        // op=5: allocate DMA pages (contiguous), map into service DMA window.
        // arg0 = num_pages, arg1 = window_slot_start (0..15).
        // Returns physical base address of the allocation, or 0 on failure.
        5 => {
            const sid5 = service_registry.serviceIdForCapability(token) orelse {
                serialWrite("dma_alloc: invalid capability token\n");
                return 0;
            };
            const pml4_5 = service_registry.getTaskBoundAddressSpace(sid5) orelse {
                serialWrite("dma_alloc: service has no address space\n");
                return 0;
            };
            const num5 = @as(u32, @truncate(arg0));
            const slot5 = @as(u32, @truncate(arg1));
            if (num5 == 0 or num5 > 16 or slot5 + num5 > 16) {
                serialWrite("dma_alloc: invalid page count or DMA window slot\n");
                return 0;
            }
            const phys5 = pmm.allocContiguousAligned(num5, 1) orelse {
                serialWrite("dma_alloc: contiguous physical allocation failed\n");
                return 0;
            };
            // Zero the allocation.
            @memset(@as([*]u8, @ptrFromInt(phys5 + hhdm_offset))[0 .. @as(usize, num5) * pmm.PAGE_SIZE], 0);
            var idx5: u32 = 0;
            while (idx5 < num5) : (idx5 += 1) {
                const dma_va: u64 = 0x0000_7D00_0000_0000 + (@as(u64, slot5 + idx5)) * pmm.PAGE_SIZE;
                task_loader.mapPageInAddressSpace(pml4_5, hhdm_offset, dma_va, phys5 + @as(u64, idx5) * pmm.PAGE_SIZE, task_loader.USER_PAGE_FLAGS) catch {
                    serialWrite("dma_alloc: failed to map DMA window\n");
                    return 0;
                };
            }
            return phys5;
        },
        // op=6: send a DIPC page. arg0 = phys base of a DMA page holding a DIPC message.
        // Kernel copies it to a fresh PMM page, re-signs with kernel auth key, and routes.
        // Returns 0 on success, 1 on failure.
        6 => {
            _ = service_registry.serviceIdForCapability(token) orelse return 1;
            const src_phys = arg0;
            if (src_phys == 0 or (src_phys & 0xFFF) != 0) return 1;
            const src_hdr: *const dipc.PageHeader = @ptrFromInt(src_phys + hhdm_offset);
            if (src_hdr.magic != dipc.WireMagic) return 1;
            const payload_len6 = @as(usize, src_hdr.payload_len);
            if (payload_len6 > dipc.MAX_PAYLOAD) return 1;
            // Allocate a fresh kernel-owned page for routing.
            const dst_phys = pmm.allocPage() orelse return 1;
            const dst_virt = dst_phys + hhdm_offset;
            // Copy header + payload.
            const src_bytes: [*]const u8 = @ptrFromInt(src_phys + hhdm_offset);
            const dst_bytes: [*]u8 = @ptrFromInt(dst_virt);
            @memcpy(dst_bytes[0 .. dipc.HEADER_SIZE + payload_len6], src_bytes[0 .. dipc.HEADER_SIZE + payload_len6]);
            // Re-sign with kernel auth key.
            const dst_hdr: *dipc.PageHeader = @ptrFromInt(dst_virt);
            const payload6: [*]const u8 = @ptrFromInt(dst_virt + dipc.HEADER_SIZE);
            dst_hdr.auth_tag = dipc.computeAuthTag(dst_hdr.src, dst_hdr.dst, payload6[0..payload_len6]);
            const table6 = @import("../../ipc/manager.zig").endpointTable();

            const identity = @import("../../ipc/identity.zig");
            const node_config = @import("../../ipc/node_config.zig");
            if (node_config.isLocalAddress(dst_hdr.dst.node) and
                dst_hdr.dst.endpoint == @intFromEnum(identity.ReservedEndpoint.kernel_control))
            {
                const control_handler = @import("../../control/control_handler.zig");
                control_handler.handleKernelControlPage(hhdm_offset, table6, dst_phys) catch {
                    pmm.freePage(dst_phys);
                    return 1;
                };
                pmm.freePage(dst_phys);
                return 0;
            }

            _ = router.routePageWithLocalNode(hhdm_offset, table6, dst_phys) catch {
                pmm.freePage(dst_phys);
                return 1;
            };
            return 0;
        },
        // op=7: map a physical MMIO range into service IO window (0x7E00_0000_0000).
        // arg0 = phys_base (page-aligned), arg1 = num_pages.
        // Returns IO_WINDOW_VA on success, 0 on failure.
        7 => {
            const sid7 = service_registry.serviceIdForCapability(token) orelse return 0;
            const pml4_7 = service_registry.getTaskBoundAddressSpace(sid7) orelse return 0;
            const phys7 = arg0 & ~@as(u64, 0xFFF);
            const num7 = @as(u32, @truncate(arg1));
            if (num7 == 0 or num7 > 256) return 0;
            const IO_VA: u64 = 0x0000_7E00_0000_0000;
            // PWT|PCD bits for uncached MMIO access (bits 3 and 4 of PTE flags).
            const io_flags: u64 = task_loader.USER_PAGE_FLAGS | (1 << 3) | (1 << 4);
            var idx7: u32 = 0;
            while (idx7 < num7) : (idx7 += 1) {
                task_loader.mapPageInAddressSpace(
                    pml4_7,
                    hhdm_offset,
                    IO_VA + @as(u64, idx7) * pmm.PAGE_SIZE,
                    phys7 + @as(u64, idx7) * pmm.PAGE_SIZE,
                    io_flags,
                ) catch return 0;
            }
            return IO_VA;
        },
        // op=21: read varde shell history into a caller-supplied DMA page.
        // arg0 = phys address of destination page.
        // Returns number of bytes copied (clamped to page size).
        // Restricted to windowd.
        21 => {
            const sid = service_registry.serviceIdForCapability(token) orelse return 0;
            const kind = service_registry.getServiceKind(sid) orelse return 0;
            if (kind != .windowd) return 0;
            const vsh = @import("../../kernel/varde_shell.zig");
            const page = arg0;
            if (page == 0) return 0;
            const len = @min(vsh.history_pos, 4096);
            const dest: [*]u8 = @ptrFromInt(page + hhdm_offset);
            @memcpy(dest[0..len], vsh.history_buf[0..len]);
            return len;
        },
        16 => {
            const sid = service_registry.serviceIdForCapability(token) orelse return 0;
            const kind = service_registry.getServiceKind(sid) orelse return 0;
            // Only windowd and dashd (for legacy fallback) can draw
            if (kind != .windowd and kind != .dashd) return 0;
            const page16 = arg0;
            if (page16 == 0) return 0;
            const row16 = @as(u32, @truncate(arg1 >> 32));
            const col16 = @as(u32, @truncate(arg1 & 0xFFFF_FFFF));
            const text: [*]const u8 = @ptrFromInt(page16 + hhdm_offset);
            const fb = @import("../../kernel/fb.zig");
            var ci: u32 = 0;
            while (ci < 256) : (ci += 1) {
                const c = text[ci];
                if (c == 0) break;
                const px = (col16 + ci) * fb.CharWidth;
                const py = row16 * fb.CharHeight;
                fb.drawChar(px, py, c, fb.ColorGoldenYellow, fb.ColorSeaGray);
            }
            return 0;
        },
        // op=17: map a received DIPC page (phys address from op=3) into the service's
        // receive window at VA 0x7F00_0000_0000 and return that VA.
        // arg0 = page_phys.  Returns DIPC_RECV_VA or 0 on failure.
        17 => {
            const RECV_VA: u64 = 0x0000_7F00_0000_0000;
            const sid17 = service_registry.serviceIdForCapability(token) orelse return 0;
            const pml4_17 = service_registry.getTaskBoundAddressSpace(sid17) orelse return 0;
            const page17 = arg0;
            if (page17 == 0 or (page17 & 0xFFF) != 0) return 0;
            // Evict any existing receive window mapping first.
            {
                const old17 = service_registry.clearRecvPage(sid17);
                if (old17 != 0) {
                    const oc = cpu.readCr3();
                    cpu.writeCr3(pml4_17);
                    host_paging.unmap(hhdm_offset, RECV_VA) catch {};
                    cpu.writeCr3(oc);
                }
            }
            task_loader.mapPageInAddressSpace(pml4_17, hhdm_offset, RECV_VA, page17, task_loader.USER_PAGE_FLAGS) catch return 0;
            service_registry.setRecvPage(sid17, page17);
            return RECV_VA;
        },
        13, 14 => {
            const sid = service_registry.serviceIdForCapability(token) orelse return 0xFFFFFFFF;
            const kind = service_registry.getServiceKind(sid) orelse return 0xFFFFFFFF;
            if (kind != .storaged and kind != .netd) return 0xFFFFFFFF;
            const bus = @as(u8, @truncate(arg0 >> 24));
            const dev = @as(u8, @truncate(arg0 >> 16));
            const func = @as(u8, @truncate(arg0 >> 8));
            const off = @as(u8, @truncate(arg0));
            const size = @as(u8, @truncate(arg1 >> 32));
            const val = @as(u32, @truncate(arg1));
            const addr = 0x80000000 | (@as(u32, bus) << 16) | (@as(u32, dev) << 11) | (@as(u32, func) << 8) | (off & 0xfc);
            cpu.outl(0xcf8, addr);
            const base_port: u16 = 0xcfc;
            if (op == 13) {
                return switch (size) {
                    1 => @as(u64, cpu.inb(base_port + @as(u16, off & 3))),
                    2 => @as(u64, cpu.inw(base_port + @as(u16, off & 2))),
                    4 => @as(u64, cpu.inl(base_port)),
                    else => 0xFFFFFFFF,
                };
            } else {
                switch (size) {
                    1 => cpu.outb(base_port + @as(u16, off & 3), @as(u8, @truncate(val))),
                    2 => cpu.outw(base_port + @as(u16, off & 2), @as(u16, @truncate(val))),
                    4 => cpu.outl(base_port, val),
                    else => {},
                }
                return 0;
            }
        },
        8 => {
            _ = service_registry.serviceIdForCapability(token) orelse return 0xFFFFFFFF;
            const kbd = @import("keyboard.zig");
            if (kbd.getRawScancode()) |scancode| {
                return scancode;
            }
            // No key buffered. Yield cooperatively, but return to user mode so
            // we do not sleep from inside the syscall trap context.
            scheduler.schedule();
            return 0xFFFFFFFF;
        },
        // op=9: SYS_SERIAL_WRITE — atomically write a user-space buffer to
        // the serial port.  INT gate has IF=0, so this cannot be preempted by
        // the timer, preventing interleaved output from concurrent services.
        // arg0 = pointer to buffer (user VA), arg1 = length.
        9 => {
            const ptr = arg0;
            const len = arg1;
            if (ptr < 0x0000_8000_0000_0000 and len <= 4096 and ptr +% len <= 0x0000_8000_0000_0000) {
                // If SMAP is active, temporarily allow supervisor access
                // to user pages. Check CR4.SMAP (bit 21) at runtime since
                // stac/clac #UD on CPUs without SMAP support.
                const smap_active = (cpu.readCr4() & (1 << 21)) != 0;
                if (smap_active) cpu.stac();
                const buf: [*]const u8 = @ptrFromInt(ptr);
                var j: usize = 0;
                while (j < len) : (j += 1) {
                    serialByte(buf[j]);
                }
                if (smap_active) cpu.clac();
            }
            return 0;
        },
        else => {},
    }
    current_user_state.demo_status = .syscall;
    return 0;
}

pub export fn breakpointIsr() callconv(.naked) void {
    asm volatile (
        \\pushq %rax
        \\pushq %rcx
        \\pushq %rdx
        \\pushq %rsi
        \\pushq %rdi
        \\pushq %r8
        \\pushq %r9
        \\pushq %r10
        \\pushq %r11
        \\
        \\movq $0, %rdi
        \\movq $0, %rsi
        \\movq 72(%rsp), %rdx
        \\callq userModeBreakpointBridge
        \\
        \\popq %r11
        \\popq %r10
        \\popq %r9
        \\popq %r8
        \\popq %rdi
        \\popq %rsi
        \\popq %rdx
        \\popq %rcx
        \\popq %rax
        \\iretq
    );
}

pub export fn gpIsr() callconv(.naked) void {
    asm volatile (
        \\pushq %rax
        \\pushq %rcx
        \\pushq %rdx
        \\pushq %rsi
        \\pushq %rdi
        \\pushq %r8
        \\pushq %r9
        \\pushq %r10
        \\pushq %r11
        \\
        \\movq 72(%rsp), %rdi
        \\movq 80(%rsp), %rsi
        \\movq 88(%rsp), %rdx
        \\movq 96(%rsp), %rcx
        \\movq 104(%rsp), %r8
        \\movq 112(%rsp), %r9
        \\callq userModeGpBridge
        \\
        \\popq %r11
        \\popq %r10
        \\popq %r9
        \\popq %r8
        \\popq %rdi
        \\popq %rsi
        \\popq %rdx
        \\popq %rcx
        \\popq %rax
        \\addq $8, %rsp
        \\
        \\movq 8(%rsp), %rax
        \\andq $3, %rax
        \\cmpq $3, %rax
        \\jne 1f
        \\mov $0x23, %ax
        \\mov %ax, %ds
        \\mov %ax, %es
        \\1:
        \\iretq
    );
}

pub export fn pfIsr() callconv(.naked) void {
    asm volatile (
        \\pushq %rax
        \\pushq %rcx
        \\pushq %rdx
        \\pushq %rsi
        \\pushq %rdi
        \\pushq %r8
        \\pushq %r9
        \\pushq %r10
        \\pushq %r11
        \\
        \\movq 72(%rsp), %rdi
        \\movq %cr2, %rsi
        \\movq 80(%rsp), %rdx
        \\movq 88(%rsp), %rcx
        \\movq 96(%rsp), %r8
        \\movq 104(%rsp), %r9
        \\movq 112(%rsp), %r10
        \\callq userModePfBridge
        \\
        \\popq %r11
        \\popq %r10
        \\popq %r9
        \\popq %r8
        \\popq %rdi
        \\popq %rsi
        \\popq %rdx
        \\popq %rcx
        \\popq %rax
        \\addq $8, %rsp
        \\
        \\movq 8(%rsp), %rax
        \\andq $3, %rax
        \\cmpq $3, %rax
        \\jne 1f
        \\mov $0x23, %ax
        \\mov %ax, %ds
        \\mov %ax, %es
        \\1:
        \\iretq
    );
}

pub export fn syscallIsr() callconv(.naked) void {
    asm volatile (
        \\pushq %rax
        \\pushq %rcx
        \\pushq %rdx
        \\pushq %rsi
        \\pushq %rdi
        \\pushq %r8
        \\pushq %r9
        \\pushq %r10
        \\pushq %r11
        \\
        \\movq 64(%rsp), %rdi
        \\movq %rbx, %rsi
        \\movq 48(%rsp), %rdx
        \\movq 72(%rsp), %rcx
        \\movq 24(%rsp), %r8
        \\callq userModeSyscallBridge
        \\
        \\popq %r11
        \\popq %r10
        \\popq %r9
        \\popq %r8
        \\popq %rdi
        \\popq %rsi
        \\popq %rdx
        \\popq %rcx
        \\addq $8, %rsp
        \\
        \\movl $0x23, %ecx
        \\movw %cx, %ds
        \\movw %cx, %es
        \\movw %cx, %fs
        \\movw %cx, %gs
        \\
        \\iretq
    );
}

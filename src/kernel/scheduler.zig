const std = @import("std");
const builtin = @import("builtin");
const pmm = @import("pmm.zig");
const arch = @import("../arch.zig");
const microvm_registry = @import("../vmm/microvm_registry.zig");
const gdt = @import("../arch/x86_64/gdt.zig");

pub const THREAD_TARGET_COUNT = 64;

pub const Thread = struct {
    rsp: u64,
    id: u32,
    sid: u32 = 0,
    state: State,
    mailbox: Mailbox = .{},
    is_vmx: bool = false,
    vmid: u32 = 0,
    vcpu_idx: u32 = 0,
    /// Top of this thread's dedicated kernel interrupt stack (TSS.rsp0).
    /// 0 = kernel thread, no Ring-3 transitions.
    kernel_int_stack_top: u64 = 0,
    /// Physical address of this thread's user PML4.
    /// 0 = kernel thread, leave CR3 unchanged.
    user_pml4: u64 = 0,
    total_tsc: u64 = 0,
    /// Null-terminated ASCII name for debug output (max 15 chars + NUL).
    name: [16]u8 = [_]u8{0} ** 16,
    /// User-space entry RIP for threads spawned via SYS_SPAWN_THREAD.
    /// Read by service_extra_thread_trampoline; 0 for primary service threads.
    user_entry: u64 = 0,
    /// User-space stack top VA for threads spawned via SYS_SPAWN_THREAD.
    user_stack_va: u64 = 0,
    /// When false this thread is not a DIPC receive target.  Extra threads
    /// spawned via SYS_SPAWN_THREAD set this to false so that sendToService
    /// always delivers inbound DIPC pages to the primary (blocking) thread.
    dipc_eligible: bool = true,

    pub const State = enum {
        Empty,
        Ready,
        Running,
        Waiting,
    };

    pub fn setName(self: *Thread, s: []const u8) void {
        @memset(&self.name, 0);
        const copy_len = if (s.len < 15) s.len else 15;
        @memcpy(self.name[0..copy_len], s[0..copy_len]);
    }

    pub fn nameSlice(self: *const Thread) []const u8 {
        var len: usize = 0;
        while (len < self.name.len and self.name[len] != 0) len += 1;
        return self.name[0..len];
    }
};

pub const Message = struct { sender: u32, value: u64 };
pub const Mailbox = struct {
    data: u64 = 0,
    full: bool = false,
};

var threads_pool: [THREAD_TARGET_COUNT]Thread align(16) linksection(".data") = undefined;
pub var threads: []Thread = threads_pool[0..THREAD_TARGET_COUNT];
pub var current_thread_idx: usize = 0;
var next_thread_id: u32 = 1;
var hhdm_offset: u64 = 0;
pub var last_tsc_stamp: u64 = 0;

pub fn init(offset: u64) void {
    hhdm_offset = offset;
    for (0..THREAD_TARGET_COUNT) |i| {
        threads[i] = Thread{
            .rsp = 0,
            .id = 0,
            .state = .Empty,
        };
    }
    threads[0].state = .Running;
    threads[0].id = 0;
    threads[0].setName("kernel/boot");
    current_thread_idx = 0;
    last_tsc_stamp = arch.cpu.rdtsc();
}

fn serviceKindName(kind: @import("../services/service_bootstrap.zig").ServiceKind) []const u8 {
    return switch (kind) {
        .netd => "netd",
        .vmm => "vmm",
        .storaged => "storaged",
        .dashd => "dashd",
        .containerd => "containerd",
        .clusterd => "clusterd",
        .inputd => "inputd",
        .windowd => "windowd",
        .configd => "configd",
    };
}

fn fmtVmxName(vmid: u32) [16]u8 {
    var buf: [16]u8 = [_]u8{0} ** 16;
    buf[0] = 'v';
    buf[1] = 'm';
    buf[2] = 'x';
    buf[3] = '/';
    const hx = "0123456789ABCDEF";
    buf[4] = hx[(vmid >> 12) & 0xF];
    buf[5] = hx[(vmid >> 8) & 0xF];
    buf[6] = hx[(vmid >> 4) & 0xF];
    buf[7] = hx[vmid & 0xF];
    return buf;
}

pub fn spawnThreadForService(sid: u32, kind: @import("../services/service_bootstrap.zig").ServiceKind) !u32 {
    arch.cpu.outb(0x3F8, 's');
    for (0..THREAD_TARGET_COUNT) |i| {
        if (threads[i].state == .Empty) {
            arch.cpu.outb(0x3F8, 'S');
            const stack_p = pmm.allocPage() orelse return error.OutOfMemory;
            const stack_top = stack_p + hhdm_offset + 4096;
            var rsp = stack_top;

            // Corrected Stack Layout for switchContext:
            // When switchContext runs the first time for a new thread, it pops 6 regs and then RETS.
            // 1. [stack_top -  8] : dummy alignment for call
            // 2. [stack_top - 16] : return address (service_trampoline_bridge)
            // 3. [stack_top - 24] : popped into r15
            // 4. [stack_top - 32] : popped into r14
            // 5. [stack_top - 40] : popped into r13
            // 6. [stack_top - 48] : popped into r12
            // 7. [stack_top - 56] : popped into rbp
            // 8. [stack_top - 64] : popped into rbx (bootstrap_addr)

            const user_mode = @import("../arch/x86_64/user_mode.zig");
            const service_registry = @import("../services/service_registry.zig");
            const launch = service_registry.getLaunchDescriptor(sid) orelse unreachable;
            const bootstrap_addr = launch.bootstrap_page_phys;

            const st: [*]u64 = @ptrFromInt(stack_top - 64);
            st[0] = 0xAAAAAAAAAAAAAAAA; // r15 (stays @ top-64)
            st[1] = 0xBBBBBBBBBBBBBBBB; // r14
            st[2] = 0xCCCCCCCCCCCCCCCC; // r13
            st[3] = 0xDDDDDDDDDDDDDDDD; // r12
            st[4] = 0xEEEEEEEEEEEEEEEE; // rbp
            st[5] = bootstrap_addr; // rbx (this is top-24)
            st[6] = @intFromPtr(&user_mode.service_trampoline_bridge);
            st[7] = 0x2222222222222222; // dummy alignment for call @ top-8

            rsp = stack_top - 64;

            const tid = next_thread_id;
            next_thread_id += 1;
            threads[i] = Thread{
                .rsp = rsp,
                .id = tid,
                .sid = sid,
                .state = .Ready,
            };
            threads[i].setName(serviceKindName(kind));

            arch.cpu.outb(0x3F8, '!');
            const hex = "0123456789ABCDEF";
            arch.cpu.outb(0x3F8, hex[(sid >> 4) & 0xF]);
            arch.cpu.outb(0x3F8, hex[sid & 0xF]);
            arch.cpu.outb(0x3F8, '>');
            {
                var shift: u6 = 60;
                while (true) {
                    arch.cpu.outb(0x3F8, hex[@intCast((bootstrap_addr >> shift) & 0xF)]);
                    if (shift == 0) break;
                    shift -= 4;
                }
            }
            arch.cpu.outb(0x3F8, '\n');

            return tid;
        }
    }
    return error.NoEmptySlots;
}
pub fn spawn(entry: *const fn () void, name: []const u8) !u32 {
    for (0..THREAD_TARGET_COUNT) |i| {
        if (threads[i].state == .Empty) {
            const stack_p = pmm.allocPage() orelse return error.OutOfMemory;
            const stack_top = stack_p + hhdm_offset + 4096;
            var rsp = stack_top - 8;
            @as(*u64, @ptrFromInt(rsp)).* = 0;
            rsp -= 8;
            @as(*u64, @ptrFromInt(rsp)).* = @intFromPtr(entry);
            rsp -= 48; // r15-rbx
            for (0..6) |j| @as(*u64, @ptrFromInt(rsp + j * 8)).* = 0;
            const id = next_thread_id;
            next_thread_id += 1;
            threads[i] = Thread{
                .rsp = rsp,
                .id = id,
                .state = .Ready,
            };
            threads[i].setName(name);
            return id;
        }
    }
    return error.NoEmptySlots;
}

pub fn get_current_thread() *Thread {
    return &threads[current_thread_idx];
}

pub fn receive() ?u64 {
    const thread = get_current_thread();
    if (thread.mailbox.full) {
        thread.mailbox.full = false;
        return thread.mailbox.data;
    }
    return null;
}

pub fn send(tid: u32, data: u64) bool {
    for (0..THREAD_TARGET_COUNT) |i| {
        if (threads[i].state != .Empty and threads[i].id == tid) {
            if (threads[i].mailbox.full) return false;
            threads[i].mailbox.data = data;
            threads[i].mailbox.full = true;
            if (threads[i].state == .Waiting) threads[i].state = .Ready;
            return true;
        }
    }
    return false;
}

pub fn sendToService(sid: u32, data: u64) bool {
    // First pass: prefer a Waiting, DIPC-eligible thread so we wake the
    // primary receive loop rather than a background polling thread.
    for (0..THREAD_TARGET_COUNT) |i| {
        if (threads[i].state == .Waiting and
            threads[i].sid == sid and
            threads[i].dipc_eligible and
            !threads[i].mailbox.full)
        {
            threads[i].mailbox.data = data;
            threads[i].mailbox.full = true;
            threads[i].state = .Ready;
            return true;
        }
    }
    // Second pass: fall back to any DIPC-eligible, non-full thread.
    for (0..THREAD_TARGET_COUNT) |i| {
        if (threads[i].state != .Empty and
            threads[i].sid == sid and
            threads[i].dipc_eligible and
            !threads[i].mailbox.full)
        {
            threads[i].mailbox.data = data;
            threads[i].mailbox.full = true;
            if (threads[i].state == .Waiting) threads[i].state = .Ready;
            return true;
        }
    }
    return false;
}

/// Spawn an additional Ring-3 thread for an existing service (SYS_SPAWN_THREAD).
/// The new thread shares the service's address space and capability token but
/// is NOT eligible for inbound DIPC delivery (dipc_eligible = false).
pub fn spawnUserThread(sid: u32, entry_va: u64, stack_va: u64) !u32 {
    const user_mode = @import("../arch/x86_64/user_mode.zig");
    const service_registry = @import("../services/service_registry.zig");

    for (0..THREAD_TARGET_COUNT) |i| {
        if (threads[i].state == .Empty) {
            const stack_p = pmm.allocPage() orelse return error.OutOfMemory;
            const stack_top = stack_p + hhdm_offset + 4096;

            // Stack frame consumed by switchContext on first dispatch:
            //   [rsp+0..40] = callee-saved regs (r15..rbx) — zeroed
            //   [rsp+48]    = return address → service_extra_thread_trampoline
            //   [rsp+56]    = dummy alignment word
            const st: [*]u64 = @ptrFromInt(stack_top - 64);
            st[0] = 0; // r15
            st[1] = 0; // r14
            st[2] = 0; // r13
            st[3] = 0; // r12
            st[4] = 0; // rbp
            st[5] = 0; // rbx (unused for extra threads)
            st[6] = @intFromPtr(&user_mode.service_extra_thread_trampoline);
            st[7] = 0; // dummy alignment

            const tid = next_thread_id;
            next_thread_id += 1;

            threads[i] = Thread{
                .rsp = stack_top - 64,
                .id = tid,
                .sid = sid,
                .state = .Ready,
                .user_entry = entry_va,
                .user_stack_va = stack_va,
                .dipc_eligible = false,
            };

            // Name: "service/N" where N is the count of sibling threads.
            var sibling_count: u32 = 0;
            for (0..THREAD_TARGET_COUNT) |j| {
                if (j != i and threads[j].state != .Empty and threads[j].sid == sid) {
                    sibling_count += 1;
                }
            }
            var name_buf: [16]u8 = [_]u8{0} ** 16;
            if (service_registry.getServiceKind(sid)) |kind| {
                const base = serviceKindName(kind);
                const blen = @min(base.len, 13);
                @memcpy(name_buf[0..blen], base[0..blen]);
                name_buf[blen] = '/';
                name_buf[blen + 1] = '0' + @as(u8, @intCast(@min(sibling_count, 9)));
            }
            threads[i].name = name_buf;

            return tid;
        }
    }
    return error.NoEmptySlots;
}

pub fn spawnWithVmx(entry: ?*const fn () void, is_vmx: bool, vmid: u32, vcpu_idx: u32) !u32 {
    for (0..THREAD_TARGET_COUNT) |i| {
        if (threads[i].state == .Empty) {
            const stack_p = pmm.allocPage() orelse return error.OutOfMemory;
            const stack_top = stack_p + hhdm_offset + 4096;
            var rsp = stack_top;

            if (is_vmx) {
                // VMX thread setup
                // When this thread is scheduled, arch.switchContext will pop 6 registers and RET.
                // We want RET to go to a bridge that calls vmx.resumeInstance(vmid).

                const st: [*]u64 = @ptrFromInt(stack_top - 64);
                st[0] = 0; // r15
                st[1] = 0; // r14
                st[2] = 0; // r13
                st[3] = 0; // r12
                st[4] = 0; // rbp
                st[5] = vmid; // rbx (passed as instance info if needed, or just for alignment)
                st[6] = @intFromPtr(&vmx_thread_bridge);
                st[7] = 0; // alignment

                rsp = stack_top - 64;
            } else {
                rsp = stack_top - 8;
                @as(*u64, @ptrFromInt(rsp)).* = 0;
                rsp -= 8;
                @as(*u64, @ptrFromInt(rsp)).* = @intFromPtr(entry.?);
                rsp -= 48; // r15-rbx
                for (0..6) |j| @as(*u64, @ptrFromInt(rsp + j * 8)).* = 0;
            }

            const id = next_thread_id;
            next_thread_id += 1;
            threads[i] = Thread{
                .rsp = rsp,
                .id = id,
                .state = .Ready,
                .is_vmx = is_vmx,
                .vmid = vmid,
                .vcpu_idx = vcpu_idx,
            };
            if (is_vmx) {
                threads[i].name = fmtVmxName(vmid);
            } else {
                threads[i].setName("kernel/task");
            }
            return id;
        }
    }
    return error.NoEmptySlots;
}

fn vmx_thread_bridge() void {
    const vmx = @import("../arch/x86_64/vmx.zig");
    const thread = get_current_thread();
    if (microvm_registry.findMutable(thread.vmid)) |inst| {
        vmx.resumeInstance(inst) catch {
            arch.cpu.outb(0x3F8, 'V');
            arch.cpu.outb(0x3F8, 'F');
        };
    }
    // If we return, just yield/schedule
    while (true) {
        schedule();
    }
}

extern fn switchContext(old_rsp: *u64, new_rsp: u64) void;

var schedule_lock: bool = false;

pub fn schedule() void {
    if (schedule_lock) return;
    schedule_lock = true;

    const old_idx = current_thread_idx;
    const old_state = threads[old_idx].state;
    var next_idx = (old_idx + 1) % THREAD_TARGET_COUNT;
    while (threads[next_idx].state != .Ready and next_idx != old_idx) {
        next_idx = (next_idx + 1) % THREAD_TARGET_COUNT;
    }
    if (next_idx == old_idx and threads[old_idx].state != .Ready and threads[old_idx].state != .Running) {
        schedule_lock = false;
        return; // No one to run
    }
    if (next_idx == old_idx) {
        schedule_lock = false;
        return;
    }

    const now = arch.cpu.rdtsc();
    threads[old_idx].total_tsc += now -% last_tsc_stamp;
    last_tsc_stamp = now;

    current_thread_idx = next_idx;
    if (old_state == .Running) {
        threads[old_idx].state = .Ready;
    }
    threads[next_idx].state = .Running;

    // Release the reentrancy guard before switchContext because the switch
    // suspends this call frame — the lock would stay held across the entire
    // time this thread is not running, blocking all timer-driven scheduling.
    schedule_lock = false;

    switchContext(&threads[old_idx].rsp, threads[next_idx].rsp);

    // After returning to the new thread's context: restore its page table and
    // kernel interrupt stack so that Ring-3 interrupts land on the right stack.
    const t = &threads[current_thread_idx];
    if (t.user_pml4 != 0) {
        arch.cpu.writeCr3(t.user_pml4);
    }
    if (t.kernel_int_stack_top != 0) {
        gdt.setKernelRsp0(t.kernel_int_stack_top);
    }
}

/// Called from vmexitStub (on the VMX host stack) when the guest session is
/// complete and the VMX thread should yield to other ready threads indefinitely.
pub export fn catenary_vmx_guest_done() callconv(.c) noreturn {
    while (true) {
        schedule();
    }
}

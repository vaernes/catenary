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
    /// Top of this thread's dedicated kernel interrupt stack (TSS.rsp0).
    /// 0 = kernel thread, no Ring-3 transitions.
    kernel_int_stack_top: u64 = 0,
    /// Physical address of this thread's user PML4.
    /// 0 = kernel thread, leave CR3 unchanged.
    user_pml4: u64 = 0,

    pub const State = enum {
        Empty,
        Ready,
        Running,
        Waiting,
    };
};

pub const Message = struct { sender: u32, value: u64 };
pub const Mailbox = struct {
    data: u64 = 0,
    full: bool = false,
};

var threads_pool: [THREAD_TARGET_COUNT]Thread align(16) linksection(".data") = undefined;
var threads: []Thread = threads_pool[0..THREAD_TARGET_COUNT];
var current_thread_idx: usize = 0;
var next_thread_id: u32 = 1;
var hhdm_offset: u64 = 0;

pub fn init(offset: u64) void {
    hhdm_offset = offset;
    for (0..THREAD_TARGET_COUNT) |i| {
        threads[i].state = .Empty;
        threads[i].id = 0;
        threads[i].sid = 0;
    }
    threads[0].state = .Running;
    threads[0].id = 0;
    current_thread_idx = 0;
}

pub fn spawnThreadForService(sid: u32, kind: @import("../services/service_bootstrap.zig").ServiceKind) !u32 {
    _ = kind;
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
            threads[i].rsp = rsp;
            threads[i].id = tid;
            threads[i].sid = sid;
            threads[i].state = .Ready;

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
pub fn spawn(entry: *const fn () void) !u32 {
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
            threads[i].rsp = rsp;
            threads[i].id = id;
            threads[i].state = .Ready;
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
    for (0..THREAD_TARGET_COUNT) |i| {
        if (threads[i].state != .Empty and threads[i].sid == sid) {
            if (threads[i].mailbox.full) continue; // Try next thread if this one is full
            threads[i].mailbox.data = data;
            threads[i].mailbox.full = true;
            if (threads[i].state == .Waiting) threads[i].state = .Ready;
            return true;
        }
    }
    return false;
}

pub fn spawnWithVmx(entry: ?*const fn () void, is_vmx: bool, vmid: u32) !u32 {
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
            threads[i].rsp = rsp;
            threads[i].id = id;
            threads[i].is_vmx = is_vmx;
            threads[i].vmid = vmid;
            threads[i].state = .Ready;
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

pub fn schedule() void {
    const old_idx = current_thread_idx;
    var next_idx = (old_idx + 1) % THREAD_TARGET_COUNT;
    while (threads[next_idx].state != .Ready and next_idx != old_idx) {
        next_idx = (next_idx + 1) % THREAD_TARGET_COUNT;
    }
    if (next_idx == old_idx and threads[old_idx].state != .Ready and threads[old_idx].state != .Running) {
        return; // No one to run
    }
    if (next_idx == old_idx) return;

    current_thread_idx = next_idx;
    threads[old_idx].state = .Ready;
    threads[next_idx].state = .Running;

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

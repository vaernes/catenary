const std = @import("std");
const builtin = @import("builtin");
const pmm = @import("pmm.zig");
const arch = @import("../arch.zig");
const microvm_registry = @import("../vmm/microvm_registry.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const smp = arch.smp;

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
    /// Function pointer for kernel worker threads spawned via spawn().
    entry_fn: ?*const fn () void = null,

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

pub const MAILBOX_CAPACITY: usize = 16;

pub const Mailbox = struct {
    slots: [MAILBOX_CAPACITY]u64 = [_]u64{0} ** MAILBOX_CAPACITY,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub fn push(self: *Mailbox, data: u64) bool {
        if (self.count >= MAILBOX_CAPACITY) return false;
        self.slots[self.tail] = data;
        self.tail = (self.tail + 1) % MAILBOX_CAPACITY;
        self.count += 1;
        return true;
    }

    pub fn pop(self: *Mailbox) ?u64 {
        if (self.count == 0) return null;
        const data = self.slots[self.head];
        self.head = (self.head + 1) % MAILBOX_CAPACITY;
        self.count -= 1;
        return data;
    }

    pub fn isFull(self: *const Mailbox) bool {
        return self.count >= MAILBOX_CAPACITY;
    }
};

var threads_pool: [THREAD_TARGET_COUNT]Thread align(16) linksection(".data") = undefined;
pub var threads: []Thread = threads_pool[0..THREAD_TARGET_COUNT];
pub var current_thread_per_cpu: [smp.MAX_CPUS]usize = [_]usize{0} ** smp.MAX_CPUS;
pub var current_thread_idx: usize = 0;
var next_thread_id: u32 = 1;
var hhdm_offset: u64 = 0;
pub var last_tsc_stamp: u64 = 0;
pub var scheduler_active: bool = false;

var schedule_spinlock: bool = false;
var lock_depth: [smp.MAX_CPUS]u32 = [_]u32{0} ** smp.MAX_CPUS;
var saved_flags: [smp.MAX_CPUS]u64 = [_]u64{0} ** smp.MAX_CPUS;
var thread_active: [THREAD_TARGET_COUNT]bool = [_]bool{false} ** THREAD_TARGET_COUNT;
var prev_switched_thread: [smp.MAX_CPUS]?usize = [_]?usize{null} ** smp.MAX_CPUS;
var ap_task_logged: [smp.MAX_CPUS][THREAD_TARGET_COUNT]bool = [_][THREAD_TARGET_COUNT]bool{[_]bool{false} ** THREAD_TARGET_COUNT} ** smp.MAX_CPUS;

fn acquireScheduleLock() void {
    var flags: u64 = 0;
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile (
            \\pushfq
            \\popq %[flags]
            \\cli
            : [flags] "=r" (flags),
        );
    }
    const cpu_id = smp.getCurrentCpuId();
    if (lock_depth[cpu_id] == 0) {
        saved_flags[cpu_id] = flags;
    }
    lock_depth[cpu_id] += 1;

    while (@atomicRmw(bool, &schedule_spinlock, .Xchg, true, .seq_cst)) {
        asm volatile ("pause");
    }
}

fn releaseScheduleLock() void {
    const cpu_id = smp.getCurrentCpuId();
    @atomicStore(bool, &schedule_spinlock, false, .seq_cst);
    lock_depth[cpu_id] -= 1;
    if (lock_depth[cpu_id] == 0) {
        const flags = saved_flags[cpu_id];
        if (comptime builtin.cpu.arch == .x86_64) {
            asm volatile (
                \\pushq %[flags]
                \\popfq
                :
                : [flags] "r" (flags),
            );
        }
    }
}

pub fn start() void {
    @atomicStore(bool, &scheduler_active, true, .seq_cst);
}

pub fn onThreadFirstDispatch() void {
    const cpu_id = smp.getCurrentCpuId();
    if (prev_switched_thread[cpu_id]) |prev| {
        thread_active[prev] = false;
        prev_switched_thread[cpu_id] = null;
    }
    @atomicStore(bool, &schedule_spinlock, false, .seq_cst);
    lock_depth[cpu_id] = 0;
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("cli");
    }
}

pub fn init(offset: u64) void {
    hhdm_offset = offset;
    for (0..THREAD_TARGET_COUNT) |i| {
        threads[i] = Thread{
            .rsp = 0,
            .id = 0,
            .state = .Empty,
        };
        thread_active[i] = false;
    }
    threads[0].state = .Running;
    threads[0].id = 0;
    threads[0].setName("kernel/boot");
    current_thread_per_cpu[0] = 0;
    current_thread_idx = 0;
    thread_active[0] = true;
    last_tsc_stamp = arch.cpu.rdtsc();

    // Dedicated idle thread slots for AP cores
    for (1..smp.MAX_CPUS) |c| {
        const idle_idx = THREAD_TARGET_COUNT - c;
        threads[idle_idx] = Thread{
            .rsp = 0,
            .id = 1000 + @as(u32, @intCast(c)),
            .state = .Waiting,
        };
        const name_buf = [_]u8{ 'i', 'd', 'l', 'e', '/', 'c', 'p', 'u', '0' + @as(u8, @intCast(c)), 0, 0, 0, 0, 0, 0, 0 };
        threads[idle_idx].name = name_buf;
        current_thread_per_cpu[c] = idle_idx;
        thread_active[idle_idx] = true;
    }
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
    acquireScheduleLock();
    defer releaseScheduleLock();
    arch.cpu.outb(0x3F8, 's');
    const max_slots = THREAD_TARGET_COUNT - smp.MAX_CPUS;
    for (0..max_slots) |i| {
        if (threads[i].state == .Empty) {
            arch.cpu.outb(0x3F8, 'S');
            const stack_p = pmm.allocPage() orelse return error.OutOfMemory;
            const stack_top = stack_p + hhdm_offset + 4096;

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
            const pml4 = service_registry.getTaskBoundAddressSpace(sid) orelse 0;

            const tid = next_thread_id;
            next_thread_id += 1;
            threads[i] = Thread{
                .rsp = stack_top - 64,
                .id = tid,
                .sid = sid,
                .state = .Ready,
                .user_pml4 = pml4,
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
fn kernel_thread_bridge() void {
    onThreadFirstDispatch();
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("sti");
    }
    const thread = get_current_thread();
    if (thread.entry_fn) |f| {
        f();
    }
    get_current_thread().state = .Waiting;
    while (true) {
        schedule();
        asm volatile ("pause");
    }
}

pub fn spawn(entry: *const fn () void, name: []const u8) !u32 {
    acquireScheduleLock();
    defer releaseScheduleLock();
    const max_slots = THREAD_TARGET_COUNT - smp.MAX_CPUS;
    for (0..max_slots) |i| {
        if (threads[i].state == .Empty) {
            const stack_p = pmm.allocPage() orelse return error.OutOfMemory;
            const stack_top = stack_p + hhdm_offset + 4096;
            const st: [*]u64 = @ptrFromInt(stack_top - 64);
            st[0] = 0; // r15
            st[1] = 0; // r14
            st[2] = 0; // r13
            st[3] = 0; // r12
            st[4] = 0; // rbp
            st[5] = 0; // rbx
            st[6] = @intFromPtr(&kernel_thread_bridge);
            st[7] = 0; // dummy alignment word

            const id = next_thread_id;
            next_thread_id += 1;
            threads[i] = Thread{
                .rsp = stack_top - 64,
                .id = id,
                .state = .Ready,
                .entry_fn = entry,
            };
            threads[i].setName(name);
            return id;
        }
    }
    return error.NoEmptySlots;
}

pub fn get_current_thread() *Thread {
    const cpu_id = smp.getCurrentCpuId();
    return &threads[current_thread_per_cpu[cpu_id]];
}

pub fn receive() ?u64 {
    acquireScheduleLock();
    defer releaseScheduleLock();
    const thread = get_current_thread();
    return thread.mailbox.pop();
}

pub fn send(tid: u32, data: u64) bool {
    acquireScheduleLock();
    defer releaseScheduleLock();
    for (0..THREAD_TARGET_COUNT) |i| {
        if (threads[i].state != .Empty and threads[i].id == tid) {
            if (threads[i].mailbox.isFull()) return false;
            if (threads[i].mailbox.push(data)) {
                if (threads[i].state == .Waiting) threads[i].state = .Ready;
                return true;
            }
        }
    }
    return false;
}

pub fn sendToService(sid: u32, data: u64) bool {
    acquireScheduleLock();
    defer releaseScheduleLock();
    // First pass: prefer a Waiting, DIPC-eligible thread so we wake the
    // primary receive loop rather than a background polling thread.
    for (0..THREAD_TARGET_COUNT) |i| {
        if (threads[i].state == .Waiting and
            threads[i].sid == sid and
            threads[i].dipc_eligible and
            !threads[i].mailbox.isFull())
        {
            if (threads[i].mailbox.push(data)) {
                threads[i].state = .Ready;
                return true;
            }
        }
    }
    // Second pass: fall back to any DIPC-eligible, non-full thread.
    for (0..THREAD_TARGET_COUNT) |i| {
        if (threads[i].state != .Empty and
            threads[i].sid == sid and
            threads[i].dipc_eligible and
            !threads[i].mailbox.isFull())
        {
            if (threads[i].mailbox.push(data)) {
                if (threads[i].state == .Waiting) threads[i].state = .Ready;
                return true;
            }
        }
    }
    return false;
}

/// Spawn an additional Ring-3 thread for an existing service (SYS_SPAWN_THREAD).
/// The new thread shares the service's address space and capability token but
/// is NOT eligible for inbound DIPC delivery (dipc_eligible = false).
pub fn spawnUserThread(sid: u32, entry_va: u64, stack_va: u64) !u32 {
    acquireScheduleLock();
    defer releaseScheduleLock();
    const user_mode = @import("../arch/x86_64/user_mode.zig");
    const service_registry = @import("../services/service_registry.zig");

    const max_slots = THREAD_TARGET_COUNT - smp.MAX_CPUS;
    for (0..max_slots) |i| {
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

            const pml4 = service_registry.getTaskBoundAddressSpace(sid) orelse 0;

            const tid = next_thread_id;
            next_thread_id += 1;

            threads[i] = Thread{
                .rsp = stack_top - 64,
                .id = tid,
                .sid = sid,
                .state = .Ready,
                .user_entry = entry_va,
                .user_stack_va = stack_va,
                .user_pml4 = pml4,
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
    acquireScheduleLock();
    defer releaseScheduleLock();
    const max_slots = THREAD_TARGET_COUNT - smp.MAX_CPUS;
    for (0..max_slots) |i| {
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
                const st: [*]u64 = @ptrFromInt(stack_top - 64);
                st[0] = 0; // r15
                st[1] = 0; // r14
                st[2] = 0; // r13
                st[3] = 0; // r12
                st[4] = 0; // rbp
                st[5] = 0; // rbx
                st[6] = @intFromPtr(&kernel_thread_bridge);
                st[7] = 0; // alignment

                rsp = stack_top - 64;
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
                .entry_fn = entry,
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
    onThreadFirstDispatch();
    const vmx = @import("../arch/x86_64/vmx.zig");
    const thread = get_current_thread();
    if (microvm_registry.findMutable(thread.vmid)) |inst| {
        vmx.resumeInstance(inst) catch {
            arch.cpu.outb(0x3F8, 'V');
            arch.cpu.outb(0x3F8, 'F');
        };
    }
    // If we return, mark thread as Waiting, re-enable interrupts, and yield
    get_current_thread().state = .Waiting;
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("sti");
    }
    while (true) {
        schedule();
        asm volatile ("pause");
    }
}

extern fn switchContext(old_rsp: *u64, new_rsp: u64) void;

fn logApTaskExecution(cpu_id: usize, task_idx: usize) void {
    smp.serialAcquire();
    defer smp.serialRelease();
    const t = &threads[task_idx];
    const prefix = "smp: AP core ";
    for (prefix) |c| arch.cpu.outb(0x3F8, c);
    arch.cpu.outb(0x3F8, '0' + @as(u8, @intCast(cpu_id)));
    const mid = " running Ring-3 task: ";
    for (mid) |c| arch.cpu.outb(0x3F8, c);
    for (t.nameSlice()) |c| {
        arch.cpu.outb(0x3F8, c);
    }
    arch.cpu.outb(0x3F8, '\n');
}

pub fn apScheduleLoop(cpu_id: usize) noreturn {
    while (!@atomicLoad(bool, &scheduler_active, .seq_cst)) {
        asm volatile ("pause");
    }

    const idle_idx = THREAD_TARGET_COUNT - cpu_id;
    threads[idle_idx].state = .Running;
    current_thread_per_cpu[cpu_id] = idle_idx;
    thread_active[idle_idx] = true;

    while (true) {
        schedule();
        asm volatile ("pause");
    }
}

pub fn schedule() void {
    if (!@atomicLoad(bool, &scheduler_active, .seq_cst)) return;

    const cpu_id = smp.getCurrentCpuId();
    acquireScheduleLock();

    // Release any previous thread that this CPU finished switching away from
    if (prev_switched_thread[cpu_id]) |prev| {
        thread_active[prev] = false;
        prev_switched_thread[cpu_id] = null;
    }

    const old_idx = current_thread_per_cpu[cpu_id];
    const old_state = threads[old_idx].state;

    // Normal runnable threads are in range [1 .. THREAD_TARGET_COUNT - smp.MAX_CPUS - 1]
    const max_runnable = THREAD_TARGET_COUNT - smp.MAX_CPUS;
    var next_idx: ?usize = null;
    var i: usize = 0;
    while (i < max_runnable) : (i += 1) {
        const candidate = (old_idx + 1 + i) % max_runnable;
        if (candidate == 0) continue; // Skip thread 0 (BSP boot/idle thread)
        if (cpu_id != 0 and threads[candidate].sid == 0 and !threads[candidate].is_vmx) continue;
        if (threads[candidate].state == .Ready and !thread_active[candidate]) {
            next_idx = candidate;
            break;
        }
    }

    // If no runnable user thread is found:
    if (next_idx == null) {
        // If current thread is a valid runnable user thread and still Running, keep running it
        if (old_idx < max_runnable and old_state == .Running) {
            releaseScheduleLock();
            return;
        }
        // Otherwise, switch to this CPU's dedicated idle thread
        const my_idle_idx = if (cpu_id == 0) 0 else (THREAD_TARGET_COUNT - cpu_id);
        if (old_idx == my_idle_idx) {
            releaseScheduleLock();
            return;
        }
        next_idx = my_idle_idx;
    }

    const chosen_idx = next_idx.?;
    if (chosen_idx == old_idx) {
        releaseScheduleLock();
        return;
    }

    // Accounting
    const now = arch.cpu.rdtsc();
    threads[old_idx].total_tsc += now -% last_tsc_stamp;
    last_tsc_stamp = now;

    // Update states
    const my_idle_idx = if (cpu_id == 0) 0 else (THREAD_TARGET_COUNT - cpu_id);
    if (old_state == .Running) {
        if (old_idx != my_idle_idx) {
            threads[old_idx].state = .Ready;
        } else {
            threads[old_idx].state = .Waiting;
        }
    }

    threads[chosen_idx].state = .Running;
    thread_active[chosen_idx] = true;
    current_thread_per_cpu[cpu_id] = chosen_idx;
    if (cpu_id == 0) {
        current_thread_idx = chosen_idx;
    }
    prev_switched_thread[cpu_id] = old_idx;

    // Emit explicit evidence when an AP runs a Ring-3 task
    if (cpu_id != 0 and threads[chosen_idx].sid != 0 and !ap_task_logged[cpu_id][chosen_idx]) {
        ap_task_logged[cpu_id][chosen_idx] = true;
        logApTaskExecution(cpu_id, chosen_idx);
    }

    switchContext(&threads[old_idx].rsp, threads[chosen_idx].rsp);

    // After returning from switchContext (we may now be running on a different CPU):
    const current_cpu = smp.getCurrentCpuId();
    if (prev_switched_thread[current_cpu]) |prev| {
        thread_active[prev] = false;
        prev_switched_thread[current_cpu] = null;
    }

    const t = &threads[current_thread_per_cpu[current_cpu]];
    if (t.user_pml4 != 0) {
        arch.cpu.writeCr3(t.user_pml4);
    }
    if (t.kernel_int_stack_top != 0) {
        gdt.setKernelRsp0ForCpu(current_cpu, t.kernel_int_stack_top);
    }

    releaseScheduleLock();
}

/// Called from vmexitStub (on the VMX host stack) when the guest session is
/// complete and the VMX thread should yield to other ready threads indefinitely.
pub export fn catenary_vmx_guest_done() callconv(.c) noreturn {
    const vmm_bridge = @import("../vmm/microvm_bridge.zig");
    vmm_bridge.broadcastTelemetryFromContext();
    get_current_thread().state = .Waiting;
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("sti");
    }
    while (true) {
        schedule();
        asm volatile ("pause");
    }
}

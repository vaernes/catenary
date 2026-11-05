//! Native Zig Empirical Stress Test Harness for Milestone M2:
//! Control Plane Multi-Instance Launch, SMP Core Distribution & VMCS Invariants
//!
//! Author: challenger_m2_2 (Empirical Challenger)
//! Toolchain: Zig 0.17.0

const std = @import("std");
const testing = std.testing;

// ============================================================================
// 1. Core Affinity Round-Robin Simulation
// Directly matches src/control/control_handler.zig:434-441 and 494-495
// ============================================================================
pub const ControlAffinityEngine = struct {
    online_cpus: usize,
    next_core_affinity: u8 = 0,

    pub fn init(online_cpus: usize) ControlAffinityEngine {
        return .{ .online_cpus = online_cpus };
    }

    pub fn launchStagedInstance(self: *ControlAffinityEngine) u8 {
        self.next_core_affinity = if (self.online_cpus > 1) 1 else 0;
        return 0; // Staged instance always executes on Core 0
    }

    pub fn allocateDynamicCore(self: *ControlAffinityEngine) u8 {
        const target_core: u8 = if (self.online_cpus > 1)
            @intCast(self.next_core_affinity % self.online_cpus)
        else
            0;
        self.next_core_affinity = if (self.online_cpus > 1)
            @intCast((target_core + 1) % self.online_cpus)
        else
            0;
        return target_core;
    }

    pub fn resolveStartCore(self: *ControlAffinityEngine, pinned_cpu: ?u8) u8 {
        if (pinned_cpu) |pin| {
            return pin;
        }
        const core: u8 = if (self.online_cpus > 1)
            @intCast(self.next_core_affinity % self.online_cpus)
        else
            0;
        self.next_core_affinity = if (self.online_cpus > 1)
            @intCast((core + 1) % self.online_cpus)
        else
            0;
        return core;
    }
};

test "Affinity Round-Robin: single CPU stays on core 0 without division by zero" {
    var engine = ControlAffinityEngine.init(1);
    const staged_core = engine.launchStagedInstance();
    try testing.expectEqual(@as(u8, 0), staged_core);
    try testing.expectEqual(@as(u8, 0), engine.next_core_affinity);

    for (0..200) |_| {
        const core = engine.allocateDynamicCore();
        try testing.expectEqual(@as(u8, 0), core);
        try testing.expectEqual(@as(u8, 0), engine.next_core_affinity);
    }
}

test "Affinity Round-Robin: 2, 4, 8, 16 CPUs across 256 allocations" {
    const topologies = [_]usize{ 2, 4, 8, 16 };
    for (topologies) |cpus| {
        var engine = ControlAffinityEngine.init(cpus);
        const staged_core = engine.launchStagedInstance();
        try testing.expectEqual(@as(u8, 0), staged_core);
        try testing.expectEqual(@as(u8, 1), engine.next_core_affinity);

        var core_counts: [16]usize = @splat(0);
        core_counts[0] += 1;

        for (0..256) |i| {
            const expected_core: u8 = @intCast((i + 1) % cpus);
            const core = engine.allocateDynamicCore();
            try testing.expectEqual(expected_core, core);
            core_counts[core] += 1;

            // Invariant: next_core_affinity must strictly stay < cpus
            try testing.expect(engine.next_core_affinity < cpus);
        }

        // Verify balance across all online CPUs
        var min_count: usize = std.math.maxInt(usize);
        var max_count: usize = 0;
        for (0..cpus) |c| {
            if (core_counts[c] < min_count) min_count = core_counts[c];
            if (core_counts[c] > max_count) max_count = core_counts[c];
        }
        try testing.expect(max_count - min_count <= 1);
        try testing.expect(min_count > 0);
    }
}

test "Affinity Lifecycle: create and start interleaving preserves target cores" {
    var engine = ControlAffinityEngine.init(2);
    _ = engine.launchStagedInstance(); // VM 1 -> Core 0

    // VM 2
    const vm2_pin = engine.allocateDynamicCore();
    try testing.expectEqual(@as(u8, 1), vm2_pin);
    const vm2_start = engine.resolveStartCore(vm2_pin);
    try testing.expectEqual(@as(u8, 1), vm2_start);

    // VM 3
    const vm3_pin = engine.allocateDynamicCore();
    try testing.expectEqual(@as(u8, 0), vm3_pin);
    const vm3_start = engine.resolveStartCore(vm3_pin);
    try testing.expectEqual(@as(u8, 0), vm3_start);

    // VM 4
    const vm4_pin = engine.allocateDynamicCore();
    try testing.expectEqual(@as(u8, 1), vm4_pin);
    const vm4_start = engine.resolveStartCore(vm4_pin);
    try testing.expectEqual(@as(u8, 1), vm4_start);
}

// ============================================================================
// 2. GDT TSS Selector Clamping
// Matches src/arch/x86_64/gdt.zig:34-37
// ============================================================================
pub const MAX_CPUS: usize = 8;

pub fn tssSelectorForCpu(cpu_id: usize) u16 {
    const id = if (cpu_id < MAX_CPUS) cpu_id else 0;
    return @as(u16, @intCast(0x28 + id * 16));
}

test "TSS Selector: exact selector calculation for valid CPUs 0..7" {
    const expected = [_]u16{ 0x28, 0x38, 0x48, 0x58, 0x68, 0x78, 0x88, 0x98 };
    for (0..MAX_CPUS) |i| {
        try testing.expectEqual(expected[i], tssSelectorForCpu(i));
    }
}

test "TSS Selector: clamping out-of-bounds CPUs to TSS 0 (0x28)" {
    const invalid_cpus = [_]usize{ 8, 9, 10, 16, 32, 64, 128, 255, 1024, std.math.maxInt(usize) };
    for (invalid_cpus) |bad_cpu| {
        try testing.expectEqual(@as(u16, 0x28), tssSelectorForCpu(bad_cpu));
    }
}

// ============================================================================
// 3. VMCS Lifecycle State Machine and SDM §24.11.1 Concurrency Oracle
// ============================================================================
pub const VmcsLaunchState = enum {
    clear,
    launched,
};

pub const VmcsHardware = struct {
    phys: u64,
    active_cpu: ?usize = null,
    launch_state: VmcsLaunchState = .clear,

    pub fn vmclear(self: *VmcsHardware) void {
        self.active_cpu = null;
        self.launch_state = .clear;
    }

    pub fn vmptrld(self: *VmcsHardware, cpu_id: usize) !void {
        if (self.active_cpu) |other_cpu| {
            if (other_cpu != cpu_id) {
                return error.ProcessorActivationCollision;
            }
        }
        self.active_cpu = cpu_id;
    }

    pub fn vmlaunch(self: *VmcsHardware, cpu_id: usize) !void {
        if (self.active_cpu == null or self.active_cpu.? != cpu_id) {
            return error.VmcsNotActiveOnProcessor;
        }
        if (self.launch_state != .clear) {
            return error.VmlaunchWithLaunchedVmcs;
        }
        self.launch_state = .launched;
    }

    pub fn vmresume(self: *VmcsHardware, cpu_id: usize) !void {
        if (self.active_cpu == null or self.active_cpu.? != cpu_id) {
            return error.VmcsNotActiveOnProcessor;
        }
        if (self.launch_state != .launched) {
            // Intel SDM Error 0x5: VMRESUME with non-launched VMCS
            return error.VmresumeWithNonLaunchedVmcs;
        }
    }
};

test "VMCS Migration: setupVmcs on Core 0 for Core 1 flushes via vmclear (SDM §24.11.1)" {
    var vmcs = VmcsHardware{ .phys = 0x8000_1000 };

    // Core 0 executes setupVmcs for Core 1
    const current_cpu: usize = 0;
    const target_core: usize = 1;

    // Line 3148-3149:
    vmcs.vmclear();
    try vmcs.vmptrld(current_cpu);
    try testing.expectEqual(@as(?usize, 0), vmcs.active_cpu);

    // Line 3158-3160:
    if (target_core != current_cpu) {
        vmcs.vmclear();
    }

    // Must be cleared on Core 0!
    try testing.expectEqual(@as(?usize, null), vmcs.active_cpu);
    try testing.expectEqual(VmcsLaunchState.clear, vmcs.launch_state);

    // Now Core 1 executes resumeInstance
    try vmcs.vmptrld(target_core);
    try testing.expectEqual(@as(?usize, 1), vmcs.active_cpu);

    // resumeInstance with exit_count == 0 routes to vmlaunch
    try vmcs.vmlaunch(target_core);
    try testing.expectEqual(VmcsLaunchState.launched, vmcs.launch_state);
}

test "VMCS Routing: exit_count == 0 strictly routes to vmlaunch, preventing Error 0x5" {
    var vmcs = VmcsHardware{ .phys = 0x8000_2000 };
    try vmcs.vmptrld(1);

    // Attempting vmresume before vmlaunch must fail with VmresumeWithNonLaunchedVmcs (error 0x5)
    try testing.expectError(error.VmresumeWithNonLaunchedVmcs, vmcs.vmresume(1));

    // Proper routing per src/arch/x86_64/vmx.zig:3174:
    const exit_count: usize = 0;
    if (exit_count == 0) {
        try vmcs.vmlaunch(1);
    } else {
        try vmcs.vmresume(1);
    }
    try testing.expectEqual(VmcsLaunchState.launched, vmcs.launch_state);

    // Subsequent resumes with exit_count > 0 route to vmresume
    const next_exit_count: usize = 1;
    if (next_exit_count > 0) {
        try vmcs.vmresume(1);
    }
}

// ============================================================================
// 4. Per-CPU TSC Independence
// ============================================================================
test "Per-CPU TSC: arrays completely isolate cycle accounting across concurrent exits" {
    var per_cpu_vmx_start_tsc: [MAX_CPUS]u64 = @splat(0);
    var instance_cpu_cycles: [MAX_CPUS]u64 = @splat(0);
    var instance_exit_counts: [MAX_CPUS]usize = @splat(0);

    // Simulate 8 cores resuming guests at staggered TSC timestamps
    for (0..MAX_CPUS) |cpu_id| {
        per_cpu_vmx_start_tsc[cpu_id] = 1_000_000 + cpu_id * 50_000;
    }

    // Simulate exits occurring in arbitrary order
    const exit_order = [_]usize{ 3, 1, 7, 0, 4, 2, 6, 5 };
    for (exit_order) |cpu_id| {
        const start = per_cpu_vmx_start_tsc[cpu_id];
        const duration: u64 = 500 + cpu_id * 10;
        const exit_tsc = start + duration;

        // Line 2867-2875:
        const delta = exit_tsc -% start;
        instance_cpu_cycles[cpu_id] += delta;
        instance_exit_counts[cpu_id] += 1;

        try testing.expectEqual(duration, delta);
    }

    for (0..MAX_CPUS) |cpu_id| {
        try testing.expectEqual(@as(usize, 1), instance_exit_counts[cpu_id]);
        try testing.expectEqual(500 + cpu_id * 10, instance_cpu_cycles[cpu_id]);
    }
}

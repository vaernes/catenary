const std = @import("std");

// Intel SDM Volume 3C Chapter 24 & 25 VMX Instruction & VMCS Definitions
pub const VMX_EXIT_VMCALL: u64 = 18;
pub const VMX_EXIT_VMCLEAR: u64 = 19;
pub const VMX_EXIT_VMLAUNCH: u64 = 20;
pub const VMX_EXIT_VMPTRLD: u64 = 21;
pub const VMX_EXIT_VMPTRST: u64 = 22;
pub const VMX_EXIT_VMREAD: u64 = 23;
pub const VMX_EXIT_VMRESUME: u64 = 24;
pub const VMX_EXIT_VMWRITE: u64 = 25;
pub const VMX_EXIT_VMXOFF: u64 = 26;
pub const VMX_EXIT_VMXON: u64 = 27;
pub const VMX_EXIT_INVEPT: u64 = 50;
pub const VMX_EXIT_INVVPID: u64 = 53;

pub const VM_INSTRUCTION_ERROR_VMCALL_IN_VMX_ROOT: u64 = 1;
pub const VM_INSTRUCTION_ERROR_VMCLEAR_INVALID_ADDRESS: u64 = 2;
pub const VM_INSTRUCTION_ERROR_VMCLEAR_WITH_VMXON_POINTER: u64 = 3;
pub const VM_INSTRUCTION_ERROR_VMLAUNCH_NON_CLEAR_VMCS: u64 = 4;
pub const VM_INSTRUCTION_ERROR_VMRESUME_NON_LAUNCHED_VMCS: u64 = 5;
pub const VM_INSTRUCTION_ERROR_VMPTRLD_INVALID_ADDRESS: u64 = 9;
pub const VM_INSTRUCTION_ERROR_VMPTRLD_WITH_VMXON_POINTER: u64 = 10;
pub const VM_INSTRUCTION_ERROR_VMPTRLD_INCORRECT_VMCS_REVISION: u64 = 11;
pub const VM_INSTRUCTION_ERROR_UNSUPPORTED_VMCS_FIELD: u64 = 12;
pub const VM_INSTRUCTION_ERROR_VMWRITE_READ_ONLY_FIELD: u64 = 13;
pub const VM_INSTRUCTION_ERROR_VMXON_IN_VMX_ROOT: u64 = 15;

pub const VmxonState = struct {
    active: bool = false,
    vmxon_region_gpa: u64 = 0,
    current_vmcs_gpa: u64 = 0,
    vmcs_active: bool = false,
    vmcs_launched: bool = false,
    guest_cr0: u64 = 0,
    guest_cr4: u64 = 0,
};

pub const MAX_NESTED_INSTANCES: usize = 8;
var nested_states: [MAX_NESTED_INSTANCES]VmxonState = @splat(.{});

fn getSlot(vmid: u32) ?usize {
    if (vmid == 0 or vmid > MAX_NESTED_INSTANCES) return null;
    return @as(usize, vmid - 1);
}

pub fn getState(vmid: u32) ?*VmxonState {
    const idx = getSlot(vmid) orelse return null;
    return &nested_states[idx];
}

pub fn resetInstance(vmid: u32) void {
    const st = getState(vmid) orelse return;
    st.* = .{};
}

pub fn handleVmxon(vmid: u32, vmxon_gpa: u64) !void {
    const st = getState(vmid) orelse return error.InvalidVmId;
    if (st.active) return error.VmxonAlreadyActive;
    if ((vmxon_gpa & 0xFFF) != 0) return error.UnalignedAddress;
    st.active = true;
    st.vmxon_region_gpa = vmxon_gpa;
    st.current_vmcs_gpa = 0;
    st.vmcs_active = false;
    st.vmcs_launched = false;
}

pub fn handleVmxoff(vmid: u32) !void {
    const st = getState(vmid) orelse return error.InvalidVmId;
    if (!st.active) return error.VmxNotActive;
    st.* = .{};
}

pub fn handleVmptrld(vmid: u32, vmcs_gpa: u64) !void {
    const st = getState(vmid) orelse return error.InvalidVmId;
    if (!st.active) return error.VmxNotActive;
    if ((vmcs_gpa & 0xFFF) != 0) return error.UnalignedAddress;
    if (vmcs_gpa == st.vmxon_region_gpa) return error.VmcsMatchesVmxonPointer;
    st.current_vmcs_gpa = vmcs_gpa;
    st.vmcs_active = true;
}

pub fn handleVmclear(vmid: u32, vmcs_gpa: u64) !void {
    const st = getState(vmid) orelse return error.InvalidVmId;
    if (!st.active) return error.VmxNotActive;
    if ((vmcs_gpa & 0xFFF) != 0) return error.UnalignedAddress;
    if (st.current_vmcs_gpa == vmcs_gpa) {
        st.vmcs_active = false;
        st.current_vmcs_gpa = 0;
        st.vmcs_launched = false;
    }
}

pub fn handleVmlaunch(vmid: u32) !void {
    const st = getState(vmid) orelse return error.InvalidVmId;
    if (!st.active or !st.vmcs_active) return error.VmcsNotActive;
    if (st.vmcs_launched) return error.VmcsAlreadyLaunched;
    st.vmcs_launched = true;
}

pub fn handleVmresume(vmid: u32) !void {
    const st = getState(vmid) orelse return error.InvalidVmId;
    if (!st.active or !st.vmcs_active) return error.VmcsNotActive;
    if (!st.vmcs_launched) return error.VmcsNotLaunched;
}

test "nested_vmx: vmxon, vmptrld, vmlaunch, vmresume, and vmxoff state machine" {
    const vmid: u32 = 1;
    resetInstance(vmid);

    // Initial state: not active
    try std.testing.expectError(error.VmxNotActive, handleVmxoff(vmid));
    try std.testing.expectError(error.VmxNotActive, handleVmptrld(vmid, 0x1000));

    // VMXON
    try handleVmxon(vmid, 0x1000);
    const st = getState(vmid).?;
    try std.testing.expect(st.active);
    try std.testing.expectEqual(@as(u64, 0x1000), st.vmxon_region_gpa);

    // VMPTRLD with VMXON pointer rejected
    try std.testing.expectError(error.VmcsMatchesVmxonPointer, handleVmptrld(vmid, 0x1000));

    // Valid VMPTRLD
    try handleVmptrld(vmid, 0x2000);
    try std.testing.expect(st.vmcs_active);
    try std.testing.expectEqual(@as(u64, 0x2000), st.current_vmcs_gpa);

    // VMLAUNCH
    try handleVmlaunch(vmid);
    try std.testing.expect(st.vmcs_launched);

    // Second VMLAUNCH fails
    try std.testing.expectError(error.VmcsAlreadyLaunched, handleVmlaunch(vmid));

    // VMRESUME succeeds
    try handleVmresume(vmid);

    // VMCLEAR
    try handleVmclear(vmid, 0x2000);
    try std.testing.expect(!st.vmcs_active);

    // VMXOFF
    try handleVmxoff(vmid);
    try std.testing.expect(!st.active);
}

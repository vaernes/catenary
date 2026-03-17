const std = @import("std");
const vmx = @import("vmx.zig");
const svm = @import("svm.zig");
const limine = @import("../../kernel/limine.zig");
const cpu = @import("cpu.zig");
const endpoint_table = @import("../../ipc/endpoint_table.zig");

fn serialWrite(s: []const u8) void {
    for (s) |c| {
        cpu.outb(0x3F8, c);
    }
}

pub fn init(memmap: *limine.MemmapResponse, hhdm_offset: u64, table: *const endpoint_table.EndpointTable) void {
    if (vmx.isVmxSupported()) {
        vmx.init(memmap, hhdm_offset, table) catch {};
        return;
    } else if (svm.isSvmSupported()) {
        svm.init(memmap, hhdm_offset) catch {
            serialWrite("HVM: SVM init failed\n");
            return;
        };
        return;
    }

    serialWrite("HVM: no VMX/SVM support\n");
}

const std = @import("std");

fn ptrFrom(comptime T: type, addr: u64) T {
    return @ptrFromInt(asm volatile ("" : [ret] "={rax}" (-> u64) : [val] "{rax}" (addr)));
}

fn syscall(op: u64, arg0: u64, arg1: u64, token: u64) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [op] "{rax}" (op),
          [arg0] "{rbx}" (arg0),
          [arg1] "{rdx}" (arg1),
          [token] "{r8}" (token),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

const SYS_REGISTER = 2;
const SYS_ALLOC_DMA = 5;
const SYS_SEND_PAGE = 6;
const SYS_GET_KEY = 8; // Custom syscall to pop a scancode

const DIPC_RECV_VA: u64 = 0x0000_7F00_0000_0000;
const DMA_BASE_VA: u64 = 0x0000_7D00_0000_0000;

const BootstrapDescriptor = extern struct {
    magic: u32,
    version: u16,
    descriptor_len: u16,
    class: u16,
    service_kind: u16,
    runtime_mode: u16,
    _r0: u16,
    service_id: u32,
    flags: u32,
    persistent_trap_vector: u8,
    _r1: u8,
    persistent_heartbeat_op: u16,
    persistent_stop_op: u16,
    _r2: u16,
    local_node: [16]u8,
    dipc_wire_magic: u32,
    dipc_wire_version: u16,
    dipc_header_len: u16,
    dipc_max_payload: u32,
    reserved_netd_endpoint: u64,
    reserved_kernel_control_endpoint: u64,
    reserved_router_endpoint: u64,
    reserved_storaged_endpoint: u64,
    reserved_dashd_endpoint: u64,
    microvm_ingress_magic: u32,
    microvm_ingress_version: u16,
    microvm_ingress_len: u16,
    capability_token: u64,
};

const USER_BOOTSTRAP_VADDR: usize = 0x0000_7FFF_FFFB_0000;

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

fn serialWrite(s: []const u8) void {
    for (s) |c| outb(0x3F8, c);
}

// Map scancodes to simple ASCII
fn scancodeToAscii(scancode: u8) ?u8 {
    return switch (scancode) {
        0x1E => 'a', 0x30 => 'b', 0x2E => 'c', 0x20 => 'd', 0x12 => 'e',
        0x21 => 'f', 0x22 => 'g', 0x23 => 'h', 0x17 => 'i', 0x24 => 'j',
        0x25 => 'k', 0x26 => 'l', 0x32 => 'm', 0x31 => 'n', 0x18 => 'o',
        0x19 => 'p', 0x10 => 'q', 0x13 => 'r', 0x1F => 's', 0x14 => 't',
        0x16 => 'u', 0x2F => 'v', 0x11 => 'w', 0x2D => 'x', 0x15 => 'y',
        0x2C => 'z',
        0x02 => '1', 0x03 => '2', 0x04 => '3', 0x05 => '4', 0x06 => '5',
        0x07 => '6', 0x08 => '7', 0x09 => '8', 0x0A => '9', 0x0B => '0',
        0x1C => '\n', 0x39 => ' ', 0x0E => 0x08,
        else => null,
    };
}

pub export fn umain() noreturn {
    const bs: *const BootstrapDescriptor = ptrFrom(*const BootstrapDescriptor, USER_BOOTSTRAP_VADDR);
    const token = bs.capability_token;

    serialWrite("inputd: starting\n");
    _ = syscall(SYS_REGISTER, 0, 8, token); // Register at endpoint 8 for inputd
    serialWrite("inputd: registered at endpoint 8\n");

    const dipc_phys = syscall(SYS_ALLOC_DMA, 1, 0, token);
    if (dipc_phys == 0) {
        serialWrite("inputd: DMA alloc failed\n");
        while(true) asm volatile("pause");
    }

    // Input loop: poll the kernel buffer via SYS_GET_KEY, then broadcast via DIPC
    serialWrite("inputd: entering event loop\n");
    while (true) {
        const scancode_val = syscall(SYS_GET_KEY, 0, 0, token);
        if (scancode_val != 0xFFFFFFFF) {
            const scancode: u8 = @truncate(scancode_val);
            if ((scancode & 0x80) == 0) { // Only Make codes for now
                if (scancodeToAscii(scancode)) |c| {
                    // Send to dashd or windowd (endpoint 5 or 9)
                    // We can just format a simple DIPC message
                    const scratch: [*]u8 = ptrFrom([*]u8, DMA_BASE_VA);
                    scratch[0] = 0x43; scratch[1] = 0x50; scratch[2] = 0x49; scratch[3] = 0x44; // DIPC magic
                    scratch[4] = 1; scratch[5] = 0;
                    scratch[6] = 64; scratch[7] = 0;
                    scratch[8] = 8; scratch[9] = 0; scratch[10] = 0; scratch[11] = 0; // payload_len=8
                    @memset(scratch[12..20], 0); // auth
                    
                    @memcpy(scratch[20..36], &bs.local_node);
                    scratch[36] = 8; @memset(scratch[37..44], 0); // src endpoint 8
                    
                    @memcpy(scratch[44..60], &bs.local_node);
                    scratch[60] = 5; @memset(scratch[61..68], 0); // dst endpoint 5 (dashd)
                    
                    // Payload: Input event
                    scratch[64] = 1; // 1 = key down
                    scratch[65] = c; // ascii char
                    scratch[66] = scancode; // raw scancode
                    
                    _ = syscall(SYS_SEND_PAGE, dipc_phys, 0, token);
                }
            }
        } else {
            // Wait briefly before polling again
            for(0..100000) |_| asm volatile("pause");
        }
    }
}

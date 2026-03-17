const builtin = @import("builtin");

pub const DescriptorTablePointer = packed struct {
    limit: u16,
    base: u64,
};

pub const CR4_OSXSAVE: u64 = 1 << 18;

pub inline fn outb(port: u16, value: u8) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("outb %[value], %[port]"
            :
            : [value] "{al}" (value),
              [port] "{dx}" (port),
        );
    }
}

pub inline fn inb(port: u16) u8 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("inb %[port], %%al"
            : [value] "={al}" (-> u8),
            : [port] "{dx}" (port),
        );
    }
    return 0;
}

pub inline fn outl(port: u16, value: u32) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("outl %[value], %[port]"
            :
            : [value] "{eax}" (value),
              [port] "{dx}" (port),
        );
    }
}

pub inline fn inl(port: u16) u32 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("inl %[port], %%eax"
            : [value] "={eax}" (-> u32),
            : [port] "{dx}" (port),
        );
    }
    return 0;
}

pub inline fn outw(port: u16, value: u16) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("outw %[value], %[port]"
            :
            : [value] "{ax}" (value),
              [port] "{dx}" (port),
        );
    }
}

pub inline fn inw(port: u16) u16 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("inw %[port], %%ax"
            : [value] "={ax}" (-> u16),
            : [port] "{dx}" (port),
        );
    }
    return 0;
}

pub inline fn cpuid(eax_in: u32, ecx_in: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx),
            : [eax_in] "{eax}" (eax_in),
              [ecx_in] "{ecx}" (ecx_in),
        );
    }

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

pub inline fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("rdmsr"
            : [low] "={eax}" (low),
              [high] "={edx}" (high),
            : [msr] "{ecx}" (msr),
        );
    }

    return (@as(u64, high) << 32) | low;
}

pub inline fn wrmsr(msr: u32, value: u64) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        const low = @as(u32, @truncate(value));
        const high = @as(u32, @truncate(value >> 32));
        asm volatile ("wrmsr"
            :
            : [msr] "{ecx}" (msr),
              [low] "{eax}" (low),
              [high] "{edx}" (high),
        );
    }
}

pub inline fn readCr0() u64 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("mov %%cr0, %[result]"
            : [result] "=r" (-> u64),
        );
    }
    return 0;
}

pub inline fn writeCr0(value: u64) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("mov %[value], %%cr0"
            :
            : [value] "r" (value),
            : .{ .memory = true });
    }
}

pub inline fn readCr3() u64 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("mov %%cr3, %[result]"
            : [result] "=r" (-> u64),
        );
    }
    return 0;
}

pub inline fn writeCr3(value: u64) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("mov %[value], %%cr3"
            :
            : [value] "r" (value),
            : .{ .memory = true });
    }
}

pub inline fn readCr4() u64 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("mov %%cr4, %[result]"
            : [result] "=r" (-> u64),
        );
    }
    return 0;
}

pub inline fn writeCr4(value: u64) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("mov %[value], %%cr4"
            :
            : [value] "r" (value),
            : .{ .memory = true });
    }
}

pub inline fn readTr() u16 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("str %[result]"
            : [result] "=r" (-> u16),
        );
    }
    return 0;
}

pub inline fn readCs() u16 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("mov %%cs, %[result]"
            : [result] "=r" (-> u16),
        );
    }
    return 0;
}

pub inline fn readDs() u16 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("mov %%ds, %[result]"
            : [result] "=r" (-> u16),
        );
    }
    return 0;
}

pub inline fn readEs() u16 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("mov %%es, %[result]"
            : [result] "=r" (-> u16),
        );
    }
    return 0;
}

pub inline fn readFs() u16 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("mov %%fs, %[result]"
            : [result] "=r" (-> u16),
        );
    }
    return 0;
}

pub inline fn readGs() u16 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("mov %%gs, %[result]"
            : [result] "=r" (-> u16),
        );
    }
    return 0;
}

pub inline fn readSs() u16 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("mov %%ss, %[result]"
            : [result] "=r" (-> u16),
        );
    }
    return 0;
}

pub inline fn xgetbv(ecx: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("xgetbv"
            : [low] "={eax}" (low),
              [high] "={edx}" (high),
            : [ecx] "{ecx}" (ecx),
        );
    }
    return (@as(u64, high) << 32) | low;
}

pub inline fn xsetbv(ecx: u32, value: u64) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        const low = @as(u32, @truncate(value));
        const high = @as(u32, @truncate(value >> 32));
        asm volatile ("xsetbv"
            :
            : [ecx] "{ecx}" (ecx),
              [low] "{eax}" (low),
              [high] "{edx}" (high),
        );
    }
}

extern fn catenary_lgdt(gdtr: *const DescriptorTablePointer) void;
extern fn catenary_lidt(idtr: *const DescriptorTablePointer) void;
extern fn catenary_sgdt(gdtr: *DescriptorTablePointer) void;
extern fn catenary_sidt(idtr: *DescriptorTablePointer) void;
extern fn catenary_ltr(selector: u16) void;

pub inline fn lgdt(gdtr: *const DescriptorTablePointer) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        catenary_lgdt(gdtr);
    }
}

pub inline fn ltr(selector: u16) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        catenary_ltr(selector);
    }
}

pub inline fn sgdt() DescriptorTablePointer {
    var gdtr: DescriptorTablePointer = undefined;
    if (comptime builtin.cpu.arch == .x86_64) {
        catenary_sgdt(&gdtr);
    }
    return gdtr;
}

pub inline fn sgdtInto(gdtr: *DescriptorTablePointer) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        catenary_sgdt(gdtr);
    }
}

pub inline fn lidt(idtr: *const DescriptorTablePointer) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        catenary_lidt(idtr);
    }
}

pub inline fn readLdtr() u16 {
    if (comptime builtin.cpu.arch == .x86_64) {
        return asm volatile ("sldt %[result]"
            : [result] "=r" (-> u16),
        );
    }
    return 0;
}

pub inline fn sidt() DescriptorTablePointer {
    var idtr: DescriptorTablePointer = undefined;
    if (comptime builtin.cpu.arch == .x86_64) {
        catenary_sidt(&idtr);
    }
    return idtr;
}

pub inline fn sidtInto(idtr: *DescriptorTablePointer) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        catenary_sidt(idtr);
    }
}

pub inline fn pause() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("pause" ::: .{ .memory = true });
    }
}

pub inline fn hlt() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

pub inline fn halt() void {
    hlt();
}

pub inline fn cli() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("cli" ::: .{ .memory = true });
    }
}

pub inline fn sti() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("sti" ::: .{ .memory = true });
    }
}

pub inline fn stac() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("stac" ::: .{ .memory = true });
    }
}

pub inline fn clac() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("clac" ::: .{ .memory = true });
    }
}

pub inline fn invlpg(addr: u64) void {
    if (comptime builtin.cpu.arch == .x86_64) {
        asm volatile ("invlpg (%[addr])"
            :
            : [addr] "r" (addr),
            : .{ .memory = true });
    }
}

pub inline fn wait() void {
    sti();
    hlt();
}

pub inline fn rdtsc() u64 {
    if (comptime builtin.cpu.arch == .x86_64) {
        var low: u32 = undefined;
        var high: u32 = undefined;
        asm volatile ("rdtsc"
            : [low] "={eax}" (low),
              [high] "={edx}" (high),
        );
        return (@as(u64, high) << 32) | low;
    }
    return 0;
}

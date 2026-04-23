const dipc = @import("../ipc/dipc.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const pmm = @import("../kernel/pmm.zig");
const service_bootstrap = @import("service_bootstrap.zig");

pub const LaunchMagic: u32 = 0x55535256; // 'USRV'
pub const LaunchVersion: u16 = 1;
const CR4_SMAP: u64 = @as(u64, 1) << 21;

pub const LaunchError = error{
    OutOfMemory,
    BadMagic,
    BadVersion,
    BadLength,
    BadSelectors,
    BadBootstrap,
};

// Minimal launch contract for a future Ring-3 service.
// This does not execute a task yet; it defines the exact state a launcher/VMM/user-task
// bootstrap path must honor once Ring 3 exists.
pub const Descriptor = extern struct {
    magic: u32,
    version: u16,
    descriptor_len: u16,
    service_kind: service_bootstrap.ServiceKind,
    _reserved0: u16 = 0,
    entry_rip: u64,
    stack_top: u64,
    entry_arg0: u64,
    code_selector: u16,
    data_selector: u16,
    _reserved1: u32 = 0,
    bootstrap_page_phys: u64,
    bootstrap_len: u32,
    flags: u32 = 0,
};

fn userCodeSelector() u16 {
    return gdt.USER_CODE_SELECTOR | 0x3;
}

fn userDataSelector() u16 {
    return gdt.USER_DATA_SELECTOR | 0x3;
}

pub fn allocNetdLaunch(
    hhdm_offset: u64,
    local_node: dipc.Ipv6Addr,
    service_id: u32,
    runtime_mode: service_bootstrap.RuntimeMode,
    entry_rip: u64,
    stack_top: u64,
) LaunchError!Descriptor {
    const registry = @import("service_registry.zig");
    return allocNetdLaunchWithToken(
        hhdm_offset,
        local_node,
        service_id,
        runtime_mode,
        entry_rip,
        stack_top,
        registry.getCapabilityToken(service_id),
    );
}

pub fn allocLaunch(
    hhdm_offset: u64,
    local_node: dipc.Ipv6Addr,
    service_id: u32,
    kind: service_bootstrap.ServiceKind,
    user_id: service_bootstrap.UserId,
    runtime_mode: service_bootstrap.RuntimeMode,
    entry_rip: u64,
    stack_top: u64,
) LaunchError!Descriptor {
    const page_phys = pmm.allocPage() orelse return error.OutOfMemory;
    errdefer pmm.freePage(page_phys);

    const registry = @import("service_registry.zig");
    const token = registry.getCapabilityToken(service_id);

    const bootstrap: service_bootstrap.Descriptor = switch (kind) {
        .netd => service_bootstrap.forNetd(local_node, service_id, user_id, runtime_mode, token),
        .vmm => service_bootstrap.forVmm(local_node, service_id, user_id, token),
        .storaged => service_bootstrap.forStoraged(local_node, service_id, user_id, token),
        .dashd => service_bootstrap.forDashd(local_node, service_id, user_id, token),
        .containerd => service_bootstrap.forContainerd(local_node, service_id, user_id, token),
        .clusterd => service_bootstrap.forClusterd(local_node, service_id, user_id, token),
        .inputd => service_bootstrap.forInputd(local_node, service_id, user_id, token),
        .windowd => service_bootstrap.forWindowd(local_node, service_id, user_id, token),
        .configd => service_bootstrap.forConfigd(local_node, service_id, user_id, token),
    };

    const page_virt = page_phys + hhdm_offset;
    const dst: *service_bootstrap.Descriptor = @ptrFromInt(page_virt);
    dst.* = bootstrap;

    return .{
        .magic = LaunchMagic,
        .version = LaunchVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .service_kind = kind,
        .entry_rip = entry_rip,
        .stack_top = stack_top,
        .entry_arg0 = page_phys,
        .code_selector = userCodeSelector(),
        .data_selector = userDataSelector(),
        .bootstrap_page_phys = page_phys,
        .bootstrap_len = @as(u32, @intCast(@sizeOf(service_bootstrap.Descriptor))),
    };
}

pub fn allocNetdLaunchWithToken(
    hhdm_offset: u64,
    local_node: dipc.Ipv6Addr,
    service_id: u32,
    runtime_mode: service_bootstrap.RuntimeMode,
    entry_rip: u64,
    stack_top: u64,
    capability_token: u64,
) LaunchError!Descriptor {
    const page_phys = pmm.allocPage() orelse return error.OutOfMemory;
    errdefer pmm.freePage(page_phys);

    const bootstrap = service_bootstrap.forNetd(local_node, service_id, .core, runtime_mode, capability_token);

    const page_virt = page_phys + hhdm_offset;
    const dst: *service_bootstrap.Descriptor = @ptrFromInt(page_virt);
    dst.* = bootstrap;

    return .{
        .magic = LaunchMagic,
        .version = LaunchVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .service_kind = .netd,
        .entry_rip = entry_rip,
        .stack_top = stack_top,
        .entry_arg0 = page_phys,
        .code_selector = userCodeSelector(),
        .data_selector = userDataSelector(),
        .bootstrap_page_phys = page_phys,
        .bootstrap_len = @as(u32, @intCast(@sizeOf(service_bootstrap.Descriptor))),
    };
}

pub fn allocVmmLaunch(
    hhdm_offset: u64,
    local_node: dipc.Ipv6Addr,
    service_id: u32,
    entry_rip: u64,
    stack_top: u64,
) LaunchError!Descriptor {
    const page_phys = pmm.allocPage() orelse return error.OutOfMemory;
    errdefer pmm.freePage(page_phys);

    const registry = @import("service_registry.zig");
    const token = registry.getCapabilityToken(service_id);
    const bootstrap = service_bootstrap.forVmm(local_node, service_id, .vm_deployer, token);

    const page_virt = page_phys + hhdm_offset;
    const dst: *service_bootstrap.Descriptor = @ptrFromInt(page_virt);
    dst.* = bootstrap;

    return .{
        .magic = LaunchMagic,
        .version = LaunchVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(Descriptor))),
        .service_kind = .vmm,
        .entry_rip = entry_rip,
        .stack_top = stack_top,
        .entry_arg0 = page_phys,
        .code_selector = userCodeSelector(),
        .data_selector = userDataSelector(),
        .bootstrap_page_phys = page_phys,
        .bootstrap_len = @as(u32, @intCast(@sizeOf(service_bootstrap.Descriptor))),
    };
}

pub fn validate(hhdm_offset: u64, desc: Descriptor) LaunchError!void {
    if (desc.magic != LaunchMagic) return error.BadMagic;
    if (desc.version != LaunchVersion) return error.BadVersion;
    if (desc.descriptor_len != @sizeOf(Descriptor)) return error.BadLength;
    if (desc.code_selector != userCodeSelector() or desc.data_selector != userDataSelector()) return error.BadSelectors;
    const smap_enabled = (cpu.readCr4() & CR4_SMAP) != 0;
    if (smap_enabled) cpu.stac();
    defer if (smap_enabled) cpu.clac();

    const bootstrap_virt = desc.bootstrap_page_phys + hhdm_offset;
    const bootstrap: *const service_bootstrap.Descriptor = @ptrFromInt(bootstrap_virt);
    service_bootstrap.validate(bootstrap.*) catch return error.BadBootstrap;
}

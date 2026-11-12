test {
    _ = @import("kernel/pmm.zig");
    _ = @import("kernel/suballoc.zig");
    _ = @import("kernel/scheduler.zig");
    _ = @import("services/service_registry.zig");
    _ = @import("ipc/router.zig");
    _ = @import("vmm/virtio_blk.zig");
    _ = @import("vmm/virtio_net.zig");
    _ = @import("vmm/microvm_bridge.zig");
    _ = @import("vmm/pc_platform.zig");
    _ = @import("vmm/efi_vars.zig");
    _ = @import("vmm/vtpm.zig");
    _ = @import("vmm/uefi_firmware.zig");
    _ = @import("vmm/vm_snapshot.zig");
    _ = @import("vmm/nested_vmx.zig");
    _ = @import("vmm/buffer_grant.zig");
    _ = @import("user/protocols/clusterd_protocol.zig");
    _ = @import("arch/x86_64/vmx.zig");
    _ = @import("user/tui/tui_tests.zig");
    _ = @import("user/tui/stress_tests.zig");
    _ = @import("kernel/varde_shell_tests.zig");
}

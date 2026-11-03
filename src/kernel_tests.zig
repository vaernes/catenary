test {
    _ = @import("kernel/pmm.zig");
    _ = @import("kernel/suballoc.zig");
    _ = @import("kernel/scheduler.zig");
    _ = @import("services/service_registry.zig");
    _ = @import("ipc/router.zig");
    _ = @import("vmm/virtio_blk.zig");
    _ = @import("vmm/virtio_net.zig");
    _ = @import("vmm/microvm_bridge.zig");
    _ = @import("user/tui/tui_tests.zig");
    _ = @import("user/tui/stress_tests.zig");
    _ = @import("kernel/varde_shell_tests.zig");
}

const pmm = @import("pmm.zig");

// Simple sub-page bump allocator for small kernel objects.
// Ownership: memory is kernel-private and sourced from PMM pages.
// This allocator does not support free() yet; callers treat allocations as
// long-lived until a future slab/free-list layer is added.
pub const SubAlloc = struct {
    hhdm_offset: u64,
    current_page_phys: ?u64 = null,
    offset: usize = 0,

    pub fn init(hhdm_offset: u64) SubAlloc {
        return .{ .hhdm_offset = hhdm_offset };
    }

    fn alignUp(value: usize, alignment: usize) usize {
        const mask = alignment - 1;
        return (value + mask) & ~mask;
    }

    pub fn alloc(self: *SubAlloc, comptime T: type) ?*T {
        return @ptrCast(@alignCast(self.allocBytes(@sizeOf(T), @alignOf(T)) orelse return null));
    }

    pub fn allocBytes(self: *SubAlloc, size: usize, alignment: usize) ?[*]u8 {
        if (size == 0) return null;
        if (alignment == 0 or (alignment & (alignment - 1)) != 0) return null;
        if (size > pmm.PAGE_SIZE) return null;

        while (true) {
            if (self.current_page_phys == null) {
                self.current_page_phys = pmm.allocPage() orelse return null;
                self.offset = 0;
            }

            const aligned = alignUp(self.offset, alignment);
            if (aligned + size <= pmm.PAGE_SIZE) {
                self.offset = aligned + size;
                const base = self.current_page_phys.? + self.hhdm_offset + aligned;
                return @ptrFromInt(base);
            }

            self.current_page_phys = pmm.allocPage() orelse return null;
            self.offset = 0;
        }
    }
};

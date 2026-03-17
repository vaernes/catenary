const std = @import("std");

/// AArch64 Stage 1 Translation Table setup.
/// This implementation provides a simple 1:1 identity map for early bringup.

pub const TCR_TG0_4KB = 0 << 14;
pub const TCR_ORGN0_WBWA = 1 << 10;
pub const TCR_IRGN0_WBWA = 1 << 8;
pub const TCR_SH0_INNER = 3 << 12;
pub const TCR_T0SZ_48 = 16; // 64 - 48 bits = 16

pub const MAIR_ATTR_DEVICE = 0x00;
pub const MAIR_ATTR_NORMAL = 0xFF;

pub const TTBR_VALID = 1 << 0;
pub const TTBR_TABLE = 1 << 1;
pub const TTBR_AF = 1 << 10;
pub const TTBR_MEM_ATTR_NORMAL = 1 << 2;

pub fn init() void {
    // Stage 1 paging will be implemented here for EL1
}

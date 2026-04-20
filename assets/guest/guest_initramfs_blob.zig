pub fn get() []const u8 {
    return @embedFile("initramfs.cpio.gz");
}

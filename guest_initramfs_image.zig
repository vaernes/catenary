pub fn get() []const u8 {
    return @embedFile("assets/guest/initramfs.cpio.gz");
}

pub fn get() []const u8 {
    return @embedFile("linux-bzImage");
}

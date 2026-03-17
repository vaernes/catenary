pub fn get() []const u8 {
    return @embedFile("assets/guest/linux-bzImage");
}

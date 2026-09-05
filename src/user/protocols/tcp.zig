/// TCP protocol definitions for Catenary OS netd
///
/// Implements TCP header layout, flags, connection states, and IPv6
/// pseudo-header checksum computation per RFC 793, RFC 8200 Section 8.1,
/// and RFC 9293.
const std = @import("std");

pub const TCP_PROTOCOL_NUMBER: u8 = 6;
pub const TCP_HEADER_MIN_SIZE: usize = 20;
pub const DEFAULT_WINDOW_SIZE: u16 = 4096;
pub const DEFAULT_MSS: u16 = 1220; // 1280 (IPv6 min MTU) - 40 (IPv6) - 20 (TCP)

pub const Flags = struct {
    pub const FIN: u8 = 0x01;
    pub const SYN: u8 = 0x02;
    pub const RST: u8 = 0x04;
    pub const PSH: u8 = 0x08;
    pub const ACK: u8 = 0x10;
    pub const URG: u8 = 0x20;
    pub const ECE: u8 = 0x40;
    pub const CWR: u8 = 0x80;
};

pub const State = enum(u8) {
    closed = 0,
    listen = 1,
    syn_sent = 2,
    syn_received = 3,
    established = 4,
    fin_wait_1 = 5,
    fin_wait_2 = 6,
    close_wait = 7,
    last_ack = 8,
    time_wait = 9,
};

pub const Header = extern struct {
    src_port: u16,
    dst_port: u16,
    seq_num: u32,
    ack_num: u32,
    data_offset_and_reserved: u8,
    flags: u8,
    window_size: u16,
    checksum: u16,
    urgent_ptr: u16,

    pub fn getSrcPort(self: *const Header) u16 {
        return std.mem.bigToNative(u16, self.src_port);
    }

    pub fn getDstPort(self: *const Header) u16 {
        return std.mem.bigToNative(u16, self.dst_port);
    }

    pub fn getSeqNum(self: *const Header) u32 {
        return std.mem.bigToNative(u32, self.seq_num);
    }

    pub fn getAckNum(self: *const Header) u32 {
        return std.mem.bigToNative(u32, self.ack_num);
    }

    pub fn getWindowSize(self: *const Header) u16 {
        return std.mem.bigToNative(u16, self.window_size);
    }

    pub fn getDataOffset(self: *const Header) usize {
        return @as(usize, (self.data_offset_and_reserved >> 4) & 0x0F) * 4;
    }

    pub fn setSrcPort(self: *Header, port: u16) void {
        self.src_port = std.mem.nativeToBig(u16, port);
    }

    pub fn setDstPort(self: *Header, port: u16) void {
        self.dst_port = std.mem.nativeToBig(u16, port);
    }

    pub fn setSeqNum(self: *Header, seq: u32) void {
        self.seq_num = std.mem.nativeToBig(u32, seq);
    }

    pub fn setAckNum(self: *Header, ack: u32) void {
        self.ack_num = std.mem.nativeToBig(u32, ack);
    }

    pub fn setWindowSize(self: *Header, wnd: u16) void {
        self.window_size = std.mem.nativeToBig(u16, wnd);
    }

    pub fn setDataOffset(self: *Header, words: u4) void {
        self.data_offset_and_reserved = @as(u8, words) << 4;
    }
};

comptime {
    if (@sizeOf(Header) != 20) {
        @compileError("TCP Header must be exactly 20 bytes");
    }
}

/// Compute 16-bit one's complement Internet checksum over IPv6 pseudo-header
/// and TCP segment (header + payload) according to RFC 8200 Section 8.1.
pub fn computeChecksum(
    src_ip: *const [16]u8,
    dst_ip: *const [16]u8,
    tcp_segment: []const u8,
) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    // IPv6 pseudo-header: Source Address (16 bytes)
    while (i < 16) : (i += 2) {
        sum += (@as(u32, src_ip[i]) << 8) | src_ip[i + 1];
    }

    // IPv6 pseudo-header: Destination Address (16 bytes)
    i = 0;
    while (i < 16) : (i += 2) {
        sum += (@as(u32, dst_ip[i]) << 8) | dst_ip[i + 1];
    }

    // IPv6 pseudo-header: Upper-Layer Packet Length (32 bits)
    const tcp_len: u32 = @intCast(tcp_segment.len);
    sum += (tcp_len >> 16) & 0xFFFF;
    sum += tcp_len & 0xFFFF;

    // IPv6 pseudo-header: Next Header (0x0006)
    sum += TCP_PROTOCOL_NUMBER;

    // TCP segment (Header + Payload)
    i = 0;
    while (i + 1 < tcp_segment.len) : (i += 2) {
        sum += (@as(u32, tcp_segment[i]) << 8) | tcp_segment[i + 1];
    }
    if (i < tcp_segment.len) {
        sum += @as(u32, tcp_segment[i]) << 8;
    }

    // Fold 32-bit sum to 16 bits
    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @as(u16, @truncate(~sum));
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "TCP Header layout and accessors" {
    var hdr = Header{
        .src_port = 0,
        .dst_port = 0,
        .seq_num = 0,
        .ack_num = 0,
        .data_offset_and_reserved = 0,
        .flags = 0,
        .window_size = 0,
        .checksum = 0,
        .urgent_ptr = 0,
    };

    try std.testing.expectEqual(@as(usize, 20), @sizeOf(Header));

    hdr.setSrcPort(8080);
    try std.testing.expectEqual(@as(u16, 8080), hdr.getSrcPort());

    hdr.setDstPort(443);
    try std.testing.expectEqual(@as(u16, 443), hdr.getDstPort());

    hdr.setSeqNum(0x12345678);
    try std.testing.expectEqual(@as(u32, 0x12345678), hdr.getSeqNum());

    hdr.setAckNum(0x9ABCDEF0);
    try std.testing.expectEqual(@as(u32, 0x9ABCDEF0), hdr.getAckNum());

    hdr.setDataOffset(5);
    try std.testing.expectEqual(@as(usize, 20), hdr.getDataOffset());

    hdr.setWindowSize(4096);
    try std.testing.expectEqual(@as(u16, 4096), hdr.getWindowSize());
}

test "TCP Flags and State enum" {
    try std.testing.expectEqual(@as(u8, 0x01), Flags.FIN);
    try std.testing.expectEqual(@as(u8, 0x02), Flags.SYN);
    try std.testing.expectEqual(@as(u8, 0x04), Flags.RST);
    try std.testing.expectEqual(@as(u8, 0x08), Flags.PSH);
    try std.testing.expectEqual(@as(u8, 0x10), Flags.ACK);
    try std.testing.expectEqual(@as(u8, 0x20), Flags.URG);

    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(State.closed));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(State.listen));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(State.syn_sent));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(State.syn_received));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(State.established));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(State.fin_wait_1));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(State.fin_wait_2));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(State.close_wait));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(State.last_ack));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(State.time_wait));
}

test "computeChecksum IPv6 verification and roundtrip" {
    const src_ip = [_]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0x02, 0x54, 0x00, 0xff, 0xfe, 0x12, 0x34, 0x56 };
    const dst_ip = [_]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0x02, 0x54, 0x00, 0xff, 0xfe, 0x78, 0x9a, 0xbc };

    var segment: [24]u8 = [_]u8{0} ** 24;
    // Dummy TCP header (20 bytes) + 4 bytes payload
    segment[0] = 0x1F; segment[1] = 0x90; // port 8080
    segment[2] = 0x00; segment[3] = 0x50; // port 80
    segment[4] = 0x00; segment[5] = 0x00; segment[6] = 0x00; segment[7] = 0x01; // seq = 1
    segment[12] = 0x50; // data offset 5 words
    segment[13] = Flags.SYN;
    segment[14] = 0x10; segment[15] = 0x00; // window 4096
    segment[20] = 'p'; segment[21] = 'i'; segment[22] = 'n'; segment[23] = 'g';

    const cksum = computeChecksum(&src_ip, &dst_ip, &segment);
    try std.testing.expect(cksum != 0);

    // Store checksum in segment
    segment[16] = @truncate(cksum >> 8);
    segment[17] = @truncate(cksum);

    // One's complement sum over segment with checksum included must fold to 0
    const verify = computeChecksum(&src_ip, &dst_ip, &segment);
    try std.testing.expectEqual(@as(u16, 0), verify);
}


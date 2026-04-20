const std = @import("std");
const pmm = @import("../kernel/pmm.zig");

pub const Ipv6Addr = extern struct {
    bytes: [16]u8,

    pub fn eql(a: Ipv6Addr, b: Ipv6Addr) bool {
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (a.bytes[i] != b.bytes[i]) return false;
        }
        return true;
    }

    pub fn loopback() Ipv6Addr {
        var out: Ipv6Addr = .{ .bytes = [_]u8{0} ** 16 };
        out.bytes[15] = 1;
        return out;
    }
};

pub const EndpointId = u64;

pub const Address = extern struct {
    node: Ipv6Addr,
    endpoint: EndpointId,
};

pub const WireVersion: u16 = 1;
pub const WireMagic: u32 = 0x44495043; // 'DIPC'

pub const PageHeader = extern struct {
    magic: u32,
    version: u16,
    header_len: u16,
    payload_len: u32,
    auth_tag: u64,
    src: Address,
    dst: Address,
};

pub const HEADER_SIZE: usize = @sizeOf(PageHeader);
pub const MAX_PAYLOAD: usize = pmm.PAGE_SIZE - HEADER_SIZE;

pub const AllocError = error{ OutOfMemory, PayloadTooLarge };

var auth_key: u64 = 0x7F91_52CD_44A2_E193;

fn u64le(value: u64) [8]u8 {
    return .{
        @as(u8, @truncate(value & 0xFF)),
        @as(u8, @truncate((value >> 8) & 0xFF)),
        @as(u8, @truncate((value >> 16) & 0xFF)),
        @as(u8, @truncate((value >> 24) & 0xFF)),
        @as(u8, @truncate((value >> 32) & 0xFF)),
        @as(u8, @truncate((value >> 40) & 0xFF)),
        @as(u8, @truncate((value >> 48) & 0xFF)),
        @as(u8, @truncate((value >> 56) & 0xFF)),
    };
}

fn u32le(value: u32) [4]u8 {
    return .{
        @as(u8, @truncate(value & 0xFF)),
        @as(u8, @truncate((value >> 8) & 0xFF)),
        @as(u8, @truncate((value >> 16) & 0xFF)),
        @as(u8, @truncate((value >> 24) & 0xFF)),
    };
}

pub fn setAuthKey(seed: u64) void {
    auth_key = if (seed == 0) 1 else seed;
}

pub fn computeAuthTag(src: Address, dst: Address, payload: []const u8) u64 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const key_bytes = u64le(auth_key);
    const payload_len_bytes = u32le(@as(u32, @intCast(payload.len)));

    hasher.update("DIPC-AUTH-V1");
    hasher.update(&key_bytes);
    hasher.update(std.mem.asBytes(&src));
    hasher.update(std.mem.asBytes(&dst));
    hasher.update(&payload_len_bytes);
    hasher.update(payload);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    const a = std.mem.readInt(u64, digest[0..8], .little);
    const b = std.mem.readInt(u64, digest[24..32], .little);
    return a ^ b;
}

pub fn verifyPageAuth(hhdm_offset: u64, page_phys: u64) bool {
    const hdr = headerFromPage(hhdm_offset, page_phys);
    if (hdr.magic != WireMagic or hdr.version != WireVersion) return false;
    if (@as(usize, hdr.header_len) != HEADER_SIZE) return false;
    if (@as(usize, hdr.payload_len) > MAX_PAYLOAD) return false;

    const payload_ptr: [*]const u8 = @ptrFromInt(page_phys + hhdm_offset + HEADER_SIZE);
    const payload = payload_ptr[0..@as(usize, hdr.payload_len)];
    const expected = computeAuthTag(hdr.src, hdr.dst, payload);
    return hdr.auth_tag == expected;
}

pub fn allocPageMessage(hhdm_offset: u64, src: Address, dst: Address, payload: []const u8) AllocError!u64 {
    if (payload.len > MAX_PAYLOAD) return error.PayloadTooLarge;

    const page_phys = pmm.allocPage() orelse return error.OutOfMemory;
    errdefer pmm.freePage(page_phys);

    const page_virt = page_phys + hhdm_offset;
    const hdr: *PageHeader = @ptrFromInt(page_virt);
    hdr.* = .{
        .magic = WireMagic,
        .version = WireVersion,
        .header_len = @as(u16, @intCast(HEADER_SIZE)),
        .payload_len = @as(u32, @intCast(payload.len)),
        .auth_tag = 0,
        .src = src,
        .dst = dst,
    };

    const payload_dst: [*]u8 = @ptrFromInt(page_virt + HEADER_SIZE);
    @memcpy(payload_dst[0..payload.len], payload);
    hdr.auth_tag = computeAuthTag(src, dst, payload);

    return page_phys;
}

pub fn headerFromPage(hhdm_offset: u64, page_phys: u64) *const PageHeader {
    const page_virt = page_phys + hhdm_offset;
    return @ptrFromInt(page_virt);
}

pub fn checkedPayloadSliceFromPage(hhdm_offset: u64, page_phys: u64) ?[]const u8 {
    const hdr = headerFromPage(hhdm_offset, page_phys);
    if (hdr.magic != WireMagic) return null;
    if (hdr.version != WireVersion) return null;
    if (@as(usize, hdr.header_len) != HEADER_SIZE) return null;

    const payload_len = @as(usize, hdr.payload_len);
    if (payload_len > MAX_PAYLOAD) return null;
    if (!verifyPageAuth(hhdm_offset, page_phys)) return null;

    const payload_ptr: [*]const u8 = @ptrFromInt(page_phys + hhdm_offset + HEADER_SIZE);
    return payload_ptr[0..payload_len];
}

pub fn payloadFromPage(hhdm_offset: u64, page_phys: u64) []const u8 {
    const hdr = headerFromPage(hhdm_offset, page_phys);
    const payload_len = @as(usize, hdr.payload_len);
    if (payload_len > MAX_PAYLOAD) return &[_]u8{};
    const payload_ptr: [*]const u8 = @ptrFromInt(page_phys + hhdm_offset + HEADER_SIZE);
    return payload_ptr[0..payload_len];
}

pub fn payloadSliceFromPage(hhdm_offset: u64, page_phys: u64) []const u8 {
    return checkedPayloadSliceFromPage(hhdm_offset, page_phys) orelse &[_]u8{};
}

pub fn freePageMessage(page_phys: u64) void {
    pmm.freePage(page_phys);
}

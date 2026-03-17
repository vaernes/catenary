const dipc = @import("../ipc/dipc.zig");
const identity = @import("../ipc/identity.zig");

pub const IngressDescriptorVersion: u16 = 1;
pub const IngressDescriptorMagic: u32 = 0x4D565154; // 'MVQT'

pub const DescriptorError = error{BadHeader};

// Shared kernel-side contract for handing a DIPC page to a local MicroVM transport.
// For now this is produced directly from the queued page handle; later phases can map it
// onto shared-memory doorbells or a user-space VMM service without changing the wire fields.
pub const IngressDescriptor = extern struct {
    magic: u32,
    version: u16,
    descriptor_len: u16,
    microvm_id: identity.MicrovmId,
    _reserved0: u32 = 0,
    page_phys: u64,
    payload_len: u32,
    _reserved1: u32 = 0,
    src: dipc.Address,
    dst: dipc.Address,
};

pub fn ingressDescriptorFromPage(
    hhdm_offset: u64,
    microvm_id: identity.MicrovmId,
    page_phys: u64,
) DescriptorError!IngressDescriptor {
    const hdr = dipc.headerFromPage(hhdm_offset, page_phys);
    if (hdr.magic != dipc.WireMagic or hdr.version != dipc.WireVersion) return error.BadHeader;
    if (!dipc.verifyPageAuth(hhdm_offset, page_phys)) return error.BadHeader;

    return .{
        .magic = IngressDescriptorMagic,
        .version = IngressDescriptorVersion,
        .descriptor_len = @as(u16, @intCast(@sizeOf(IngressDescriptor))),
        .microvm_id = microvm_id,
        .page_phys = page_phys,
        .payload_len = hdr.payload_len,
        .src = hdr.src,
        .dst = hdr.dst,
    };
}

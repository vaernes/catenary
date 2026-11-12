const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const MAX_VMS: usize = 8;
pub const TPM_CRB_MMIO_BASE: u64 = 0xFED4_0000;
pub const TPM_CRB_MMIO_SIZE: u64 = 0x1000;
pub const NUM_PCRS: usize = 24;
pub const MAX_SEALED_SIZE: usize = 32;
pub const CRB_DATA_BUFFER_OFFSET: u64 = 0x080;
pub const CRB_DATA_BUFFER_SIZE: usize = 0x400;

// TCG PC Client PTP CRB register offsets (Locality 0)
pub const REG_LOC_STATE: u64 = 0x000;
pub const REG_LOC_CTRL: u64 = 0x004;
pub const REG_LOC_STS: u64 = 0x008;
pub const REG_INTF_ID: u64 = 0x030;
pub const REG_CTRL_EXT: u64 = 0x038;
pub const REG_CTRL_REQ: u64 = 0x040;
pub const REG_CTRL_STS: u64 = 0x044;
pub const REG_CTRL_CANCEL: u64 = 0x048;
pub const REG_CTRL_START: u64 = 0x04C;
pub const REG_CTRL_INT_ENABLE: u64 = 0x050;
pub const REG_CTRL_INT_STS: u64 = 0x054;
pub const REG_CTRL_CMD_SIZE: u64 = 0x058;
pub const REG_CTRL_CMD_LADDR: u64 = 0x05C;
pub const REG_CTRL_CMD_HADDR: u64 = 0x060;
pub const REG_CTRL_RSP_SIZE: u64 = 0x064;
pub const REG_CTRL_RSP_LADDR: u64 = 0x068;
pub const REG_CTRL_RSP_HADDR: u64 = 0x06C;

// TPM 2.0 Tags, Command Codes, and Response Codes
pub const TPM_ST_NO_SESSIONS: u16 = 0x8001;
pub const TPM_ST_SESSIONS: u16 = 0x8002;

pub const TPM_CC_STARTUP: u32 = 0x0000_0144;
pub const TPM_CC_SELF_TEST: u32 = 0x0000_0143;
pub const TPM_CC_GET_CAPABILITY: u32 = 0x0000_017A;
pub const TPM_CC_PCR_EXTEND: u32 = 0x0000_0182;
pub const TPM_CC_PCR_READ: u32 = 0x0000_017E;
pub const TPM_CC_CREATE: u32 = 0x0000_0153;
pub const TPM_CC_UNSEAL: u32 = 0x0000_015E;

pub const TPM_SU_CLEAR: u16 = 0x0000;
pub const TPM_SU_STATE: u16 = 0x0001;

pub const TPM_RC_SUCCESS: u32 = 0x0000_0000;
pub const TPM_RC_INITIALIZE: u32 = 0x0000_0100;
pub const TPM_RC_FAILURE: u32 = 0x0000_0101;
pub const TPM_RC_COMMAND_CODE: u32 = 0x0000_0143;
pub const TPM_RC_COMMAND_SIZE: u32 = 0x0000_0142;
pub const TPM_RC_VALUE: u32 = 0x0000_0184;
pub const TPM_RC_POLICY_FAIL: u32 = 0x0000_019D;

pub const VmTpmState = struct {
    started: bool = false,
    selftest_passed: bool = false,
    locality_active: bool = true,
    ctrl_req: u32 = 0,
    ctrl_sts: u32 = 0, // bit 0 = tpmSts, bit 1 = tpmIdle
    ctrl_start: u32 = 0,
    pcrs: [NUM_PCRS][32]u8 = @splat(@splat(0)),
    data_buffer: [CRB_DATA_BUFFER_SIZE]u8 = @splat(0),

    // Persistent NV state across warm reboots
    has_sealed_object: bool = false,
    sealed_pcr0_digest: [32]u8 = @splat(0),
    sealed_secret: [MAX_SEALED_SIZE]u8 = @splat(0),
    sealed_secret_len: u16 = 0,
    nv_monotonic_counter: u64 = 0,

    pub fn writeResponseHeader(self: *VmTpmState, tag: u16, size: u32, rc: u32) void {
        std.mem.writeInt(u16, self.data_buffer[0..2], tag, .big);
        std.mem.writeInt(u32, self.data_buffer[2..6], size, .big);
        std.mem.writeInt(u32, self.data_buffer[6..10], rc, .big);
    }

    pub fn executeCommand(self: *VmTpmState) void {
        const tag = std.mem.readInt(u16, self.data_buffer[0..2], .big);
        const cmd_size = std.mem.readInt(u32, self.data_buffer[2..6], .big);
        const cc = std.mem.readInt(u32, self.data_buffer[6..10], .big);

        if ((tag != TPM_ST_NO_SESSIONS and tag != TPM_ST_SESSIONS) or
            cmd_size < 10 or cmd_size > CRB_DATA_BUFFER_SIZE)
        {
            self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_COMMAND_SIZE);
            return;
        }

        if (cc == TPM_CC_STARTUP) {
            if (cmd_size < 12) {
                self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_COMMAND_SIZE);
                return;
            }
            const startup_type = std.mem.readInt(u16, self.data_buffer[10..12], .big);
            if (startup_type == TPM_SU_CLEAR) {
                self.pcrs = @splat(@splat(0));
            }
            self.started = true;
            self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_SUCCESS);
            return;
        }

        if (!self.started) {
            self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_INITIALIZE);
            return;
        }

        switch (cc) {
            TPM_CC_SELF_TEST => {
                self.selftest_passed = true;
                self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_SUCCESS);
            },
            TPM_CC_GET_CAPABILITY => {
                // Return TPM2.0 PT_FAMILY_INDICATOR "2.0\0" and monotonic counter low 32 bits
                self.writeResponseHeader(TPM_ST_NO_SESSIONS, 18, TPM_RC_SUCCESS);
                std.mem.writeInt(u32, self.data_buffer[10..14], 0x322E_3000, .big); // "2.0\0"
                std.mem.writeInt(u32, self.data_buffer[14..18], @truncate(self.nv_monotonic_counter), .big);
            },
            TPM_CC_PCR_EXTEND => {
                // Layout: [0..10] header, [10..14] pcr_index (BE u32), [14..46] 32-byte digest
                if (cmd_size < 46) {
                    self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_COMMAND_SIZE);
                    return;
                }
                const pcr_idx = std.mem.readInt(u32, self.data_buffer[10..14], .big);
                if (pcr_idx >= NUM_PCRS) {
                    self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_VALUE);
                    return;
                }
                var hasher = Sha256.init(.{});
                hasher.update(&self.pcrs[pcr_idx]);
                hasher.update(self.data_buffer[14..46]);
                hasher.final(&self.pcrs[pcr_idx]);
                self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_SUCCESS);
            },
            TPM_CC_PCR_READ => {
                // Layout: [0..10] header, [10..14] pcr_index (BE u32)
                // Response: [0..10] header, [10..42] 32-byte PCR digest
                if (cmd_size < 14) {
                    self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_COMMAND_SIZE);
                    return;
                }
                const pcr_idx = std.mem.readInt(u32, self.data_buffer[10..14], .big);
                if (pcr_idx >= NUM_PCRS) {
                    self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_VALUE);
                    return;
                }
                self.writeResponseHeader(TPM_ST_NO_SESSIONS, 42, TPM_RC_SUCCESS);
                @memcpy(self.data_buffer[10..42], &self.pcrs[pcr_idx]);
            },
            TPM_CC_CREATE => {
                // Seal secret to current PCR[0] digest.
                // Layout: [0..10] header, [10..12] secret_len (BE u16), [12..12+secret_len] secret
                if (cmd_size < 12) {
                    self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_COMMAND_SIZE);
                    return;
                }
                const secret_len = std.mem.readInt(u16, self.data_buffer[10..12], .big);
                if (secret_len == 0 or secret_len > MAX_SEALED_SIZE or cmd_size < 12 + @as(u32, secret_len)) {
                    self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_VALUE);
                    return;
                }
                self.sealed_pcr0_digest = self.pcrs[0];
                self.sealed_secret = @splat(0);
                @memcpy(self.sealed_secret[0..secret_len], self.data_buffer[12 .. 12 + secret_len]);
                self.sealed_secret_len = secret_len;
                self.has_sealed_object = true;
                self.nv_monotonic_counter +%= 1;
                self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_SUCCESS);
            },
            TPM_CC_UNSEAL => {
                if (!self.has_sealed_object) {
                    self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_VALUE);
                    return;
                }
                if (!std.mem.eql(u8, &self.pcrs[0], &self.sealed_pcr0_digest)) {
                    self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_POLICY_FAIL);
                    return;
                }
                const len: usize = self.sealed_secret_len;
                const rsp_size: u32 = @intCast(12 + len);
                self.writeResponseHeader(TPM_ST_NO_SESSIONS, rsp_size, TPM_RC_SUCCESS);
                std.mem.writeInt(u16, self.data_buffer[10..12], self.sealed_secret_len, .big);
                @memcpy(self.data_buffer[12 .. 12 + len], self.sealed_secret[0..len]);
            },
            else => {
                self.writeResponseHeader(TPM_ST_NO_SESSIONS, 10, TPM_RC_COMMAND_CODE);
            },
        }
    }
};

pub const MAX_SNAPSHOTS: usize = 4;

var vtpm_states: [MAX_VMS]VmTpmState = @splat(.{});
var vtpm_snapshots: [MAX_VMS][MAX_SNAPSHOTS]VmTpmState = @splat(@splat(.{}));

pub fn checkpointState(vmid: u32, generation: u32) bool {
    const idx = slotIndex(vmid) orelse return false;
    if (generation == 0 or generation > MAX_SNAPSHOTS) return false;
    const snap_idx = @as(usize, generation - 1);
    vtpm_snapshots[idx][snap_idx] = vtpm_states[idx];
    return true;
}

pub fn restoreStateFromCheckpoint(vmid: u32, generation: u32) bool {
    const idx = slotIndex(vmid) orelse return false;
    if (generation == 0 or generation > MAX_SNAPSHOTS) return false;
    const snap_idx = @as(usize, generation - 1);
    const snap = vtpm_snapshots[idx][snap_idx];
    vtpm_states[idx] = snap;
    return true;
}

fn slotIndex(vmid: u32) ?usize {
    if (vmid == 0 or vmid > MAX_VMS) return null;
    return @as(usize, vmid - 1);
}

pub fn getState(vmid: u32) ?*VmTpmState {
    const idx = slotIndex(vmid) orelse return null;
    return &vtpm_states[idx];
}

pub fn resetForReboot(vmid: u32) void {
    const st = getState(vmid) orelse return;
    // Preserve persistent NV sealed state and monotonic counter; clear volatile PCRs and startup state
    st.started = false;
    st.selftest_passed = false;
    st.ctrl_start = 0;
    st.pcrs = @splat(@splat(0));
    st.data_buffer = @splat(0);
}

pub fn resetInstance(vmid: u32) void {
    const st = getState(vmid) orelse return;
    st.* = .{};
}

pub fn mmioRead(vmid: u32, offset: u64) u32 {
    const st = getState(vmid) orelse return 0;
    if (offset >= CRB_DATA_BUFFER_OFFSET and offset + 4 <= CRB_DATA_BUFFER_OFFSET + CRB_DATA_BUFFER_SIZE) {
        const buf_off: usize = @intCast(offset - CRB_DATA_BUFFER_OFFSET);
        return std.mem.readInt(u32, st.data_buffer[buf_off..][0..4], .little);
    }
    return switch (offset) {
        // tpmEstablished (bit 0) | locAssigned (bit 1) | tpmRegValidSts (bit 7)
        REG_LOC_STATE => 0x0000_0083,
        // Granted (bit 0)
        REG_LOC_STS => if (st.locality_active) 0x0000_0001 else 0x0000_0000,
        // InterfaceType = 1 (CRB), InterfaceVersion = 1, CapCRB = 1
        REG_INTF_ID => 0x0000_4011,
        REG_CTRL_REQ => st.ctrl_req,
        REG_CTRL_STS => st.ctrl_sts,
        REG_CTRL_START => st.ctrl_start,
        REG_CTRL_CMD_SIZE => @intCast(CRB_DATA_BUFFER_SIZE),
        REG_CTRL_CMD_LADDR => @truncate(TPM_CRB_MMIO_BASE + CRB_DATA_BUFFER_OFFSET),
        REG_CTRL_CMD_HADDR => 0,
        REG_CTRL_RSP_SIZE => @intCast(CRB_DATA_BUFFER_SIZE),
        REG_CTRL_RSP_LADDR => @truncate(TPM_CRB_MMIO_BASE + CRB_DATA_BUFFER_OFFSET),
        REG_CTRL_RSP_HADDR => 0,
        else => 0,
    };
}

pub fn mmioWrite(vmid: u32, offset: u64, value: u32) void {
    const st = getState(vmid) orelse return;
    if (offset >= CRB_DATA_BUFFER_OFFSET and offset + 4 <= CRB_DATA_BUFFER_OFFSET + CRB_DATA_BUFFER_SIZE) {
        const buf_off: usize = @intCast(offset - CRB_DATA_BUFFER_OFFSET);
        std.mem.writeInt(u32, st.data_buffer[buf_off..][0..4], value, .little);
        return;
    }
    switch (offset) {
        REG_LOC_CTRL => {
            if ((value & 1) != 0) st.locality_active = true;
            if ((value & 2) != 0) st.locality_active = false;
        },
        REG_CTRL_REQ => {
            // cmdReady (bit 0) clears tpmIdle; goIdle (bit 1) sets tpmIdle
            if ((value & 1) != 0) st.ctrl_sts &= ~@as(u32, 2);
            if ((value & 2) != 0) st.ctrl_sts |= 2;
            st.ctrl_req = 0;
        },
        REG_CTRL_START => {
            if ((value & 1) != 0) {
                st.ctrl_start = 1;
                st.executeCommand();
                st.ctrl_start = 0;
            }
        },
        else => {},
    }
}

fn submitTpmCmd(vmid: u32, cmd: []const u8) u32 {
    const st = getState(vmid).?;
    st.data_buffer = @splat(0);
    @memcpy(st.data_buffer[0..cmd.len], cmd);
    mmioWrite(vmid, REG_CTRL_START, 1);
    return std.mem.readInt(u32, st.data_buffer[6..10], .big);
}

test "vtpm: Startup, SelfTest, PCR0 extend, Seal, Unseal, and PCR mismatch rejection" {
    resetInstance(1);

    // 1. Command before TPM2_Startup fails with TPM_RC_INITIALIZE
    var selftest_cmd: [11]u8 = undefined;
    std.mem.writeInt(u16, selftest_cmd[0..2], TPM_ST_NO_SESSIONS, .big);
    std.mem.writeInt(u32, selftest_cmd[2..6], 11, .big);
    std.mem.writeInt(u32, selftest_cmd[6..10], TPM_CC_SELF_TEST, .big);
    selftest_cmd[10] = 1;
    try std.testing.expectEqual(TPM_RC_INITIALIZE, submitTpmCmd(1, &selftest_cmd));

    // 2. TPM2_Startup(TPM_SU_CLEAR)
    var startup_cmd: [12]u8 = undefined;
    std.mem.writeInt(u16, startup_cmd[0..2], TPM_ST_NO_SESSIONS, .big);
    std.mem.writeInt(u32, startup_cmd[2..6], 12, .big);
    std.mem.writeInt(u32, startup_cmd[6..10], TPM_CC_STARTUP, .big);
    std.mem.writeInt(u16, startup_cmd[10..12], TPM_SU_CLEAR, .big);
    try std.testing.expectEqual(TPM_RC_SUCCESS, submitTpmCmd(1, &startup_cmd));

    // 3. TPM2_SelfTest
    try std.testing.expectEqual(TPM_RC_SUCCESS, submitTpmCmd(1, &selftest_cmd));

    // 4. TPM2_PCR_Extend PCR[0] with deterministic measurement
    var extend_cmd: [46]u8 = @splat(0);
    std.mem.writeInt(u16, extend_cmd[0..2], TPM_ST_SESSIONS, .big);
    std.mem.writeInt(u32, extend_cmd[2..6], 46, .big);
    std.mem.writeInt(u32, extend_cmd[6..10], TPM_CC_PCR_EXTEND, .big);
    std.mem.writeInt(u32, extend_cmd[10..14], 0, .big); // PCR 0
    @memset(extend_cmd[14..46], 0xA5);
    try std.testing.expectEqual(TPM_RC_SUCCESS, submitTpmCmd(1, &extend_cmd));

    // Verify PCR[0] = SHA256(0^32 || 0xA5^32)
    var expected_pcr0: [32]u8 = undefined;
    var h = Sha256.init(.{});
    const zeros: [32]u8 = @splat(0);
    const a5s: [32]u8 = @splat(0xA5);
    h.update(&zeros);
    h.update(&a5s);
    h.final(&expected_pcr0);

    var pcr_read_cmd: [14]u8 = undefined;
    std.mem.writeInt(u16, pcr_read_cmd[0..2], TPM_ST_NO_SESSIONS, .big);
    std.mem.writeInt(u32, pcr_read_cmd[2..6], 14, .big);
    std.mem.writeInt(u32, pcr_read_cmd[6..10], TPM_CC_PCR_READ, .big);
    std.mem.writeInt(u32, pcr_read_cmd[10..14], 0, .big);
    try std.testing.expectEqual(TPM_RC_SUCCESS, submitTpmCmd(1, &pcr_read_cmd));
    const st = getState(1).?;
    try std.testing.expectEqualSlices(u8, &expected_pcr0, st.data_buffer[10..42]);

    // 5. TPM2_Create (Seal 8-byte secret "VMK-2026" to current PCR[0])
    var create_cmd: [20]u8 = undefined;
    std.mem.writeInt(u16, create_cmd[0..2], TPM_ST_SESSIONS, .big);
    std.mem.writeInt(u32, create_cmd[2..6], 20, .big);
    std.mem.writeInt(u32, create_cmd[6..10], TPM_CC_CREATE, .big);
    std.mem.writeInt(u16, create_cmd[10..12], 8, .big);
    @memcpy(create_cmd[12..20], "VMK-2026");
    try std.testing.expectEqual(TPM_RC_SUCCESS, submitTpmCmd(1, &create_cmd));

    // 6. TPM2_Unseal succeeds while PCR[0] matches policy
    var unseal_cmd: [10]u8 = undefined;
    std.mem.writeInt(u16, unseal_cmd[0..2], TPM_ST_SESSIONS, .big);
    std.mem.writeInt(u32, unseal_cmd[2..6], 10, .big);
    std.mem.writeInt(u32, unseal_cmd[6..10], TPM_CC_UNSEAL, .big);
    try std.testing.expectEqual(TPM_RC_SUCCESS, submitTpmCmd(1, &unseal_cmd));
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, st.data_buffer[10..12], .big));
    try std.testing.expectEqualStrings("VMK-2026", st.data_buffer[12..20]);

    // 7. Extend PCR[0] again; TPM2_Unseal now fails closed with TPM_RC_POLICY_FAIL
    try std.testing.expectEqual(TPM_RC_SUCCESS, submitTpmCmd(1, &extend_cmd));
    try std.testing.expectEqual(TPM_RC_POLICY_FAIL, submitTpmCmd(1, &unseal_cmd));
}

const std = @import("std");

pub const MAX_PORTS: usize = 32;
pub const MAX_RULES_PER_DIRECTION: usize = 16;
pub const MAX_FRAME_SIZE: usize = 1514;
pub const MAX_DELIVERIES: usize = MAX_PORTS;
const ZERO_MAC: [6]u8 = @splat(0);

pub const SegmentId = u64;
pub const PortId = u32;
pub const AttachmentGeneration = u64;

pub const IpVersion = enum(u8) {
    ipv4 = 4,
    ipv6 = 6,
};

pub const Rule = struct {
    ip_version: IpVersion,
    protocol: u8,
    destination: [16]u8,
    destination_port_first: u16,
    destination_port_last: u16,
};

pub const Policy = struct {
    ingress: [MAX_RULES_PER_DIRECTION]Rule = undefined,
    ingress_count: u8 = 0,
    egress: [MAX_RULES_PER_DIRECTION]Rule = undefined,
    egress_count: u8 = 0,
};

pub const PortConfig = struct {
    id: PortId,
    segment: SegmentId,
    mac: [6]u8,
    ipv4_addresses: [4][4]u8 = @splat(@splat(0)),
    ipv4_count: u8 = 0,
    ipv6_addresses: [4][16]u8 = @splat(@splat(0)),
    ipv6_count: u8 = 0,
    policy: Policy = .{},
};

pub const Delivery = struct {
    port_id: PortId,
    generation: AttachmentGeneration,
};

pub const DropReason = enum {
    none,
    unknown_source,
    stale_generation,
    malformed_frame,
    spoofed_mac,
    unauthorized_source_address,
    unsupported_packet,
    egress_denied,
    no_eligible_destination,
};

pub const Decision = struct {
    deliveries: [MAX_DELIVERIES]Delivery = undefined,
    count: usize = 0,
    drop_reason: DropReason = .none,
};

const Port = struct {
    active: bool = false,
    generation: AttachmentGeneration = 0,
    policy_revision: u64 = 0,
    config: PortConfig = undefined,
};

const ParsedFrame = struct {
    destination_mac: [6]u8,
    ip_version: IpVersion,
    source_ip: [16]u8,
    destination_ip: [16]u8,
    protocol: u8,
    destination_port: u16,
};

pub const Switch = struct {
    ports: [MAX_PORTS]Port = @splat(.{}),

    pub fn attach(self: *Switch, config: PortConfig) ?AttachmentGeneration {
        if (config.id == 0 or config.segment == 0) return null;
        if (!isUnicastMac(&config.mac) or config.ipv4_count > config.ipv4_addresses.len or
            config.ipv6_count > config.ipv6_addresses.len or
            config.policy.ingress_count > MAX_RULES_PER_DIRECTION or
            config.policy.egress_count > MAX_RULES_PER_DIRECTION or
            !validAddresses(&config) or !validPolicy(config.policy))
        {
            return null;
        }

        var free_slot: ?usize = null;
        for (&self.ports, 0..) |*port, idx| {
            if (port.active) {
                if (port.config.id == config.id) return null;
                if (port.config.segment == config.segment and std.mem.eql(u8, &port.config.mac, &config.mac)) return null;
                if (port.config.segment == config.segment and addressBindingConflicts(&port.config, &config)) return null;
            } else if (free_slot == null) {
                free_slot = idx;
            }
        }

        const idx = free_slot orelse return null;
        const next_generation = std.math.add(AttachmentGeneration, self.ports[idx].generation, 1) catch return null;
        self.ports[idx] = .{
            .active = true,
            .generation = next_generation,
            .policy_revision = 1,
            .config = config,
        };
        return next_generation;
    }

    pub fn detach(self: *Switch, id: PortId, generation: AttachmentGeneration) bool {
        const port = self.findPort(id) orelse return false;
        if (port.generation != generation) return false;
        port.generation = std.math.add(AttachmentGeneration, port.generation, 1) catch return false;
        port.active = false;
        return true;
    }

    pub fn replacePolicy(
        self: *Switch,
        id: PortId,
        generation: AttachmentGeneration,
        expected_revision: u64,
        policy: Policy,
    ) ?u64 {
        if (policy.ingress_count > MAX_RULES_PER_DIRECTION or
            policy.egress_count > MAX_RULES_PER_DIRECTION or !validPolicy(policy))
        {
            return null;
        }
        const port = self.findPort(id) orelse return null;
        if (port.generation != generation or port.policy_revision != expected_revision) return null;
        const next_revision = std.math.add(u64, port.policy_revision, 1) catch return null;
        port.config.policy = policy;
        port.policy_revision = next_revision;
        return next_revision;
    }

    pub fn policyRevision(self: *const Switch, id: PortId, generation: AttachmentGeneration) ?u64 {
        const port = self.findPortConst(id) orelse return null;
        if (port.generation != generation) return null;
        return port.policy_revision;
    }

    pub fn currentGeneration(self: *const Switch, id: PortId) ?AttachmentGeneration {
        const port = self.findPortConst(id) orelse return null;
        return port.generation;
    }

    pub fn decide(
        self: *const Switch,
        source_id: PortId,
        source_generation: AttachmentGeneration,
        frame: []const u8,
    ) Decision {
        const source = self.findPortConst(source_id) orelse return .{ .drop_reason = .unknown_source };
        if (source.generation != source_generation) return .{ .drop_reason = .stale_generation };
        const parsed = parseFrame(frame) orelse return .{ .drop_reason = .malformed_frame };
        if (!std.mem.eql(u8, frame[6..12], &source.config.mac)) return .{ .drop_reason = .spoofed_mac };
        if (!sourceOwnsAddress(&source.config, parsed.ip_version, &parsed.source_ip)) {
            return .{ .drop_reason = .unauthorized_source_address };
        }
        if (!matchesRules(source.config.policy.egress[0..source.config.policy.egress_count], parsed)) {
            return .{ .drop_reason = .egress_denied };
        }

        var result: Decision = .{};
        for (&self.ports) |*candidate| {
            if (!candidate.active or candidate.config.id == source_id or
                candidate.config.segment != source.config.segment)
            {
                continue;
            }
            if (!isMulticastMac(&parsed.destination_mac) and
                !std.mem.eql(u8, &parsed.destination_mac, &candidate.config.mac) and
                hasUnicastDestination(self, source.config.segment, &parsed.destination_mac))
            {
                continue;
            }
            if (!destinationOwnsAddress(&candidate.config, parsed.ip_version, &parsed.destination_ip)) continue;
            if (!matchesRules(candidate.config.policy.ingress[0..candidate.config.policy.ingress_count], parsed)) continue;
            if (result.count == result.deliveries.len) break;
            result.deliveries[result.count] = .{
                .port_id = candidate.config.id,
                .generation = candidate.generation,
            };
            result.count += 1;
        }
        if (result.count == 0) result.drop_reason = .no_eligible_destination;
        return result;
    }

    fn findPort(self: *Switch, id: PortId) ?*Port {
        for (&self.ports) |*port| {
            if (port.active and port.config.id == id) return port;
        }
        return null;
    }

    fn findPortConst(self: *const Switch, id: PortId) ?*const Port {
        for (&self.ports) |*port| {
            if (port.active and port.config.id == id) return port;
        }
        return null;
    }

    fn hasUnicastDestination(self: *const Switch, segment: SegmentId, mac: *const [6]u8) bool {
        for (&self.ports) |*port| {
            if (port.active and port.config.segment == segment and std.mem.eql(u8, &port.config.mac, mac)) return true;
        }
        return false;
    }
};

fn isUnicastMac(mac: *const [6]u8) bool {
    return mac[0] & 1 == 0 and !isZeroMac(mac);
}

fn isMulticastMac(mac: *const [6]u8) bool {
    return mac[0] & 1 != 0;
}

fn isZeroMac(mac: *const [6]u8) bool {
    return std.mem.eql(u8, mac, &ZERO_MAC);
}

fn validAddresses(config: *const PortConfig) bool {
    for (config.ipv4_addresses[0..config.ipv4_count], 0..) |*address, idx| {
        if (std.mem.allEqual(u8, address, 0)) return false;
        for (config.ipv4_addresses[0..idx]) |*previous| {
            if (std.mem.eql(u8, address, previous)) return false;
        }
    }
    for (config.ipv6_addresses[0..config.ipv6_count], 0..) |*address, idx| {
        if (std.mem.allEqual(u8, address, 0)) return false;
        for (config.ipv6_addresses[0..idx]) |*previous| {
            if (std.mem.eql(u8, address, previous)) return false;
        }
    }
    return true;
}

fn validPolicy(policy: Policy) bool {
    for (policy.ingress[0..policy.ingress_count]) |rule| {
        if (!validRule(rule)) return false;
    }
    for (policy.egress[0..policy.egress_count]) |rule| {
        if (!validRule(rule)) return false;
    }
    return true;
}

fn validRule(rule: Rule) bool {
    if ((rule.protocol != 6 and rule.protocol != 17) or
        rule.destination_port_first > rule.destination_port_last)
    {
        return false;
    }
    if (rule.ip_version == .ipv4 and !std.mem.allEqual(u8, rule.destination[4..], 0)) return false;
    return true;
}

fn addressBindingConflicts(existing: *const PortConfig, new: *const PortConfig) bool {
    for (existing.ipv4_addresses[0..existing.ipv4_count]) |*old_address| {
        for (new.ipv4_addresses[0..new.ipv4_count]) |*new_address| {
            if (std.mem.eql(u8, old_address, new_address)) return true;
        }
    }
    for (existing.ipv6_addresses[0..existing.ipv6_count]) |*old_address| {
        for (new.ipv6_addresses[0..new.ipv6_count]) |*new_address| {
            if (std.mem.eql(u8, old_address, new_address)) return true;
        }
    }
    return false;
}

fn parseFrame(frame: []const u8) ?ParsedFrame {
    if (frame.len < 14 or frame.len > MAX_FRAME_SIZE) return null;
    const ether_type = std.mem.readInt(u16, frame[12..14], .big);
    const payload = frame[14..];

    return switch (ether_type) {
        0x0800 => parseIpv4(frame[0..6], payload),
        0x86DD => parseIpv6(frame[0..6], payload),
        else => null,
    };
}

fn parseIpv4(destination_mac: []const u8, packet: []const u8) ?ParsedFrame {
    if (packet.len < 20 or packet[0] >> 4 != 4) return null;
    const header_len = @as(usize, packet[0] & 0x0F) * 4;
    const total_len = std.mem.readInt(u16, packet[2..4], .big);
    if (header_len < 20 or total_len < header_len + 4 or total_len > packet.len) return null;
    const fragment = std.mem.readInt(u16, packet[6..8], .big);
    if (fragment & 0x3FFF != 0) return null;

    const protocol = packet[9];
    const transport = packet[header_len..total_len];
    const destination_port = parseTransportDestinationPort(protocol, transport) orelse return null;
    var source_ip: [16]u8 = @splat(0);
    var destination_ip: [16]u8 = @splat(0);
    @memcpy(source_ip[0..4], packet[12..16]);
    @memcpy(destination_ip[0..4], packet[16..20]);
    return .{
        .destination_mac = destination_mac[0..6].*,
        .ip_version = .ipv4,
        .source_ip = source_ip,
        .destination_ip = destination_ip,
        .protocol = protocol,
        .destination_port = destination_port,
    };
}

fn parseIpv6(destination_mac: []const u8, packet: []const u8) ?ParsedFrame {
    if (packet.len < 40 or packet[0] >> 4 != 6) return null;
    const payload_len = std.mem.readInt(u16, packet[4..6], .big);
    if (@as(usize, payload_len) + 40 > packet.len) return null;
    const protocol = packet[6];
    if (protocol != 6 and protocol != 17) return null;
    const transport = packet[40 .. 40 + payload_len];
    const destination_port = parseTransportDestinationPort(protocol, transport) orelse return null;
    var source_ip: [16]u8 = undefined;
    var destination_ip: [16]u8 = undefined;
    @memcpy(&source_ip, packet[8..24]);
    @memcpy(&destination_ip, packet[24..40]);
    return .{
        .destination_mac = destination_mac[0..6].*,
        .ip_version = .ipv6,
        .source_ip = source_ip,
        .destination_ip = destination_ip,
        .protocol = protocol,
        .destination_port = destination_port,
    };
}

fn parseTransportDestinationPort(protocol: u8, transport: []const u8) ?u16 {
    if (protocol == 6) {
        if (transport.len < 20) return null;
        const header_len = @as(usize, transport[12] >> 4) * 4;
        if (header_len < 20 or header_len > transport.len) return null;
    } else if (protocol == 17) {
        if (transport.len < 8) return null;
        const udp_len = std.mem.readInt(u16, transport[4..6], .big);
        if (udp_len < 8 or udp_len > transport.len) return null;
    } else {
        return null;
    }
    return std.mem.readInt(u16, transport[2..4], .big);
}

fn sourceOwnsAddress(port: *const PortConfig, version: IpVersion, address: *const [16]u8) bool {
    return switch (version) {
        .ipv4 => blk: {
            for (port.ipv4_addresses[0..port.ipv4_count]) |*candidate| {
                if (std.mem.eql(u8, candidate, address[0..4])) break :blk true;
            }
            break :blk false;
        },
        .ipv6 => blk: {
            for (port.ipv6_addresses[0..port.ipv6_count]) |*candidate| {
                if (std.mem.eql(u8, candidate, address)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn destinationOwnsAddress(port: *const PortConfig, version: IpVersion, address: *const [16]u8) bool {
    return sourceOwnsAddress(port, version, address);
}

fn matchesRules(rules: []const Rule, parsed: ParsedFrame) bool {
    for (rules) |rule| {
        if (rule.ip_version == parsed.ip_version and rule.protocol == parsed.protocol and
            std.mem.eql(u8, &rule.destination, &parsed.destination_ip) and
            parsed.destination_port >= rule.destination_port_first and
            parsed.destination_port <= rule.destination_port_last)
        {
            return true;
        }
    }
    return false;
}

test "dual-stack policy requires source egress and destination ingress" {
    var switcher: Switch = .{};
    const source_mac = [_]u8{ 0x02, 0, 0, 0, 0, 1 };
    const target_mac = [_]u8{ 0x02, 0, 0, 0, 0, 2 };
    const source4 = [_]u8{ 10, 0, 0, 1 };
    const target4 = [_]u8{ 10, 0, 0, 2 };
    const source6 = [_]u8{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const target6 = [_]u8{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
    const source_v4_wide = ip4Wide(source4);
    const target_v4_wide = ip4Wide(target4);
    var source_policy: Policy = .{};
    source_policy.egress[0] = .{ .ip_version = .ipv4, .protocol = 17, .destination = target_v4_wide, .destination_port_first = 53, .destination_port_last = 53 };
    source_policy.egress[1] = .{ .ip_version = .ipv6, .protocol = 17, .destination = target6, .destination_port_first = 53, .destination_port_last = 53 };
    source_policy.egress_count = 2;
    var target_policy: Policy = .{};
    target_policy.ingress[0] = .{ .ip_version = .ipv4, .protocol = 17, .destination = target_v4_wide, .destination_port_first = 53, .destination_port_last = 53 };
    target_policy.ingress[1] = .{ .ip_version = .ipv6, .protocol = 17, .destination = target6, .destination_port_first = 53, .destination_port_last = 53 };
    target_policy.ingress_count = 2;
    const source_generation = switcher.attach(.{
        .id = 1,
        .segment = 7,
        .mac = source_mac,
        .ipv4_addresses = @as([4][4]u8, .{ source4, @splat(0), @splat(0), @splat(0) }),
        .ipv4_count = 1,
        .ipv6_addresses = @as([4][16]u8, .{ source6, @splat(0), @splat(0), @splat(0) }),
        .ipv6_count = 1,
        .policy = source_policy,
    }) orelse return error.TestUnexpectedResult;
    const target_generation = switcher.attach(.{
        .id = 2,
        .segment = 7,
        .mac = target_mac,
        .ipv4_addresses = @as([4][4]u8, .{ target4, @splat(0), @splat(0), @splat(0) }),
        .ipv4_count = 1,
        .ipv6_addresses = @as([4][16]u8, .{ target6, @splat(0), @splat(0), @splat(0) }),
        .ipv6_count = 1,
        .policy = target_policy,
    }) orelse return error.TestUnexpectedResult;

    const ipv4_frame = buildUdpFrame(source_mac, target_mac, 0x0800, &source_v4_wide, &target_v4_wide, 17);
    const ipv4_decision = switcher.decide(1, source_generation, &ipv4_frame);
    try std.testing.expectEqual(@as(usize, 1), ipv4_decision.count);
    try std.testing.expectEqual(@as(PortId, 2), ipv4_decision.deliveries[0].port_id);
    try std.testing.expectEqual(target_generation, ipv4_decision.deliveries[0].generation);

    const ipv6_frame = buildUdpFrame(source_mac, target_mac, 0x86DD, &source6, &target6, 17);
    const ipv6_decision = switcher.decide(1, source_generation, &ipv6_frame);
    try std.testing.expectEqual(@as(usize, 1), ipv6_decision.count);

    try std.testing.expectEqual(
        @as(?u64, 2),
        switcher.replacePolicy(2, target_generation, 1, .{}),
    );
    try std.testing.expectEqual(
        DropReason.no_eligible_destination,
        switcher.decide(1, source_generation, &ipv4_frame).drop_reason,
    );
    try std.testing.expectEqual(
        @as(?u64, 3),
        switcher.replacePolicy(2, target_generation, 2, target_policy),
    );

    var denied_source = ipv4_frame;
    denied_source[26] = 9;
    try std.testing.expectEqual(DropReason.unauthorized_source_address, switcher.decide(1, source_generation, &denied_source).drop_reason);

    var spoofed_mac = ipv4_frame;
    spoofed_mac[11] ^= 1;
    try std.testing.expectEqual(DropReason.spoofed_mac, switcher.decide(1, source_generation, &spoofed_mac).drop_reason);

    var fragmented = ipv4_frame;
    std.mem.writeInt(u16, fragmented[20..22], 0x2000, .big);
    try std.testing.expectEqual(DropReason.malformed_frame, switcher.decide(1, source_generation, &fragmented).drop_reason);

    try std.testing.expectEqual(DropReason.stale_generation, switcher.decide(1, source_generation + 1, &ipv4_frame).drop_reason);
    try std.testing.expect(switcher.detach(2, target_generation));
    try std.testing.expectEqual(DropReason.no_eligible_destination, switcher.decide(1, source_generation, &ipv4_frame).drop_reason);

    try std.testing.expectEqual(@as(?u64, 1), switcher.policyRevision(1, source_generation));
    try std.testing.expectEqual(@as(?u64, 2), switcher.replacePolicy(1, source_generation, 1, .{}));
    try std.testing.expectEqual(DropReason.egress_denied, switcher.decide(1, source_generation, &ipv4_frame).drop_reason);

    const conflicting_address = switcher.attach(.{
        .id = 3,
        .segment = 7,
        .mac = [_]u8{ 0x02, 0, 0, 0, 0, 3 },
        .ipv4_addresses = @as([4][4]u8, .{ source4, @splat(0), @splat(0), @splat(0) }),
        .ipv4_count = 1,
    });
    try std.testing.expectEqual(@as(?AttachmentGeneration, null), conflicting_address);

    const reattached_generation = switcher.attach(.{
        .id = 2,
        .segment = 7,
        .mac = target_mac,
        .ipv4_addresses = @as([4][4]u8, .{ target4, @splat(0), @splat(0), @splat(0) }),
        .ipv4_count = 1,
        .ipv6_addresses = @as([4][16]u8, .{ target6, @splat(0), @splat(0), @splat(0) }),
        .ipv6_count = 1,
        .policy = target_policy,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(reattached_generation > target_generation);
    try std.testing.expect(!switcher.detach(2, target_generation));
}

test "allowed policy does not bridge isolated segments" {
    var switcher: Switch = .{};
    const source_mac = [_]u8{ 0x02, 0, 0, 0, 0, 1 };
    const target_mac = [_]u8{ 0x02, 0, 0, 0, 0, 2 };
    const source4 = [_]u8{ 10, 0, 0, 1 };
    const target4 = [_]u8{ 10, 0, 0, 2 };
    const source_wide = ip4Wide(source4);
    const target_wide = ip4Wide(target4);
    var source_policy: Policy = .{};
    source_policy.egress[0] = .{
        .ip_version = .ipv4,
        .protocol = 17,
        .destination = target_wide,
        .destination_port_first = 53,
        .destination_port_last = 53,
    };
    source_policy.egress_count = 1;
    var target_policy: Policy = .{};
    target_policy.ingress[0] = .{
        .ip_version = .ipv4,
        .protocol = 17,
        .destination = target_wide,
        .destination_port_first = 53,
        .destination_port_last = 53,
    };
    target_policy.ingress_count = 1;

    const source_generation = switcher.attach(.{
        .id = 1,
        .segment = 1,
        .mac = source_mac,
        .ipv4_addresses = @as([4][4]u8, .{ source4, @splat(0), @splat(0), @splat(0) }),
        .ipv4_count = 1,
        .policy = source_policy,
    }) orelse return error.TestUnexpectedResult;
    _ = switcher.attach(.{
        .id = 2,
        .segment = 2,
        .mac = target_mac,
        .ipv4_addresses = @as([4][4]u8, .{ target4, @splat(0), @splat(0), @splat(0) }),
        .ipv4_count = 1,
        .policy = target_policy,
    }) orelse return error.TestUnexpectedResult;

    const frame = buildUdpFrame(source_mac, target_mac, 0x0800, &source_wide, &target_wide, 17);
    const decision = switcher.decide(1, source_generation, &frame);
    try std.testing.expectEqual(@as(usize, 0), decision.count);
    try std.testing.expectEqual(DropReason.no_eligible_destination, decision.drop_reason);
}

test "unconfigured and invalid switch ports fail closed" {
    var switcher: Switch = .{};
    const source_mac = [_]u8{ 0x02, 0, 0, 0, 0, 1 };
    const target_mac = [_]u8{ 0x02, 0, 0, 0, 0, 2 };
    const source4 = [_]u8{ 10, 0, 0, 1 };
    const target4 = [_]u8{ 10, 0, 0, 2 };
    const source_wide = ip4Wide(source4);
    const target_wide = ip4Wide(target4);
    const frame = buildUdpFrame(source_mac, target_mac, 0x0800, &source_wide, &target_wide, 17);

    const unconfigured_generation = switcher.attach(.{
        .id = 1,
        .segment = 1,
        .mac = source_mac,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        DropReason.unauthorized_source_address,
        switcher.decide(1, unconfigured_generation, &frame).drop_reason,
    );

    var invalid_policy: Policy = .{};
    invalid_policy.egress[0] = .{
        .ip_version = .ipv4,
        .protocol = 17,
        .destination = target_wide,
        .destination_port_first = 54,
        .destination_port_last = 53,
    };
    invalid_policy.egress_count = 1;
    try std.testing.expectEqual(@as(?AttachmentGeneration, null), switcher.attach(.{
        .id = 2,
        .segment = 1,
        .mac = target_mac,
        .ipv4_addresses = @as([4][4]u8, .{ target4, @splat(0), @splat(0), @splat(0) }),
        .ipv4_count = 1,
        .policy = invalid_policy,
    }));
    try std.testing.expectEqual(@as(?AttachmentGeneration, null), switcher.attach(.{
        .id = 4,
        .segment = 1,
        .mac = target_mac,
        .ipv4_addresses = @as([4][4]u8, .{ [_]u8{ 0, 0, 0, 0 }, @splat(0), @splat(0), @splat(0) }),
        .ipv4_count = 1,
    }));

    const source_generation = switcher.attach(.{
        .id = 3,
        .segment = 2,
        .mac = source_mac,
        .ipv4_addresses = @as([4][4]u8, .{ source4, @splat(0), @splat(0), @splat(0) }),
        .ipv4_count = 1,
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        DropReason.egress_denied,
        switcher.decide(3, source_generation, &frame).drop_reason,
    );
}

fn ip4Wide(address: [4]u8) [16]u8 {
    var result: [16]u8 = @splat(0);
    @memcpy(result[0..4], &address);
    return result;
}

fn buildUdpFrame(
    source_mac: [6]u8,
    destination_mac: [6]u8,
    ether_type: u16,
    source_ip: *const [16]u8,
    destination_ip: *const [16]u8,
    version: u8,
) [64]u8 {
    var frame: [64]u8 = @splat(0);
    @memcpy(frame[0..6], &destination_mac);
    @memcpy(frame[6..12], &source_mac);
    std.mem.writeInt(u16, frame[12..14], ether_type, .big);
    if (ether_type == 0x0800) {
        frame[14] = 0x45;
        std.mem.writeInt(u16, frame[16..18], 28, .big);
        frame[23] = 17;
        @memcpy(frame[26..30], source_ip[0..4]);
        @memcpy(frame[30..34], destination_ip[0..4]);
        std.mem.writeInt(u16, frame[34..36], 1000, .big);
        std.mem.writeInt(u16, frame[36..38], 53, .big);
        std.mem.writeInt(u16, frame[38..40], 8, .big);
    } else {
        frame[14] = 0x60;
        std.mem.writeInt(u16, frame[18..20], 8, .big);
        frame[20] = version;
        @memcpy(frame[22..38], source_ip);
        @memcpy(frame[38..54], destination_ip);
        std.mem.writeInt(u16, frame[54..56], 1000, .big);
        std.mem.writeInt(u16, frame[56..58], 53, .big);
        std.mem.writeInt(u16, frame[58..60], 8, .big);
    }
    return frame;
}

const std = @import("std");

pub const MAX_PORTS: usize = 32;
pub const MAX_RULES_PER_DIRECTION: usize = 16;
pub const MAX_FRAME_SIZE: usize = 1514;
pub const MAX_DELIVERIES: usize = MAX_PORTS;
const ZERO_MAC: [6]u8 = @splat(0);
const BROADCAST_MAC: [6]u8 = @splat(0xFF);

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

pub const AddressBindings = struct {
    ipv4_addresses: [4][4]u8 = @splat(@splat(0)),
    ipv4_count: u8 = 0,
    ipv6_addresses: [4][16]u8 = @splat(@splat(0)),
    ipv6_count: u8 = 0,
};

pub const BindingError = error{ InvalidBindings, AddressConflict, Stale, RevisionExhausted };

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
    arp_spoof,
    neighbor_spoof,
    router_message_denied,
};

pub const DROP_REASON_COUNT: usize = std.enums.values(DropReason).len;

/// Bounded per-switch observability counters. `drops[@intFromEnum(reason)]`
/// counts frames rejected for that reason; `bootstrap_forwarded` counts
/// validated ARP/NDP frames; `forwarded` counts policy-approved data frames.
pub const Counters = struct {
    forwarded: u64 = 0,
    bootstrap_forwarded: u64 = 0,
    drops: [DROP_REASON_COUNT]u64 = @splat(0),
};

pub const Direction = enum(u8) { ingress = 0, egress = 1 };

pub const RuleError = error{ Stale, Invalid, Duplicate, Full, RevisionExhausted };

pub const Decision = struct {
    deliveries: [MAX_DELIVERIES]Delivery = undefined,
    count: usize = 0,
    drop_reason: DropReason = .none,
};

const Port = struct {
    active: bool = false,
    generation: AttachmentGeneration = 0,
    policy_revision: u64 = 0,
    initial_bindings: AddressBindings = .{},
    config: PortConfig = undefined,
};

const FrameKind = enum { transport, arp_request, arp_reply, ndp_solicit, ndp_advert, router_discovery };

const ParsedFrame = struct {
    destination_mac: [6]u8,
    ip_version: IpVersion,
    source_ip: [16]u8,
    destination_ip: [16]u8,
    protocol: u8,
    destination_port: u16,
    kind: FrameKind = .transport,
    /// ARP target protocol address or NDP target address (IPv4 uses the first 4 bytes).
    target_ip: [16]u8 = @splat(0),
    /// ARP target hardware address.
    target_mac: [6]u8 = @splat(0),
    /// ARP sender hardware address.
    sender_mac: [6]u8 = @splat(0),
    /// NDP link-layer address option (source LLA for NS, target LLA for NA), if present.
    nd_option_mac: ?[6]u8 = null,
};

pub const Switch = struct {
    ports: [MAX_PORTS]Port = @splat(.{}),
    next_generation: AttachmentGeneration = 0,
    counters: Counters = .{},

    /// Like `decide`, but also records the outcome in `counters`.
    pub fn decideCounted(
        self: *Switch,
        source_id: PortId,
        source_generation: AttachmentGeneration,
        frame: []const u8,
    ) Decision {
        const decision = self.decide(source_id, source_generation, frame);
        if (decision.count == 0) {
            self.counters.drops[@intFromEnum(decision.drop_reason)] +|= 1;
        } else if (isBootstrapFrame(frame)) {
            self.counters.bootstrap_forwarded +|= 1;
        } else {
            self.counters.forwarded +|= 1;
        }
        return decision;
    }

    pub fn addRule(
        self: *Switch,
        id: PortId,
        generation: AttachmentGeneration,
        expected_revision: u64,
        direction: Direction,
        rule: Rule,
    ) RuleError!u64 {
        if (!validRule(rule)) return error.Invalid;
        const port = self.findPort(id) orelse return error.Stale;
        if (port.generation != generation or port.policy_revision != expected_revision) return error.Stale;
        const next_revision = std.math.add(u64, port.policy_revision, 1) catch return error.RevisionExhausted;
        const policy = &port.config.policy;
        const rules: []Rule = if (direction == .ingress) policy.ingress[0..] else policy.egress[0..];
        const count: *u8 = if (direction == .ingress) &policy.ingress_count else &policy.egress_count;
        for (rules[0..count.*]) |existing| {
            if (sameRule(existing, rule)) return error.Duplicate;
        }
        if (count.* >= MAX_RULES_PER_DIRECTION) return error.Full;
        rules[count.*] = rule;
        count.* += 1;
        port.policy_revision = next_revision;
        return next_revision;
    }

    pub fn clearRules(
        self: *Switch,
        id: PortId,
        generation: AttachmentGeneration,
        expected_revision: u64,
    ) RuleError!u64 {
        const port = self.findPort(id) orelse return error.Stale;
        if (port.generation != generation or port.policy_revision != expected_revision) return error.Stale;
        const next_revision = std.math.add(u64, port.policy_revision, 1) catch return error.RevisionExhausted;
        port.config.policy = .{};
        port.policy_revision = next_revision;
        return next_revision;
    }

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
                if (port.config.id == config.id) {
                    if (sameAttachment(port, config)) return port.generation;
                    return null;
                }
                if (port.config.segment == config.segment and std.mem.eql(u8, &port.config.mac, &config.mac)) return null;
                if (port.config.segment == config.segment and addressBindingConflicts(&port.config, &config)) return null;
            } else if (free_slot == null) {
                free_slot = idx;
            }
        }

        const idx = free_slot orelse return null;
        const next_generation = std.math.add(AttachmentGeneration, self.next_generation, 1) catch return null;
        self.next_generation = next_generation;
        self.ports[idx] = .{
            .active = true,
            .generation = next_generation,
            .policy_revision = 1,
            .initial_bindings = bindingsForConfig(&config),
            .config = config,
        };
        return next_generation;
    }

    pub fn detach(self: *Switch, id: PortId, generation: AttachmentGeneration) bool {
        for (&self.ports) |*port| {
            if (port.generation == 0) continue;
            if (port.config.id != id) continue;
            if (!port.active) {
                return port.generation == generation;
            }
            if (port.generation != generation) return false;
            port.active = false;
            return true;
        }
        return false;
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

    pub fn replaceBindings(
        self: *Switch,
        id: PortId,
        generation: AttachmentGeneration,
        expected_revision: u64,
        bindings: AddressBindings,
    ) BindingError!u64 {
        if (bindings.ipv4_count > bindings.ipv4_addresses.len or
            bindings.ipv6_count > bindings.ipv6_addresses.len)
        {
            return error.InvalidBindings;
        }
        const port = self.findPort(id) orelse return error.Stale;
        if (port.generation != generation) return error.Stale;

        var updated = port.config;
        updated.ipv4_addresses = bindings.ipv4_addresses;
        updated.ipv4_count = bindings.ipv4_count;
        updated.ipv6_addresses = bindings.ipv6_addresses;
        updated.ipv6_count = bindings.ipv6_count;
        if (!validAddresses(&updated)) return error.InvalidBindings;

        const next_revision = std.math.add(u64, expected_revision, 1) catch return error.RevisionExhausted;
        if (port.policy_revision != expected_revision) {
            const current_bindings = bindingsForConfig(&port.config);
            if (port.policy_revision == next_revision and sameBindings(&current_bindings, &bindings) and
                port.config.policy.ingress_count == 0 and port.config.policy.egress_count == 0)
            {
                return port.policy_revision;
            }
            return error.Stale;
        }
        for (&self.ports) |*candidate| {
            if (candidate.active and candidate.config.id != id and
                candidate.config.segment == updated.segment and addressBindingConflicts(&candidate.config, &updated))
            {
                return error.AddressConflict;
            }
        }

        updated.policy = .{};
        port.config = updated;
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
        if (parsed.kind != .transport) return self.decideBootstrap(source, parsed);
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

    /// Address-resolution bootstrap (ARP, NDP). These frames carry no
    /// application payload; they are validated against the host-authorised
    /// bindings of the sending port and delivered only to the ports that own
    /// the resolved address (or, for unsolicited advertisements, the segment).
    /// Router advertisements/solicitations are never accepted from guests.
    fn decideBootstrap(self: *const Switch, source: *const Port, parsed: ParsedFrame) Decision {
        const config = &source.config;
        switch (parsed.kind) {
            .transport => unreachable,
            .router_discovery => return .{ .drop_reason = .router_message_denied },
            .arp_request, .arp_reply => {
                if (!std.mem.eql(u8, &parsed.sender_mac, &config.mac)) return .{ .drop_reason = .arp_spoof };
                const zero4: [4]u8 = @splat(0);
                const sender_zero = std.mem.eql(u8, parsed.source_ip[0..4], &zero4);
                if (parsed.kind == .arp_request) {
                    if (!std.mem.eql(u8, &parsed.destination_mac, &BROADCAST_MAC)) return .{ .drop_reason = .arp_spoof };
                    if (!sender_zero and !sourceOwnsAddress(config, .ipv4, &parsed.source_ip)) {
                        return .{ .drop_reason = .arp_spoof };
                    }
                    if (sender_zero and config.ipv4_count == 0) return .{ .drop_reason = .arp_spoof };
                } else {
                    if (sender_zero or !sourceOwnsAddress(config, .ipv4, &parsed.source_ip)) {
                        return .{ .drop_reason = .arp_spoof };
                    }
                    if (!std.mem.eql(u8, &parsed.target_mac, &parsed.destination_mac)) {
                        return .{ .drop_reason = .arp_spoof };
                    }
                }
            },
            .ndp_solicit => {
                if (parsed.nd_option_mac) |option| {
                    if (!std.mem.eql(u8, &option, &config.mac)) return .{ .drop_reason = .neighbor_spoof };
                }
                const unspecified = std.mem.allEqual(u8, &parsed.source_ip, 0);
                if (unspecified) {
                    // Duplicate address detection: only for a bound target address.
                    if (!sourceOwnsAddress(config, .ipv6, &parsed.target_ip)) return .{ .drop_reason = .neighbor_spoof };
                } else if (!sourceOwnsAddress(config, .ipv6, &parsed.source_ip)) {
                    return .{ .drop_reason = .neighbor_spoof };
                }
            },
            .ndp_advert => {
                if (parsed.nd_option_mac) |option| {
                    if (!std.mem.eql(u8, &option, &config.mac)) return .{ .drop_reason = .neighbor_spoof };
                }
                if (!sourceOwnsAddress(config, .ipv6, &parsed.source_ip) or
                    !sourceOwnsAddress(config, .ipv6, &parsed.target_ip))
                {
                    return .{ .drop_reason = .neighbor_spoof };
                }
            },
        }

        var result: Decision = .{};
        for (&self.ports) |*candidate| {
            if (!candidate.active or candidate.config.id == config.id or
                candidate.config.segment != config.segment)
            {
                continue;
            }
            const eligible = switch (parsed.kind) {
                .arp_request => sourceOwnsAddress(&candidate.config, .ipv4, &parsed.target_ip),
                .arp_reply => std.mem.eql(u8, &parsed.destination_mac, &candidate.config.mac) and
                    sourceOwnsAddress(&candidate.config, .ipv4, &parsed.target_ip),
                .ndp_solicit => sourceOwnsAddress(&candidate.config, .ipv6, &parsed.target_ip),
                .ndp_advert => if (isMulticastMac(&parsed.destination_mac))
                    true
                else
                    std.mem.eql(u8, &parsed.destination_mac, &candidate.config.mac) and
                        sourceOwnsAddress(&candidate.config, .ipv6, &parsed.destination_ip),
                else => false,
            };
            if (!eligible) continue;
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

fn bindingsForConfig(config: *const PortConfig) AddressBindings {
    return .{
        .ipv4_addresses = config.ipv4_addresses,
        .ipv4_count = config.ipv4_count,
        .ipv6_addresses = config.ipv6_addresses,
        .ipv6_count = config.ipv6_count,
    };
}

fn sameBindings(first: *const AddressBindings, second: *const AddressBindings) bool {
    return first.ipv4_count == second.ipv4_count and
        first.ipv6_count == second.ipv6_count and
        std.mem.eql(u8, std.mem.sliceAsBytes(first.ipv4_addresses[0..first.ipv4_count]), std.mem.sliceAsBytes(second.ipv4_addresses[0..second.ipv4_count])) and
        std.mem.eql(u8, std.mem.sliceAsBytes(first.ipv6_addresses[0..first.ipv6_count]), std.mem.sliceAsBytes(second.ipv6_addresses[0..second.ipv6_count]));
}

fn sameAttachment(existing: *const Port, requested: PortConfig) bool {
    const requested_bindings = bindingsForConfig(&requested);
    return existing.config.segment == requested.segment and
        std.mem.eql(u8, &existing.config.mac, &requested.mac) and
        sameBindings(&existing.initial_bindings, &requested_bindings);
}

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
        if (address[0] == 0 or address[0] == 127 or address[0] >= 224) return false;
        for (config.ipv4_addresses[0..idx]) |*previous| {
            if (std.mem.eql(u8, address, previous)) return false;
        }
    }
    for (config.ipv6_addresses[0..config.ipv6_count], 0..) |*address, idx| {
        if (address[0] == 0xFF or std.mem.allEqual(u8, address, 0) or
            std.mem.eql(u8, address, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 })) return false;
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

const PROTO_ICMP: u8 = 1;
const PROTO_ICMPV6: u8 = 58;

fn sameRule(a: Rule, b: Rule) bool {
    return a.ip_version == b.ip_version and a.protocol == b.protocol and
        std.mem.eql(u8, &a.destination, &b.destination) and
        a.destination_port_first == b.destination_port_first and
        a.destination_port_last == b.destination_port_last;
}

fn isBootstrapFrame(frame: []const u8) bool {
    const parsed = parseFrame(frame) orelse return false;
    return parsed.kind != .transport;
}

fn validRule(rule: Rule) bool {
    if (rule.destination_port_first > rule.destination_port_last) return false;
    switch (rule.protocol) {
        6, 17 => {},
        // ICMP / ICMPv6 echo: matched on destination address only (port range must be 0-0).
        PROTO_ICMP => if (rule.ip_version != .ipv4 or rule.destination_port_last != 0) return false,
        PROTO_ICMPV6 => if (rule.ip_version != .ipv6 or rule.destination_port_last != 0) return false,
        else => return false,
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
        0x0806 => parseArp(frame[0..6], payload),
        else => null,
    };
}

/// Ethernet/IPv4 ARP (RFC 826): fixed 28-byte body, request or reply only.
fn parseArp(destination_mac: []const u8, packet: []const u8) ?ParsedFrame {
    if (packet.len < 28) return null;
    if (std.mem.readInt(u16, packet[0..2], .big) != 1 or
        std.mem.readInt(u16, packet[2..4], .big) != 0x0800 or
        packet[4] != 6 or packet[5] != 4)
    {
        return null;
    }
    const op = std.mem.readInt(u16, packet[6..8], .big);
    if (op != 1 and op != 2) return null;
    var result = ParsedFrame{
        .destination_mac = destination_mac[0..6].*,
        .ip_version = .ipv4,
        .source_ip = @splat(0),
        .destination_ip = @splat(0),
        .protocol = 0,
        .destination_port = 0,
        .kind = if (op == 1) .arp_request else .arp_reply,
    };
    @memcpy(result.source_ip[0..4], packet[14..18]);
    @memcpy(&result.target_mac, packet[18..24]);
    @memcpy(result.target_ip[0..4], packet[24..28]);
    result.sender_mac = packet[8..14].*;
    return result;
}

fn parseIpv4(destination_mac: []const u8, packet: []const u8) ?ParsedFrame {
    if (packet.len < 20 or packet[0] >> 4 != 4) return null;
    const header_len = @as(usize, packet[0] & 0x0F) * 4;
    const total_len = std.mem.readInt(u16, packet[2..4], .big);
    if (header_len < 20 or total_len < header_len + 4 or total_len > packet.len) return null;
    const fragment = std.mem.readInt(u16, packet[6..8], .big);
    if (fragment & 0xBFFF != 0) return null;

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
    const transport = packet[40 .. 40 + payload_len];
    var source_ip: [16]u8 = undefined;
    var destination_ip: [16]u8 = undefined;
    @memcpy(&source_ip, packet[8..24]);
    @memcpy(&destination_ip, packet[24..40]);
    var result = ParsedFrame{
        .destination_mac = destination_mac[0..6].*,
        .ip_version = .ipv6,
        .source_ip = source_ip,
        .destination_ip = destination_ip,
        .protocol = protocol,
        .destination_port = 0,
    };
    if (protocol == PROTO_ICMPV6) {
        if (transport.len < 4) return null;
        const icmp_type = transport[0];
        switch (icmp_type) {
            // Echo request / reply: matched on destination address only.
            128, 129 => {
                if (transport.len < 8 or transport[1] != 0) return null;
            },
            // Router solicitation / advertisement: never accepted from a guest port.
            133, 134 => {
                result.kind = .router_discovery;
            },
            // Neighbor solicitation / advertisement (RFC 4861): hop limit 255, code 0.
            135, 136 => {
                if (packet[7] != 255 or transport[1] != 0 or transport.len < 24) return null;
                @memcpy(&result.target_ip, transport[8..24]);
                if (result.target_ip[0] == 0xFF) return null;
                if (!parseNdOptions(transport[24..], if (icmp_type == 135) 1 else 2, &result.nd_option_mac)) return null;
                result.kind = if (icmp_type == 135) .ndp_solicit else .ndp_advert;
            },
            else => return null,
        }
        return result;
    }
    if (protocol != 6 and protocol != 17) return null;
    result.destination_port = parseTransportDestinationPort(protocol, transport) orelse return null;
    return result;
}

/// NDP options are bounded TLVs in units of 8 bytes; zero-length options are
/// malformed. Returns false for malformed options; `mac` receives the first
/// link-layer address option of `wanted_type` (1 = source, 2 = target).
fn parseNdOptions(options: []const u8, wanted_type: u8, mac: *?[6]u8) bool {
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < options.len) {
        if (options.len - offset < 2 or count >= 8) return false;
        const units = @as(usize, options[offset + 1]);
        if (units == 0 or offset + units * 8 > options.len) return false;
        if (options[offset] == wanted_type and mac.* == null) {
            if (units != 1) return false;
            mac.* = options[offset + 2 ..][0..6].*;
        }
        offset += units * 8;
        count += 1;
    }
    return true;
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
    } else if (protocol == PROTO_ICMP) {
        // Echo request (8) / reply (0) only.
        if (transport.len < 8 or transport[1] != 0 or (transport[0] != 8 and transport[0] != 0)) return null;
        return 0;
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

    var reserved_fragment_flag = ipv4_frame;
    std.mem.writeInt(u16, reserved_fragment_flag[20..22], 0x8000, .big);
    try std.testing.expectEqual(
        DropReason.malformed_frame,
        switcher.decide(1, source_generation, &reserved_fragment_flag).drop_reason,
    );

    var truncated_ipv4_packet = ipv4_frame;
    std.mem.writeInt(u16, truncated_ipv4_packet[16..18], 27, .big);
    try std.testing.expectEqual(
        DropReason.malformed_frame,
        switcher.decide(1, source_generation, &truncated_ipv4_packet).drop_reason,
    );

    var oversized_udp_length = ipv4_frame;
    std.mem.writeInt(u16, oversized_udp_length[38..40], 9, .big);
    try std.testing.expectEqual(
        DropReason.malformed_frame,
        switcher.decide(1, source_generation, &oversized_udp_length).drop_reason,
    );

    var ipv6_extension_header = ipv6_frame;
    ipv6_extension_header[20] = 0;
    try std.testing.expectEqual(
        DropReason.malformed_frame,
        switcher.decide(1, source_generation, &ipv6_extension_header).drop_reason,
    );

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

test "repeated identical attachment requests are idempotent" {
    var switcher: Switch = .{};
    const config = PortConfig{
        .id = 7,
        .segment = 1,
        .mac = .{ 0x02, 0xCA, 0, 0, 0, 7 },
    };
    const first = switcher.attach(config) orelse return error.TestUnexpectedResult;
    var policy: Policy = .{};
    policy.egress[0] = .{
        .ip_version = .ipv4,
        .protocol = 17,
        .destination = @splat(0),
        .destination_port_first = 53,
        .destination_port_last = 53,
    };
    policy.egress_count = 1;
    try std.testing.expectEqual(@as(?u64, 2), switcher.replacePolicy(7, first, 1, policy));
    try std.testing.expectEqual(first, switcher.attach(config).?);
    try std.testing.expectEqual(@as(?u64, 2), switcher.policyRevision(7, first));

    var changed = config;
    changed.segment = 2;
    try std.testing.expectEqual(@as(?AttachmentGeneration, null), switcher.attach(changed));
}

test "address binding replacement revokes policy and preserves attachment retries" {
    var switcher: Switch = .{};
    const initial = PortConfig{
        .id = 7,
        .segment = 1,
        .mac = .{ 0x02, 0xCA, 0, 0, 0, 7 },
    };
    const generation = switcher.attach(initial) orelse return error.TestUnexpectedResult;
    var old_policy: Policy = .{};
    old_policy.egress[0] = .{
        .ip_version = .ipv4,
        .protocol = 17,
        .destination = ip4Wide(.{ 10, 0, 0, 2 }),
        .destination_port_first = 53,
        .destination_port_last = 53,
    };
    old_policy.egress_count = 1;
    try std.testing.expectEqual(@as(?u64, 2), switcher.replacePolicy(7, generation, 1, old_policy));

    const bindings = AddressBindings{
        .ipv4_addresses = .{ .{ 10, 0, 0, 1 }, @splat(0), @splat(0), @splat(0) },
        .ipv4_count = 1,
        .ipv6_addresses = .{ .{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, @splat(0), @splat(0), @splat(0) },
        .ipv6_count = 1,
    };
    try std.testing.expectEqual(@as(u64, 3), try switcher.replaceBindings(7, generation, 2, bindings));
    try std.testing.expectEqual(@as(u64, 3), try switcher.replaceBindings(7, generation, 2, bindings));
    try std.testing.expectEqual(generation, switcher.attach(initial).?);
    try std.testing.expectEqual(@as(?u64, 3), switcher.policyRevision(7, generation));

    const port = switcher.findPortConst(7).?;
    try std.testing.expectEqual(@as(u8, 1), port.config.ipv4_count);
    try std.testing.expectEqual(@as(u8, 1), port.config.ipv6_count);
    try std.testing.expectEqual(@as(u8, 0), port.config.policy.egress_count);
    try std.testing.expectEqual(@as(?u64, 4), switcher.replacePolicy(7, generation, 3, old_policy));
    try std.testing.expectError(error.Stale, switcher.replaceBindings(7, generation, 2, bindings));
    try std.testing.expectEqual(@as(u8, 1), switcher.findPortConst(7).?.config.policy.egress_count);
}

test "address binding replacement rejects stale or conflicting updates atomically" {
    var switcher: Switch = .{};
    const generation = switcher.attach(.{
        .id = 1,
        .segment = 1,
        .mac = .{ 0x02, 0xCA, 0, 0, 0, 1 },
    }) orelse return error.TestUnexpectedResult;
    _ = switcher.attach(.{
        .id = 2,
        .segment = 1,
        .mac = .{ 0x02, 0xCA, 0, 0, 0, 2 },
        .ipv4_addresses = .{ .{ 10, 0, 0, 2 }, @splat(0), @splat(0), @splat(0) },
        .ipv4_count = 1,
    }) orelse return error.TestUnexpectedResult;
    const bindings = AddressBindings{
        .ipv4_addresses = .{ .{ 10, 0, 0, 1 }, @splat(0), @splat(0), @splat(0) },
        .ipv4_count = 1,
    };
    try std.testing.expectError(error.Stale, switcher.replaceBindings(1, generation + 1, 1, bindings));
    try std.testing.expectError(error.Stale, switcher.replaceBindings(1, generation, 2, bindings));
    var invalid = bindings;
    invalid.ipv4_count = 5;
    try std.testing.expectError(error.InvalidBindings, switcher.replaceBindings(1, generation, 1, invalid));
    invalid = bindings;
    invalid.ipv4_addresses[0] = .{ 10, 0, 0, 2 };
    try std.testing.expectError(error.AddressConflict, switcher.replaceBindings(1, generation, 1, invalid));
    invalid = bindings;
    invalid.ipv4_addresses[1] = invalid.ipv4_addresses[0];
    invalid.ipv4_count = 2;
    try std.testing.expectError(error.InvalidBindings, switcher.replaceBindings(1, generation, 1, invalid));
    invalid = bindings;
    invalid.ipv4_addresses[0] = .{ 224, 0, 0, 1 };
    try std.testing.expectError(error.InvalidBindings, switcher.replaceBindings(1, generation, 1, invalid));
    invalid = bindings;
    invalid.ipv6_count = 1;
    invalid.ipv6_addresses[0] = .{ 0xFF, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try std.testing.expectError(error.InvalidBindings, switcher.replaceBindings(1, generation, 1, invalid));
    try std.testing.expectEqual(@as(?u64, 1), switcher.policyRevision(1, generation));
    try std.testing.expectEqual(@as(u8, 0), switcher.findPortConst(1).?.config.ipv4_count);
    try std.testing.expectEqual(@as(u64, 2), try switcher.replaceBindings(1, generation, 1, bindings));
}

test "updated bindings require fresh explicit ingress and egress policy" {
    var switcher: Switch = .{};
    const source_mac = [_]u8{ 0x02, 0, 0, 0, 0, 1 };
    const target_mac = [_]u8{ 0x02, 0, 0, 0, 0, 2 };
    const source4 = [_]u8{ 10, 0, 0, 1 };
    const target4 = [_]u8{ 10, 0, 0, 2 };
    const source6 = [_]u8{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const target6 = [_]u8{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
    const source_ip = ip4Wide(source4);
    const target_ip = ip4Wide(target4);
    const source_generation = switcher.attach(.{ .id = 1, .segment = 1, .mac = source_mac }) orelse return error.TestUnexpectedResult;
    const target_generation = switcher.attach(.{ .id = 2, .segment = 1, .mac = target_mac }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), try switcher.replaceBindings(1, source_generation, 1, .{
        .ipv4_addresses = .{ source4, @splat(0), @splat(0), @splat(0) },
        .ipv4_count = 1,
        .ipv6_addresses = .{ source6, @splat(0), @splat(0), @splat(0) },
        .ipv6_count = 1,
    }));
    try std.testing.expectEqual(@as(u64, 2), try switcher.replaceBindings(2, target_generation, 1, .{
        .ipv4_addresses = .{ target4, @splat(0), @splat(0), @splat(0) },
        .ipv4_count = 1,
        .ipv6_addresses = .{ target6, @splat(0), @splat(0), @splat(0) },
        .ipv6_count = 1,
    }));
    const frame = buildUdpFrame(source_mac, target_mac, 0x0800, &source_ip, &target_ip, 17);
    const ipv6_frame = buildUdpFrame(source_mac, target_mac, 0x86DD, &source6, &target6, 17);
    try std.testing.expectEqual(DropReason.egress_denied, switcher.decide(1, source_generation, &frame).drop_reason);
    try std.testing.expectEqual(DropReason.egress_denied, switcher.decide(1, source_generation, &ipv6_frame).drop_reason);

    var source_policy: Policy = .{};
    source_policy.egress[0] = .{ .ip_version = .ipv4, .protocol = 17, .destination = target_ip, .destination_port_first = 53, .destination_port_last = 53 };
    source_policy.egress[1] = .{ .ip_version = .ipv6, .protocol = 17, .destination = target6, .destination_port_first = 53, .destination_port_last = 53 };
    source_policy.egress_count = 2;
    var target_policy: Policy = .{};
    target_policy.ingress[0] = source_policy.egress[0];
    target_policy.ingress[1] = source_policy.egress[1];
    target_policy.ingress_count = 2;
    try std.testing.expectEqual(@as(?u64, 3), switcher.replacePolicy(1, source_generation, 2, source_policy));
    try std.testing.expectEqual(DropReason.no_eligible_destination, switcher.decide(1, source_generation, &frame).drop_reason);
    try std.testing.expectEqual(@as(?u64, 3), switcher.replacePolicy(2, target_generation, 2, target_policy));
    try std.testing.expectEqual(@as(usize, 1), switcher.decide(1, source_generation, &frame).count);
    try std.testing.expectEqual(@as(usize, 1), switcher.decide(1, source_generation, &ipv6_frame).count);

    try std.testing.expectEqual(@as(u64, 4), try switcher.replaceBindings(1, source_generation, 3, .{
        .ipv4_addresses = .{ source4, @splat(0), @splat(0), @splat(0) },
        .ipv4_count = 1,
    }));
    try std.testing.expectEqual(DropReason.egress_denied, switcher.decide(1, source_generation, &frame).drop_reason);
}

test "repeated detach after a lost acknowledgement is idempotent" {
    var switcher: Switch = .{};
    try std.testing.expect(!switcher.detach(5, 0));
    try std.testing.expect(!switcher.detach(5, 1));
    const config = PortConfig{
        .id = 5,
        .segment = 1,
        .mac = .{ 0x02, 0xCA, 0, 0, 0, 5 },
    };
    const generation = switcher.attach(config) orelse return error.TestUnexpectedResult;

    try std.testing.expect(switcher.detach(5, generation));
    try std.testing.expect(switcher.detach(5, generation));
    try std.testing.expect(!switcher.detach(5, generation + 1));
    const reattached = switcher.attach(config) orelse return error.TestUnexpectedResult;
    try std.testing.expect(reattached > generation);
    try std.testing.expect(!switcher.detach(5, generation));
}

test "attachment generations cannot alias across reused port slots" {
    var switcher: Switch = .{};
    const first = switcher.attach(.{
        .id = 1,
        .segment = 1,
        .mac = .{ 0x02, 0xCA, 0, 0, 0, 1 },
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), first);
    try std.testing.expect(switcher.detach(1, first));

    const second = switcher.attach(.{
        .id = 2,
        .segment = 1,
        .mac = .{ 0x02, 0xCA, 0, 0, 0, 2 },
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), second);
    const reattached = switcher.attach(.{
        .id = 1,
        .segment = 1,
        .mac = .{ 0x02, 0xCA, 0, 0, 0, 1 },
    }) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u64, 3), reattached);
    try std.testing.expect(!switcher.detach(1, first));
    try std.testing.expect(switcher.detach(1, reattached));
}

test "attachment generation exhaustion fails closed" {
    var switcher: Switch = .{ .next_generation = std.math.maxInt(AttachmentGeneration) };
    try std.testing.expect(switcher.attach(.{
        .id = 1,
        .segment = 1,
        .mac = .{ 0x02, 0xCA, 0, 0, 0, 1 },
    }) == null);
    try std.testing.expect(switcher.currentGeneration(1) == null);
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

fn buildArpFrame(
    op: u16,
    eth_dst: [6]u8,
    eth_src: [6]u8,
    sender_mac: [6]u8,
    sender_ip: [4]u8,
    target_mac: [6]u8,
    target_ip: [4]u8,
) [42]u8 {
    var frame: [42]u8 = @splat(0);
    @memcpy(frame[0..6], &eth_dst);
    @memcpy(frame[6..12], &eth_src);
    std.mem.writeInt(u16, frame[12..14], 0x0806, .big);
    std.mem.writeInt(u16, frame[14..16], 1, .big);
    std.mem.writeInt(u16, frame[16..18], 0x0800, .big);
    frame[18] = 6;
    frame[19] = 4;
    std.mem.writeInt(u16, frame[20..22], op, .big);
    @memcpy(frame[22..28], &sender_mac);
    @memcpy(frame[28..32], &sender_ip);
    @memcpy(frame[32..38], &target_mac);
    @memcpy(frame[38..42], &target_ip);
    return frame;
}

/// Neighbor solicitation (type 135) or advertisement (type 136) with an
/// optional 8-byte link-layer address option; returns the frame length.
fn buildNdFrame(
    buf: *[96]u8,
    icmp_type: u8,
    eth_dst: [6]u8,
    eth_src: [6]u8,
    source_ip: [16]u8,
    destination_ip: [16]u8,
    target: [16]u8,
    option_mac: ?[6]u8,
) usize {
    @memset(buf, 0);
    @memcpy(buf[0..6], &eth_dst);
    @memcpy(buf[6..12], &eth_src);
    std.mem.writeInt(u16, buf[12..14], 0x86DD, .big);
    buf[14] = 0x60;
    const icmp_len: usize = 24 + if (option_mac != null) @as(usize, 8) else 0;
    std.mem.writeInt(u16, buf[18..20], @intCast(icmp_len), .big);
    buf[20] = 58;
    buf[21] = 255;
    @memcpy(buf[22..38], &source_ip);
    @memcpy(buf[38..54], &destination_ip);
    buf[54] = icmp_type;
    @memcpy(buf[62..78], &target);
    if (option_mac) |mac| {
        buf[78] = if (icmp_type == 135) 1 else 2;
        buf[79] = 1;
        @memcpy(buf[80..86], &mac);
    }
    return 54 + icmp_len;
}

const test_mac_a = [_]u8{ 0x02, 0xCA, 0, 0, 0, 1 };
const test_mac_b = [_]u8{ 0x02, 0xCA, 0, 0, 0, 2 };
const test_ip4_a = [_]u8{ 10, 77, 0, 1 };
const test_ip4_b = [_]u8{ 10, 77, 0, 2 };
const test_ip6_a = [_]u8{ 0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const test_ip6_b = [_]u8{ 0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };

fn attachDualStackPair(switcher: *Switch) !struct { a: AttachmentGeneration, b: AttachmentGeneration } {
    const a = switcher.attach(.{
        .id = 1,
        .segment = 1,
        .mac = test_mac_a,
        .ipv4_addresses = @as([4][4]u8, .{ test_ip4_a, @splat(0), @splat(0), @splat(0) }),
        .ipv4_count = 1,
        .ipv6_addresses = @as([4][16]u8, .{ test_ip6_a, @splat(0), @splat(0), @splat(0) }),
        .ipv6_count = 1,
    }) orelse return error.TestUnexpectedResult;
    const b = switcher.attach(.{
        .id = 2,
        .segment = 1,
        .mac = test_mac_b,
        .ipv4_addresses = @as([4][4]u8, .{ test_ip4_b, @splat(0), @splat(0), @splat(0) }),
        .ipv4_count = 1,
        .ipv6_addresses = @as([4][16]u8, .{ test_ip6_b, @splat(0), @splat(0), @splat(0) }),
        .ipv6_count = 1,
    }) orelse return error.TestUnexpectedResult;
    return .{ .a = a, .b = b };
}

test "ARP resolves only between bound addresses and rejects forged claims" {
    var switcher: Switch = .{};
    const gen = try attachDualStackPair(&switcher);
    const broadcast: [6]u8 = @splat(0xFF);
    const zero_mac: [6]u8 = @splat(0);

    // Request for B's address from A is delivered only to B.
    const request = buildArpFrame(1, broadcast, test_mac_a, test_mac_a, test_ip4_a, zero_mac, test_ip4_b);
    const decision = switcher.decideCounted(1, gen.a, &request);
    try std.testing.expectEqual(@as(usize, 1), decision.count);
    try std.testing.expectEqual(@as(PortId, 2), decision.deliveries[0].port_id);
    try std.testing.expectEqual(@as(u64, 1), switcher.counters.bootstrap_forwarded);

    // B's reply goes back unicast to A.
    const reply = buildArpFrame(2, test_mac_a, test_mac_b, test_mac_b, test_ip4_b, test_mac_a, test_ip4_a);
    const reply_decision = switcher.decideCounted(2, gen.b, &reply);
    try std.testing.expectEqual(@as(usize, 1), reply_decision.count);
    try std.testing.expectEqual(@as(PortId, 1), reply_decision.deliveries[0].port_id);

    // Address-conflict probe (zero sender) is allowed for a port with a binding.
    const probe = buildArpFrame(1, broadcast, test_mac_a, test_mac_a, .{ 0, 0, 0, 0 }, zero_mac, test_ip4_b);
    try std.testing.expectEqual(@as(usize, 1), switcher.decide(1, gen.a, &probe).count);

    // A claims B's IP, or forges the ARP sender MAC: dropped and counted.
    const claim = buildArpFrame(2, test_mac_b, test_mac_a, test_mac_a, test_ip4_b, test_mac_b, test_ip4_b);
    try std.testing.expectEqual(DropReason.arp_spoof, switcher.decideCounted(1, gen.a, &claim).drop_reason);
    const forged_sender = buildArpFrame(1, broadcast, test_mac_a, test_mac_b, test_ip4_a, zero_mac, test_ip4_b);
    try std.testing.expectEqual(DropReason.arp_spoof, switcher.decideCounted(1, gen.a, &forged_sender).drop_reason);
    try std.testing.expectEqual(@as(u64, 2), switcher.counters.drops[@intFromEnum(DropReason.arp_spoof)]);

    // An unbound port cannot use ARP at all (default-deny).
    var fresh: Switch = .{};
    const lonely = fresh.attach(.{ .id = 3, .segment = 1, .mac = test_mac_a }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(DropReason.arp_spoof, fresh.decide(3, lonely, &request).drop_reason);
}

test "NDP validates solicited and advertised addresses and denies router messages" {
    var switcher: Switch = .{};
    const gen = try attachDualStackPair(&switcher);
    var buf: [96]u8 = undefined;
    const multicast_mac = [_]u8{ 0x33, 0x33, 0xFF, 0, 0, 2 };
    var solicited_node: [16]u8 = .{ 0xFF, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xFF, 0, 0, 2 };

    const ns_len = buildNdFrame(&buf, 135, multicast_mac, test_mac_a, test_ip6_a, solicited_node, test_ip6_b, test_mac_a);
    const ns = switcher.decideCounted(1, gen.a, buf[0..ns_len]);
    try std.testing.expectEqual(@as(usize, 1), ns.count);
    try std.testing.expectEqual(@as(PortId, 2), ns.deliveries[0].port_id);

    // Solicited advertisement: unicast back to the asker.
    const na_len = buildNdFrame(&buf, 136, test_mac_a, test_mac_b, test_ip6_b, test_ip6_a, test_ip6_b, test_mac_b);
    const na = switcher.decideCounted(2, gen.b, buf[0..na_len]);
    try std.testing.expectEqual(@as(usize, 1), na.count);
    try std.testing.expectEqual(@as(PortId, 1), na.deliveries[0].port_id);

    // DAD for the sender's own bound address is allowed; for someone else's it is not.
    var dad_dst = solicited_node;
    dad_dst[15] = 1;
    dad_dst[13] = 0;
    const dad_len = buildNdFrame(&buf, 135, multicast_mac, test_mac_a, @splat(0), dad_dst, test_ip6_a, null);
    try std.testing.expectEqual(DropReason.no_eligible_destination, switcher.decide(1, gen.a, buf[0..dad_len]).drop_reason);
    const bad_dad_len = buildNdFrame(&buf, 135, multicast_mac, test_mac_a, @splat(0), solicited_node, test_ip6_b, null);
    try std.testing.expectEqual(DropReason.neighbor_spoof, switcher.decide(1, gen.a, buf[0..bad_dad_len]).drop_reason);

    // A advertises B's address, forges the link-layer option, or solicits from a foreign source.
    const claim_len = buildNdFrame(&buf, 136, multicast_mac, test_mac_a, test_ip6_a, test_ip6_b, test_ip6_b, test_mac_a);
    try std.testing.expectEqual(DropReason.neighbor_spoof, switcher.decideCounted(1, gen.a, buf[0..claim_len]).drop_reason);
    const forged_lla_len = buildNdFrame(&buf, 135, multicast_mac, test_mac_a, test_ip6_a, solicited_node, test_ip6_b, test_mac_b);
    try std.testing.expectEqual(DropReason.neighbor_spoof, switcher.decideCounted(1, gen.a, buf[0..forged_lla_len]).drop_reason);
    const foreign_src_len = buildNdFrame(&buf, 135, multicast_mac, test_mac_a, test_ip6_b, solicited_node, test_ip6_b, null);
    try std.testing.expectEqual(DropReason.neighbor_spoof, switcher.decide(1, gen.a, buf[0..foreign_src_len]).drop_reason);
    try std.testing.expectEqual(@as(u64, 2), switcher.counters.drops[@intFromEnum(DropReason.neighbor_spoof)]);

    // Hop limit other than 255 is malformed; router advertisements are denied.
    const bad_hop_len = buildNdFrame(&buf, 135, multicast_mac, test_mac_a, test_ip6_a, solicited_node, test_ip6_b, null);
    buf[21] = 64;
    try std.testing.expectEqual(DropReason.malformed_frame, switcher.decide(1, gen.a, buf[0..bad_hop_len]).drop_reason);
    solicited_node = .{ 0xFF, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const ra_len = buildNdFrame(&buf, 134, test_mac_b, test_mac_a, test_ip6_a, solicited_node, @splat(0), null);
    try std.testing.expectEqual(DropReason.router_message_denied, switcher.decideCounted(1, gen.a, buf[0..ra_len]).drop_reason);
}

test "operator rules are bounded, revisioned, and default-deny until added" {
    var switcher: Switch = .{};
    const gen = try attachDualStackPair(&switcher);
    const src = ip4Wide(test_ip4_a);
    const dst = ip4Wide(test_ip4_b);
    const frame = buildUdpFrame(test_mac_a, test_mac_b, 0x0800, &src, &dst, 17);
    try std.testing.expectEqual(DropReason.egress_denied, switcher.decideCounted(1, gen.a, &frame).drop_reason);

    const rule: Rule = .{ .ip_version = .ipv4, .protocol = 17, .destination = dst, .destination_port_first = 53, .destination_port_last = 53 };
    try std.testing.expectEqual(@as(u64, 2), try switcher.addRule(1, gen.a, 1, .egress, rule));
    // Egress alone is not enough: the destination also needs an ingress rule.
    try std.testing.expectEqual(DropReason.no_eligible_destination, switcher.decide(1, gen.a, &frame).drop_reason);
    try std.testing.expectEqual(@as(u64, 2), try switcher.addRule(2, gen.b, 1, .ingress, rule));
    try std.testing.expectEqual(@as(usize, 1), switcher.decideCounted(1, gen.a, &frame).count);
    try std.testing.expectEqual(@as(u64, 1), switcher.counters.forwarded);

    // Stale revision, duplicate, invalid rules are rejected without changes.
    try std.testing.expectError(error.Stale, switcher.addRule(1, gen.a, 1, .egress, rule));
    try std.testing.expectError(error.Duplicate, switcher.addRule(1, gen.a, 2, .egress, rule));
    var bad = rule;
    bad.protocol = 47;
    try std.testing.expectError(error.Invalid, switcher.addRule(1, gen.a, 2, .egress, bad));
    try std.testing.expectError(error.Stale, switcher.addRule(1, gen.a + 99, 2, .egress, rule));

    // Rule capacity is bounded.
    var port: u16 = 1000;
    var revision: u64 = 2;
    while (revision - 2 < MAX_RULES_PER_DIRECTION - 1) : (revision += 1) {
        var extra = rule;
        extra.destination_port_first = port;
        extra.destination_port_last = port;
        port += 1;
        try std.testing.expectEqual(revision + 1, try switcher.addRule(1, gen.a, revision, .egress, extra));
    }
    var overflow = rule;
    overflow.destination_port_first = 2000;
    overflow.destination_port_last = 2000;
    try std.testing.expectError(error.Full, switcher.addRule(1, gen.a, revision, .egress, overflow));

    // Clearing restores default-deny in both directions at a new revision.
    try std.testing.expectEqual(revision + 1, try switcher.clearRules(1, gen.a, revision));
    try std.testing.expectEqual(DropReason.egress_denied, switcher.decide(1, gen.a, &frame).drop_reason);
    try std.testing.expectError(error.Stale, switcher.clearRules(1, gen.a, revision));
}

test "ICMP echo is classified by destination address and spoofed sources are dropped" {
    var switcher: Switch = .{};
    const gen = try attachDualStackPair(&switcher);
    var frame: [64]u8 = @splat(0);
    @memcpy(frame[0..6], &test_mac_b);
    @memcpy(frame[6..12], &test_mac_a);
    std.mem.writeInt(u16, frame[12..14], 0x0800, .big);
    frame[14] = 0x45;
    std.mem.writeInt(u16, frame[16..18], 28, .big);
    frame[23] = 1;
    @memcpy(frame[26..30], &test_ip4_a);
    @memcpy(frame[30..34], &test_ip4_b);
    frame[34] = 8;

    const dst = ip4Wide(test_ip4_b);
    const rule: Rule = .{ .ip_version = .ipv4, .protocol = 1, .destination = dst, .destination_port_first = 0, .destination_port_last = 0 };
    _ = try switcher.addRule(1, gen.a, 1, .egress, rule);
    _ = try switcher.addRule(2, gen.b, 1, .ingress, rule);
    try std.testing.expectEqual(@as(usize, 1), switcher.decide(1, gen.a, frame[0..42]).count);

    // Forged IP source, forged MAC source, and a port-ranged ICMP rule are all rejected.
    var forged_ip = frame;
    forged_ip[29] = 9;
    try std.testing.expectEqual(DropReason.unauthorized_source_address, switcher.decide(1, gen.a, forged_ip[0..42]).drop_reason);
    var forged_mac = frame;
    forged_mac[11] = 0x77;
    try std.testing.expectEqual(DropReason.spoofed_mac, switcher.decide(1, gen.a, forged_mac[0..42]).drop_reason);
    var ranged = rule;
    ranged.destination_port_last = 5;
    try std.testing.expectError(error.Invalid, switcher.addRule(1, gen.a, 2, .egress, ranged));
}

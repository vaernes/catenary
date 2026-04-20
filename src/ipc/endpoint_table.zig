const identity = @import("identity.zig");

pub const EndpointTable = struct {
    pub const MAX_ENDPOINTS: usize = 32;

    slots: [MAX_ENDPOINTS]Slot = undefined,
    next_dynamic: identity.EndpointId = identity.FIRST_DYNAMIC_ENDPOINT,
    reserved_netd_service: u32 = 0,
    reserved_storaged_service: u32 = 0,
    reserved_dashd_service: u32 = 0,

    pub const Slot = struct {
        in_use: bool = false,
        endpoint: identity.EndpointId = 0,
        target: identity.LocalEntity = .{ .service = 0 },
    };

    pub fn init(self: *EndpointTable) void {
        for (0..MAX_ENDPOINTS) |i| {
            self.slots[i] = .{};
        }
        self.next_dynamic = identity.FIRST_DYNAMIC_ENDPOINT;
        self.reserved_netd_service = 0;
        self.reserved_storaged_service = 0;
        self.reserved_dashd_service = 0;
    }

    pub fn registerReservedNetdThread(self: *EndpointTable, thread_id: identity.ThreadId) void {
        // Best-effort: ensure there's exactly one netd mapping.
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.netd));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.netd), .{ .thread = thread_id });
    }

    pub fn registerReservedStoragedThread(self: *EndpointTable, thread_id: identity.ThreadId) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.storaged));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.storaged), .{ .thread = thread_id });
        self.reserved_storaged_service = 0;
    }

    pub fn registerReservedDashdThread(self: *EndpointTable, thread_id: identity.ThreadId) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.dashd));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.dashd), .{ .thread = thread_id });
        self.reserved_dashd_service = 0;
    }

    pub fn registerReservedContainerdThread(self: *EndpointTable, thread_id: identity.ThreadId) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.containerd));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.containerd), .{ .thread = thread_id });
    }

    pub fn registerReservedClusterdThread(self: *EndpointTable, thread_id: identity.ThreadId) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.clusterd));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.clusterd), .{ .thread = thread_id });
    }

    pub fn registerReservedInputdThread(self: *EndpointTable, thread_id: identity.ThreadId) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.inputd));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.inputd), .{ .thread = thread_id });
    }

    pub fn registerReservedWindowdThread(self: *EndpointTable, thread_id: identity.ThreadId) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.windowd));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.windowd), .{ .thread = thread_id });
    }

    pub fn registerReservedConfigdThread(self: *EndpointTable, thread_id: identity.ThreadId) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.configd));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.configd), .{ .thread = thread_id });
    }

    pub fn registerReservedStoragedService(self: *EndpointTable, service_id: u32) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.storaged));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.storaged), .{ .service = service_id });
        self.reserved_storaged_service = service_id;
    }

    pub fn registerReservedDashdService(self: *EndpointTable, service_id: u32) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.dashd));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.dashd), .{ .service = service_id });
        self.reserved_dashd_service = service_id;
    }

    pub fn registerReservedNetdService(self: *EndpointTable, service_id: u32) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.netd));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.netd), .{ .service = service_id });
        self.reserved_netd_service = service_id;
    }

    pub fn clearReservedNetdService(self: *EndpointTable, service_id: u32) bool {
        const endpoint = @intFromEnum(identity.ReservedEndpoint.netd);
        for (0..MAX_ENDPOINTS) |i| {
            if (!self.slots[i].in_use or self.slots[i].endpoint != endpoint) continue;
            switch (self.slots[i].target) {
                .service => |existing_service_id| {
                    if (existing_service_id == service_id) {
                        self.slots[i] = .{};
                        self.reserved_netd_service = 0;
                        return true;
                    }
                },
                else => {},
            }
            return false;
        }
        return false;
    }

    pub fn registerReservedKernelControlThread(self: *EndpointTable, thread_id: identity.ThreadId) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.kernel_control));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.kernel_control), .{ .thread = thread_id });
    }

    pub fn registerReservedRouterThread(self: *EndpointTable, thread_id: identity.ThreadId) void {
        self.unregisterEndpoint(@intFromEnum(identity.ReservedEndpoint.router));
        _ = self.insert(@intFromEnum(identity.ReservedEndpoint.router), .{ .thread = thread_id });
    }

    pub fn netdThreadId(self: *const EndpointTable) ?identity.ThreadId {
        const t = self.lookup(@intFromEnum(identity.ReservedEndpoint.netd)) orelse return null;
        return switch (t) {
            .thread => |tid| tid,
            else => null,
        };
    }

    pub fn routerThreadId(self: *const EndpointTable) ?identity.ThreadId {
        const t = self.lookup(@intFromEnum(identity.ReservedEndpoint.router)) orelse return null;
        return switch (t) {
            .thread => |tid| tid,
            else => null,
        };
    }

    pub fn netdTarget(self: *const EndpointTable) ?identity.LocalEntity {
        return self.lookup(@intFromEnum(identity.ReservedEndpoint.netd));
    }

    pub fn registerThread(self: *EndpointTable, thread_id: identity.ThreadId) identity.EndpointId {
        if (self.endpointForThread(thread_id)) |existing| return existing;

        const endpoint = self.next_dynamic;
        self.next_dynamic += 1;
        if (!self.insert(endpoint, .{ .thread = thread_id })) {
            // Table full: fall back to returning 0 (invalid endpoint).
            return 0;
        }
        return endpoint;
    }

    pub fn registerMicrovm(self: *EndpointTable, microvm_id: identity.MicrovmId) identity.EndpointId {
        if (self.endpointForMicrovm(microvm_id)) |existing| return existing;

        const endpoint = self.next_dynamic;
        self.next_dynamic += 1;
        if (!self.insert(endpoint, .{ .microvm = microvm_id })) {
            return 0;
        }
        return endpoint;
    }

    pub fn endpointForThread(self: *const EndpointTable, thread_id: identity.ThreadId) ?identity.EndpointId {
        for (self.slots) |slot| {
            if (!slot.in_use) continue;
            switch (slot.target) {
                .thread => |tid| if (tid == thread_id) return slot.endpoint,
                else => {},
            }
        }
        return null;
    }

    pub fn endpointForMicrovm(self: *const EndpointTable, microvm_id: identity.MicrovmId) ?identity.EndpointId {
        for (self.slots) |slot| {
            if (!slot.in_use) continue;
            switch (slot.target) {
                .microvm => |id| if (id == microvm_id) return slot.endpoint,
                else => {},
            }
        }
        return null;
    }

    pub fn lookup(self: *const EndpointTable, endpoint: identity.EndpointId) ?identity.LocalEntity {
        for (self.slots) |slot| {
            if (slot.in_use and slot.endpoint == endpoint) return slot.target;
        }
        return null;
    }

    pub fn unregisterEndpoint(self: *EndpointTable, endpoint: identity.EndpointId) void {
        for (0..MAX_ENDPOINTS) |i| {
            if (self.slots[i].in_use and self.slots[i].endpoint == endpoint) {
                self.slots[i] = .{};
                return;
            }
        }
    }

    fn insert(self: *EndpointTable, endpoint: identity.EndpointId, target: identity.LocalEntity) bool {
        for (0..MAX_ENDPOINTS) |i| {
            if (!self.slots[i].in_use) {
                self.slots[i] = .{
                    .in_use = true,
                    .endpoint = endpoint,
                    .target = target,
                };
                return true;
            }
        }
        return false;
    }
};

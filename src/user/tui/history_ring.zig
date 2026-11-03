const std = @import("std");

/// 16-entry command history recall ring buffer for Varde Shell and TUI line editors.
/// Supports circular rollover, immediate duplicate rejection, and uncommitted draft
/// (in-progress typing) stashing and restoration.
pub const HistoryRing = struct {
    pub const CAPACITY: usize = 16;
    pub const MAX_CMD_LEN: usize = 64;

    entries: [CAPACITY][MAX_CMD_LEN]u8 = @splat(@splat(0)),
    lens: [CAPACITY]usize = @splat(0),
    count: usize = 0,
    write_idx: usize = 0, // points to next write slot

    // browse_offset: -1 means not browsing (active draft line).
    // 0 means browsing the most recent command,
    // 1 means 1 command older, ..., count - 1 means oldest command.
    browse_offset: isize = -1,

    in_progress_buf: [MAX_CMD_LEN]u8 = @splat(0),
    in_progress_len: usize = 0,
    in_progress_cursor: usize = 0,

    pub fn init() HistoryRing {
        return .{};
    }

    /// Reset browse state and clear in-progress draft.
    pub fn resetBrowse(self: *HistoryRing) void {
        self.browse_offset = -1;
        self.in_progress_len = 0;
        self.in_progress_cursor = 0;
    }

    /// Push a command into the history ring.
    /// Rejects empty commands and immediate consecutive duplicates.
    /// Resets browse state.
    pub fn push(self: *HistoryRing, cmd: []const u8) void {
        const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
        if (trimmed.len == 0) {
            self.resetBrowse();
            return;
        }

        // Check immediate consecutive duplicate
        if (self.count > 0) {
            const last_slot = if (self.write_idx == 0) CAPACITY - 1 else self.write_idx - 1;
            const last_len = self.lens[last_slot];
            if (std.mem.eql(u8, self.entries[last_slot][0..last_len], trimmed)) {
                self.resetBrowse();
                return;
            }
        }

        const n = @min(trimmed.len, MAX_CMD_LEN);
        @memcpy(self.entries[self.write_idx][0..n], trimmed[0..n]);
        self.lens[self.write_idx] = n;
        self.write_idx = (self.write_idx + 1) % CAPACITY;
        if (self.count < CAPACITY) {
            self.count += 1;
        }
        self.resetBrowse();
    }

    pub const RecallResult = struct {
        text: []const u8,
        cursor: usize,
    };

    /// Recalls an older command (Up Arrow).
    /// If currently at draft (`browse_offset == -1`), stashes `current_draft` and `current_cursor`
    /// into `in_progress_buf` before recalling the most recent command.
    /// Clamps at the oldest command.
    pub fn recallUp(self: *HistoryRing, current_draft: []const u8, current_cursor: usize) ?RecallResult {
        if (self.count == 0) return null;

        if (self.browse_offset == -1) {
            const n = @min(current_draft.len, MAX_CMD_LEN);
            @memcpy(self.in_progress_buf[0..n], current_draft[0..n]);
            self.in_progress_len = n;
            self.in_progress_cursor = current_cursor;
            self.browse_offset = 0;
        } else if (self.browse_offset < @as(isize, @intCast(self.count)) - 1) {
            self.browse_offset += 1;
        }

        const cmd = self.getAtOffset(@as(usize, @intCast(self.browse_offset)));
        return RecallResult{
            .text = cmd,
            .cursor = cmd.len,
        };
    }

    /// Recalls a newer command (Down Arrow).
    /// If moving past the newest command (`browse_offset == 0`), restores the stashed
    /// in-progress draft and resets `browse_offset = -1`.
    pub fn recallDown(self: *HistoryRing) ?RecallResult {
        if (self.count == 0) return null;
        if (self.browse_offset == -1) return null;

        if (self.browse_offset > 0) {
            self.browse_offset -= 1;
            const cmd = self.getAtOffset(@as(usize, @intCast(self.browse_offset)));
            return RecallResult{
                .text = cmd,
                .cursor = cmd.len,
            };
        } else {
            // Advancing past newest -> restore in_progress draft
            self.browse_offset = -1;
            return RecallResult{
                .text = self.in_progress_buf[0..self.in_progress_len],
                .cursor = self.in_progress_cursor,
            };
        }
    }

    /// Returns whether the history ring is currently in browse mode.
    pub fn isBrowsing(self: *const HistoryRing) bool {
        return self.browse_offset >= 0;
    }

    fn getAtOffset(self: *const HistoryRing, offset: usize) []const u8 {
        const total = CAPACITY;
        const idx = (self.write_idx + total - 1 - (offset % total)) % total;
        const len = self.lens[idx];
        return self.entries[idx][0..len];
    }
};

//! Opt-in command metadata over upstream semantic cells. No output buffer,
//! viewport, layout, or native UI state is owned here.
const CommandBlocks = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const Screen = @import("Screen.zig");
const Page = @import("page.zig").Page;
const Cell = @import("page.zig").Cell;
const osc = @import("osc.zig");
const formatter = @import("formatter.zig");

pub const Id = u64;
pub const Part = enum { command, output, block, cwd };
pub const Phase = enum { editing, running, complete, incomplete };

/// An insertion boundary. `after` represents the cursor's pending-wrap case.
const Fence = struct {
    pin: *Pin,
    after: bool = false,
};

pub const Entry = struct {
    id: Id,
    prompt: *Pin,
    prompt_retained: bool = true,
    output_start: ?Fence = null,
    output_end: ?Fence = null,
    phase: Phase = .editing,
    exit_status: ?i32 = null,
    cwd: ?[]const u8 = null,
    command: ?[]const u8 = null,

    fn deinit(self: *Entry, alloc: Allocator, pages: *PageList) void {
        pages.untrackPin(self.prompt);
        if (self.output_start) |f| pages.untrackPin(f.pin);
        if (self.output_end) |f| pages.untrackPin(f.pin);
        if (self.cwd) |v| alloc.free(v);
        if (self.command) |v| alloc.free(v);
    }
};

/// Metadata-only page ordering cache. Pointer reuse is checked by serial.
/// New tail pages are indexed incrementally; reflow explicitly rebuilds it.
const Rank = struct { serial: u64, order: u64 };
const rank_step: u64 = 1 << 32;

alloc: Allocator,
entries: std.ArrayList(Entry) = .empty,
head: usize = 0,
next_id: Id = 1,
ranks: std.AutoHashMapUnmanaged(*PageList.List.Node, Rank) = .empty,
redraw: ?Id = null,

pub fn init(alloc: Allocator) CommandBlocks {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *CommandBlocks, pages: *PageList) void {
    self.clear(pages);
    self.entries.deinit(self.alloc);
    self.ranks.deinit(self.alloc);
}

pub fn clear(self: *CommandBlocks, pages: *PageList) void {
    for (self.entries.items[self.head..]) |*e| e.deinit(self.alloc, pages);
    self.entries.clearRetainingCapacity();
    self.head = 0;
    self.ranks.clearRetainingCapacity();
    self.redraw = null;
    // IDs are never reused, including across RIS and enable/disable.
}

pub fn rebuildRanks(self: *CommandBlocks, pages: *PageList) !void {
    self.ranks.clearRetainingCapacity();
    var node = pages.pages.first;
    var order: u64 = rank_step;
    while (node) |n| : (node = n.next) {
        try self.ranks.put(self.alloc, n, .{ .serial = n.serial, .order = order });
        order += rank_step;
    }
}

fn cachedRank(self: *const CommandBlocks, node: *PageList.List.Node) ?u64 {
    const r = self.ranks.get(node) orelse return null;
    return if (r.serial == node.serial) r.order else null;
}

fn rank(self: *CommandBlocks, pages: *PageList, node: *PageList.List.Node) !u64 {
    if (self.cachedRank(node)) |r| return r;
    // Find the nearest indexed predecessor without touching page contents.
    var first = node;
    while (first.prev) |prev| {
        if (self.cachedRank(prev) != null) break;
        first = prev;
    }
    var order: u64 = if (first.prev) |p| self.cachedRank(p).? else 0;
    var current = first;
    while (true) {
        var upper: ?u64 = null;
        var next = current.next;
        while (next) |n| : (next = n.next) {
            if (self.cachedRank(n)) |r| {
                upper = r;
                break;
            }
        }
        const new_order = if (upper) |u| blk: {
            if (u <= order + 1) {
                try self.rebuildRanks(pages);
                return self.cachedRank(node).?;
            }
            break :blk order + (u - order) / 2;
        } else order + rank_step;
        try self.ranks.put(self.alloc, current, .{ .serial = current.serial, .order = new_order });
        if (current == node) return new_order;
        order = new_order;
        current = current.next.?;
    }
}

fn before(self: *CommandBlocks, pages: *PageList, a: Pin, b: Pin) !bool {
    if (a.node == b.node) return a.y < b.y or (a.y == b.y and a.x < b.x);
    return try self.rank(pages, a.node) < try self.rank(pages, b.node);
}

pub fn get(self: *CommandBlocks, id: Id) ?*Entry {
    var low = self.head;
    var high = self.entries.items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const e = &self.entries.items[mid];
        if (e.id == id) return e;
        if (e.id < id) low = mid + 1 else high = mid;
    }
    return null;
}

fn nextEntry(self: *CommandBlocks, id: Id) ?*Entry {
    var low = self.head;
    var high = self.entries.items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (self.entries.items[mid].id <= id) low = mid + 1 else high = mid;
    }
    return if (low < self.entries.items.len) &self.entries.items[low] else null;
}

fn active(self: *CommandBlocks) ?*Entry {
    return if (self.entries.items.len > self.head) &self.entries.items[self.entries.items.len - 1] else null;
}

/// Prune only the evicted prefix. Keep surviving output and a running command
/// even when their original prompt has disappeared.
pub fn reconcile(self: *CommandBlocks, pages: *PageList) void {
    const top = pages.getTopLeft(.screen);
    while (self.head < self.entries.items.len) {
        const e = &self.entries.items[self.head];
        if (!e.prompt.garbage) break;
        const has_tail = if (e.output_end) |f|
            !f.pin.garbage and (f.after or !f.pin.eql(top))
        else
            false;
        if (e.phase == .running or has_tail) {
            e.prompt.* = top;
            e.prompt_retained = false;
            if (e.output_start) |*f| if (f.pin.garbage) {
                f.pin.* = top;
                f.after = false;
            };
            break;
        }
        e.deinit(self.alloc, pages);
        self.head += 1;
    }
    if (self.head > 64 and self.head * 2 >= self.entries.items.len) {
        const remaining = self.entries.items.len - self.head;
        std.mem.copyForwards(Entry, self.entries.items[0..remaining], self.entries.items[self.head..]);
        self.entries.items.len = remaining;
        self.head = 0;
    }
}

/// Erase/line operations only need to reconcile the active suffix. Completed
/// interactions whose prompt was erased cannot remain targets for later text
/// written at that location. Editing redraws and live commands keep identity.
pub fn invalidateActive(self: *CommandBlocks, screen: *Screen) !void {
    self.reconcile(&screen.pages);
    const top = screen.pages.getTopLeft(.active);
    var i = self.entries.items.len;
    while (i > self.head) {
        i -= 1;
        const e = &self.entries.items[i];
        if (!e.prompt.garbage and try self.before(&screen.pages, e.prompt.*, top)) break;
        if (e.prompt.garbage or
            ((e.phase == .complete or e.phase == .incomplete) and e.prompt_retained and
                e.prompt.rowAndCell().row.semantic_prompt == .none))
        {
            e.deinit(self.alloc, &screen.pages);
            _ = self.entries.orderedRemove(i);
        }
    }
}

pub fn atPin(self: *CommandBlocks, pages: *PageList, pin: Pin, cursor: Pin) !?*Entry {
    self.reconcile(pages);
    var low = self.head;
    var high = self.entries.items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (try self.before(pages, pin, self.entries.items[mid].prompt.*)) high = mid else low = mid + 1;
    }
    if (low == self.head) return null;
    const e = &self.entries.items[low - 1];
    if (e.prompt.garbage) return null;
    // An erased prompt is not a surviving command boundary.
    if (e.prompt_retained) {
        if (e.prompt.node.pageIfResident()) |page| {
            if (page.getRow(e.prompt.y).semantic_prompt == .none) return null;
        }
    }
    if (low == self.entries.items.len) {
        const end = if (e.output_end) |f| f.pin.* else cursor;
        if (try self.before(pages, end.left(end.x), pin.left(pin.x))) return null;
        if (e.output_end) |f| {
            if (!f.after and end.x == 0 and pin.node == end.node and pin.y == end.y and
                !(e.prompt.node == end.node and e.prompt.y == end.y)) return null;
        }
    }
    return e;
}

fn cursorFence(screen: *Screen) struct { pin: Pin, after: bool } {
    return .{ .pin = screen.cursor.page_pin.*, .after = screen.cursor.pending_wrap };
}

/// Called after upstream printing/indexing, never instead of it. Track the
/// written extent so moving the cursor backwards cannot truncate live output.
pub fn touch(self: *CommandBlocks, screen: *Screen) !void {
    self.reconcile(&screen.pages);
    _ = try self.rank(&screen.pages, screen.cursor.page_pin.node);
    const e = self.active() orelse return;
    if (e.phase != .running) return;
    const current = cursorFence(screen);
    if (e.output_end) |*f| {
        if (f.pin.garbage or try self.before(&screen.pages, f.pin.*, current.pin) or
            (f.pin.eql(current.pin) and current.after))
        {
            f.pin.* = current.pin;
            f.after = current.after;
        }
    }
}

pub fn observe(self: *CommandBlocks, screen: *Screen, cmd: osc.Command.SemanticPrompt, cwd: ?[]const u8) !void {
    const pages = &screen.pages;
    self.reconcile(pages);
    switch (cmd.action) {
        .fresh_line_new_prompt, .prompt_start => {
            if ((cmd.readOption(.prompt_kind) orelse .initial) != .initial) return;
            const pin = screen.cursor.page_pin.*;
            if (self.active()) |e| {
                const same_row = e.prompt.node == pin.node and e.prompt.y == pin.y;
                if (self.redraw == e.id or (e.phase == .editing and (same_row or cmd.action == .prompt_start))) {
                    e.prompt.* = pin;
                    e.prompt_retained = true;
                    self.redraw = null;
                    return;
                }
                if (e.phase == .running) e.phase = .incomplete;
            }
            const tracked = try pages.trackPin(pin);
            errdefer pages.untrackPin(tracked);
            const directory = if (cwd) |v| try self.alloc.dupe(u8, v) else null;
            errdefer if (directory) |v| self.alloc.free(v);
            try self.entries.append(self.alloc, .{ .id = self.next_id, .prompt = tracked, .cwd = directory });
            self.next_id += 1;
            _ = try self.rank(pages, pin.node);
        },
        .end_input_start_output => {
            const e = self.active() orelse return;
            if (e.phase != .editing) return;
            const f = cursorFence(screen);
            const start = try pages.trackPin(f.pin);
            errdefer pages.untrackPin(start);
            const end = try pages.trackPin(f.pin);
            errdefer pages.untrackPin(end);
            if (cwd) |v| {
                const directory = try self.alloc.dupe(u8, v);
                if (e.cwd) |old| self.alloc.free(old);
                e.cwd = directory;
            }
            e.output_start = .{ .pin = start, .after = f.after };
            e.output_end = .{ .pin = end, .after = f.after };
            e.phase = .running;
            if (cmd.readOption(.cmdline) != null or cmd.readOption(.cmdline_url) != null) {
                var aw: std.Io.Writer.Allocating = .init(self.alloc);
                defer aw.deinit();
                cmd.writeCommandLine(&aw.writer) catch return;
                e.command = try aw.toOwnedSlice();
            }
        },
        .end_command => {
            try self.touch(screen);
            const e = self.active() orelse return;
            e.phase = .complete;
            e.exit_status = cmd.readOption(.exit_code);
        },
        else => return,
    }
}

/// One reusable request for bindings, Cmd+C, and future native menus/multi-copy.
/// The caller holds terminal access while preparing/capturing a page. Encoding
/// the owned chunk does not access terminal storage and can run after unlocking.
pub const Extraction = struct {
    const Range = struct { start: *Pin, end: *Pin, content: Cell.SemanticContent, trailing: usize };
    alloc: Allocator,
    ranges: [2]?Range = .{ null, null },
    index: usize = 0,
    state: formatter.PageFormatter.TrailingState = .empty,
    initial: ?[]const u8 = null,
    separator: bool = false,
    epoch: u64,
    cols: u16,
    rows: u16,
    command_bytes: usize = 0,

    pub fn deinit(self: *Extraction, pages: *PageList) void {
        for (self.ranges) |r_| if (r_) |r| {
            pages.untrackPin(r.start);
            pages.untrackPin(r.end);
        };
        if (self.initial) |v| self.alloc.free(v);
    }

    pub const Chunk = struct {
        page: Page,
        alloc: Allocator,
        start: Pin,
        end: Pin,
        content: Cell.SemanticContent,
        last: bool,
        trailing: usize,
        separator: bool,

        pub fn deinit(self: *Chunk) void {
            self.alloc.free(self.page.memory);
        }
    };

    pub fn capture(self: *Extraction, pages: *PageList) !?Chunk {
        if (pages.page_serial_epoch != self.epoch or pages.cols != self.cols or pages.rows != self.rows) return error.StaleBlock;
        while (self.index < self.ranges.len) {
            const r = self.ranges[self.index] orelse {
                self.index += 1;
                continue;
            };
            if (r.start.garbage or r.end.garbage) return error.StaleBlock;
            const preserved = try r.start.node.pagePreservingState(self.alloc);
            // A compressed page is already an owned snapshot: transfer it
            // directly. Resident pages need one copy before terminal unlock.
            const page = switch (preserved) {
                .owned => |owned| owned.page,
                .borrowed => |source| source.cloneBuf(try self.alloc.alignedAlloc(
                    u8,
                    .fromByteUnits(std.heap.page_size_min),
                    source.memory.len,
                )),
            };
            const last = r.start.node == r.end.node;
            const end: Pin = if (last) r.end.* else .{ .node = r.start.node, .y = page.size.rows - 1, .x = page.size.cols - 1 };
            const start = r.start.*;
            const separator = self.separator and self.index == 1;
            if (separator) self.separator = false;
            if (last) self.index += 1 else r.start.* = .{ .node = r.start.node.next.? };
            return .{ .page = page, .alloc = self.alloc, .start = start, .end = end, .content = r.content, .last = last, .trailing = r.trailing, .separator = separator };
        }
        return null;
    }

    pub fn formatChunk(self: *Extraction, chunk: *const Chunk, opts_: formatter.Options, writer: *std.Io.Writer) !void {
        if (chunk.separator and (self.command_bytes > 0 or (if (self.initial) |v| v.len > 0 else false))) try writer.writeByte('\n');
        var opts = opts_;
        opts.semantic_content = chunk.content;
        var fmt = formatter.PageFormatter.init(&chunk.page, opts);
        fmt.start_x = chunk.start.x;
        fmt.start_y = chunk.start.y;
        fmt.end_x = chunk.end.x;
        fmt.end_y = chunk.end.y;
        fmt.trailing_state = self.state;
        var counting: CountingWriter = .{ .target = writer };
        self.state = try fmt.formatWithState(&counting.writer);
        if (chunk.last) {
            try counting.writer.splatByteAll('\n', self.state.rows -| chunk.trailing);
            self.state = .empty;
        }
        if (chunk.content == .input) self.command_bytes += counting.count;
    }
};

/// Counts emitted command bytes without allocating or re-encoding output.
const CountingWriter = struct {
    target: *std.Io.Writer,
    count: usize = 0,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CountingWriter = @alignCast(@fieldParentPtr("writer", w));
        const n = try self.target.writeSplat(data, splat);
        self.count += n;
        return n;
    }
};

fn addRange(self: *CommandBlocks, pages: *PageList, request: *Extraction, index: usize, start: Pin, fence: Fence, content: Cell.SemanticContent) !void {
    const end = if (fence.after) fence.pin.* else fence.pin.leftWrap(1) orelse return;
    if (try self.before(pages, end, start)) return;
    const tracked_start = try pages.trackPin(start);
    errdefer pages.untrackPin(tracked_start);
    const tracked_end = try pages.trackPin(end);
    request.ranges[index] = .{
        .start = tracked_start,
        .end = tracked_end,
        .content = content,
        // A partial final row has no terminating LF. Input also excludes the
        // structural submit newline, while retaining additional blank lines.
        .trailing = if (content == .input or fence.after or fence.pin.x != 0) 1 else 0,
    };
}

pub fn extract(self: *CommandBlocks, screen: *Screen, id: Id, part: Part) !Extraction {
    const pages = &screen.pages;
    self.reconcile(pages);
    const e = self.get(id) orelse return error.StaleBlock;
    if (e.prompt.garbage) return error.StaleBlock;
    if (e.prompt_retained) {
        var preserved = try e.prompt.node.pagePreservingState(self.alloc);
        defer preserved.deinit();
        if (preserved.page().getRow(e.prompt.y).semantic_prompt == .none) return error.StaleBlock;
    }
    var request: Extraction = .{ .alloc = self.alloc, .epoch = pages.page_serial_epoch, .cols = pages.cols, .rows = pages.rows };
    errdefer request.deinit(pages);
    if (part == .cwd) {
        if (e.cwd) |v| request.initial = try self.alloc.dupe(u8, v);
        return request;
    }
    if (part == .command or part == .block) {
        if (e.command) |v| {
            request.initial = try self.alloc.dupe(u8, v);
        } else if (e.prompt_retained) {
            const limit = e.output_start orelse blk: {
                // Editing/missing-C commands use existing semantic cells up
                // to the current cursor. Unknown output isn't guessed.
                break :blk if (self.nextEntry(e.id)) |next| Fence{ .pin = next.prompt } else Fence{ .pin = screen.cursor.page_pin, .after = screen.cursor.pending_wrap };
            };
            try self.addRange(pages, &request, 0, e.prompt.*, limit, .input);
        }
    }
    if (part == .output or part == .block) {
        if (e.output_start) |start| if (e.output_end) |end| {
            const p = if (start.after) start.pin.rightWrap(1) orelse return request else start.pin.*;
            try self.addRange(pages, &request, 1, p, end, .output);
        };
    }
    request.separator = part == .block and (request.initial != null or request.ranges[0] != null);
    return request;
}

const testing = std.testing;
const Terminal = @import("Terminal.zig");
const Stream = @import("stream_terminal.zig").Stream;

fn testExtract(t: *Terminal, id: Id, part: Part, trim: bool) ![]u8 {
    const screen = t.screens.get(.primary).?;
    var request = try screen.command_blocks.?.extract(screen, id, part);
    defer request.deinit(&screen.pages);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    if (request.initial) |v| try aw.writer.writeAll(v);
    while (try request.capture(&screen.pages)) |chunk_| {
        var chunk = chunk_;
        defer chunk.deinit();
        try request.formatChunk(&chunk, .{ .emit = .plain, .unwrap = true, .trim = trim }, &aw.writer);
    }
    return aw.toOwnedSlice();
}

fn expectText(t: *Terminal, id: Id, part: Part, expected: []const u8) !void {
    const text = try testExtract(t, id, part, true);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "CommandBlocks OSC extraction preserves Unicode wraps and blank output" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 12, .rows = 8, .max_scrollback_bytes = 1024 * 1024 });
    defer t.deinit(testing.allocator);
    try t.setCommandBlocks(true);
    try t.setPwd("/tmp/work");
    var stream: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer stream.deinit();
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07echo cafe\xcc\x81 \xf0\x9f\x98\x80\r\n\x1b]133;C\x07\r\nabcdefghijklmnopqrst\r\n\r\n\x1b]133;D;7\x07\x1b]133;A\x07$ \x1b]133;B\x07");
    const blocks = t.screens.active.command_blocks.?;
    const id = blocks.entries.items[0].id;
    try testing.expectEqual(@as(?i32, 7), blocks.get(id).?.exit_status);
    try expectText(&t, id, .command, "echo cafe\xcc\x81 \xf0\x9f\x98\x80");
    try expectText(&t, id, .output, "\nabcdefghijklmnopqrst\n\n");
    try expectText(&t, id, .block, "echo cafe\xcc\x81 \xf0\x9f\x98\x80\n\nabcdefghijklmnopqrst\n\n");
    try expectText(&t, id, .cwd, "/tmp/work");
}

test "CommandBlocks multiline command excludes continuation prompts" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 30, .rows = 8 });
    defer t.deinit(testing.allocator);
    try t.setCommandBlocks(true);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07printf 'hello\r\n\x1b]133;P;k=s\x07> \x1b]133;B\x07world'\r\n\x1b]133;C\x07hello\r\nworld\x1b]133;D;0\x07");
    const blocks = t.screens.active.command_blocks.?;
    try testing.expectEqual(@as(usize, 1), blocks.entries.items.len);
    try expectText(&t, blocks.entries.items[0].id, .command, "printf 'hello\nworld'");
    try expectText(&t, blocks.entries.items[0].id, .output, "hello\nworld");
}

test "CommandBlocks zero output empty command missing status and live copy" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 10 });
    defer t.deinit(testing.allocator);
    try t.setCommandBlocks(true);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07true\r\n\x1b]133;C\x07\x1b]133;D\x07");
    const id = t.screens.active.command_blocks.?.entries.items[0].id;
    try expectText(&t, id, .output, "");
    try expectText(&t, id, .block, "true");
    try testing.expectEqual(Phase.complete, t.screens.active.command_blocks.?.get(id).?.phase);
    try testing.expectEqual(@as(?i32, null), t.screens.active.command_blocks.?.get(id).?.exit_status);
    s.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07\r\n\x1b]133;C\x07\x1b]133;D;0\x07");
    const empty = t.screens.active.command_blocks.?.entries.items[1].id;
    try expectText(&t, empty, .block, "");
    s.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07yes\r\n\x1b]133;C\x07first\r\nsecond");
    const live = t.screens.active.command_blocks.?.entries.items[2].id;
    try expectText(&t, live, .output, "first\nsecond");
    s.nextSlice("\x1b]133;A\x07");
    try testing.expectEqual(Phase.incomplete, t.screens.active.command_blocks.?.get(live).?.phase);
}

test "CommandBlocks isolation disabled alternate reset and stale requests" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    const pins = t.screens.active.pages.countTrackedPins();
    s.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07echo x\r\n\x1b]133;C\x07x\r\n\x1b]133;D;0\x07");
    try testing.expect(t.screens.active.command_blocks == null);
    try testing.expectEqual(pins, t.screens.active.pages.countTrackedPins());
    try t.setCommandBlocks(true);
    s.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07echo y\r\n\x1b]133;C\x07y\r\n\x1b]133;D;3\x07");
    const blocks = t.screens.active.command_blocks.?;
    const id = blocks.entries.items[blocks.entries.items.len - 1].id;
    const count = blocks.entries.items.len;
    s.nextSlice("\x1b[?1049h\x1b]133;A\x07fake\x1b]133;C\x07\x1b]133;D;9\x07\x1b[?1049l");
    try testing.expectEqual(count, blocks.entries.items.len);
    try testing.expectEqual(@as(?i32, 3), blocks.get(id).?.exit_status);
    var request = try blocks.extract(t.screens.active, id, .output);
    defer request.deinit(&t.screens.get(.primary).?.pages);
    t.fullReset();
    try testing.expectError(error.StaleBlock, request.capture(&t.screens.active.pages));
    try testing.expect(blocks.get(id) == null);
    const next_id = blocks.next_id;
    try t.setCommandBlocks(false);
    try t.setCommandBlocks(true);
    try testing.expectEqual(next_id, t.screens.active.command_blocks.?.next_id);
}

test "CommandBlocks large output survives prompt eviction without truncation" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 80, .rows = 5, .max_scrollback_bytes = 16 * 1024 * 1024 });
    defer t.deinit(testing.allocator);
    try t.setCommandBlocks(true);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07seq\r\n\x1b]133;C\x07");
    const id = t.screens.active.command_blocks.?.entries.items[0].id;
    for (0..10000) |_| s.nextSlice("abcdefghij\r\n");
    s.nextSlice("\x1b]133;D;0\x07");
    const output = try testExtract(&t, id, .output, true);
    defer testing.allocator.free(output);
    try testing.expect(output.len > 64 * 1024);
    try testing.expect(std.mem.endsWith(u8, output, "abcdefghij\n"));
    t.setScrollbackMaxBytes(10000);
    t.screens.active.command_blocks.?.reconcile(&t.screens.active.pages);
    try testing.expect(!t.screens.active.command_blocks.?.get(id).?.prompt_retained);
    const retained = try testExtract(&t, id, .output, true);
    defer testing.allocator.free(retained);
    try testing.expect(retained.len > 0);
    try testing.expect(retained.len < output.len);
}

test "CommandBlocks resize redraw preserves identity and extraction" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 8 });
    defer t.deinit(testing.allocator);
    try t.setCommandBlocks(true);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();
    s.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07echo 1234567890123456789\r\n\x1b]133;C\x07result\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07edit");
    const blocks = t.screens.active.command_blocks.?;
    const completed = blocks.entries.items[0].id;
    const editing = blocks.entries.items[1].id;
    try t.resize(testing.allocator, .{ .cols = 10, .rows = 8 });
    s.nextSlice("\r\x1b]133;A\x07$ \x1b]133;B\x07edit");
    try testing.expectEqual(@as(usize, 2), blocks.entries.items.len);
    try testing.expectEqual(editing, blocks.entries.items[1].id);
    try expectText(&t, completed, .command, "echo 1234567890123456789");
    try expectText(&t, completed, .output, "result\n");
}

test "CommandBlocks empty continuation lines and leading multiline prompt" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 30, .rows = 10 });
    defer t.deinit(testing.allocator);
    try t.setCommandBlocks(true);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]133;A\x07heading\r\n\x1b]133;P;k=s\x07$ \x1b]133;B\x07cat <<EOF\r\n\x1b]133;P;k=s\x07> \x1b]133;B\x07\r\n\x1b]133;P;k=s\x07> \x1b]133;B\x07EOF\r\n\x1b]133;C\x07\r\n\x1b]133;D;0\x07");
    const id = t.screens.active.command_blocks.?.entries.items[0].id;
    try expectText(&t, id, .command, "cat <<EOF\n\nEOF");
    try expectText(&t, id, .output, "\n");
}

test "CommandBlocks padding whitespace pending wrap and explicit command metadata" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 8, .rows = 10 });
    defer t.deinit(testing.allocator);
    try t.setCommandBlocks(true);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]133;P;k=i\x07$ \x1b]133;I\x07echo\r\n\x1b]133;C;cmdline_url=printf%20hi\x07abcdefgh\x1b]133;D;0\x07");
    const id = t.screens.active.command_blocks.?.entries.items[0].id;
    try expectText(&t, id, .command, "printf hi");
    try expectText(&t, id, .block, "printf hi\nabcdefgh");
    s.nextSlice("\r\n\x1b]133;A\x07$ \x1b]133;B\x07echo\r\n\x1b]133;C\x07a  \r\nb  \x1b]133;D;0\x07");
    const whitespace = t.screens.active.command_blocks.?.entries.items[1].id;
    const raw = try testExtract(&t, whitespace, .output, false);
    defer testing.allocator.free(raw);
    try testing.expectEqualStrings("a  \nb  ", raw);
    try expectText(&t, whitespace, .output, "a\nb");
}

test "CommandBlocks extraction cancels on reflow and chunks preserve compression" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 40, .rows = 4, .max_scrollback_bytes = 1024 * 1024 });
    defer t.deinit(testing.allocator);
    try t.setCommandBlocks(true);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07seq\r\n\x1b]133;C\x07");
    for (0..300) |_| s.nextSlice("line\r\n");
    s.nextSlice("\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07");
    const blocks = t.screens.active.command_blocks.?;
    const id = blocks.entries.items[0].id;
    _ = t.screens.active.pages.compress(.drain);
    const node = t.screens.active.pages.pages.first.?;
    const storage = node.storage();
    var request = try blocks.extract(t.screens.active, id, .output);
    defer request.deinit(&t.screens.active.pages);
    var chunk = (try request.capture(&t.screens.active.pages)).?;
    defer chunk.deinit();
    try testing.expectEqual(storage, node.storage());
    try t.resize(testing.allocator, .{ .cols = 30, .rows = 4 });
    try testing.expectError(error.StaleBlock, request.capture(&t.screens.active.pages));
}

test "CommandBlocks erased interactions release metadata and cannot retarget clipboard" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 30, .rows = 8 });
    defer t.deinit(testing.allocator);
    try t.setCommandBlocks(true);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07echo old\r\n\x1b]133;C\x07old\r\n\x1b]133;D;0\x07");
    const blocks = t.screens.active.command_blocks.?;
    const old = blocks.entries.items[0].id;
    s.nextSlice("\x1b[2J\x1b[H\x1b]133;A\x07$ \x1b]133;B\x07echo new\r\n\x1b]133;C\x07new\r\n\x1b]133;D;0\x07");
    try testing.expect(blocks.get(old) == null);
    try testing.expectError(error.StaleBlock, blocks.extract(t.screens.active, old, .block));
    for (0..100) |_| {
        s.nextSlice("\x1b[2J\x1b[H\x1b]133;A\x07$ \x1b]133;B\x07echo x\r\n\x1b]133;C\x07x\r\n\x1b]133;D;0\x07");
    }
    try testing.expectEqual(@as(usize, 1), blocks.entries.items.len - blocks.head);
}

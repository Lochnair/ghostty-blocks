//! A viewport-only decoration snapshot. Positions are ordinary viewport rows;
//! no scrolling, row capture, padding, or terminal coordinates are changed.
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const size = @import("size.zig");

pub const Color = enum { unknown, running, success, failure, selected };
pub const Marker = struct {
    id: terminal.CommandBlocks.Id,
    first_row: u16,
    end_row: u16,
    color: Color,
};

/// The gutter uses existing padding exclusively. Keep a pixel clear of both
/// the surface edge and terminal text. Narrow padding hides markers.
pub fn gutterWidth(padding_left: u32) u32 {
    return if (padding_left >= 4) @min(6, padding_left - 2) else 0;
}

pub fn hitGutter(surface_size: size.Size, x: f64, y: f64) ?u16 {
    if (surface_size.cell.width == 0 or surface_size.cell.height == 0) return null;
    if (gutterWidth(surface_size.padding.left) == 0 or x < 0 or
        x >= @as(f64, @floatFromInt(surface_size.padding.left)) or
        y < @as(f64, @floatFromInt(surface_size.padding.top))) return null;
    const row = (y - @as(f64, @floatFromInt(surface_size.padding.top))) /
        @as(f64, @floatFromInt(surface_size.cell.height));
    if (row >= @as(f64, @floatFromInt(surface_size.grid().rows))) return null;
    return @intFromFloat(row);
}

/// Call while terminal access is protected. Only captured viewport rows are
/// inspected, and the result contains no terminal pointers.
pub fn snapshot(alloc: std.mem.Allocator, t: *terminal.Terminal, state: *const terminal.RenderState, selected: ?terminal.CommandBlocks.Id) ![]const Marker {
    if (t.screens.active_key != .primary) return &.{};
    const screen = t.screens.active;
    const blocks = screen.command_blocks orelse return &.{};
    var result: std.ArrayList(Marker) = .empty;
    errdefer result.deinit(alloc);
    const start = state.viewportStart();
    for (start..start + state.rows) |i| {
        const row = state.row_data.get(i);
        const e = (try blocks.atPin(&screen.pages, row.pin, screen.cursor.page_pin.*)) orelse continue;
        const color: Color = if (selected == e.id) .selected else switch (e.phase) {
            .running => .running,
            .editing, .incomplete => .unknown,
            .complete => if (e.exit_status) |code| if (code == 0) .success else .failure else .unknown,
        };
        const y: u16 = @intCast(i - start);
        if (result.items.len > 0) {
            const previous = &result.items[result.items.len - 1];
            if (previous.id == e.id and previous.end_row == y) {
                previous.end_row = y + 1;
                continue;
            }
        }
        try result.append(alloc, .{ .id = e.id, .first_row = y, .end_row = y + 1, .color = color });
    }
    return result.toOwnedSlice(alloc);
}

test "BlockMarkers gutter preserves grid and excludes terminal cells" {
    const testing = std.testing;
    const s: size.Size = .{ .screen = .{ .width = 800, .height = 600 }, .cell = .{ .width = 10, .height = 20 }, .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 } };
    const columns = s.grid().columns;
    try testing.expectEqual(@as(?u16, 0), hitGutter(s, 7, 5));
    try testing.expectEqual(@as(?u16, null), hitGutter(s, 8, 5));
    try testing.expectEqual(@as(?u16, null), hitGutter(s, 7, 3));
    try testing.expectEqual(@as(u32, 0), gutterWidth(0));
    try testing.expectEqual(columns, s.grid().columns);
}

test "BlockMarkers snapshot uses viewport rows and isolates alternate screen" {
    const testing = std.testing;
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 8 });
    defer t.deinit(testing.allocator);
    try t.setCommandBlocks(true);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]133;A\x07$ \x1b]133;B\x07echo x\r\n\x1b]133;C\x07x\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07");
    const id = t.screens.active.command_blocks.?.entries.items[0].id;
    var state: terminal.RenderState = .empty;
    defer state.deinit(testing.allocator);
    try state.update(testing.allocator, &t);
    const markers = try snapshot(testing.allocator, &t, &state, id);
    defer testing.allocator.free(markers);
    try testing.expectEqual(@as(usize, 2), markers.len);
    try testing.expectEqual(Color.selected, markers[0].color);
    try testing.expectEqual(@as(u16, 0), markers[0].first_row);
    try testing.expectEqual(@as(u16, 2), markers[0].end_row);
    try testing.expectEqual(@as(u16, 3), markers[1].end_row);
    // Ordinary terminal selection can cross both command blocks.
    try t.screens.active.select(.init(t.screens.active.pages.getTopLeft(.screen), t.screens.active.cursor.page_pin.*, false));
    try state.update(testing.allocator, &t);
    const selected = try t.screens.active.selectionString(testing.allocator, .{ .sel = t.screens.active.selection.?, .trim = true });
    defer testing.allocator.free(selected);
    try testing.expect(std.mem.indexOf(u8, selected, "echo x\nx\n$") != null);
    stream.nextSlice("\x1b[?1049h");
    try state.update(testing.allocator, &t);
    try testing.expectEqual(@as(usize, 0), (try snapshot(testing.allocator, &t, &state, id)).len);
}

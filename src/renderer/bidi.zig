//! BiDi helpers for renderer-side visual coordinate mapping.
//!
//! The font shaper keeps cells at logical positions and the renderer moves
//! them to visual columns using the map built here. Everything that draws at
//! a column (cells, cursor) must use this one map so they can't disagree.
//! Rows with no strong-RTL codepoints return null before allocating.

const std = @import("std");
const Allocator = std.mem.Allocator;
const itijah = @import("itijah");
const terminal = @import("../terminal/main.zig");

/// Build the row's logical-to-visual column map. Returns null when the row
/// has no strong-RTL codepoints. Caller owns the returned slice.
///
/// The base direction is the first strong character (UAX #9 P2/P3), and it
/// must match the base direction the run iterator resolves in the shaper.
///
/// Only the row's content is reordered, so a row with an RTL base stays
/// left-aligned rather than being pushed right by its trailing blank cells.
/// With `justify`, RTL-base rows are rotated so that content ends at the
/// right edge and the blank cells fill the left.
pub fn visualMap(
    alloc: Allocator,
    cells: []const terminal.page.Cell,
    justify: bool,
) !?[]u16 {
    if (!rowHasRtl(cells)) return null;

    // rowHasRtl guarantees at least one filled cell.
    const content = lastFilledCell(cells).? + 1;

    const cps = try alloc.alloc(u21, content);
    defer alloc.free(cps);
    for (cells[0..content], 0..) |cell, idx| {
        const cp: u32 = cell.codepoint();
        cps[idx] = if (cp == 0) ' ' else @intCast(cp);
    }

    var dir: itijah.ParDirection = .auto_ltr;
    const emb = try itijah.getParEmbeddingLevels(alloc, cps, &dir);
    defer alloc.free(emb.levels);

    const l_to_v = try itijah.logToVis(alloc, emb.levels, dir.toLevel());
    defer alloc.free(l_to_v);

    const out = try alloc.alloc(u16, cells.len);
    for (l_to_v, 0..) |v, i| out[i] = @intCast(v);
    for (content..cells.len) |i| out[i] = @intCast(i);

    if (justify and (dir == .rtl or dir == .auto_rtl)) {
        const shift = cells.len - content;
        for (out) |*v| v.* = if (v.* < content)
            @intCast(v.* + shift)
        else
            @intCast(v.* - content);
    }

    return out;
}

/// The visual column of a single logical column. Falls back to the logical
/// column when it is out of range or the map can't be allocated, because a
/// misplaced cursor is better than a failed frame.
pub fn visualX(
    alloc: Allocator,
    cells: []const terminal.page.Cell,
    logical_x: u16,
    justify: bool,
) u16 {
    if (logical_x >= cells.len) return logical_x;
    const map = (visualMap(alloc, cells, justify) catch return logical_x) orelse
        return logical_x;
    defer alloc.free(map);
    return map[logical_x];
}

/// The logical column displayed at a visual column, for mapping the mouse.
pub const Logical = struct {
    x: u16,

    /// The cell is displayed right-to-left, so pointer motion within it runs
    /// opposite to logical order.
    rtl: bool,
};

/// Inverse of `visualMap` for a single column. Returns null when the column
/// isn't reordered: an LTR row, out of range, or the map can't be allocated.
pub fn logicalX(
    alloc: Allocator,
    cells: []const terminal.page.Cell,
    visual_x: u16,
    justify: bool,
) ?Logical {
    const map = (visualMap(alloc, cells, justify) catch return null) orelse
        return null;
    defer alloc.free(map);

    const i = std.mem.indexOfScalar(u16, map, visual_x) orelse return null;
    return .{
        .x = @intCast(i),
        .rtl = (i + 1 < map.len and map[i + 1] + 1 == map[i]) or
            (i > 0 and map[i - 1] == map[i] + 1),
    };
}

fn rowHasRtl(cells: []const terminal.page.Cell) bool {
    for (cells) |cell| {
        const cp: u32 = cell.codepoint();
        if (cp == 0) continue;
        const cls = itijah.unicode.bidiClass(@intCast(cp));
        if (itijah.unicode.isRtlStrong(cls)) return true;
    }
    return false;
}

fn lastFilledCell(cells: []const terminal.page.Cell) ?usize {
    var i: usize = cells.len;
    while (i > 0) {
        i -= 1;
        if (!cells[i].isEmpty()) return i;
    }
    return null;
}

const TestRow = struct {
    t: terminal.Terminal,
    state: terminal.RenderState = .empty,

    fn init(alloc: Allocator, cols: u16, text: []const u8) !*TestRow {
        const self = try alloc.create(TestRow);
        errdefer alloc.destroy(self);
        self.* = .{ .t = try .init(std.testing.io, alloc, .{ .cols = cols, .rows = 3 }) };
        var s = self.t.vtStream();
        defer s.deinit();
        s.nextSlice(text);
        try self.state.update(alloc, &self.t);
        return self;
    }

    fn deinit(self: *TestRow, alloc: Allocator) void {
        self.state.deinit(alloc);
        self.t.deinit(alloc);
        alloc.destroy(self);
    }

    fn cells(self: *const TestRow) []const terminal.page.Cell {
        return self.state.row_data.get(0).cells.slice().items(.raw);
    }
};

test "visualMap: ltr-only row has no map" {
    const alloc = std.testing.allocator;
    const row: *TestRow = try .init(alloc, 10, "ABCD");
    defer row.deinit(alloc);

    try std.testing.expectEqual(null, try visualMap(alloc, row.cells(), false));
    try std.testing.expectEqual(2, visualX(alloc, row.cells(), 2, false));
}

test "visualMap: arabic row reverses and stays left-aligned" {
    const alloc = std.testing.allocator;
    const row: *TestRow = try .init(alloc, 10, "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}");
    defer row.deinit(alloc);

    const map = (try visualMap(alloc, row.cells(), false)).?;
    defer alloc.free(map);
    try std.testing.expectEqualSlices(
        u16,
        &.{ 4, 3, 2, 1, 0, 5, 6, 7, 8, 9 },
        map,
    );
}

test "visualMap: trailing punctuation goes to the left of arabic" {
    const alloc = std.testing.allocator;
    const row: *TestRow = try .init(alloc, 10, "\u{0645}\u{0631}!");
    defer row.deinit(alloc);

    const map = (try visualMap(alloc, row.cells(), false)).?;
    defer alloc.free(map);
    try std.testing.expectEqualSlices(u16, &.{ 2, 1, 0 }, map[0..3]);
}

test "visualMap: arabic-first mixed row uses rtl base" {
    const alloc = std.testing.allocator;
    // Two Arabic letters, a space, then "ab". The Latin run is read second
    // so in an RTL paragraph it sits to the left and keeps its own order.
    const row: *TestRow = try .init(alloc, 10, "\u{0645}\u{0631} ab");
    defer row.deinit(alloc);

    const map = (try visualMap(alloc, row.cells(), false)).?;
    defer alloc.free(map);
    try std.testing.expectEqualSlices(u16, &.{ 4, 3, 2, 0, 1 }, map[0..5]);
}

test "visualMap: latin-first mixed row uses ltr base" {
    const alloc = std.testing.allocator;
    const row: *TestRow = try .init(alloc, 10, "ab \u{0645}\u{0631}");
    defer row.deinit(alloc);

    const map = (try visualMap(alloc, row.cells(), false)).?;
    defer alloc.free(map);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2, 4, 3 }, map[0..5]);
}

test "visualMap: justify rotates content to the right edge" {
    const alloc = std.testing.allocator;
    const row: *TestRow = try .init(alloc, 6, "\u{0645}\u{0631}");
    defer row.deinit(alloc);

    const map = (try visualMap(alloc, row.cells(), true)).?;
    defer alloc.free(map);
    try std.testing.expectEqualSlices(u16, &.{ 5, 4, 0, 1, 2, 3 }, map);
}

test "visualMap: justify leaves ltr-base rows alone" {
    const alloc = std.testing.allocator;
    const row: *TestRow = try .init(alloc, 6, "a\u{0645}");
    defer row.deinit(alloc);

    const map = (try visualMap(alloc, row.cells(), true)).?;
    defer alloc.free(map);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3, 4, 5 }, map);
}

test "logicalX: inverts visualMap and reports direction" {
    const alloc = std.testing.allocator;
    const row: *TestRow = try .init(alloc, 8, "ab \u{0645}\u{0631}");
    defer row.deinit(alloc);

    // Latin keeps its column, the Arabic pair is swapped, blanks are identity.
    const a = logicalX(alloc, row.cells(), 0, false).?;
    try std.testing.expectEqual(0, a.x);
    try std.testing.expect(!a.rtl);
    const first = logicalX(alloc, row.cells(), 4, false).?;
    try std.testing.expectEqual(3, first.x);
    try std.testing.expect(first.rtl);
    const blank = logicalX(alloc, row.cells(), 7, false).?;
    try std.testing.expectEqual(7, blank.x);
    try std.testing.expect(!blank.rtl);
}

test "logicalX: ltr row has no mapping" {
    const alloc = std.testing.allocator;
    const row: *TestRow = try .init(alloc, 8, "abc");
    defer row.deinit(alloc);
    try std.testing.expectEqual(null, logicalX(alloc, row.cells(), 1, false));
}

test "visualX: out of range returns the input" {
    const alloc = std.testing.allocator;
    const row: *TestRow = try .init(alloc, 10, "Hi");
    defer row.deinit(alloc);

    try std.testing.expectEqual(10, visualX(alloc, row.cells(), 10, false));
}

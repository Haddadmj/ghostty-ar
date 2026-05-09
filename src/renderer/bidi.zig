//! BiDi helpers for renderer-side visual coordinate mapping.
//!
//! The font shaper resolves UAX #9 embedding levels per row inside the run
//! iterator, but that work is scoped to shaping. The renderer needs the
//! same resolution to position the cursor at the visual cell, not the
//! logical cell. Rows with no strong-RTL codepoints early-exit before
//! allocating.

const std = @import("std");
const Allocator = std.mem.Allocator;
const itijah = @import("itijah");
const terminal = @import("../terminal/main.zig");

/// Translate a logical cell column to its visual column under UAX #9 with
/// an LTR base direction (matching the run iterator's choice). Returns the
/// input unchanged when the row contains no strong-RTL codepoints.
pub fn logicalToVisualX(
    alloc: Allocator,
    cells: []const terminal.page.Cell,
    logical_x: u16,
) !u16 {
    if (logical_x >= cells.len) return logical_x;

    if (!rowHasRtl(cells)) return logical_x;

    const cps = try alloc.alloc(u21, cells.len);
    defer alloc.free(cps);
    for (cells, 0..) |cell, idx| {
        const cp: u32 = cell.codepoint();
        cps[idx] = if (cp == 0) ' ' else @intCast(cp);
    }

    var dir: itijah.ParDirection = .ltr;
    const emb = try itijah.getParEmbeddingLevels(alloc, cps, &dir);
    defer alloc.free(emb.levels);

    const l_to_v = try itijah.logToVis(alloc, emb.levels, dir.toLevel());
    defer alloc.free(l_to_v);

    return @intCast(l_to_v[logical_x]);
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

/// Resolve the row's UAX #9 paragraph direction. `auto_ltr` defers to the
/// first strong directional character: pure-Arabic and pure-Hebrew rows
/// resolve RTL, mixed-script rows usually resolve LTR (their first strong
/// run is typically Latin). LTR-only rows early-exit without allocating.
pub fn paragraphIsRTL(
    alloc: Allocator,
    cells: []const terminal.page.Cell,
) !bool {
    if (!rowHasRtl(cells)) return false;

    const cps = try alloc.alloc(u21, cells.len);
    defer alloc.free(cps);
    for (cells, 0..) |cell, idx| {
        const cp: u32 = cell.codepoint();
        cps[idx] = if (cp == 0) ' ' else @intCast(cp);
    }

    var dir: itijah.ParDirection = .auto_ltr;
    const emb = try itijah.getParEmbeddingLevels(alloc, cps, &dir);
    defer alloc.free(emb.levels);

    return dir == .rtl or dir == .auto_rtl;
}

/// Index of the rightmost cell holding visible content, or null if the row
/// is empty. Used to compute the right-justify shift.
pub fn lastFilledCell(cells: []const terminal.page.Cell) ?usize {
    var i: usize = cells.len;
    while (i > 0) {
        i -= 1;
        if (!cells[i].isEmpty()) return i;
    }
    return null;
}

test "logicalToVisualX: ltr-only row returns input" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("ABCD");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const cells_slice = state.row_data.get(0).cells.slice();
    const cells_raw = cells_slice.items(.raw);

    try testing.expectEqual(@as(u16, 0), try logicalToVisualX(alloc, cells_raw, 0));
    try testing.expectEqual(@as(u16, 2), try logicalToVisualX(alloc, cells_raw, 2));
}

test "logicalToVisualX: arabic row reverses positions" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const cells_slice = state.row_data.get(0).cells.slice();
    const cells_raw = cells_slice.items(.raw);

    // Logical 0 (the first Arabic letter typed) should map to the visual
    // position at the right end of the Arabic run.
    const v0 = try logicalToVisualX(alloc, cells_raw, 0);
    const v4 = try logicalToVisualX(alloc, cells_raw, 4);
    try testing.expect(v0 > v4);
}

test "logicalToVisualX: x past row length returns input" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Hi");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const cells_slice = state.row_data.get(0).cells.slice();
    const cells_raw = cells_slice.items(.raw);

    try testing.expectEqual(
        @as(u16, @intCast(cells_raw.len)),
        try logicalToVisualX(alloc, cells_raw, @intCast(cells_raw.len)),
    );
}

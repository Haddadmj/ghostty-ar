const std = @import("std");
const options = @import("main.zig").options;
const run = @import("shaper/run.zig");
const feature = @import("shaper/feature.zig");
const configpkg = @import("../config.zig");
const terminal = @import("../terminal/main.zig");
const SharedGrid = @import("main.zig").SharedGrid;
pub const noop = @import("shaper/noop.zig");
pub const harfbuzz = @import("shaper/harfbuzz.zig");
pub const coretext = @import("shaper/coretext.zig");
pub const web_canvas = @import("shaper/web_canvas.zig");
pub const Cache = @import("shaper/Cache.zig");
pub const TextRun = run.TextRun;
pub const RunIterator = run.RunIterator;
pub const Feature = feature.Feature;
pub const FeatureList = feature.FeatureList;
pub const default_features = feature.default_features;

/// Shaper implementation for our compile options.
pub const Shaper = switch (options.backend) {
    .freetype,
    .freetype_windows,
    .fontconfig_freetype,
    .coretext_freetype,
    .coretext_harfbuzz,
    => harfbuzz.Shaper,

    // Note that coretext_freetype cannot use the coretext
    // shaper because the coretext shaper requests CoreText
    // font faces.
    .coretext => coretext.Shaper,

    .coretext_noshape => noop.Shaper,

    .web_canvas => web_canvas.Shaper,
};

/// A cell is a single glyph within a terminal that should be rendered
/// for a shaping call. Not all terminal cells may be present; only
/// cells that have a glyph that needs to be rendered.
pub const Cell = struct {
    /// The X position of this shaper cell relative to the offset of the
    /// run. Because runs are always within a single row, it is expected
    /// that the caller can reconstruct the full position of the cell by
    /// using the known Y position of the cell and adding the X position
    /// to the run offset.
    x: u16,

    /// An additional offset to apply to the rendering.
    x_offset: i16 = 0,
    y_offset: i16 = 0,

    /// The glyph index for this cell. The font index to use alongside
    /// this cell is available in the text run. This glyph index is only
    /// valid for a given GroupCache and FontIndex that was used to create
    /// the runs.
    glyph_index: u32,
};

/// Options for shapers.
pub const Options = struct {
    /// Font features to use when shaping.
    ///
    /// Note: eventually, this will move to font.Face probably as we may
    /// want to support per-face feature configuration. For now, we only
    /// support applying features globally.
    features: []const []const u8 = &.{},
};

/// Close the gaps ligatures leave in a shaped right-to-left run.
///
/// A ligature is one glyph covering several cells, so the cells it absorbed
/// stay empty and open a gap inside the word (or, with a fallback font whose
/// ligature is narrower than its cells, between letters). Moving each glyph
/// down by the number of absorbed cells below it collects those empty cells
/// at the run's logical end, which displays at the left of the RTL text next
/// to the whitespace that already separates it from what follows.
///
/// A cell with no codepoints, such as a wide character's tail, isn't absorbed
/// and keeps its place. `codepoints` is anything with a `cluster` field.
pub fn packRtlCells(
    alloc: std.mem.Allocator,
    cells: []Cell,
    codepoints: anytype,
    run_cells: u16,
) !void {
    const has_cp = try alloc.alloc(bool, run_cells);
    defer alloc.free(has_cp);
    @memset(has_cp, false);
    for (codepoints) |cp| {
        if (cp.cluster < run_cells) has_cp[cp.cluster] = true;
    }

    const has_glyph = try alloc.alloc(bool, run_cells);
    defer alloc.free(has_glyph);
    @memset(has_glyph, false);
    for (cells) |cell| {
        if (cell.x < run_cells) has_glyph[cell.x] = true;
    }

    const shift = try alloc.alloc(u16, run_cells);
    defer alloc.free(shift);
    var absorbed: u16 = 0;
    for (shift, has_cp, has_glyph) |*v, cp, glyph| {
        v.* = absorbed;
        if (cp and !glyph) absorbed += 1;
    }

    for (cells) |*cell| {
        if (cell.x < run_cells) cell.x -= shift[cell.x];
    }
}

test "packRtlCells closes ligature gaps" {
    const alloc = std.testing.allocator;
    const Cp = struct { cluster: u32 };

    // Four cells of text, where cell 1 absorbed cell 2.
    var cells = [_]Cell{
        .{ .x = 3, .glyph_index = 30 },
        .{ .x = 1, .glyph_index = 10 },
        .{ .x = 0, .glyph_index = 0 },
    };
    try packRtlCells(alloc, &cells, &[_]Cp{ .{ .cluster = 0 }, .{ .cluster = 1 }, .{ .cluster = 2 }, .{ .cluster = 3 } }, 4);
    try std.testing.expectEqual(2, cells[0].x);
    try std.testing.expectEqual(1, cells[1].x);
    try std.testing.expectEqual(0, cells[2].x);
}

test "packRtlCells keeps a wide character's tail cell" {
    const alloc = std.testing.allocator;
    const Cp = struct { cluster: u32 };

    // A wide glyph in cell 0 with its tail in cell 1, which has no codepoint.
    var cells = [_]Cell{
        .{ .x = 2, .glyph_index = 2 },
        .{ .x = 0, .glyph_index = 0 },
    };
    try packRtlCells(alloc, &cells, &[_]Cp{ .{ .cluster = 0 }, .{ .cluster = 2 } }, 3);
    try std.testing.expectEqual(2, cells[0].x);
}

/// Options for runIterator.
pub const RunOptions = struct {
    /// The font state for the terminal screen. This is mutable because
    /// cached values may be updated during shaping.
    grid: *SharedGrid,

    /// The cells for the row to shape.
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice = .empty,

    /// The x boundaries of the selection in this row.
    selection: ?[2]u16 = null,

    /// The cursor position within this row. This is used to break shaping
    /// on cursor boundaries. This can be disabled by setting this to
    /// null.
    cursor_x: ?usize = null,

    /// Apply the font break configuration to the run.
    pub fn applyBreakConfig(
        self: *RunOptions,
        config: configpkg.FontShapingBreak,
    ) void {
        if (!config.cursor) self.cursor_x = null;
    }
};

test {
    _ = Cache;
    _ = Shaper;

    // Always test noop
    _ = noop;
}

//! This benchmark measures the per-codepoint BiDi-class scan that the
//! font shaper's run iterator runs once per row before deciding whether
//! to take the LTR fast path. For LTR-only content this scan is the
//! entire BiDi cost.
const BidiScan = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const UTF8Decoder = @import("../terminal/UTF8Decoder.zig");
const global = @import("../global.zig");
const itijah = @import("itijah");

const log = std.log.scoped(.@"bidi-scan-bench");

opts: Options,

/// The file, opened in the setup function.
data_f: ?std.Io.File = null,

pub const Options = struct {
    /// Which test to run.
    mode: Mode = .scan,

    /// The data to read as a filepath. If this is "-" then we read stdin.
    /// If unset, the benchmark is a noop.
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// Baseline: decode codepoints, do nothing else. Establishes the cost
    /// of the decode loop the other modes share.
    noop,

    /// Per-codepoint strong-RTL check matching the run iterator's row scan.
    scan,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*BidiScan {
    const ptr = try alloc.create(BidiScan);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *BidiScan, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn benchmark(self: *BidiScan) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .scan => stepScan,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *BidiScan = @ptrCast(@alignCast(ptr));
    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn teardown(ptr: *anyopaque) void {
    const self: *BidiScan = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close(global.io());
        self.data_f = null;
    }
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *BidiScan = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;
    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = f.reader(global.io(), &read_buf);
    var r = &f_reader.interface;

    var d: UTF8Decoder = .{};
    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break;
        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| std.mem.doNotOptimizeAway(cp);
        }
    }
}

fn stepScan(ptr: *anyopaque) Benchmark.Error!void {
    const self: *BidiScan = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;
    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = f.reader(global.io(), &read_buf);
    var r = &f_reader.interface;

    var d: UTF8Decoder = .{};
    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break;
        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                const cls = itijah.unicode.bidiClass(@intCast(cp));
                std.mem.doNotOptimizeAway(itijah.unicode.isRtlStrong(cls));
            }
        }
    }
}

test BidiScan {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *BidiScan = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

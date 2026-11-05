const std = @import("std");
const language = @import("anathame");

/// Run Uiua's show primitive, avoiding the CLI's extra stack-display padding.
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var random_state = std.Random.DefaultPrng.init(1729);
    const random = random_state.random();
    var count: usize = 0;
    for (0..7) |rank| {
        for (0..8) |variant| {
            const shape = try a.alloc(usize, rank);
            var size: usize = 1;
            for (shape, 0..) |*dim, axis| {
                dim.* = if ((variant == 0 and axis == rank / 2) or (variant == 7 and axis + 1 == rank)) 0 else if (variant == 1) 1 else if (rank == 2 and variant == 6) 10 else 2;
                size *= dim.*;
            }
            const data = try a.alloc(f64, size);
            var source: std.Io.Writer.Allocating = .init(a);
            try source.writer.writeAll("&s ");
            if (rank > 0) {
                try source.writer.writeAll("reshape [");
                for (shape) |dim| try source.writer.print("{d} ", .{dim});
                try source.writer.writeAll("] ");
                try source.writer.writeByte('[');
            }
            for (data) |*n| {
                n.* = switch (variant) {
                    2 => @as(f64, @floatFromInt(random.intRangeAtMost(i32, -1000, 1000))) / 8,
                    3 => if (random.boolean()) std.math.pi else -std.math.inf(f64),
                    4 => if (random.boolean()) -0.0 else std.math.nan(f64),
                    else => @floatFromInt(random.intRangeAtMost(i32, -1000, 1000)),
                };
                if (std.math.isNan(n.*)) {
                    try source.writer.writeAll("NaN ");
                } else if (std.math.isInf(n.*)) {
                    try source.writer.writeAll("¯∞ ");
                } else if (n.* == std.math.pi) {
                    try source.writer.writeAll("π ");
                } else {
                    if (std.math.signbit(n.*)) try source.writer.writeAll("¯");
                    try source.writer.print("{d} ", .{@abs(n.*)});
                }
            }
            if (rank > 0) try source.writer.writeByte(']');
            const oracle = try std.process.run(a, init.io, .{ .argv = &.{ "uiua", "eval", source.written() } });
            switch (oracle.term) {
                .exited => |status| if (status != 0) {
                    std.debug.print("Uiua failed: {s}\n{s}\n", .{ source.written(), oracle.stderr });
                    return error.UiuaFailed;
                },
                else => return error.UiuaFailed,
            }
            var actual: std.Io.Writer.Allocating = .init(a);
            try language.runtime.writeValue(&actual.writer, .{ .data = data, .shape = shape });
            try actual.writer.writeByte('\n');
            const expected = try std.mem.replaceOwned(u8, a, oracle.stdout, "\r\n", "\n");
            if (!std.mem.eql(u8, expected, actual.written())) {
                std.debug.print("Display mismatch: {s}\nexpected:\n{s}actual:\n{s}", .{ source.written(), expected, actual.written() });
                return error.DisplayMismatch;
            }
            count += 1;
        }
    }
    std.debug.print("{d} display cases match Uiua (seed 1729, ranks 0–6).\n", .{count});
}

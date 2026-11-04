const std = @import("std");
const language = @import("anathame");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const seed = if (args.len > 1) try std.fmt.parseInt(u64, args[1], 10) else 1729;
    const cases = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 30;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var failures: usize = 0;
    for (0..cases) |i| {
        for ([_][]const u8{ "mul", "couple", "partition" }) |code| {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const allocator = arena.allocator();
            const x = @as(f64, @floatFromInt(random.intRangeAtMost(i32, -48, 48))) / 4;
            const y = @as(f64, @floatFromInt(random.intRangeAtMost(i32, -48, 48))) / 4;
            const is_partition = std.mem.eql(u8, code, "partition");
            const input = if (is_partition) switch (i % 6) {
                0 => "[1 2 3 4 5 6 7 8] [0 0 2 2 1 1 3 3]",
                1 => "[1 2 3 4 5 6] [1 1 -1 0 1 1]",
                2 => "[1 2 3] [0 -2 0]",
                3 => "[] []",
                4 => "[1_2 3_4 5_6 7_8] [2 2 1 1]",
                else => try std.fmt.allocPrint(allocator, "[{d}_{d} {d}_{d}] [1 2]", .{ x, y, y, x }),
            } else try std.fmt.allocPrint(allocator, "{d} {d}", .{ x, y });
            const source = if (is_partition) blk: {
                const split = std.mem.lastIndexOf(u8, input, " [").?;
                break :blk try std.fmt.allocPrint(allocator, "&p partition identity {s} {s}", .{ input[split + 1 ..], input[0..split] });
            } else try std.fmt.allocPrint(allocator, "&p {s} {s}", .{ code, input });
            const uiua_source = try std.mem.replaceOwned(u8, allocator, source, "-", "¯");
            const oracle = try std.process.run(allocator, init.io, .{ .argv = &.{ "uiua", "eval", uiua_source } });
            switch (oracle.term) {
                .exited => |status| if (status != 0) {
                    std.debug.print("Uiua failed: {s}\n", .{oracle.stderr});
                    return error.UiuaFailed;
                },
                else => return error.UiuaFailed,
            }
            const normalized = try std.mem.replaceOwned(u8, allocator, oracle.stdout, "¯", "-");
            const expected = try language.parser.parse(allocator, normalized);
            var memory = try language.ReservedBumpAllocator.init(64 * 1024 * 1024);
            defer memory.deinit();
            const program = try std.fmt.allocPrint(allocator, "{{ {s} }}", .{if (is_partition) "partition id" else code});
            const actual = try language.runtime.evaluate(&memory, program, input);
            var passed = expected.len == actual.len;
            for (expected, 0..) |instruction, index| {
                const value = switch (instruction) {
                    .literal => |value| value,
                    else => return error.InvalidOracleOutput,
                };
                if (index >= actual.len) break;
                const result = actual[index];
                if (!std.mem.eql(usize, value.shape, result.shape) or value.data.len != result.data.len) {
                    passed = false;
                    continue;
                }
                for (value.data, result.data) |want, got| {
                    if (!std.math.approxEqRel(f64, want, got, 1e-12) and !std.math.approxEqAbs(f64, want, got, 1e-12)) passed = false;
                }
            }
            std.debug.print("Uiua {s}, seed={d}, case={d}\ninput: {s}\nexpected: {s}result: {s}\n", .{ code, seed, i, input, oracle.stdout, if (passed) "PASS" else "FAIL" });
            if (!passed) failures += 1;
        }
    }
    if (failures != 0) return error.DifferentialMismatch;
}

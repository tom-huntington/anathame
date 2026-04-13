const std = @import("std");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator; // ../vendor/ReservedBumpAllocator/root.zig
const Expr = types.Expr;
const Value = types.Value;
const EvalContext = @import("eval.zig").EvalContext;

pub fn isHofName(name: []const u8) bool {
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const member = @field(@This(), decl.name);
        if (isHofFunction(member) and std.mem.eql(u8, name, decl.name)) {
            return true;
        }
    }
    return false;
}

pub fn Reduce(ctx: *EvalContext, result_dest: ?[]f64, args: *[1]Value, fn_arg: Expr.FuncExpr) Value {
    _ = result_dest;
    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("reduce expects an array"),
    };

    if (array.shape.len != 1) @panic("reduce only supports rank-1 arrays");
    if (array.data.len == 0) @panic("reduce requires a non-empty array");

    var acc: Value = .{
        .scalar = array.data[0],
    };

    for (array.data[1..]) |item| {
        acc = @import("eval.zig").evalFunc(ctx, null, &fn_arg, &.{
            acc,
            .{ .scalar = item },
        }) catch @panic("reduce function evaluation failed");
    }

    return acc;
}

pub fn Scan(ctx: *EvalContext, result_dest: ?[]f64, args: *[1]Value, fn_arg: Expr.FuncExpr) Value {
    const all = ctx.allocator;
    const array = switch (args[0]) {
        .array => |array| array,
        else => @panic("Scan expects an array"),
    };

    if (array.shape.len != 1) @panic("Scan only supports rank-1 arrays");
    if (array.data.len == 0) @panic("Scan requires a non-empty array");

    const result_data = if (result_dest) |dest| blk: {
        if (dest.len < array.data.len) @panic("Scan result destination too small");
        break :blk dest[0..array.data.len];
    } else all.allocator().alloc(f64, array.data.len) catch @panic("out of memory");

    result_data[0] = array.data[0];
    var acc: Value = .{ .scalar = array.data[0] };

    for (array.data[1..], 1..) |item, i| {
        const result = @import("eval.zig").evalFunc(ctx, result_data[i .. i + 1], &fn_arg, &.{
            acc,
            .{ .scalar = item },
        }) catch @panic("Scan function evaluation failed");
        acc = switch (result) {
            .scalar => result,
            .array => @panic("Scan function must return a scalar"),
        };
    }

    const result_shape = all.allocator().alloc(usize, 1) catch @panic("out of memory");
    result_shape[0] = array.data.len;
    return .{ .array = .{
        .data = result_data,
        .ownership = if (result_dest == null) .Exclusive else .Shared,
        .shape = result_shape,
    } };
}

pub fn partition(ctx: *EvalContext, result_dest: ?[]f64, args: *[2]Value, fn_arg: Expr.FuncExpr) Value {
    const all = ctx.allocator;
    _ = result_dest;
    const array = switch (args[0]) {
        .array => |arr| arr,
        else => @panic("partition expects an array"),
    };
    const mask = switch (args[1]) {
        .array => |arr| arr,
        else => @panic("partition expects an array"),
    };

    if (mask.shape.len != 1) @panic("partition markers must be rank 1");
    if (array.shape.len == 0) @panic("partition expects an array with rows");
    if (mask.shape[0] != array.shape[0]) @panic("partition markers length must match row count");

    // TODO loop over mask to find number of groups?? or just over allocate??
    var runs = PartitionRuns.init(mask.data);
    const row_size = rowSize(array.shape);

    const first_run = findNextIncludedRun(&runs) orelse {
        const empty = types.Array.initWithShape(all, &.{0});
        return .{ .array = empty };
    };

    const first_group = makeGroupView(all, array, row_size, first_run.start, first_run.len);

    const first_result = @import("eval.zig").evalFunc(ctx, null, &fn_arg, &.{.{ .array = first_group }}) catch @panic("partition function evaluation failed");

    const kept_capacity = array.shape[0];
    const output_item_len = switch (first_result) {
        .scalar => @as(usize, 1),
        .array => |result| result.data.len,
    };

    const output_depth = switch (first_result) {
        .scalar => 1,
        .array => |result| result.shape.len + 1,
    };

    var output = types.Array.initWithDepth(all, output_depth, kept_capacity * output_item_len);
    output.shape[0] = kept_capacity;
    switch (first_result) {
        .scalar => {},
        .array => |result| @memcpy(output.shape[1..], result.shape),
    }

    storeGroupResult(&output, 0, output_item_len, first_result);

    var kept_count: usize = 1;
    while (findNextIncludedRun(&runs)) |run| {
        const group = makeGroupView(all, array, row_size, run.start, run.len);
        const dest = output.data[kept_count * output_item_len .. (kept_count + 1) * output_item_len];
        const result = @import("eval.zig").evalFunc(ctx, dest, &fn_arg, &.{.{ .array = group }}) catch @panic("partition function evaluation failed");
        assertSamePartitionShape(first_result, result);
        storeGroupResult(&output, kept_count, output_item_len, result);
        kept_count += 1;
    }

    output.shape[0] = kept_count;
    return .{ .array = output };
}

const PartitionRun = struct {
    start: usize,
    len: usize,
    key: i64,
};

const PartitionRuns = struct {
    markers: []const f64,
    index: usize = 0,

    fn init(markers: []const f64) PartitionRuns {
        return .{ .markers = markers };
    }

    fn next(self: *PartitionRuns) ?PartitionRun {
        if (self.index >= self.markers.len) return null;

        const start = self.index;
        const key = expectIntegerMarker(self.markers[start]);
        self.index += 1;
        while (self.index < self.markers.len and self.markers[self.index] == self.markers[start]) : (self.index += 1) {}

        return .{
            .start = start,
            .len = self.index - start,
            .key = key,
        };
    }
};

fn findNextIncludedRun(runs: *PartitionRuns) ?PartitionRun {
    while (runs.next()) |run| {
        if (run.key > 0) return run;
    }
    return null;
}

fn expectIntegerMarker(value: f64) i64 {
    if (!std.math.isFinite(value) or @floor(value) != value) {
        @panic("partition markers must be integers");
    }
    return std.math.lossyCast(i64, value);
}

fn rowSize(shape: []const usize) usize {
    var size: usize = 1;
    for (shape[1..]) |dim| {
        size *= dim;
    }
    return size;
}

fn makeGroupView(
    all: *ReservedBumpAllocator,
    array: types.Array,
    row_size: usize,
    start: usize,
    len: usize,
) types.Array {
    const group_shape = all.allocator().alloc(usize, array.shape.len) catch @panic("out of memory");
    group_shape[0] = len;
    @memcpy(group_shape[1..], array.shape[1..]);

    const slice_start = start * row_size;
    const slice_end = (start + len) * row_size;
    var meta = types.Array.initWithShape(all, group_shape);
    meta.data = array.data[slice_start..slice_end];
    return meta;
}

fn assertSamePartitionShape(expected: Value, actual: Value) void {
    switch (expected) {
        .scalar => switch (actual) {
            .scalar => {},
            .array => @panic("partition function result shape changed"),
        },
        .array => |expected_array| switch (actual) {
            .scalar => @panic("partition function result shape changed"),
            .array => |actual_array| {
                if (!std.mem.eql(usize, expected_array.shape, actual_array.shape)) {
                    @panic("partition function result shape changed");
                }
            },
        },
    }
}

fn storeGroupResult(output: *types.Array, group_index: usize, output_item_len: usize, result: Value) void {
    const dest = output.data[group_index * output_item_len .. (group_index + 1) * output_item_len];
    switch (result) {
        .scalar => |scalar| dest[0] = scalar,
        .array => |array| @memcpy(dest, array.data),
    }
}

fn isHofFunction(comptime member: anytype) bool {
    const member_info = @typeInfo(@TypeOf(member));
    if (member_info != .@"fn") return false;

    const params = member_info.@"fn".params;
    if (params.len != 4) return false;
    if ((params[0].type orelse return false) != *EvalContext) return false;
    if ((params[1].type orelse return false) != ?[]f64) return false;
    if ((params[3].type orelse return false) != Expr.FuncExpr) return false;

    const args_type = params[2].type orelse return false;
    const args_info = @typeInfo(args_type);
    if (args_info != .pointer) return false;
    if (args_info.pointer.size != .one) return false;

    const child_info = @typeInfo(args_info.pointer.child);
    if (child_info != .array) return false;
    return child_info.array.child == Value;
}

test "Scan returns inclusive scalar prefixes" {
    const builtins = @import("builtins.zig");

    var all = try ReservedBumpAllocator.init(1024 * 1024);
    defer all.deinit();
    var ctx = EvalContext.init(&all);
    defer ctx.deinit();

    const add_func = Expr.FuncExpr{
        .arity = 2,
        .type = .{ .builtin = .{
            .arity = 2,
            .pointer = &struct {
                fn call(allocator: *ReservedBumpAllocator, result_dest: ?[]f64, args: []const Value) Value {
                    std.debug.assert(args.len == 2);
                    const typed_args: *const [2]Value = @ptrCast(args.ptr);
                    return builtins.add(allocator, result_dest, @constCast(typed_args));
                }
            }.call,
        } },
    };

    var shape = [_]usize{4};
    var data = [_]f64{ 1, 2, 3, 4 };
    var args = [_]Value{.{ .array = .{ .data = &data, .ownership = .Shared, .shape = &shape } }};

    const result = Scan(&ctx, null, &args, add_func).array;
    try std.testing.expectEqualSlices(f64, &.{ 1, 3, 6, 10 }, result.data);
    try std.testing.expectEqualSlices(usize, &shape, result.shape);
}

test "Scan is registered as a hof name" {
    try std.testing.expect(isHofName("Scan"));
}

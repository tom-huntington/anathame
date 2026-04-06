const std = @import("std");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator;
const Expr = types.Expr;
const Value = types.Value;

pub fn isHofName(name: []const u8) bool {
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const member = @field(@This(), decl.name);
        if (isHofFunction(member) and std.mem.eql(u8, name, decl.name)) {
            return true;
        }
    }
    return false;
}

pub fn reduce(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[1]Value, fn_arg: Expr.FuncExpr) Value {
    const checkpoint = all.checkpoint();
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
        acc = @import("eval.zig").evalFunc(all, &fn_arg, &.{
            acc,
            .{ .scalar = item },
        }) catch @panic("reduce function evaluation failed");
    }

    return switch (acc) {
        .scalar => acc,
        .array => |result| types.Array.Return(all, checkpoint, result),
    };
}

pub fn partition(all: *ReservedBumpAllocator, result_dest: ?[]f64, args: *[2]Value, fn_arg: Expr.FuncExpr) Value {
    const checkpoint = all.checkpoint();
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

    var runs = PartitionRuns.init(mask.data);
    const row_size = rowSize(array.shape);

    const first_run = findNextIncludedRun(&runs) orelse {
        const empty = types.Array.init(all, &.{0});
        return types.Array.Return(all, checkpoint, empty);
    };

    const first_group = makeGroupView(all, array, row_size, first_run.start, first_run.len);
    var first_result = @import("eval.zig").evalFuncTo(all, null, &fn_arg, &.{.{ .array = first_group }}) catch @panic("partition function evaluation failed");

    const kept_capacity = array.shape[0];
    const output_item_len = switch (first_result) {
        .scalar => @as(usize, 1),
        .array => |result| result.data.len,
    };

    const output_depth = switch (first_result) {
        .scalar => 1,
        .array => |result| result.shape.len + 1,
    };

    const last_allocation = all.base[checkpoint..all.checkpoint()];
    const moved_array: ?**types.Array = switch (first_result) {
        .scalar => null,
        .array => |*result| result,
    };
    var output = types.Array.initWithDepthBefore(all, checkpoint, last_allocation, output_depth, kept_capacity * output_item_len, moved_array);
    output.shape[0] = kept_capacity;
    switch (first_result) {
        .scalar => {},
        .array => |result| @memcpy(output.shape[1..], result.shape),
    }

    storeGroupResult(output, 0, output_item_len, first_result);

    var kept_count: usize = 1;
    while (findNextIncludedRun(&runs)) |run| {
        const group = makeGroupView(all, array, row_size, run.start, run.len);
        const dest = output.data[kept_count * output_item_len .. (kept_count + 1) * output_item_len];
        const result = @import("eval.zig").evalFuncTo(all, dest, &fn_arg, &.{.{ .array = group }}) catch @panic("partition function evaluation failed");
        assertSamePartitionShape(first_result, result);
        storeGroupResult(output, kept_count, output_item_len, result);
        kept_count += 1;
    }

    output.shape[0] = kept_count;
    return types.Array.Return(all, checkpoint, output);
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
    array: *types.Array,
    row_size: usize,
    start: usize,
    len: usize,
) *types.Array {
    const group_shape = all.allocator().alloc(usize, array.shape.len) catch @panic("out of memory");
    group_shape[0] = len;
    @memcpy(group_shape[1..], array.shape[1..]);

    const slice_start = start * row_size;
    const slice_end = (start + len) * row_size;
    const meta = types.Array.initWithShape(all, .Shared, group_shape);
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

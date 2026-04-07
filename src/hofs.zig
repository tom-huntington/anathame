const std = @import("std");
const types = @import("types.zig");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator; // ../vendor/ReservedBumpAllocator/root.zig
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
        .array => |result| blk: {
            var final = result;
            break :blk final.Return(all, checkpoint);
        },
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

    const row_size = rowSize(array.shape);
    const groups = collectPartitionGroups(all, mask.data);
    const num_groups = groups.len;

    if (num_groups == 0) {
        var empty = types.Array.initWithShape(all, &.{0});
        return empty.Return(all, checkpoint);
    }
    const first_partition_group = groups[0];

    const first_group = makeGroupByKey(all, array, row_size, mask.data, first_partition_group);
    var first_result = @import("eval.zig").evalFuncTo(all, null, &fn_arg, &.{.{ .array = first_group }}) catch @panic("partition function evaluation failed");

    const output_item_len = switch (first_result) {
        .scalar => @as(usize, 1),
        .array => |result| result.data.len,
    };

    const output_depth = switch (first_result) {
        .scalar => 1,
        .array => |result| result.shape.len + 1,
    };

    const last_allocation = all.base[checkpoint..all.checkpoint()];
    const moved_array: ?*types.Array = switch (first_result) {
        .scalar => null,
        .array => |*result| result,
    };
    var output = @import("array_helpers.zig").initWithDepthBefore(all, checkpoint, last_allocation, output_depth, num_groups * output_item_len, moved_array);
    output.shape[0] = num_groups;
    switch (first_result) {
        .scalar => {},
        .array => |result| @memcpy(output.shape[1..], result.shape),
    }

    storeGroupResult(&output, 0, output_item_len, first_result);

    const output_groups = collectPartitionGroups(all, mask.data);
    std.debug.assert(output_groups.len == num_groups);

    var kept_count: usize = 1;
    for (output_groups[1..]) |partition_group| {
        const group = makeGroupByKey(all, array, row_size, mask.data, partition_group);
        const dest = output.data[kept_count * output_item_len .. (kept_count + 1) * output_item_len];
        const result = @import("eval.zig").evalFuncTo(all, dest, &fn_arg, &.{.{ .array = group }}) catch @panic("partition function evaluation failed");
        assertSamePartitionShape(first_result, result);
        storeGroupResult(&output, kept_count, output_item_len, result);
        kept_count += 1;
    }

    output.shape[0] = kept_count;
    return output.Return(all, checkpoint);
}

const PartitionGroup = struct {
    key: i64,
    rows: usize,
};

fn collectPartitionGroups(all: *ReservedBumpAllocator, markers: []const f64) []PartitionGroup {
    const groups = all.allocator().alloc(PartitionGroup, markers.len) catch @panic("out of memory");
    var len: usize = 0;

    for (markers) |marker| {
        const key = expectIntegerMarker(marker);
        if (key <= 0) continue;

        const group_index = findPartitionGroup(groups[0..len], key);
        if (group_index) |i| {
            groups[i].rows += 1;
        } else {
            groups[len] = .{ .key = key, .rows = 1 };
            len += 1;
        }
    }

    return groups[0..len];
}

fn findPartitionGroup(groups: []const PartitionGroup, key: i64) ?usize {
    for (groups, 0..) |group, i| {
        if (group.key == key) return i;
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

fn makeGroupByKey(
    all: *ReservedBumpAllocator,
    array: types.Array,
    row_size: usize,
    markers: []const f64,
    group: PartitionGroup,
) types.Array {
    var meta = types.Array.initWithDepth(all, array.shape.len, group.rows * row_size);
    meta.shape[0] = group.rows;
    @memcpy(meta.shape[1..], array.shape[1..]);

    var dest_offset: usize = 0;
    for (markers, 0..) |marker, row| {
        if (expectIntegerMarker(marker) != group.key) continue;

        const slice_start = row * row_size;
        const slice_end = slice_start + row_size;
        @memcpy(meta.data[dest_offset .. dest_offset + row_size], array.data[slice_start..slice_end]);
        dest_offset += row_size;
    }

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

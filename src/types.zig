const std = @import("std");
const ReservedBumpAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator;
const build_options = @import("build_options");
const debug_array_return_snapshot = build_options.debug_array_return_snapshot;

pub const TokenTag = enum {
    ident,
    table,
    combinator,
    arrow,
    number,
    char_lit,
    raw_string,
    comma,
    caret,
    underscore,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    backslash,
    dbl_backslash,
    hof,
    equal,
    whitespace,
};

pub const Token = struct {
    tag: TokenTag,
    start: usize,
    end: usize,
    lexeme: []const u8,
};

const metadata_shape_alignment = std.mem.Alignment.of(usize);

pub const CowStatus = enum {
    Exclusive,
    Shared,
};
pub const Metadata = struct {
    status: CowStatus,
    shape: []usize,

    pub fn shapeOffset() usize {
        return metadata_shape_alignment.forward(@sizeOf(Metadata));
    }

    pub fn totalByteLen(depth: usize) usize {
        return shapeOffset() + depth * @sizeOf(usize);
    }

    pub fn allocationBytes(self: *Metadata) []u8 {
        const ptr: [*]u8 = @ptrCast(self);
        return ptr[0..totalByteLen(self.shape.len)];
    }

    pub fn initWithDepth(
        allocator: *ReservedBumpAllocator,
        status: CowStatus,
        depth: usize,
    ) *Metadata {
        const shape_offset = shapeOffset();
        const total_bytes = totalByteLen(depth);
        const bytes = allocator.allocator().alignedAlloc(u8, metadata_header_alignment, total_bytes) catch @panic("out of memory");
        const header: *Metadata = @ptrCast(@alignCast(bytes.ptr));
        const shape_ptr: [*]usize = @ptrCast(@alignCast(bytes.ptr + shape_offset));
        header.* = .{
            .status = status,
            .shape = shape_ptr[0..depth],
        };
        return header;
    }

    pub fn initWithShape(
        allocator: *ReservedBumpAllocator,
        status: CowStatus,
        shape: []const usize, // copied into inline storage after the header
    ) *Metadata {
        const header = initWithDepth(allocator, status, shape.len);
        @memcpy(header.shape, shape);
        return header;
    }
};

const metadata_header_alignment = std.mem.Alignment.of(Metadata);
const array_data_alignment = std.mem.Alignment.of(f64);
const array_allocation_alignment = std.mem.Alignment.fromByteUnits(@max(@alignOf(Metadata), @alignOf(f64)));

pub const Array = struct {
    data: []f64,
    meta: *Metadata,

    pub fn allocationAlignment() std.mem.Alignment {
        return array_allocation_alignment;
    }

    pub fn shape(self: Array) []const usize {
        return self.meta.shape;
    }

    pub fn dataOffset(depth: usize) usize {
        return array_data_alignment.forward(Metadata.totalByteLen(depth));
    }

    pub fn totalByteLen(depth: usize, size: usize) usize {
        return dataOffset(depth) + size * @sizeOf(f64);
    }

    pub fn compactAllocationBytes(self: Array) ?[]u8 {
        const meta_bytes = self.meta.allocationBytes();
        const expected_data_ptr = meta_bytes.ptr + dataOffset(self.shape().len);
        if (@intFromPtr(self.data.ptr) != @intFromPtr(expected_data_ptr)) return null;

        return meta_bytes.ptr[0..totalByteLen(self.shape().len, self.data.len)];
    }

    pub fn fromCompactAllocation(bytes: []u8, depth: usize, size: usize) Array {
        std.debug.assert(bytes.len >= totalByteLen(depth, size));

        const meta: *Metadata = @ptrCast(@alignCast(bytes.ptr));
        const shape_ptr: [*]usize = @ptrCast(@alignCast(bytes.ptr + Metadata.shapeOffset()));
        meta.* = .{
            .status = CowStatus.Exclusive,
            .shape = shape_ptr[0..depth],
        };

        const data_ptr: [*]f64 = @ptrCast(@alignCast(bytes.ptr + dataOffset(depth)));
        return .{
            .data = data_ptr[0..size],
            .meta = meta,
        };
    }

    pub fn move(self: Array) Array {
        std.debug.assert(self.meta.status == CowStatus.Exclusive);
        return self;
    }
    pub fn manually_counted_move(self: Array) Array {
        // up to programming to ensure there are no outstanding references
        self.meta.status = CowStatus.Exclusive;
        return self;
    }
    pub fn copy(self: Array) Array {
        self.meta.status = CowStatus.Shared;
        return self;
    }

    pub fn init(
        allocator: *ReservedBumpAllocator,
        dims: []const usize,
    ) Array {
        const array = initWithDepth(allocator, dims.len, prod(dims));
        @memcpy(array.meta.shape, dims);
        return array;
    }

    pub fn initWithDepth(
        allocator: *ReservedBumpAllocator,
        depth: usize,
        size: usize,
    ) Array {
        const shape_offset = Metadata.shapeOffset();
        const data_offset = dataOffset(depth);
        const total_bytes = totalByteLen(depth, size);
        const bytes = allocator.allocator().alignedAlloc(u8, array_allocation_alignment, total_bytes) catch @panic("out of memory");

        _ = shape_offset;
        _ = data_offset;
        return fromCompactAllocation(bytes, depth, size);
    }

    pub fn initWithDepthBefore(
        allocator: *ReservedBumpAllocator,
        checkpoint: usize,
        last_allocation: []u8,
        depth: usize,
        size: usize,
        moved_array: ?*Array,
    ) Array {
        const total_bytes = totalByteLen(depth, size);
        const bytes = allocator.insertBeforeLastAllocation(checkpoint, last_allocation, total_bytes);
        if (moved_array) |array| {
            array.offsetTailPointersByBytes(last_allocation, total_bytes);
        }
        return fromCompactAllocation(bytes, depth, size);
    }

    fn offsetTailPointersByBytes(self: *Array, tail: []const u8, byte_offset: usize) void {
        const data_bytes = std.mem.sliceAsBytes(self.data);
        const data_ptr: [*]f64 = if (sliceContainsSlice(tail, data_bytes))
            @ptrFromInt(@intFromPtr(self.data.ptr) + byte_offset)
        else
            self.data.ptr;
        const meta: *Metadata = if (sliceContainsPtr(tail, @ptrCast(self.meta)))
            @ptrFromInt(@intFromPtr(self.meta) + byte_offset)
        else
            self.meta;
        self.* = .{
            .data = data_ptr[0..self.data.len],
            .meta = meta,
        };
    }

    pub fn Return(all: *ReservedBumpAllocator, checkpoint: usize, result_before: Array) Value {
        //if (comptime debug_array_return_snapshot) {
        if (comptime @import("builtin").mode == .Debug) {
            var debug_gpa = std.heap.GeneralPurposeAllocator(.{}).init;
            defer std.debug.assert(debug_gpa.deinit() == .ok);

            const debug_allocator = debug_gpa.allocator();
            const deep_copy = debugCopyArray(debug_allocator, result_before);
            defer destroyDebugCopy(debug_allocator, deep_copy);

            const result_after = ReturnImpl(all, checkpoint, result_before);
            assertReturnedArrayUnchanged(deep_copy, result_after.array);
            assertReturnedArrayInvariants(all, result_after.array);
            return result_after;
        } else return ReturnImpl(all, checkpoint, result_before);
    }

    pub fn ReturnImpl(all: *ReservedBumpAllocator, checkpoint: usize, result: Array) Value {
        const depth = result.shape().len;
        const size = prod(result.shape());
        if (result.data.len < size) {
            @panic("Array.Return result data is shorter than its shape");
        }
        const meta_bytes = result.meta.allocationBytes();
        const compact_bytes = result.compactAllocationBytes();
        const result_data = result.data[0..size];
        const compact_size = totalByteLen(depth, size);

        all.restore(checkpoint);

        if (compact_bytes) |bytes| {
            const compact_prefix = bytes[0..compact_size];
            if (all.isNextAllocation(bytes.ptr)) {
                _ = all.reclaim(compact_prefix);
                result.meta.status = .Exclusive;
                return .{ .array = .{
                    .data = result_data,
                    .meta = result.meta,
                } };
            }

            if (all.ownsSlice(bytes) and @intFromPtr(bytes.ptr) >= @intFromPtr(all.base + all.sentinel)) {
                // Reclaim the gap too; allocating first can debug-fill and clobber the source.
                const reclaim_start = all.base + all.sentinel;
                const align_offset = std.mem.alignPointerOffset(reclaim_start, Array.allocationAlignment().toByteUnits()) orelse unreachable;
                const reclaimed_len = align_offset + compact_size;
                const reclaimed = all.reclaim(reclaim_start[0..reclaimed_len]);
                const final_bytes = reclaimed[align_offset..][0..compact_size];
                std.mem.copyForwards(u8, final_bytes, compact_prefix);
                return .{ .array = Array.fromCompactAllocation(final_bytes, depth, size) };
            }

            const final_bytes = all.allocator().alignedAlloc(u8, Array.allocationAlignment(), compact_size) catch @panic("out of memory");
            std.mem.copyForwards(u8, final_bytes, compact_prefix);
            return .{ .array = Array.fromCompactAllocation(final_bytes, depth, size) };
        }

        const final_data = if (all.isNextAllocation(@ptrCast(result.data.ptr))) blk: {
            const bytes = std.mem.sliceAsBytes(result_data);
            _ = all.reclaim(bytes);
            const ptr: [*]f64 = @ptrCast(@alignCast(bytes.ptr));
            break :blk ptr[0..size];
        } else blk: {
            const data = all.allocator().alloc(f64, size) catch @panic("out of memory");
            std.mem.copyForwards(f64, data, result_data);
            break :blk data;
        };

        const final_meta = if (all.isNextAllocation(meta_bytes.ptr)) blk: {
            _ = all.reclaim(meta_bytes);
            result.meta.status = .Exclusive;
            break :blk result.meta;
        } else Metadata.initWithShape(all, .Exclusive, result.shape());

        return .{ .array = .{
            .data = final_data,
            .meta = final_meta,
        } };
    }
};

fn debugCopyArray(allocator: std.mem.Allocator, array: Array) Array {
    const data = allocator.dupe(f64, array.data) catch @panic("out of memory");
    errdefer allocator.free(data);

    const shape = allocator.dupe(usize, array.shape()) catch @panic("out of memory");
    errdefer allocator.free(shape);

    const meta = allocator.create(Metadata) catch @panic("out of memory");
    meta.* = .{
        .status = array.meta.status,
        .shape = shape,
    };

    return .{
        .data = data,
        .meta = meta,
    };
}

fn destroyDebugCopy(allocator: std.mem.Allocator, array: Array) void {
    const shape = array.shape();
    const data = array.data;
    allocator.destroy(array.meta);
    allocator.free(shape);
    allocator.free(data);
}

fn assertReturnedArrayUnchanged(input: Array, output: Array) void {
    if (arraysEqualByValue(input, output)) return;

    std.debug.print("Array.Return changed array value\n", .{});
    debugPrintArray("input", input);
    debugPrintArray("output", output);
    @panic("Array.Return changed array value");
}

fn assertReturnedArrayInvariants(all: *ReservedBumpAllocator, array: Array) void {
    const expected_data_len = prod(array.shape());
    if (array.data.len != expected_data_len) {
        std.debug.print(
            "Array.Return returned data length that does not match shape: expected {d}, got {d}\n",
            .{ expected_data_len, array.data.len },
        );
        debugPrintArray("output", array);
        @panic("Array.Return returned invalid array shape/data length");
    }

    if (!all.isLastAllocation(std.mem.sliceAsBytes(array.data))) {
        std.debug.print("Array.Return returned data that is not the final bump allocation\n", .{});
        debugPrintArray("output", array);
        @panic("Array.Return returned non-final array data");
    }
}

fn arraysEqualByValue(lhs: Array, rhs: Array) bool {
    const lhs_data_len = prod(lhs.shape());
    const rhs_data_len = prod(rhs.shape());
    if (lhs.data.len < lhs_data_len or rhs.data.len < rhs_data_len) return false;

    return std.mem.eql(usize, lhs.shape(), rhs.shape()) and
        std.mem.eql(f64, lhs.data[0..lhs_data_len], rhs.data[0..rhs_data_len]);
}

fn debugPrintArray(label: []const u8, array: Array) void {
    std.debug.print(
        "{s}: shape={any} data={any}\n",
        .{ label, array.shape(), array.data },
    );
}

fn prod(shape: []const usize) usize {
    var len: usize = 1;
    for (shape) |dim| {
        len = len * dim;
    }
    return len;
}

fn sliceContainsPtr(container: []const u8, ptr: [*]const u8) bool {
    return @intFromPtr(ptr) >= @intFromPtr(container.ptr) and
        @intFromPtr(ptr) < (@intFromPtr(container.ptr) + container.len);
}

fn sliceContainsSlice(container: []const u8, slice: []const u8) bool {
    return @intFromPtr(slice.ptr) >= @intFromPtr(container.ptr) and
        (@intFromPtr(slice.ptr) + slice.len) <= (@intFromPtr(container.ptr) + container.len);
}

pub const Value = union(enum) {
    scalar: f64,
    array: Array,
};

pub const Combinator = enum {
    B,
    B1,
    S,
    Sig,
    D,
    Delta,
    Phi,
    Psi,
    D1,
    D2,
    N,
    V,
    X,
    Xi,
    Phi1,

    pub fn arity(self: Combinator) u32 {
        return switch (self) {
            .B, .B1, .S => 1,
            .Sig,
            .D,
            .Delta,
            .Phi,
            .Psi,
            .D1,
            .D2,
            .N,
            .V,
            .X,
            .Xi,
            .Phi1,
            => std.debug.panic("TODO: define arity for combinator {s}", .{@tagName(self)}),
        };
    }
};

pub const Builtin = struct {
    arity: u32,
    pointer: *const fn (*ReservedBumpAllocator, ?[]f64, []const Value) Value,
};

pub const Hof = struct {
    arity: u32,
    funcArg: *Expr.FuncExpr,
    pointer: *const fn (*ReservedBumpAllocator, ?[]f64, []const Value, Expr.FuncExpr) Value,
};

pub const PartialApply = enum { comma, caret };

pub const Expr = union(enum) {
    value: ValueExpr,
    func: FuncExpr,

    pub const FuncExpr = struct {
        arity: u32,
        type: union(enum) {
            combinator: struct { op: Combinator, first_arg: *FuncExpr, remaining_args: []*FuncExpr },
            hof: Hof,
            table: struct { lookup: Array, unmatched: enum { Error, Identity } },
            partial_apply_permute: struct { func: *FuncExpr, arguments: []ValueExpr, permutation_index: u32 },
            scope: *FuncExpr,
            userFn: struct { left: []const u8, right: ?[]const u8, body: *Expr },
            builtin: Builtin,
        },
    };

    pub const ValueExpr = union(enum) {
        literal: Value,
        strand: struct { left: *Expr, right: *Expr },
        apply: struct { func: *Expr, arg: *Expr },
        ident: []const u8,
    };
};

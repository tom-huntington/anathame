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

    pub fn Return(all: *ReservedBumpAllocator, checkpoint: usize, result: Array) Value {
        var debug_gpa: if (debug_array_return_snapshot) std.heap.GeneralPurposeAllocator(.{}) else void = undefined;
        var debug_snapshot: if (debug_array_return_snapshot) Array else void = undefined;
        var final_result: ?Array = null;

        if (comptime debug_array_return_snapshot) {
            debug_gpa = .init;
            defer std.debug.assert(debug_gpa.deinit() == .ok);

            const debug_allocator = debug_gpa.allocator();

            const debug_data = debug_allocator.alloc(f64, result.data.len) catch @panic("out of memory");
            errdefer debug_allocator.free(debug_data);
            std.mem.copyForwards(f64, debug_data, result.data);

            const debug_shape = debug_allocator.alloc(usize, result.shape().len) catch @panic("out of memory");
            errdefer debug_allocator.free(debug_shape);
            std.mem.copyForwards(usize, debug_shape, result.shape());

            const debug_meta = debug_allocator.create(Metadata) catch @panic("out of memory");
            errdefer debug_allocator.destroy(debug_meta);
            debug_meta.* = .{
                .status = result.meta.status,
                .shape = debug_shape,
            };

            debug_snapshot = .{
                .data = debug_data,
                .meta = debug_meta,
            };

            defer debug_allocator.destroy(debug_snapshot.meta);
            defer debug_allocator.free(debug_snapshot.shape());
            defer debug_allocator.free(debug_snapshot.data);
            defer if (final_result) |returned_array| {
                assertReturnedArrayUnchanged(debug_snapshot, returned_array);
            };
        }

        const depth = result.shape().len;
        const size = result.data.len;
        const meta_bytes = result.meta.allocationBytes();
        const compact_bytes = result.compactAllocationBytes();

        all.restore(checkpoint);

        if (compact_bytes) |bytes| {
            if (all.isNextAllocation(bytes.ptr)) {
                _ = all.reclaim(bytes);
                result.meta.status = .Exclusive;
                final_result = result;
                return .{ .array = result };
            }

            const final_bytes = all.allocator().alignedAlloc(u8, Array.allocationAlignment(), bytes.len) catch @panic("out of memory");
            std.mem.copyForwards(u8, final_bytes, bytes);
            const returned_array = Array.fromCompactAllocation(final_bytes, depth, size);
            final_result = returned_array;
            return .{ .array = returned_array };
        }

        const final_data = if (all.isNextAllocation(@ptrCast(result.data.ptr))) blk: {
            const bytes = std.mem.sliceAsBytes(result.data);
            _ = all.reclaim(bytes);
            const ptr: [*]f64 = @ptrCast(@alignCast(bytes.ptr));
            break :blk ptr[0..size];
        } else blk: {
            const data = all.allocator().alloc(f64, size) catch @panic("out of memory");
            std.mem.copyForwards(f64, data, result.data);
            break :blk data;
        };

        const final_meta = if (all.isNextAllocation(meta_bytes.ptr)) blk: {
            _ = all.reclaim(meta_bytes);
            result.meta.status = .Exclusive;
            break :blk result.meta;
        } else Metadata.initWithShape(all, .Exclusive, result.shape());

        const returned_array: Array = .{
            .data = final_data,
            .meta = final_meta,
        };
        final_result = returned_array;
        return .{ .array = returned_array };
    }
};

fn assertReturnedArrayUnchanged(input: Array, output: Array) void {
    if (arraysEqualByValue(input, output)) return;

    std.debug.print("Array.Return changed array value\n", .{});
    debugPrintArray("input", input);
    debugPrintArray("output", output);
    @panic("Array.Return changed array value");
}

fn arraysEqualByValue(lhs: Array, rhs: Array) bool {
    return std.mem.eql(usize, lhs.shape(), rhs.shape()) and
        std.mem.eql(f64, lhs.data, rhs.data);
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

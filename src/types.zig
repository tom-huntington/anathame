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

const array_shape_alignment = std.mem.Alignment.of(usize);

pub const CowStatus = enum {
    Exclusive,
    Shared,
};
pub const Array = struct {
    data: []f64,
    status: CowStatus,
    shape: []usize,

    pub fn shapeOffset() usize {
        return array_shape_alignment.forward(@sizeOf(@This()));
    }

    pub fn headerByteLen(depth: usize) usize {
        return shapeOffset() + depth * @sizeOf(usize);
    }

    pub fn allocationBytes(self: *@This()) []u8 {
        const ptr: [*]u8 = @ptrCast(self);
        return ptr[0..headerByteLen(self.shape.len)];
    }

    pub fn initWithShape(
        allocator: *ReservedBumpAllocator,
        status: CowStatus,
        shape: []const usize, // copied into inline storage after the header
    ) *@This() {
        const header = @import("array_helpers.zig").initArrayWithDepth(allocator, status, shape.len);
        @memcpy(header.shape, shape);
        return header;
    }

    pub fn allocationAlignment() std.mem.Alignment {
        return @import("array_helpers.zig").array_allocation_alignment;
    }

    pub fn dataOffset(depth: usize) usize {
        return @import("array_helpers.zig").array_data_alignment.forward(headerByteLen(depth));
    }

    pub fn totalByteLen(depth: usize, size: usize) usize {
        return dataOffset(depth) + size * @sizeOf(f64);
    }

    pub fn compactAllocationBytes(self: *@This()) ?[]u8 {
        const meta_bytes = self.allocationBytes();
        const expected_data_ptr = meta_bytes.ptr + dataOffset(self.shape.len);
        if (@intFromPtr(self.data.ptr) != @intFromPtr(expected_data_ptr)) return null;

        return meta_bytes.ptr[0..totalByteLen(self.shape.len, self.data.len)];
    }

    pub fn fromCompactAllocation(bytes: []u8, depth: usize, size: usize) *@This() {
        std.debug.assert(bytes.len >= totalByteLen(depth, size));

        const meta: *@This() = @ptrCast(@alignCast(bytes.ptr));
        const shape_ptr: [*]usize = @ptrCast(@alignCast(bytes.ptr + @This().shapeOffset()));
        meta.* = .{
            .data = &.{},
            .status = CowStatus.Exclusive,
            .shape = shape_ptr[0..depth],
        };

        const data_ptr: [*]f64 = @ptrCast(@alignCast(bytes.ptr + dataOffset(depth)));
        meta.data = data_ptr[0..size];
        return meta;
    }

    pub fn move(self: *@This()) *@This() {
        std.debug.assert(self.status == CowStatus.Exclusive);
        return self;
    }
    pub fn manually_counted_move(self: *@This()) *@This() {
        // up to programming to ensure there are no outstanding references
        self.status = CowStatus.Exclusive;
        return self;
    }
    pub fn copy(self: *@This()) *@This() {
        self.status = CowStatus.Shared;
        return self;
    }

    pub fn init(
        allocator: *ReservedBumpAllocator,
        dims: []const usize,
    ) *@This() {
        const array = initWithDepth(allocator, dims.len, @import("array_helpers.zig").prod(dims));
        @memcpy(array.shape, dims);
        return array;
    }

    pub fn initWithDepth(
        allocator: *ReservedBumpAllocator,
        depth: usize,
        size: usize,
    ) *@This() {
        const shape_offset = @This().shapeOffset();
        const data_offset = dataOffset(depth);
        const total_bytes = totalByteLen(depth, size);
        const bytes = allocator.allocator().alignedAlloc(u8, @import("array_helpers.zig").array_allocation_alignment, total_bytes) catch @panic("out of memory");

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
        moved_array: ?**@This(),
    ) *@This() {
        const total_bytes = totalByteLen(depth, size);
        const bytes = allocator.insertBeforeLastAllocation(checkpoint, last_allocation, total_bytes);
        if (moved_array) |array| {
            @import("array_helpers.zig").offsetTailArrayPointerByBytes(array, last_allocation, total_bytes);
        }
        return fromCompactAllocation(bytes, depth, size);
    }

    pub fn Return(all: *ReservedBumpAllocator, checkpoint: usize, result_before: *@This()) Value {
        return @import("array_helpers.zig").ArrayReturn(all, checkpoint, result_before);
    }

    pub fn num_elements(self: @This()) usize {
        return @import("array_helpers.zig").prod(self.shape);
    }
};

pub const Value = union(enum) {
    scalar: f64,
    array: *Array,
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
            .Sig, .D, .Delta, .Phi, .Psi, .D1, .D2, .N, .V, .X, .Xi, .Phi1 => std.debug.panic("TODO: define arity for combinator {s}", .{@tagName(self)}),
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
            table: struct { lookup: *Array, unmatched: enum { Error, Identity } },
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

const std = @import("std");
const ReservedBufferAllocator = @import("ReservedBumpAllocator").ReservedBumpAllocator;

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
pub const MetadataHeader = struct {
    status: CowStatus,
    depth: u8,

    pub fn prefix_bytes() usize {
        return metadata_shape_alignment.forward(@sizeOf(MetadataHeader));
    }

    pub fn size_bytes(self: *const MetadataHeader) usize {
        return prefix_bytes() + self.depth * @sizeOf(usize);
    }

    pub fn shape(self: *const MetadataHeader) []const usize {
        const ptr: [*]const usize = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(self)) + prefix_bytes()));
        return ptr[0..self.depth];
    }

    pub fn shape_mut(self: *MetadataHeader) []usize {
        const ptr: [*]usize = @ptrCast(@alignCast(@as([*]u8, @ptrCast(self)) + prefix_bytes()));
        return ptr[0..self.depth];
    }
};

pub fn InitMetadata(
    allocator: *ReservedBufferAllocator,
    status: CowStatus,
    shape: []const usize,
) *MetadataHeader {
    const total_bytes = MetadataHeader.prefix_bytes() + shape.len * @sizeOf(usize);
    const bytes = allocator.allocator().alignedAlloc(u8, metadata_shape_alignment, total_bytes) catch @panic("out of memory");
    const header: *MetadataHeader = @ptrCast(@alignCast(bytes.ptr));
    header.* = .{
        .status = status,
        .depth = std.math.cast(u8, shape.len) orelse @panic("too many dimensions"),
    };
    @memcpy(header.shape_mut(), shape);
    return header;
}

const metadata_header_alignment = std.mem.Alignment.of(MetadataHeader);
const array_data_alignment = std.mem.Alignment.of(f64);
const array_allocation_alignment = std.mem.Alignment.fromByteUnits(@max(@alignOf(MetadataHeader), @alignOf(f64)));

pub const Array = struct {
    data: []f64,
    meta: *MetadataHeader,

    pub fn shape(self: Array) []const usize {
        return self.meta.shape();
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
        allocator: *ReservedBufferAllocator,
        dims: []const usize,
    ) Array {
        const data_len = prod(dims);
        const shape_offset = MetadataHeader.prefix_bytes();
        const data_offset = array_data_alignment.forward(shape_offset + dims.len * @sizeOf(usize));
        const total_bytes = data_offset + data_len * @sizeOf(f64);
        const bytes = allocator.allocator().alignedAlloc(u8, array_allocation_alignment, total_bytes) catch @panic("out of memory");

        const meta: *MetadataHeader = @ptrCast(@alignCast(bytes.ptr));
        meta.* = .{
            .status = CowStatus.Exclusive,
            .depth = std.math.cast(u8, dims.len) orelse @panic("too many dimensions"),
        };
        @memcpy(meta.shape_mut(), dims);

        const data_ptr: [*]f64 = @ptrCast(@alignCast(bytes.ptr + data_offset));
        return .{
            .data = data_ptr[0..data_len],
            .meta = meta,
        };
    }
};

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
    pointer: *const fn (*ReservedBufferAllocator, []const Value) Value,
};

pub const Hof = struct {
    arity: u32,
    funcArg: *Expr.FuncExpr,
    pointer: *const fn (*ReservedBufferAllocator, []const Value, Expr.FuncExpr) Value,
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

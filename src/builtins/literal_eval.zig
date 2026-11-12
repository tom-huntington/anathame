const std = @import("std");
const Value = @import("../runtime.zig").Value;

pub fn evaluate(a: std.mem.Allocator, x: Value, fill: ?f64) !Value {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    if (x.tuple) |items| {
        const rows = try scratch.alloc(Value, items.len);
        for (items, rows) |item, *row| row.* = try evaluate(scratch, item, fill);
        var assembler: Parser = .{ .a = scratch, .text = "", .fill = fill };
        const result = try assembler.assemble(rows);
        const data = try a.dupe(f64, result.data);
        errdefer a.free(data);
        return .{ .data = data, .shape = try a.dupe(usize, result.shape) };
    }
    if (x.shape.len > 1) {
        const rows = try scratch.alloc(Value, x.shape[0]);
        var width: usize = 1;
        for (x.shape[1..]) |dim| width = try std.math.mul(usize, width, dim);
        for (rows, 0..) |*row, i| row.* = try evaluate(scratch, .{
            .data = x.data[i * width ..][0..width],
            .shape = x.shape[1..],
        }, fill);
        var assembler: Parser = .{ .a = scratch, .text = "", .fill = fill };
        const result = try assembler.assemble(rows);
        const data = try a.dupe(f64, result.data);
        errdefer a.free(data);
        return .{ .data = data, .shape = try a.dupe(usize, result.shape) };
    }
    var bytes: std.ArrayList(u8) = .empty;
    for (x.data) |cp| {
        if (!std.math.isFinite(cp) or cp < 0 or cp > 0x10ffff or @trunc(cp) != cp)
            return error.InvalidInput;
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intFromFloat(cp), &encoded) catch return error.InvalidInput;
        try bytes.appendSlice(scratch, encoded[0..len]);
    }
    var parser: Parser = .{ .a = scratch, .text = bytes.items, .fill = fill };
    const result = try parser.value();
    parser.whitespace();
    if (parser.pos != parser.text.len) return error.InvalidInput;
    const data = try a.dupe(f64, result.data);
    errdefer a.free(data);
    return .{ .data = data, .shape = try a.dupe(usize, result.shape) };
}

const Parser = struct {
    a: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,
    fill: ?f64,
    depth: usize = 0,

    fn whitespace(self: *Parser) void {
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
    }

    fn value(self: *Parser) anyerror!Value {
        self.whitespace();
        if (self.pos == self.text.len or self.depth >= 256) return error.InvalidInput;
        if (self.text[self.pos] != '[') {
            const start = self.pos;
            while (self.pos < self.text.len and !std.ascii.isWhitespace(self.text[self.pos]) and
                std.mem.indexOfScalar(u8, "[],_", self.text[self.pos]) == null) self.pos += 1;
            if (self.pos == start) return error.InvalidInput;
            const number = std.fmt.parseFloat(f64, self.text[start..self.pos]) catch return error.InvalidInput;
            return .{ .data = try self.a.dupe(f64, &.{number}) };
        }
        self.pos += 1;
        self.depth += 1;
        defer self.depth -= 1;
        var rows: std.ArrayList(Value) = .empty;
        self.whitespace();
        while (self.pos < self.text.len and self.text[self.pos] != ']') {
            try rows.append(self.a, try self.value());
            const end = self.pos;
            self.whitespace();
            if (self.pos < self.text.len and (self.text[self.pos] == ',' or self.text[self.pos] == '_')) {
                self.pos += 1;
                self.whitespace();
                // Permit a trailing comma, as in conventional array literals.
                if (self.pos < self.text.len and self.text[self.pos] == ']') break;
            } else if (self.pos < self.text.len and self.text[self.pos] != ']' and end == self.pos) {
                return error.InvalidInput;
            }
        }
        if (self.pos == self.text.len) return error.InvalidInput;
        self.pos += 1;
        return self.assemble(rows.items);
    }

    fn assemble(self: *Parser, rows: []const Value) !Value {
        var cell_shape: []usize = &.{};
        for (rows, 0..) |row, i| {
            if (self.fill == null) {
                if (i == 0) cell_shape = try self.a.dupe(usize, row.shape) else if (!std.mem.eql(usize, cell_shape, row.shape)) return error.ShapeMismatch;
            } else {
                if (row.shape.len > cell_shape.len) {
                    const expanded = try self.a.alloc(usize, row.shape.len);
                    @memset(expanded, 1);
                    @memcpy(expanded[expanded.len - cell_shape.len ..], cell_shape);
                    if (i == 0) @memcpy(expanded, row.shape);
                    cell_shape = expanded;
                }
                for (row.shape, 0..) |dim, axis| {
                    const target = cell_shape.len - row.shape.len + axis;
                    cell_shape[target] = @max(cell_shape[target], dim);
                }
            }
        }
        var width: usize = 1;
        for (cell_shape) |dim| width = try std.math.mul(usize, width, dim);
        const data = try self.a.alloc(f64, try std.math.mul(usize, rows.len, width));
        @memset(data, self.fill orelse 0);
        for (rows, 0..) |row, r| {
            for (row.data, 0..) |item, index| {
                var remaining = index;
                var dest: usize = 0;
                var stride: usize = 1;
                var axis = row.shape.len;
                while (axis > 0) {
                    axis -= 1;
                    dest += (remaining % row.shape[axis]) * stride;
                    remaining /= row.shape[axis];
                    stride *= cell_shape[cell_shape.len - row.shape.len + axis];
                }
                data[r * width + dest] = item;
            }
        }
        return .{ .data = data, .shape = try std.mem.concat(self.a, usize, &.{ &.{rows.len}, cell_shape }) };
    }
};

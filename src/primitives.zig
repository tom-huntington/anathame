const std = @import("std");
const Value = @import("runtime.zig").Value;
pub const Function = *const fn (std.mem.Allocator, Value, Value) anyerror!Value;
pub fn arity(name: []const u8) usize {
    if (std.mem.eql(u8, name, "env")) return 1;
    if (std.mem.eql(u8, name, "deduplicate")) return 1;
    if (std.mem.eql(u8, name, "eye")) return 1;
    if (std.mem.eql(u8, name, "shape")) return 1;
    if (std.mem.eql(u8, name, "adjacency_matrix")) return 1;
    if (std.mem.eql(u8, name, "where") or std.mem.eql(u8, name, "unwhere")) return 1;
    if (std.mem.eql(u8, name, "rise") or std.mem.eql(u8, name, "fall")) return 1;
    if (std.mem.eql(u8, name, "squeeze")) return 1;
    if (std.mem.eql(u8, name, "log.str")) return 1;
    if (std.mem.eql(u8, name, "not")) return 1;
    if (std.mem.eql(u8, name, "sort") or std.mem.eql(u8, name, "lexisort")) return 1;
    if (std.mem.eql(u8, name, "first") or std.mem.eql(u8, name, "second")) return 1;
    if (std.mem.eql(u8, name, "transpose") or std.mem.eql(u8, name, "last.row")) return 1;
    if (std.mem.eql(u8, name, "reverse") or std.mem.eql(u8, name, "flatten")) return 1;
    if (std.mem.eql(u8, name, "base10") or std.mem.eql(u8, name, "radix10")) return 1;
    if (std.mem.eql(u8, name, "ints") or std.mem.eql(u8, name, "ints2d") or std.mem.eql(u8, name, "digits") or std.mem.eql(u8, name, "digits2d")) return 1;
    return if (std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "iota") or std.mem.eql(u8, name, "Reduce") or std.mem.eql(u8, name, "Partials") or std.mem.eql(u8, name, "floor") or std.mem.eql(u8, name, "abs") or std.mem.eql(u8, name, "absolute value") or std.mem.eql(u8, name, "sq") or std.mem.eql(u8, name, "parse") or std.mem.eql(u8, name, "to_string") or std.mem.eql(u8, name, "uncons") or std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "identity")) 1 else 2;
}
// ASCII names snapshotted from uiua/site/primitives.json.
pub const names = [_][]const u8{
    "&ap",
    "&apngs",
    "&args",
    "&asr",
    "&ast",
    "&camcap",
    "&camlist",
    "&cd",
    "&cl",
    "&clip",
    "&ep",
    "&epf",
    "&exit",
    "&fc",
    "&fde",
    "&fe",
    "&fetch",
    "&ffi",
    "&fif",
    "&fld",
    "&fmd",
    "&fo",
    "&frab",
    "&fras",
    "&ftr",
    "&fwa",
    "&gifs",
    "&ims",
    "&invk",
    "&malloc",
    "&memcpy",
    "&memfree",
    "&memset",
    "&p",
    "&pf",
    "&raw",
    "&rb",
    "&rl",
    "&rs",
    "&ru",
    "&runc",
    "&runi",
    "&runs",
    "&s",
    "&sc",
    "&seek",
    "&sl",
    "&tcpa",
    "&tcpaddr",
    "&tcpc",
    "&tcpl",
    "&tcpsnb",
    "&tcpsrt",
    "&tcpswt",
    "&tlsc",
    "&tlsl",
    "&ts",
    "&udpb",
    "&udpr",
    "&udps",
    "&udpsml",
    "&var",
    "&w",
    "above",
    "absolute value",
    "add",
    "anti",
    "apng",
    "arch",
    "args",
    "assert",
    "atangent",
    "audio",
    "backward",
    "base",
    "below",
    "binary",
    "bits",
    "both",
    "box",
    "bracket",
    "by",
    "bytes",
    "case",
    "ceiling",
    "classify",
    "complex",
    "compress",
    "comptime",
    "content",
    "cos",
    "cosh",
    "couple",
    "csv",
    "datetime",
    "deduplicate",
    "derivative",
    "deshape",
    "dip",
    "divide",
    "dllext",
    "do",
    "drop",
    "dump",
    "duplicate",
    "each",
    "equals",
    "eta",
    "evert",
    "exeext",
    "exponential",
    "fall",
    "fft",
    "fill",
    "eye",
    "find",
    "first",
    "fix",
    "flip",
    "floor",
    "fold",
    "fork",
    "gap",
    "gen",
    "get",
    "gif",
    "graphemes",
    "greater or equal",
    "greater than",
    "group",
    "has",
    "hsv",
    "identity",
    "img",
    "indexin",
    "infinity",
    "inner product",
    "insert",
    "integral",
    "inventory",
    "join",
    "json",
    "keep",
    "last",
    "layout",
    "length",
    "less or equal",
    "less than",
    "map",
    "mask",
    "match",
    "maximum",
    "memberof",
    "memo",
    "minimum",
    "modulo",
    "multiply",
    "multivector",
    "negate",
    "noise",
    "not",
    "not equals",
    "now",
    "numprocs",
    "obverse",
    "occurrences",
    "off",
    "oklch",
    "on",
    "or",
    "orient",
    "os",
    "osfamily",
    "outer product",
    "parse",
    "Partition",
    "path",
    "pathsep",
    "pattern",
    "pi",
    "pick",
    "pool",
    "uncons",
    "power",
    "pretty",
    "quote",
    "random",
    "range",
    "reach",
    "reciprocal",
    "recur",
    "recv",
    "reduce",
    "regex",
    "remove",
    "repeat",
    "repr",
    "rerank",
    "reshape",
    "reverse",
    "rise",
    "rotate",
    "round",
    "rows",
    "Rows",
    "Table",
    "Flip",
    "Join",
    "Switch",
    "Filter",
    "Unc",
    "Scan",
    "Partials",
    "Reduce",
    "Fold",
    "MapAccum",
    "Log",
    "Repeat",
    "Repeat.check",
    "Fix",
    "Fix.check",
    "Stencil",
    "Tuples",
    "TuplesWith",
    "select",
    "second",
    "self",
    "send",
    "shape",
    "sign",
    "sine",
    "sinh",
    "sort",
    "spawn",
    "sqrt",
    "stencil",
    "subtract",
    "switch",
    "table",
    "take",
    "tan",
    "tanh",
    "tau",
    "timezone",
    "transpose",
    "try",
    "tryrecv",
    "tuples",
    "type",
    "un",
    "under",
    "unique",
    "utf8",
    "validate",
    "voxels",
    "wait",
    "where",
    "windows",
    "with",
    "xlsx",
};
pub fn known(name: []const u8) bool {
    if (lookup(name) != null) return true;
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}
// Register public builtin implementations through comptime reflection.
pub fn lookup(name: []const u8) ?Function {
    if (@import("builtins/products.zig").lookup(name)) |function| return function;
    if (std.mem.eql(u8, name, "shape")) return &@import("builtins/axis_agnostic.zig").arrayShape;
    if (std.mem.startsWith(u8, name, "convolve.")) {
        inline for (comptime std.meta.declarations(@import("builtins/convolve_builtins.zig"))) |decl| {
            if (std.mem.eql(u8, name[9..], decl)) return &@field(@import("builtins/convolve_builtins.zig"), decl);
        }
        return null;
    }
    if (std.mem.startsWith(u8, name, "re.")) {
        inline for (comptime std.meta.declarations(@import("builtins/regex_builtins.zig"))) |decl| {
            if (std.mem.eql(u8, name[3..], decl)) return &@field(@import("builtins/regex_builtins.zig"), decl);
        }
        return null;
    }
    const pervasives = @import("builtins/pervasives.zig");
    const axial = @import("builtins/axial.zig");
    const axis_agnostic = @import("builtins/axis_agnostic.zig");
    inline for (.{ pervasives, axial, axis_agnostic }) |implementations| {
        inline for (comptime std.meta.declarations(implementations)) |decl| {
            if (comptime std.mem.eql(u8, decl, "indexinComponents") or std.mem.eql(u8, decl, "sortComponents") or std.mem.eql(u8, decl, "deduplicateComponents") or std.mem.eql(u8, decl, "arrayShape") or std.mem.eql(u8, decl, "extractNumbers")) continue;
            if (std.mem.eql(u8, name, decl)) return &@field(implementations, decl);
        }
    }
    if (std.mem.eql(u8, name, "less than")) return &pervasives.less;
    if (std.mem.eql(u8, name, "greater than") or std.mem.eql(u8, name, ">")) return &pervasives.greater;
    if (std.mem.eql(u8, name, "maximum")) return &pervasives.max;
    if (std.mem.eql(u8, name, "absolute value")) return &pervasives.abs;
    if (std.mem.eql(u8, name, "divide")) return &pervasives.div;
    if (std.mem.eql(u8, name, "identity")) return &axis_agnostic.id;
    if (std.mem.eql(u8, name, "multiply")) return &pervasives.mul;
    if (std.mem.eql(u8, name, "subtract")) return &pervasives.sub;
    if (std.mem.eql(u8, name, "modulo")) return &pervasives.mod;
    return null;
}

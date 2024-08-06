const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const isa = @import("isa.zig");
const Compiler = @import("Compiler.zig");
const PrintLoc = @import("PrintLoc.zig");
const ErrorInfo = @import("ErrorInfo.zig");
const @"test" = @import("test.zig");

const Error = error{
    TypeMismatch,
    Unimplemented,
    Overflow,
};

pub fn Machine(comptime Effects: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        effects: *Effects,
        errorinfo: ?*ErrorInfo,

        stack: std.ArrayListUnmanaged(isa.Value) = .{},
        slots: std.ArrayListUnmanaged(isa.Value) = .{},

        pub fn init(allocator: Allocator, effects: *Effects, errorinfo: ?*ErrorInfo) Self {
            return .{
                .allocator = allocator,
                .effects = effects,
                .errorinfo = errorinfo,
            };
        }

        pub fn deinit(self: *Self) void {
            self.effects.deinit();
            self.valueFreeMany(self.stack.items);
            self.stack.deinit(self.allocator);
            self.valueFreeMany(self.slots.items);
            self.slots.deinit(self.allocator);
        }

        fn valueFreeMany(self: *Self, vx: []const isa.Value) void {
            for (vx) |v| self.valueFree(v);
        }

        fn valueFree(self: *Self, v: isa.Value) void {
            switch (v) {
                .integer, .long, .single, .double => {},
                .string => |s| self.allocator.free(s),
            }
        }

        fn stackTake(self: *Self, comptime n: usize) [n]isa.Value {
            std.debug.assert(self.stack.items.len >= n);
            defer self.stack.items.len -= n;
            return self.stack.items[self.stack.items.len - n ..][0..n].*;
        }

        fn variableGet(self: *Self, slot: u8) !isa.Value {
            return self.slots.items[slot].clone(self.allocator);
        }

        fn variableOwn(self: *Self, slot: u8, v: isa.Value) !void {
            if (slot < self.slots.items.len) {
                self.valueFree(self.slots.items[slot]);
                self.slots.items[slot] = v;
            } else {
                // Assuming no random new slot access (e.g. 0, then 2).
                std.debug.assert(slot == self.slots.items.len);
                try self.slots.append(self.allocator, v);
            }
        }

        pub fn run(self: *Self, code: []const u8) (Error || Allocator.Error || Effects.Error)!void {
            var i: usize = 0;
            while (i < code.len) {
                const b = code[i];
                const op = @as(isa.Opcode, @enumFromInt(b));
                i += 1;
                switch (op) {
                    .PUSH_IMM_INTEGER => {
                        std.debug.assert(code.len - i + 1 >= 2);
                        const imm = code[i..][0..2];
                        i += 2;
                        try self.stack.append(
                            self.allocator,
                            .{ .integer = std.mem.readInt(i16, imm, .little) },
                        );
                    },
                    .PUSH_IMM_LONG => {
                        std.debug.assert(code.len - i + 1 >= 4);
                        const imm = code[i..][0..4];
                        i += 4;
                        try self.stack.append(
                            self.allocator,
                            .{ .long = std.mem.readInt(i32, imm, .little) },
                        );
                    },
                    .PUSH_IMM_SINGLE => {
                        std.debug.assert(code.len - i + 1 >= 4);
                        const imm = code[i..][0..4];
                        i += 4;
                        var r: [1]f32 = undefined;
                        @memcpy(std.mem.sliceAsBytes(r[0..]), imm);
                        try self.stack.append(self.allocator, .{ .single = r[0] });
                    },
                    .PUSH_IMM_DOUBLE => {
                        std.debug.assert(code.len - i + 1 >= 8);
                        const imm = code[i..][0..8];
                        i += 8;
                        var r: [1]f64 = undefined;
                        @memcpy(std.mem.sliceAsBytes(r[0..]), imm);
                        try self.stack.append(self.allocator, .{ .double = r[0] });
                    },
                    .PUSH_IMM_STRING => {
                        std.debug.assert(code.len - i + 1 >= 2);
                        const lenb = code[i..][0..2];
                        i += 2;
                        const len = std.mem.readInt(u16, lenb, .little);
                        const str = code[i..][0..len];
                        i += len;
                        const s = try self.allocator.dupe(u8, str);
                        errdefer self.allocator.free(s);
                        try self.stack.append(self.allocator, .{ .string = s });
                    },
                    .PUSH_VARIABLE => {
                        std.debug.assert(code.len - i + 1 >= 1);
                        const slot = code[i];
                        i += 1;
                        const v = try self.variableGet(slot);
                        errdefer self.valueFree(v);
                        try self.stack.append(self.allocator, v);
                    },
                    .PROMOTE_INTEGER_LONG => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.stack.append(self.allocator, .{ .long = val[0].integer });
                    },
                    .COERCE_INTEGER_SINGLE => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.stack.append(self.allocator, .{ .single = @floatFromInt(val[0].integer) });
                    },
                    .COERCE_INTEGER_DOUBLE => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.stack.append(self.allocator, .{ .double = @floatFromInt(val[0].integer) });
                    },
                    .COERCE_LONG_INTEGER => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        const n = val[0].long;
                        if (n < std.math.minInt(i16) or n > std.math.maxInt(i16))
                            return ErrorInfo.ret(self, Error.Overflow, "overflow coercing LONG to INTEGER", .{});
                        try self.stack.append(self.allocator, .{ .integer = @intCast(n) });
                    },
                    .COERCE_LONG_SINGLE => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.stack.append(self.allocator, .{ .single = @floatFromInt(val[0].long) });
                    },
                    .COERCE_LONG_DOUBLE => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.stack.append(self.allocator, .{ .double = @floatFromInt(val[0].long) });
                    },
                    .COERCE_SINGLE_INTEGER => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        const n = val[0].single;
                        const r: i16 = if (n < std.math.minInt(i16) or n > std.math.maxInt(i16))
                            std.math.minInt(i16)
                        else
                            @intFromFloat(n);
                        try self.stack.append(self.allocator, .{ .integer = r });
                    },
                    .COERCE_SINGLE_LONG => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        const n = val[0].single;
                        const r: i32 = if (n < std.math.minInt(i32) or n > std.math.maxInt(i32))
                            std.math.minInt(i32)
                        else
                            @intFromFloat(n);
                        try self.stack.append(self.allocator, .{ .long = r });
                    },
                    .PROMOTE_SINGLE_DOUBLE => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.stack.append(self.allocator, .{ .double = val[0].single });
                    },
                    .COERCE_DOUBLE_INTEGER => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        const n = val[0].double;
                        const r: i16 = if (n < std.math.minInt(i16) or n > std.math.maxInt(i16))
                            std.math.minInt(i16)
                        else
                            @intFromFloat(n);
                        try self.stack.append(self.allocator, .{ .integer = r });
                    },
                    .COERCE_DOUBLE_LONG => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        const n = val[0].double;
                        const r: i32 = if (n < std.math.minInt(i32) or n > std.math.maxInt(i32))
                            std.math.minInt(i32)
                        else
                            @intFromFloat(n);
                        try self.stack.append(self.allocator, .{ .long = r });
                    },
                    .COERCE_DOUBLE_SINGLE => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.stack.append(self.allocator, .{ .single = @floatCast(val[0].double) });
                    },
                    .LET => {
                        std.debug.assert(code.len - i + 1 >= 1);
                        std.debug.assert(self.stack.items.len >= 1);
                        const slot = code[i];
                        i += 1;
                        const val = self.stackTake(1);
                        errdefer self.valueFreeMany(&val);
                        try self.variableOwn(slot, val[0]);
                    },
                    .BUILTIN_PRINT => {
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.effects.print(val[0]);
                    },
                    .BUILTIN_PRINT_COMMA => try self.effects.printComma(),
                    .BUILTIN_PRINT_LINEFEED => try self.effects.printLinefeed(),
                    .OPERATOR_ADD_INTEGER => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        // TODO: catch overflow and return error.
                        const lhs = try self.assertType(vals[0], .integer);
                        const rhs = try self.assertType(vals[1], .integer);
                        try self.stack.append(self.allocator, .{ .integer = lhs + rhs });
                    },
                    .OPERATOR_ADD_LONG => {
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        // TODO: catch overflow and return error.
                        const lhs = try self.assertType(vals[0], .long);
                        const rhs = try self.assertType(vals[1], .long);
                        try self.stack.append(self.allocator, .{ .long = lhs + rhs });
                    },
                    .OPERATOR_ADD_SINGLE => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        // TODO: catch overflow and return error.
                        const lhs = try self.assertType(vals[0], .single);
                        const rhs = try self.assertType(vals[1], .single);
                        try self.stack.append(self.allocator, .{ .single = lhs + rhs });
                    },
                    .OPERATOR_ADD_DOUBLE => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        // TODO: catch overflow and return error.
                        const lhs = try self.assertType(vals[0], .double);
                        const rhs = try self.assertType(vals[1], .double);
                        try self.stack.append(self.allocator, .{ .double = lhs + rhs });
                    },
                    .OPERATOR_ADD_STRING => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        // TODO: catch overflow and return error.
                        const lhs = try self.assertType(vals[0], .string);
                        const rhs = try self.assertType(vals[1], .string);
                        const v = try self.allocator.alloc(u8, lhs.len + rhs.len);
                        errdefer self.allocator.free(v);
                        @memcpy(v[0..lhs.len], lhs);
                        @memcpy(v[lhs.len..], rhs);
                        try self.stack.append(self.allocator, .{ .string = v });
                    },
                    .OPERATOR_MULTIPLY_INTEGER => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .integer);
                        const rhs = try self.assertType(vals[1], .integer);
                        try self.stack.append(self.allocator, .{ .integer = lhs * rhs });
                    },
                    .OPERATOR_MULTIPLY_LONG => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .long);
                        const rhs = try self.assertType(vals[1], .long);
                        try self.stack.append(self.allocator, .{ .long = lhs * rhs });
                    },
                    .OPERATOR_MULTIPLY_SINGLE => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .single);
                        const rhs = try self.assertType(vals[1], .single);
                        try self.stack.append(self.allocator, .{ .single = lhs * rhs });
                    },
                    .OPERATOR_MULTIPLY_DOUBLE => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .double);
                        const rhs = try self.assertType(vals[1], .double);
                        try self.stack.append(self.allocator, .{ .double = lhs * rhs });
                    },
                    .OPERATOR_SUBTRACT_INTEGER => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .integer);
                        const rhs = try self.assertType(vals[1], .integer);
                        try self.stack.append(self.allocator, .{ .integer = lhs - rhs });
                    },
                    .OPERATOR_SUBTRACT_LONG => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .long);
                        const rhs = try self.assertType(vals[1], .long);
                        try self.stack.append(self.allocator, .{ .long = lhs - rhs });
                    },
                    .OPERATOR_SUBTRACT_SINGLE => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .single);
                        const rhs = try self.assertType(vals[1], .single);
                        try self.stack.append(self.allocator, .{ .single = lhs - rhs });
                    },
                    .OPERATOR_SUBTRACT_DOUBLE => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .double);
                        const rhs = try self.assertType(vals[1], .double);
                        try self.stack.append(self.allocator, .{ .double = lhs - rhs });
                    },
                    .OPERATOR_IDIVIDE_INTEGER => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .integer);
                        const rhs = try self.assertType(vals[1], .integer);
                        try self.stack.append(self.allocator, .{ .integer = @divTrunc(lhs, rhs) });
                    },
                    .OPERATOR_IDIVIDE_LONG => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .long);
                        const rhs = try self.assertType(vals[1], .long);
                        try self.stack.append(self.allocator, .{ .long = @divTrunc(lhs, rhs) });
                    },
                    .OPERATOR_IDIVIDE_SINGLE => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .single);
                        const rhs = try self.assertType(vals[1], .single);
                        // XXX: specific rules around whether integer or long is produced?
                        try self.stack.append(self.allocator, .{
                            .integer = @divTrunc(
                                @as(i16, @intFromFloat(@round(lhs))),
                                @as(i16, @intFromFloat(@round(rhs))),
                            ),
                        });
                    },
                    .OPERATOR_IDIVIDE_DOUBLE => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .double);
                        const rhs = try self.assertType(vals[1], .double);
                        // XXX: specific rules around whether integer or long is produced?
                        try self.stack.append(self.allocator, .{
                            .long = @divTrunc(
                                @as(i32, @intFromFloat(@round(lhs))),
                                @as(i32, @intFromFloat(@round(rhs))),
                            ),
                        });
                    },
                    .OPERATOR_FDIVIDE_INTEGER => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .integer);
                        const rhs = try self.assertType(vals[1], .integer);
                        // XXX: specific rules around whether single or double is produced?
                        try self.stack.append(self.allocator, .{
                            .single = @as(f32, @floatFromInt(lhs)) / @as(f32, @floatFromInt(rhs)),
                        });
                    },
                    .OPERATOR_FDIVIDE_LONG => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .long);
                        const rhs = try self.assertType(vals[1], .long);
                        // XXX: specific rules around whether single or double is produced?
                        try self.stack.append(self.allocator, .{
                            .single = @as(f32, @floatFromInt(lhs)) / @as(f32, @floatFromInt(rhs)),
                        });
                    },
                    .OPERATOR_FDIVIDE_SINGLE => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .single);
                        const rhs = try self.assertType(vals[1], .single);
                        try self.stack.append(self.allocator, .{ .single = lhs / rhs });
                    },
                    .OPERATOR_FDIVIDE_DOUBLE => {
                        std.debug.assert(self.stack.items.len >= 2);
                        const vals = self.stackTake(2);
                        defer self.valueFreeMany(&vals);
                        const lhs = try self.assertType(vals[0], .double);
                        const rhs = try self.assertType(vals[1], .double);
                        try self.stack.append(self.allocator, .{ .double = lhs / rhs });
                    },
                    .OPERATOR_NEGATE_INTEGER => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.stack.append(self.allocator, .{ .integer = -val[0].integer });
                    },
                    .OPERATOR_NEGATE_LONG => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.stack.append(self.allocator, .{ .long = -val[0].long });
                    },
                    .OPERATOR_NEGATE_SINGLE => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.stack.append(self.allocator, .{ .single = -val[0].single });
                    },
                    .OPERATOR_NEGATE_DOUBLE => {
                        std.debug.assert(self.stack.items.len >= 1);
                        const val = self.stackTake(1);
                        defer self.valueFreeMany(&val);
                        try self.stack.append(self.allocator, .{ .double = -val[0].double });
                    },
                    .PRAGMA_PRINTED => {
                        std.debug.assert(code.len - i + 1 >= 2);
                        const lenb = code[i..][0..2];
                        i += 2;
                        const len = std.mem.readInt(u16, lenb, .little);
                        const str = code[i..][0..len];
                        i += len;
                        const s = try @"test".parsePragmaString(self.allocator, str);
                        defer self.allocator.free(s);
                        try self.effects.pragmaPrinted(s);
                    },
                    // else => return ErrorInfo.ret(self, Error.Unimplemented, "unhandled opcode: {s}", .{@tagName(op)}),
                }
            }
        }

        fn assertType(self: *Self, v: isa.Value, comptime t: std.meta.Tag(isa.Value)) !std.meta.TagPayload(isa.Value, t) {
            if (v != t)
                return ErrorInfo.ret(self, Error.TypeMismatch, "expected type {s}, got {s}", .{ @tagName(t), @tagName(v) });
            return @field(v, @tagName(t));
        }

        fn expectStack(self: *const Self, vx: []const isa.Value) !void {
            try testing.expectEqualSlices(isa.Value, vx, self.stack.items);
        }
    };
}

pub const TestEffects = struct {
    const Self = @This();
    pub const Error = error{
        TestExpectedEqual, // for expectPrinted
    };
    const PrintedWriter = std.io.GenericWriter(*Self, Allocator.Error, writerFn);

    printed: std.ArrayListUnmanaged(u8) = .{},
    printedwr: PrintedWriter,
    printloc: PrintLoc = .{},

    expectations: std.ArrayListUnmanaged(struct { exp: []u8, act: []u8 }) = .{},

    pub fn init() !*Self {
        const self = try testing.allocator.create(Self);
        self.* = .{
            .printedwr = PrintedWriter{ .context = self },
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.printed.deinit(testing.allocator);
        for (self.expectations.items) |e| {
            testing.allocator.free(e.exp);
            testing.allocator.free(e.act);
        }
        self.expectations.deinit(testing.allocator);
        testing.allocator.destroy(self);
    }

    fn writerFn(self: *Self, m: []const u8) Allocator.Error!usize {
        self.printloc.write(m);
        try self.printed.appendSlice(testing.allocator, m);
        return m.len;
    }

    pub fn print(self: *Self, v: isa.Value) !void {
        try isa.printFormat(testing.allocator, self.printedwr, v);
    }

    pub fn printComma(self: *Self) !void {
        switch (self.printloc.comma()) {
            .newline => try self.printedwr.writeByte('\n'),
            .spaces => |s| try self.printedwr.writeByteNTimes(' ', s),
        }
    }

    pub fn printLinefeed(self: *Self) !void {
        try self.printedwr.writeByte('\n');
    }

    pub fn expectPrinted(self: *Self, s: []const u8) !void {
        try testing.expectEqualStrings(s, self.printed.items);
        self.printed.items.len = 0;
    }

    pub fn pragmaPrinted(self: *Self, s: []const u8) !void {
        const exp = try testing.allocator.dupe(u8, s);
        errdefer testing.allocator.free(exp);

        const act = try self.printed.toOwnedSlice(testing.allocator);
        errdefer testing.allocator.free(act);

        try self.expectations.append(testing.allocator, .{ .exp = exp, .act = act });
    }
};

fn testRun(inp: anytype) !Machine(TestEffects) {
    const code = try isa.assemble(testing.allocator, inp);
    defer testing.allocator.free(code);

    var m = Machine(TestEffects).init(testing.allocator, try TestEffects.init(), null);
    errdefer m.deinit();

    try m.run(code);
    return m;
}

test "simple push" {
    var m = try testRun(.{
        isa.Opcode.PUSH_IMM_INTEGER,
        isa.Value{ .integer = 0x7fff },
    });
    defer m.deinit();

    try m.expectStack(&.{.{ .integer = 0x7fff }});
}

test "actually print a thing" {
    var m = try testRun(.{
        isa.Opcode.PUSH_IMM_INTEGER,
        isa.Value{ .integer = 123 },
        isa.Opcode.BUILTIN_PRINT,
        isa.Opcode.BUILTIN_PRINT_LINEFEED,
    });
    defer m.deinit();

    try m.expectStack(&.{});
    try m.effects.expectPrinted(" 123 \n");
}

fn testRunBas(allocator: Allocator, inp: []const u8, errorinfo: ?*ErrorInfo) !Machine(TestEffects) {
    const code = try Compiler.compileText(allocator, inp, errorinfo);
    defer allocator.free(code);

    var m = Machine(TestEffects).init(allocator, try TestEffects.init(), errorinfo);
    errdefer m.deinit();

    try m.run(code);
    try m.expectStack(&.{});

    return m;
}

test "actually print a calculated thing" {
    var m = try testRunBas(testing.allocator,
        \\PRINT 1 + 2 * 3
        \\
    , null);
    defer m.deinit();

    try m.effects.expectPrinted(" 7 \n");
}

fn expectRunOutputInner(allocator: Allocator, inp: []const u8, expected: []const u8, errorinfo: ?*ErrorInfo) !void {
    var m = try testRunBas(allocator, inp, errorinfo);
    defer m.deinit();

    try m.effects.expectPrinted(expected);
}

fn expectRunOutput(inp: []const u8, expected: []const u8, errorinfo: ?*ErrorInfo) !void {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        expectRunOutputInner,
        .{ inp, expected, errorinfo },
    );
}

fn expectRunError(inp: []const u8, err: anyerror, msg: ?[]const u8) !void {
    var errorinfo: ErrorInfo = .{};
    defer errorinfo.clear(testing.allocator);
    const eu = expectRunOutput(inp, "", &errorinfo);
    try testing.expectError(err, eu);
    try testing.expectEqualDeep(msg, errorinfo.msg);
}

test "print zones" {
    try expectRunOutput(
        \\print "a", "b", "c"
        \\print 1;-2;3;
    ,
    //    123456789012345678901234567890
        \\a             b             c
        \\ 1 -2  3 
    , null);
}

test "string concat" {
    try expectRunOutput(
        \\print "a"+"b"
    ,
        \\ab
        \\
    , null);
}

test "type mismatch" {
    try expectRunError(
        \\print "a"+2
    , Error.TypeMismatch, "cannot coerce INTEGER to STRING");
}

test "variable assign and recall" {
    try expectRunOutput(
        \\a$ = "koer"
        \\print a$;"a";a$;
    ,
        \\koerakoer
    , null);
}

test "variable reassignment" {
    try expectRunOutput(
        \\a$ = "koer"
        \\a$ = a$ + "akass"
        \\print a$
    , "koerakass\n", null);
}

test "coercion" {
    try expectRunOutput(
        \\a! = 1 + 1.5
        \\b& = 1 + 32768     ' deliberately not testing overflow here
        \\PRINT a!; b&
    , " 2.5  32769 \n", null);
}

test "DOUBLE literal" {
    try expectRunOutput(
        \\a# = 12.345678901
        \\b# = 12.345678901#
        \\PRINT a#; b#
        \\PRINT 12.345678901#; 12.345678901
    ,
        \\ 12.345678901  12.345678901 
        \\ 12.345678901  12.345678901 
        \\
    , null);
}

test "variable autovivification" {
    try expectRunOutput(
        \\a = 1 * b
        \\a$ = "x" + b$
        \\print a; a$
    , " 0 x\n", null);
}

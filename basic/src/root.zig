const std = @import("std");
const testing = std.testing;

comptime {
    testing.refAllDeclsRecursive(@import("Token.zig"));
    testing.refAllDeclsRecursive(@import("Tokenizer.zig"));
    testing.refAllDeclsRecursive(@import("ast/Stmt.zig"));
    testing.refAllDeclsRecursive(@import("ast/Expr.zig"));
    testing.refAllDeclsRecursive(@import("Parser.zig"));
    testing.refAllDeclsRecursive(@import("print.zig"));
    testing.refAllDeclsRecursive(@import("isa.zig"));
    testing.refAllDeclsRecursive(@import("Compiler.zig"));
    testing.refAllDeclsRecursive(@import("stack.zig"));
    testing.refAllDeclsRecursive(@import("PrintLoc.zig"));
}

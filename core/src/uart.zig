const std = @import("std");
const Allocator = std.mem.Allocator;
const uart = @This();

const proto = @import("proto.zig");

const UART: *volatile u8 = @ptrFromInt(0xf000_0000);
const UART_STATUS: *volatile u16 = @ptrFromInt(0xf000_0000);

pub const WriteError = error{};
pub const writer = std.io.GenericWriter(void, WriteError, writeFn){ .context = {} };

fn writeFn(context: void, bytes: []const u8) WriteError!usize {
    _ = context;
    for (bytes) |b|
        UART.* = b;
    return bytes.len;
}

pub const ReadError = error{};
pub const reader = std.io.GenericReader(void, ReadError, readFn){ .context = {} };

fn readFn(context: void, buffer: []u8) ReadError!usize {
    // 0 means EOS, which we never want to signal, so always return a minimum of 1 byte.
    _ = context;
    var i: usize = 0;

    while (i < buffer.len) {
        const cs: u16 = UART_STATUS.*;
        if (cs & 0x100 == 0x100) {
            buffer[i] = @truncate(cs);
            i += 1;
        } else if (i > 0) {
            break;
        }
    }

    return i;
}

pub fn readRequest(allocator: Allocator) !proto.Request {
    return try proto.Request.read(allocator, reader);
}

pub fn writeEvent(response: proto.Event) !void {
    try response.write(writer);
}

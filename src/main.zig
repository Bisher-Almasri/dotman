const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 2) {
        try stdout.print("Usage: dotman [init|add|list|remove]\n", .{});
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        try stdout.print("not implemented", .{});
        return;
    } else if (std.mem.eql(u8, command, "add")) {
        try stdout.print("not implemented", .{});
        return;
    } else if (std.mem.eql(u8, command, "list")) {
        try stdout.print("not implemented", .{});
        return;
    } else if (std.mem.eql(u8, command, "remove")) {
        try stdout.print("not implemented", .{});
        return;
    } else {
        try stdout.print("not command", .{});
        return;
    }
}

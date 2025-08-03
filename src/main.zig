// DotMan
//
// A tool to manage your dot files.

const std = @import("std");

const allocator = std.heap.page_allocator;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try stdout.print("Usage: dotman [init|add|list|remove]\n", .{});
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        try init();
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

const FileRecord = struct {
    original_abs: []const u8,
    repo_abs: []const u8,
};
fn getHomeDir() ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch return friendly(MyError.NoHomeDir);
}

fn getConfigDir() ![]u8 {
    if (try std.process.hasEnvVar(allocator, "DOTMAN_DIR")) {
        return std.process.getEnvVarOwned(allocator, "DOTMAN_DIR");
    }

    if (try std.process.hasEnvVar(allocator, "XDG_DATA_HOME")) {
        const xdg = try std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME");
        return std.fs.path.join(allocator, &.{ xdg, "dotman" });
    }

    const home = try getHomeDir();
    return std.fs.path.join(allocator, &.{ home, ".config", "dotman" });
}

fn readIndex(config_dir: []const u8) !std.ArrayList(FileRecord) {
    var lis = std.ArrayList(FileRecord).init(allocator);

    const path_buf = try std.fs.path.join(allocator, .{ config_dir, "index.txt" });
    defer allocator.free(path_buf);

    const file = std.fs.openFileAbsolute(path_buf, .{ .read = true }) catch |err| {
        if (err == error.FileNotFound) return list else return err;
    };
    defer file.close();

    const contents = file.reader().readAllAlloc(allocator, std.math.maxInt(usize)) catch MyError.IndexReadFailed;
    defer allocator.free(contents);

    var lines = std.mem.splitAny(u8, contents, "\n");

    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        var parts = std.mem.splitAny(u8, line, "\t");

        const orig = parts.next() orelse continue;
        const repo_abs = parts.next() orelse continue;

        try lis.append(FileRecord{ .original_abs = orig, .repo_abs = repo_abs });
    }

    return lis;
}

fn writeIndex(config_dir: []const u8, lis: []const FileRecord) !void {
    const idx_path = try std.fs.path.join(allocator, &.{ config_dir, "index.txt" });
    defer allocator.free(idx_path);

    const idx = try std.fs.createFileAbsolute(idx_path, .{ .truncate = true });
    defer idx.close();

    var fw = idx.writer();
    for (lis) |rec| {
        try fw.print("{}\t{}\n", .{ rec.original_abs, rec.repo_abs });
    }
}

fn init() !void {
    const config_dir = try getConfigDir();
    defer allocator.free(config_dir);

    try std.fs.makeDirAbsolute(config_dir);

    const files_sub = try std.fs.path.join(allocator, &.{ config_dir, "files" });
    defer allocator.free(files_sub);

    _ = std.fs.deleteTreeAbsolute(files_sub) catch {};
    try std.fs.makeDirAbsolute(files_sub);

    const idx_path = try std.fs.path.join(allocator, &.{ config_dir, "index.txt" });
    defer allocator.free(idx_path);

    const idx = try std.fs.createFileAbsolute(idx_path, .{ .truncate = true });
    defer idx.close();

    try std.io.getStdOut().writer().print("Initialized dotman repo at {s}\n", .{config_dir});
}

fn remove() !void {}

fn list() !void {}

pub const MyError = error{
    NoHomeDir,
    NotInHome,
    InvalidRel,
    AlreadyTracked,
    NotTracked,
    IndexReadFailed,
    IndexWriteFailed,
};

pub fn friendly(err: MyError) []const u8 {
    return switch (err) {
        MyError.NoHomeDir => "HOME not set",
        MyError.NotInHome => "Only support files from inside $HOME",
        MyError.InvalidRel => "Cannot determine relative path",
        MyError.AlreadyTracked => "File already tracked",
        MyError.NotTracked => "That file is not tracked",
        MyError.IndexReadFailed => "Failed to read index",
        MyError.IndexWriteFailed => "Failed to write index",
    };
}

// DotMan
//
// A tool to manage your dot files by tracking, symlinking, and organizing them in a central repository.
// This allows for easy backup, versioning, and synchronization across different machines.

const std = @import("std");

const allocator = std.heap.page_allocator;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
  try stdout.print(
            \\Usage: dotman <command> [args]
            \\Commands:
            \\  init [repository-url]  Initialize dotman (optionally with a remote repository)
            \\  add <path>            Track a new dotfile
            \\  list                  Show tracked dotfiles
            \\  remove <path>         Stop tracking a dotfile
            \\  push                  Push changes to remote repository
            \\  pull                  Pull changes from remote repository
            \\  sync                  Synchronize with remote repository
            \\
        , // <- Add this comma to separate arguments
        .{}
        );
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "init")) {
        if (args.len > 2) {
            try init(args[2]);
        } else {
            try init(null);
        }
        return;
    } else if (std.mem.eql(u8, command, "add")) {
        if (args.len != 3) {
            try stdout.print("Usage: dotman add <path>\n", .{});
            return;
        }
        try add(args[2]);
        return;
    } else if (std.mem.eql(u8, command, "list")) {
        try list();
        return;
    } else if (std.mem.eql(u8, command, "remove")) {
        if (args.len != 3) {
            try stdout.print("Usage: dotman remove <path>\n", .{});
            return;
        }
        try remove(args[2]);
        return;
    } else if (std.mem.eql(u8, command, "push")) {
        try push();
        return;
    } else if (std.mem.eql(u8, command, "pull")) {
        try pull();
        return;
    } else if (std.mem.eql(u8, command, "sync")) {
        try sync();
        return;
    } else {
        try stdout.print("Unknown command: {s}\n", .{command});
        return;
    }
}

// FileRecord represents a tracked dotfile with its original location and repository location
const FileRecord = struct {
    original_abs: []const u8, // Absolute path to the original file in user's home directory
    repo_abs: []const u8,     // Absolute path to the file in dotman's repository
};
// getHomeDir returns the user's home directory path from the HOME environment variable
fn getHomeDir() ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch return friendly(MyError.NoHomeDir);
}

// getConfigDir determines the configuration directory for dotman using the following priority:
// 1. DOTMAN_DIR environment variable if set
// 2. XDG_DATA_HOME/dotman if XDG_DATA_HOME is set
// 3. ~/.config/dotman as fallback
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

// readIndex reads and parses the index file that tracks all managed dotfiles
// The index file format is tab-separated: original_path<tab>repo_path
// Lines starting with # are treated as comments
fn readIndex(config_dir: []const u8) !std.ArrayList(FileRecord) {
    var lis = std.ArrayList(FileRecord).init(allocator);

    const path_buf = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, "index.txt" });
    defer allocator.free(path_buf);

    const file = std.fs.openFileAbsolute(path_buf, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) return lis else return err;
    };
    defer file.close();

    const contents = try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(contents);

    var lines = std.mem.splitAny(u8, contents, "\n");

    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;

        var parts = std.mem.splitAny(u8, line, "\t");

        const orig = parts.next() orelse continue;
        const repo_abs = parts.next() orelse continue;

        try lis.append(FileRecord{
            .original_abs = try allocator.dupe(u8, orig),
            .repo_abs = try allocator.dupe(u8, repo_abs),
        });
    }

    return lis;
}

// writeIndex writes the current state of tracked files to the index file
// Each record is written as: original_path<tab>repo_path\n
fn writeIndex(config_dir: []const u8, lis: []const FileRecord) !void {
    const idx_path = try std.fs.path.join(allocator, &.{ config_dir, "index.txt" });
    defer allocator.free(idx_path);

    const idx = try std.fs.createFileAbsolute(idx_path, .{ .truncate = true });
    defer idx.close();

    var fw = idx.writer();
    for (lis) |rec| {
        try fw.print("{s}\t{s}\n", .{ rec.original_abs, rec.repo_abs });
    }
}

const posix = std.posix;

fn getFlags() posix.O {
    return switch (@import("builtin").os.tag) {
        .linux => .{ .NOFOLLOW = true, .PATH = true },
        .macos, .freebsd, .openbsd => .{ .SYMLINK = true },
        else => .{ .NOFOLLOW = true }, // Generic POSIX fallback
    };
}

pub fn lstatLink(path: []const u8) !posix.Stat {
    const flags: posix.O = getFlags();
    const fd = try posix.open(path, flags, 0); // 0 = no mode required (read-only)
    defer posix.close(fd);
    return try posix.fstat(fd);
}

pub fn isLink(path: []const u8) !bool {
    const st = try lstatLink(path);
    return posix.S.ISLNK(st.mode);
}

// init creates a new dotman repository with the following structure:
// - config_dir/
//   |- files/     (where actual dotfiles are stored)
//   |- index.txt  (tracks the mapping between original and repo files)
fn init(repo_url: ?[]const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const config_dir = try getConfigDir();
    defer allocator.free(config_dir);

    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const files_sub = try std.fs.path.join(allocator, &.{ config_dir, "files" });
    defer allocator.free(files_sub);

    _ = std.fs.deleteTreeAbsolute(files_sub) catch {};
    std.fs.makeDirAbsolute(files_sub) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const idx_path = try std.fs.path.join(allocator, &.{ config_dir, "index.txt" });
    defer allocator.free(idx_path);

    const idx = try std.fs.createFileAbsolute(idx_path, .{ .truncate = true });
    defer idx.close();

    // Initialize git repository
    var child = std.process.Child.init(&[_][]const u8{ "git", "init", "--quiet" }, allocator);
    child.cwd = config_dir;
    var result = try child.spawnAndWait();

    if (result.Exited != 0) {
        return error.GitError;
    }


    try stdout.print("Initialized dotman repo with Git at {s}\n", .{config_dir});

    child = std.process.Child.init(&[_][]const u8{ "git", "branch", "-M", "main"}, allocator);
    child.cwd = config_dir;
    result = try child.spawnAndWait();

    if (result.Exited != 0) {
        return error.GitError;
    }

    if (repo_url) |url| {
        // Add remote repository
        child = std.process.Child.init(&[_][]const u8{ "git", "remote", "add", "origin", url}, allocator);
        child.cwd = config_dir;
        result = try child.spawnAndWait();

        if (result.Exited != 0) {
            return error.GitError;
        }

        try stdout.print("Added remote repository: {s}\n", .{url});
    } else {
        try stdout.print("To add a remote repository later, use:\ngit remote add origin <repository-url>\n", .{});
    }
}

// add tracks a new dotfile in the repository
// It performs the following steps:
// 1. Resolves and validates the absolute path
// 2. Ensures the file is within the home directory
// 3. Creates necessary directory structure in the repo
// 4. Creates a symlink from the repo to the original location
// 5. Updates the index file with the new entry
fn add(path_arg: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    const home = getHomeDir() catch return MyError.NoHomeDir;
    defer allocator.free(home);

    var abs = try std.fs.path.resolve(allocator, &.{path_arg});
    defer allocator.free(abs);

    if (abs.len == 0 or abs[0] != '/') {
        const joined = try std.fs.path.join(allocator, &[_][]const u8{ home, abs });
        allocator.free(abs);
        abs = joined;
    }

    const real_abs = try std.fs.realpathAlloc(allocator, abs);
    allocator.free(abs);
    abs = real_abs;

    const home_slash = try std.fs.path.join(allocator, &[_][]const u8{ home, "/" });
    defer allocator.free(home_slash);

    if (!std.mem.startsWith(u8, abs, home_slash)) {
        return MyError.NotInHome;
    }

    const config_dir = getConfigDir() catch return MyError.ConfigDirLookupFailed;
    defer allocator.free(config_dir);

    const files_sub = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, "/files" });
    defer allocator.free(files_sub);

    const rel = abs[home.len + 1 .. abs.len];
    const repo_abs = try std.fs.path.join(allocator, &[_][]const u8{ files_sub, rel });
    defer allocator.free(repo_abs);

    var index = readIndex(config_dir) catch |e|
        return if (e == MyError.IndexReadFailed) e else e;
    defer index.deinit();

    for (index.items) |rec| {
        if (std.mem.eql(u8, rec.original_abs, abs)) {
            return MyError.AlreadyTracked;
        }
    }

    const dirname = std.fs.path.dirname(repo_abs) orelse return MyError.InvalidRel;
    std.fs.cwd().makeDir(dirname) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    try std.fs.cwd().symLink(abs, repo_abs, .{});

    try index.append(FileRecord{
        .original_abs = try allocator.dupe(u8, abs),
        .repo_abs = try allocator.dupe(u8, repo_abs),
    });

    try writeIndex(config_dir, try index.toOwnedSlice());

    try stdout.print("Added: {s}\n → {s}\n", .{ abs, repo_abs });
    return;
}

fn remove(path_arg: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    const home = try getHomeDir();
    defer allocator.free(home);

    var abs = try std.fs.path.resolve(allocator, &.{path_arg});
    defer allocator.free(abs);

    if (abs.len == 0 or abs[0] != '/') {
        const joined = try std.fs.path.join(allocator, &[_][]const u8{ home, abs });
        allocator.free(abs);
        abs = joined;
    }

    const config_dir = try getConfigDir();
    defer allocator.free(config_dir);

    var index = try readIndex(config_dir);
    defer index.deinit();

    var found_idx: ?usize = null;
    for (index.items, 0..) |rec, i| {
        if (std.mem.eql(u8, rec.original_abs, abs)) {
            found_idx = i;
            break;
        }
    }

    if (found_idx == null) {
        return MyError.NotTracked;
    }

    const record = index.items[found_idx.?];

    // Remove symlink if it exists and points to our repo
    if (try isLink(record.original_abs)) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const target = try std.fs.cwd().readLink(record.original_abs, &buffer);
        if (std.mem.eql(u8, target, record.repo_abs)) {
            try std.fs.deleteFileAbsolute(record.original_abs);
        }
    }

    // Remove the file from repo
    std.fs.deleteFileAbsolute(record.repo_abs) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    // Remove the record from index
    _ = index.orderedRemove(found_idx.?);
    try writeIndex(config_dir, index.items);

    try stdout.print("Removed: {s}\n", .{abs});
}

// list displays all tracked files and their current status:
// - [OK]: File is correctly symlinked to the repo
// - [Bad link]: File is symlinked but to wrong destination
// - [Not linked]: File exists but is not a symlink
// - [Not found]: Original file doesn't exist
// - [Broken link]: Symlink exists but target is invalid
fn list() !void {
    const stdout = std.io.getStdOut().writer();
    const config_dir = try getConfigDir();
    defer allocator.free(config_dir);
    const index = try readIndex(config_dir);
    defer index.deinit();

    if (index.items.len == 0) {
        try stdout.print("No files are tracked.\n", .{});
        return;
    }

    try stdout.print("{s: <50} {s: <15} {s}\n", .{ "Original", "Status", "Repo" });
    for (index.items) |rec| {
        var status: []const u8 = "";
        
        if (try isLink(rec.repo_abs)) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const rd = std.fs.cwd().readLink(rec.repo_abs, &buffer) catch {
                status = "[Broken link]";
                try stdout.print("{s: <50} {s: <15} {s}\n", .{ rec.original_abs, status, rec.repo_abs });
                continue;
            };
            status = if (std.mem.eql(u8, rd, rec.original_abs)) "[OK]" else "[Bad link]";
        } else {
            status = "[Not linked]";
        }
        try stdout.print("{s: <50} {s: <15} {s}\n", .{ rec.original_abs, status, rec.repo_abs });
    }
}

// Custom error types for dotman-specific error conditions
pub const MyError = error{ NoHomeDir, NotInHome, InvalidRel, AlreadyTracked, NotTracked, IndexReadFailed, IndexWriteFailed, ConfigDirLookupFailed, GitError };

pub fn friendly(err: MyError) []const u8 {
    return switch (err) {
        MyError.NoHomeDir => "HOME not set",
        MyError.NotInHome => "Only support files from inside $HOME",
        MyError.InvalidRel => "Cannot determine relative path",
        MyError.AlreadyTracked => "File already tracked",
        MyError.NotTracked => "That file is not tracked",
        MyError.IndexReadFailed => "Failed to read index",
        MyError.IndexWriteFailed => "Failed to write index",
        MyError.ConfigDirLookupFailed => "Cannot find Config Dir",
        MyError.GitError => "Git operation failed",
    };
}

// push commits and pushes changes to the remote repository
fn push() !void {
    const config_dir = try getConfigDir();
    defer allocator.free(config_dir);

    var child = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, allocator);
    child.cwd = config_dir;
    _ = try child.spawnAndWait();

    child = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Update dotfiles" }, allocator);
    child.cwd = config_dir;
    _ = try child.spawnAndWait();

    child = std.process.Child.init(&[_][]const u8{ "git", "push", "--set-upstream", "origin", "main" }, allocator);
    child.cwd = config_dir;
    const result = try child.spawnAndWait();

    if (result.Exited != 0) {
        // Try regular push if setting upstream failed (in case it's already set)
        child = std.process.Child.init(&[_][]const u8{ "git", "push" }, allocator);
        child.cwd = config_dir;
        const retry_result = try child.spawnAndWait();
        
        if (retry_result.Exited != 0) {
            return error.GitError;
        }
    }

    try std.io.getStdOut().writer().print("Successfully pushed changes to remote repository\n", .{});
}

// pull fetches and merges changes from the remote repository
fn pull() !void {
    const config_dir = try getConfigDir();
    defer allocator.free(config_dir);

    var child = std.process.Child.init(&[_][]const u8{ "rm", "-rf", "index.txt" }, allocator);
    child.cwd = config_dir;
    var result = try child.spawnAndWait();

    child = std.process.Child.init(&[_][]const u8{ "git", "pull", "origin", "main" }, allocator);
    child.cwd = config_dir;
    result = try child.spawnAndWait();

    if (result.Exited != 0) {
        return error.GitError;
    }

    try std.io.getStdOut().writer().print("Successfully pulled changes from remote repository\n", .{});
}

// sync performs both pull and push operations
fn sync() !void {
    try pull();
    try push();
    try std.io.getStdOut().writer().print("Successfully synchronized with remote repository\n", .{});
}
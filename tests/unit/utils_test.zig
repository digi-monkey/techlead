const std = @import("std");
const testing = std.testing;
const techlead = @import("techlead");
const utils = techlead.utils;

// ============================================
// Tests for isExitedZero
// ============================================

test "isExitedZero returns true for exit code 0" {
    const term: std.process.Child.Term = .{ .Exited = 0 };
    try testing.expect(utils.isExitedZero(term));
}

test "isExitedZero returns false for non-zero exit code" {
    const term1: std.process.Child.Term = .{ .Exited = 1 };
    const term255: std.process.Child.Term = .{ .Exited = 255 };
    const term127: std.process.Child.Term = .{ .Exited = 127 };

    try testing.expect(!utils.isExitedZero(term1));
    try testing.expect(!utils.isExitedZero(term255));
    try testing.expect(!utils.isExitedZero(term127));
}

test "isExitedZero returns false for signal termination" {
    const term_signal: std.process.Child.Term = .{ .Signal = 9 };
    try testing.expect(!utils.isExitedZero(term_signal));
}

test "isExitedZero returns false for stopped process" {
    const term_stopped: std.process.Child.Term = .{ .Stopped = 19 };
    try testing.expect(!utils.isExitedZero(term_stopped));
}

test "isExitedZero returns false for unknown termination" {
    const term_unknown: std.process.Child.Term = .{ .Unknown = 0 };
    try testing.expect(!utils.isExitedZero(term_unknown));
}

// ============================================
// Tests for fileExists
// ============================================

test "fileExists returns true for existing file" {
    const tmp_file = "/tmp/techlead_test_existing_file.txt";

    {
        var file = try std.fs.cwd().createFile(tmp_file, .{});
        defer file.close();
        try file.writeAll("test content");
    }
    defer std.fs.cwd().deleteFile(tmp_file) catch {};

    try testing.expect(utils.fileExists(tmp_file));
}

test "fileExists returns false for non-existent file" {
    const non_existent = "/tmp/techlead_test_nonexistent_file_abc123.xyz";
    std.fs.cwd().deleteFile(non_existent) catch {};
    try testing.expect(!utils.fileExists(non_existent));
}

// ============================================
// Tests for writeFileWithPolicy
// ============================================

test "writeFileWithPolicy creates new file" {
    const tmp_file = "/tmp/techlead_test_write_new.txt";
    const content = "hello world";

    std.fs.cwd().deleteFile(tmp_file) catch {};
    defer std.fs.cwd().deleteFile(tmp_file) catch {};

    try utils.writeFileWithPolicy(tmp_file, content, false);

    try testing.expect(utils.fileExists(tmp_file));

    const read_content = try std.fs.cwd().readFileAlloc(testing.allocator, tmp_file, 1024);
    defer testing.allocator.free(read_content);
    try testing.expectEqualStrings(content, read_content);
}

test "writeFileWithPolicy returns error.FileAlreadyExists when force=false" {
    const tmp_file = "/tmp/techlead_test_write_exists.txt";
    const content1 = "original content";
    const content2 = "new content";

    {
        var file = try std.fs.cwd().createFile(tmp_file, .{});
        defer file.close();
        try file.writeAll(content1);
    }
    defer std.fs.cwd().deleteFile(tmp_file) catch {};

    const result = utils.writeFileWithPolicy(tmp_file, content2, false);
    try testing.expectError(error.FileAlreadyExists, result);

    const read_content = try std.fs.cwd().readFileAlloc(testing.allocator, tmp_file, 1024);
    defer testing.allocator.free(read_content);
    try testing.expectEqualStrings(content1, read_content);
}

test "writeFileWithPolicy overwrites when force=true" {
    const tmp_file = "/tmp/techlead_test_write_force.txt";
    const content1 = "original content";
    const content2 = "overwritten content";

    {
        var file = try std.fs.cwd().createFile(tmp_file, .{});
        defer file.close();
        try file.writeAll(content1);
    }
    defer std.fs.cwd().deleteFile(tmp_file) catch {};

    try utils.writeFileWithPolicy(tmp_file, content2, true);

    const read_content = try std.fs.cwd().readFileAlloc(testing.allocator, tmp_file, 1024);
    defer testing.allocator.free(read_content);
    try testing.expectEqualStrings(content2, read_content);
}

// ============================================
// Tests for command execution
// ============================================

test "runCommandCapture captures stdout" {
    const argv = &[_][]const u8{ "echo", "hello from test" };

    const result = try utils.runCommandCapture(testing.allocator, null, argv);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(utils.isExitedZero(result.term));
    try testing.expectStringEndsWith(result.stdout, "hello from test\n");
}

test "runShellStdout returns trimmed output" {
    const cmd = "echo '  hello with spaces  '";

    const output = try utils.runShellStdout(testing.allocator, null, cmd);
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("hello with spaces", output);
}

test "commandExists returns true for common commands" {
    try testing.expect(utils.commandExists(testing.allocator, "echo"));
    try testing.expect(utils.commandExists(testing.allocator, "ls"));
}

test "commandExists returns false for non-existent command" {
    try testing.expect(!utils.commandExists(testing.allocator, "definitely_not_a_real_command_xyz123"));
}

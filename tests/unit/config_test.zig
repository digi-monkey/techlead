const std = @import("std");
const techlead = @import("techlead");
const config = techlead.config;

// Helper: Create a temporary directory for testing
fn createTempDir(allocator: std.mem.Allocator) ![]u8 {
    const timestamp = std.time.milliTimestamp();
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/tmp/techlead_test_{d}", .{timestamp});
    try std.fs.cwd().makeDir(path);
    return try allocator.dupe(u8, path);
}

// Helper: Remove a temporary directory
fn removeTempDir(test_dir: []const u8) void {
    std.fs.cwd().deleteTree(test_dir) catch {};
}

// Helper: Create .techlead directory and write config file
fn writeConfig(test_dir: []const u8, json_content: []const u8) !void {
    const techlead_dir = try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ test_dir, ".techlead" });
    defer std.heap.page_allocator.free(techlead_dir);
    try std.fs.cwd().makeDir(techlead_dir);

    const config_path = try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ techlead_dir, "techlead.json" });
    defer std.heap.page_allocator.free(config_path);

    const file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();
    try file.writeAll(json_content);
}

// Test 1: Valid minimal config parsing
test "loadConfigFromJson parses valid minimal config" {
    const allocator = std.testing.allocator;

    const test_dir = try createTempDir(allocator);
    defer {
        removeTempDir(test_dir);
        allocator.free(test_dir);
    }

    const minimal_json =
        \\{
        \\  "iterations": 10,
        \\  "work_dir": "/tmp/project",
        \\  "log_dir": ".techlead/logs",
        \\  "model": "gpt-4",
        \\  "agent": "Sisyphus",
        \\  "main_branch": "master",
        \\  "max_branches": 5
        \\}
    ;

    try writeConfig(test_dir, minimal_json);

    const cfg = try config.loadConfigFromJson(allocator, test_dir);
    defer config.deinitConfig(allocator, &cfg);

    try std.testing.expectEqual(@as(usize, 10), cfg.iterations);
    const expected_work_dir = std.fs.cwd().realpathAlloc(allocator, test_dir) catch test_dir;
    defer if (expected_work_dir.ptr != test_dir.ptr) allocator.free(expected_work_dir);
    try std.testing.expectEqualStrings(expected_work_dir, cfg.work_dir);
    try std.testing.expectEqualStrings(".techlead/logs", cfg.log_dir);
    try std.testing.expectEqualStrings("gpt-4", cfg.model);
    try std.testing.expectEqualStrings("Sisyphus", cfg.agent);
    try std.testing.expectEqualStrings("master", cfg.main_branch);
    try std.testing.expectEqual(@as(usize, 5), cfg.max_branches);

    // Check defaults were applied
    try std.testing.expectEqualStrings("codex", cfg.provider);
    try std.testing.expectEqual(@as(u64, 300), cfg.pool_lease_seconds);
    try std.testing.expectEqual(@as(u32, 2), cfg.pool_max_retries);
    try std.testing.expect(cfg.project_test_cmd == null);
    try std.testing.expect(cfg.project_lint_cmd == null);
}

// Test 2: Valid config with all optional fields
test "loadConfigFromJson parses config with all optional fields" {
    const allocator = std.testing.allocator;

    const test_dir = try createTempDir(allocator);
    defer {
        removeTempDir(test_dir);
        allocator.free(test_dir);
    }

    const full_json =
        \\{
        \\  "iterations": 20,
        \\  "opencode_url": "http://localhost:3000",
        \\  "work_dir": "/home/user/project",
        \\  "log_dir": "logs",
        \\  "model": "claude-3-opus",
        \\  "agent": "CustomAgent",
        \\  "provider": "claude",
        \\  "main_branch": "main",
        \\  "max_branches": 15,
        \\  "pool_lease_seconds": 600,
        \\  "pool_max_retries": 5,
        \\  "project_test_cmd": "npm test",
        \\  "project_lint_cmd": "npm run lint"
        \\}
    ;

    try writeConfig(test_dir, full_json);

    const cfg = try config.loadConfigFromJson(allocator, test_dir);
    defer config.deinitConfig(allocator, &cfg);

    try std.testing.expectEqual(@as(usize, 20), cfg.iterations);
    try std.testing.expect(cfg.project_test_cmd != null);
    try std.testing.expectEqualStrings("npm test", cfg.project_test_cmd.?);
}

// Test 3: Reject empty work_dir
test "loadConfigFromJson rejects empty work_dir" {
    const allocator = std.testing.allocator;

    const test_dir = try createTempDir(allocator);
    defer {
        removeTempDir(test_dir);
        allocator.free(test_dir);
    }

    const bad_json =
        \\{
        \\  "iterations": 10,
        \\  "work_dir": "",
        \\  "log_dir": "logs",
        \\  "model": "gpt-4",
        \\  "agent": "Test",
        \\  "main_branch": "main",
        \\  "max_branches": 5
        \\}
    ;

    try writeConfig(test_dir, bad_json);

    const result = config.loadConfigFromJson(allocator, test_dir);
    try std.testing.expectError(error.InvalidConfig, result);
}

// Test 4: Default values for omitted fields
test "loadConfigFromJson applies correct defaults for omitted fields" {
    const allocator = std.testing.allocator;

    const test_dir = try createTempDir(allocator);
    defer {
        removeTempDir(test_dir);
        allocator.free(test_dir);
    }

    const json_no_defaults =
        \\{
        \\  "iterations": 5,
        \\  "work_dir": "/tmp",
        \\  "log_dir": "logs",
        \\  "model": "gpt-3",
        \\  "agent": "Test",
        \\  "main_branch": "develop",
        \\  "max_branches": 3
        \\}
    ;

    try writeConfig(test_dir, json_no_defaults);

    const cfg = try config.loadConfigFromJson(allocator, test_dir);
    defer config.deinitConfig(allocator, &cfg);

    try std.testing.expectEqualStrings("codex", cfg.provider);
    try std.testing.expectEqual(@as(u64, 300), cfg.pool_lease_seconds);
    try std.testing.expectEqual(@as(u32, 2), cfg.pool_max_retries);
    try std.testing.expect(cfg.project_test_cmd == null);
    try std.testing.expect(cfg.project_lint_cmd == null);
}

// Test 5: Config file not found
test "loadConfigFromJson returns ConfigFileNotFound when no config exists" {
    const allocator = std.testing.allocator;

    const test_dir = try createTempDir(allocator);
    defer {
        removeTempDir(test_dir);
        allocator.free(test_dir);
    }

    const result = config.loadConfigFromJson(allocator, test_dir);
    try std.testing.expectError(error.ConfigFileNotFound, result);
}

// Test 6: Invalid JSON parsing
test "loadConfigFromJson returns ConfigParseFailed for invalid JSON" {
    const allocator = std.testing.allocator;

    const test_dir = try createTempDir(allocator);
    defer {
        removeTempDir(test_dir);
        allocator.free(test_dir);
    }

    const invalid_json = "{ invalid json here!!! }";

    try writeConfig(test_dir, invalid_json);

    const result = config.loadConfigFromJson(allocator, test_dir);
    try std.testing.expectError(error.ConfigParseFailed, result);
}

// Test 7: deinitConfig frees all allocated strings
test "deinitConfig frees all allocated strings" {
    const allocator = std.testing.allocator;

    const test_dir = try createTempDir(allocator);
    defer {
        removeTempDir(test_dir);
        allocator.free(test_dir);
    }

    const full_json =
        \\{
        \\  "iterations": 10,
        \\  "opencode_url": "http://example.com",
        \\  "work_dir": "/tmp/work",
        \\  "log_dir": "logs",
        \\  "model": "gpt-4",
        \\  "agent": "Test",
        \\  "provider": "opencode",
        \\  "main_branch": "main",
        \\  "max_branches": 5,
        \\  "pool_lease_seconds": 300,
        \\  "pool_max_retries": 2,
        \\  "project_test_cmd": "cargo test",
        \\  "project_lint_cmd": "cargo clippy"
        \\}
    ;

    try writeConfig(test_dir, full_json);

    {
        const cfg = try config.loadConfigFromJson(allocator, test_dir);
        config.deinitConfig(allocator, &cfg);
    }

    {
        const cfg = try config.loadConfigFromJson(allocator, test_dir);
        config.deinitConfig(allocator, &cfg);
    }
}

// Test 8: deinitConfig handles optional null fields
test "deinitConfig handles optional null fields" {
    const allocator = std.testing.allocator;

    const test_dir = try createTempDir(allocator);
    defer {
        removeTempDir(test_dir);
        allocator.free(test_dir);
    }

    const minimal_json =
        \\{
        \\  "iterations": 10,
        \\  "work_dir": "/tmp",
        \\  "log_dir": "logs",
        \\  "model": "gpt-4",
        \\  "agent": "Test",
        \\  "main_branch": "main",
        \\  "max_branches": 5
        \\}
    ;

    try writeConfig(test_dir, minimal_json);

    const cfg = try config.loadConfigFromJson(allocator, test_dir);

    try std.testing.expect(cfg.project_test_cmd == null);
    try std.testing.expect(cfg.project_lint_cmd == null);

    config.deinitConfig(allocator, &cfg);
}

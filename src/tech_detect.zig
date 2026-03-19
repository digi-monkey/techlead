const std = @import("std");
const config = @import("config.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;

/// Errors that can occur during tech stack detection
pub const TechStackError = error{
    PathNotAccessible,
    OutOfMemory,
};

/// Detect the technology stack of a project by scanning for indicator files.
/// Returns a TechStackDetection struct with primary and optional secondary technologies.
/// Limits results to the first 3 matches found.
pub fn detectTechStack(allocator: Allocator, project_path: []const u8) TechStackError!config.TechStackDetection {
    // Check if path is accessible
    std.fs.cwd().access(project_path, .{}) catch {
        return TechStackError.PathNotAccessible;
    };

    var found_technologies: std.ArrayList([]const u8) = .{};
    errdefer found_technologies.deinit(allocator);

    var found_indicators: std.ArrayList([]const u8) = .{};
    errdefer {
        for (found_indicators.items) |item| {
            allocator.free(item);
        }
        found_indicators.deinit(allocator);
    }

    // Scan through TECH_INDICATORS and check if each file exists
    for (config.TECH_INDICATORS) |indicator| {
        const full_path = std.fs.path.join(allocator, &[_][]const u8{ project_path, indicator.file }) catch {
            return TechStackError.OutOfMemory;
        };
        defer allocator.free(full_path);

        if (utils.fileExists(full_path)) {
            // Check if we already have this technology
            var already_found = false;
            for (found_technologies.items) |tech| {
                if (std.mem.eql(u8, tech, indicator.tech)) {
                    already_found = true;
                    break;
                }
            }

            if (!already_found) {
                const tech_copy = allocator.dupe(u8, indicator.tech) catch {
                    return TechStackError.OutOfMemory;
                };
                try found_technologies.append(allocator, tech_copy);

                const indicator_copy = allocator.dupe(u8, indicator.file) catch {
                    return TechStackError.OutOfMemory;
                };
                try found_indicators.append(allocator, indicator_copy);

                // Limit to first 3 matches
                if (found_technologies.items.len >= 3) {
                    break;
                }
            }
        }
    }

    // Build the result
    var result = config.TechStackDetection{};

    if (found_technologies.items.len > 0) {
        result.primary = found_technologies.items[0];

        if (found_technologies.items.len > 1) {
            result.secondary = found_technologies.items[1];
        }

        // Free any additional technologies beyond what we use (index 2+)
        if (found_technologies.items.len > 2) {
            for (found_technologies.items[2..]) |tech| {
                allocator.free(tech);
            }
        }

        // Convert indicators to slice
        const indicators_slice = allocator.alloc([]const u8, found_indicators.items.len) catch {
            return TechStackError.OutOfMemory;
        };
        for (found_indicators.items, 0..) |item, i| {
            indicators_slice[i] = item;
        }
        result.indicators_found = indicators_slice;
    } else {
        // No technologies found, return "unknown"
        result.primary = "unknown";
        result.indicators_found = &.{};
    }

    // Clean up the array lists but keep the allocated data for the result
    found_technologies.deinit(allocator);
    found_indicators.deinit(allocator);

    return result;
}

/// Free memory owned by a TechStackDetection struct.
/// Must be called when the detection result is no longer needed.
pub fn deinitDetection(allocator: Allocator, detection: *const config.TechStackDetection) void {
    // Only free if primary is not the static "unknown" string
    if (!std.mem.eql(u8, detection.primary, "unknown")) {
        allocator.free(detection.primary);
    }
    if (detection.secondary) |sec| {
        allocator.free(sec);
    }
    for (detection.indicators_found) |indicator| {
        allocator.free(indicator);
    }
    allocator.free(detection.indicators_found);
}

test "detectTechStack returns unknown for empty directory" {
    const allocator = std.testing.allocator;

    // Create a temporary empty directory for testing
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const detection = try detectTechStack(allocator, dir_path);
    defer deinitDetection(allocator, &detection);

    try std.testing.expectEqualStrings("unknown", detection.primary);
    try std.testing.expect(detection.secondary == null);
    try std.testing.expect(detection.indicators_found.len == 0);
}

test "detectTechStack finds Node.js from package.json" {
    const allocator = std.testing.allocator;

    // Create a temporary directory with package.json
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create package.json file
    try tmp_dir.dir.writeFile(.{ .sub_path = "package.json", .data = "{}" });

    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const detection = try detectTechStack(allocator, dir_path);
    defer deinitDetection(allocator, &detection);

    try std.testing.expectEqualStrings("Node.js/npm", detection.primary);
    try std.testing.expect(detection.secondary == null);
    try std.testing.expect(detection.indicators_found.len == 1);
    try std.testing.expectEqualStrings("package.json", detection.indicators_found[0]);
}

test "detectTechStack limits to first 3 matches" {
    const allocator = std.testing.allocator;

    // Create a temporary directory with multiple indicator files
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create multiple indicator files
    try tmp_dir.dir.writeFile(.{ .sub_path = "package.json", .data = "{}" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "Cargo.toml", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "go.mod", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "pyproject.toml", .data = "" });

    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const detection = try detectTechStack(allocator, dir_path);
    defer deinitDetection(allocator, &detection);

    // Should be limited to 3 matches
    try std.testing.expect(detection.indicators_found.len <= 3);
}

test "detectTechStack returns PathNotAccessible for invalid path" {
    const allocator = std.testing.allocator;

    const result = detectTechStack(allocator, "/nonexistent/path/12345");
    try std.testing.expectError(TechStackError.PathNotAccessible, result);
}

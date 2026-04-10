const std = @import("std");
const utils = @import("utils.zig");
const ui = @import("ui.zig");

const Allocator = std.mem.Allocator;

pub const CONFIG_FILE_NAME = "techlead.json";
pub const CONFIG_REL_PATH = ".techlead/techlead.json";
pub const DEFAULT_PROGRAM_REL_PATH = ".techlead/program.md";
pub const DEFAULT_LOG_DIR = ".techlead/iteration-logs";

/// Technology stack indicators for detection
pub const TECH_INDICATORS = [_]struct {
    file: []const u8,
    tech: []const u8,
    priority: u8,
}{
    .{ .file = "package.json", .tech = "Node.js/npm", .priority = 1 },
    .{ .file = "Cargo.toml", .tech = "Rust", .priority = 1 },
    .{ .file = "go.mod", .tech = "Go", .priority = 1 },
    .{ .file = "pyproject.toml", .tech = "Python", .priority = 1 },
    .{ .file = "requirements.txt", .tech = "Python", .priority = 2 },
    .{ .file = "pom.xml", .tech = "Java (Maven)", .priority = 1 },
    .{ .file = "build.gradle", .tech = "Java (Gradle)", .priority = 1 },
    .{ .file = "Gemfile", .tech = "Ruby", .priority = 1 },
    .{ .file = "composer.json", .tech = "PHP", .priority = 1 },
    .{ .file = "zig.mod", .tech = "Zig", .priority = 1 },
};

/// Result of technology stack detection
pub const TechStackDetection = struct {
    primary: []const u8 = "unknown",
    secondary: ?[]const u8 = null,
    indicators_found: []const []const u8 = &.{},

    pub fn format(
        self: TechStackDetection,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.writeAll(self.primary);
        if (self.secondary) |sec| {
            try writer.writeAll(", ");
            try writer.writeAll(sec);
        }
    }
};

/// Configuration structure for JSON serialization/deserialization.
/// This is the on-disk format used in techlead.json config files.
pub const ConfigFile = struct {
    iterations: usize,
    program_file: []const u8,
    opencode_url: []const u8 = "",
    work_dir: []const u8,
    log_dir: []const u8,
    model: []const u8,
    agent: []const u8,
    provider: []const u8 = "codex",
    main_branch: []const u8,
    max_branches: usize,
    pool_lease_seconds: u64 = 300,
    pool_max_retries: u32 = 2,
    project_test_cmd: ?[]const u8 = null,
    project_lint_cmd: ?[]const u8 = null,
};

/// Runtime configuration structure with owned strings.
/// All fields are allocated and must be freed using deinitConfig.
/// The `provider` field is the acpx agent name (e.g. "codex", "claude", "opencode").
pub const Config = struct {
    iterations: usize,
    program_file: []u8,
    opencode_url: []u8,
    work_dir: []u8,
    log_dir: []u8,
    model: []u8,
    agent: []u8,
    provider: []u8,
    main_branch: []u8,
    max_branches: usize,
    pool_lease_seconds: u64,
    pool_max_retries: u32,
    project_test_cmd: ?[]u8 = null,
    project_lint_cmd: ?[]u8 = null,
};

/// Free all memory owned by a Config struct.
/// Must be called when the Config is no longer needed.
pub fn deinitConfig(allocator: Allocator, config: *const Config) void {
    allocator.free(config.program_file);
    allocator.free(config.opencode_url);
    allocator.free(config.work_dir);
    allocator.free(config.log_dir);
    allocator.free(config.model);
    allocator.free(config.agent);
    allocator.free(config.provider);
    allocator.free(config.main_branch);
    if (config.project_test_cmd) |cmd| allocator.free(cmd);
    if (config.project_lint_cmd) |cmd| allocator.free(cmd);
}

/// Resolve the config file path, checking both new (.techlead/techlead.json)
/// and legacy (techlead.json) locations for backward compatibility.
/// Returns error.ConfigFileNotFound if neither location exists.
pub fn resolveConfigPath(allocator: Allocator, base_dir: []const u8) ![]u8 {
    const new_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, CONFIG_REL_PATH });
    if (utils.fileExists(new_path)) {
        return new_path;
    }
    allocator.free(new_path);

    const legacy_path = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, CONFIG_FILE_NAME });
    if (utils.fileExists(legacy_path)) {
        ui.logWarn("检测到旧版配置路径: {s}", .{legacy_path});
        return legacy_path;
    }
    allocator.free(legacy_path);

    return error.ConfigFileNotFound;
}

/// Load configuration from JSON file at the specified base directory.
/// Resolves the config path, parses the JSON, and validates required fields.
/// Returns Config with allocated strings that must be freed with deinitConfig.
pub fn loadConfigFromJson(allocator: Allocator, base_dir: []const u8) !Config {
    const config_path = resolveConfigPath(allocator, base_dir) catch |err| switch (err) {
        error.ConfigFileNotFound => return error.ConfigFileNotFound,
        else => return err,
    };
    defer allocator.free(config_path);

    const config_bytes = std.fs.cwd().readFileAlloc(allocator, config_path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.ConfigFileNotFound,
        else => return err,
    };
    defer allocator.free(config_bytes);

    const parsed = std.json.parseFromSlice(ConfigFile, allocator, config_bytes, .{}) catch {
        return error.ConfigParseFailed;
    };
    defer parsed.deinit();

    const value = parsed.value;
    if (value.program_file.len == 0 or value.work_dir.len == 0 or value.log_dir.len == 0 or value.main_branch.len == 0) {
        return error.InvalidConfig;
    }

    return .{
        .iterations = value.iterations,
        .program_file = try allocator.dupe(u8, value.program_file),
        .opencode_url = try allocator.dupe(u8, value.opencode_url),
        .work_dir = std.fs.cwd().realpathAlloc(allocator, base_dir) catch try allocator.dupe(u8, value.work_dir),
        .log_dir = try allocator.dupe(u8, value.log_dir),
        .model = try allocator.dupe(u8, value.model),
        .agent = try allocator.dupe(u8, value.agent),
        .provider = try allocator.dupe(u8, value.provider),
        .main_branch = try allocator.dupe(u8, value.main_branch),
        .max_branches = value.max_branches,
        .pool_lease_seconds = value.pool_lease_seconds,
        .pool_max_retries = value.pool_max_retries,
        .project_test_cmd = if (value.project_test_cmd) |cmd| try allocator.dupe(u8, cmd) else null,
        .project_lint_cmd = if (value.project_lint_cmd) |cmd| try allocator.dupe(u8, cmd) else null,
    };
}

/// Write a default configuration file to the target directory.
/// Uses the absolute work directory path and default values for all settings.
/// The force parameter controls whether to overwrite existing files.
pub fn writeDefaultConfig(allocator: Allocator, force: bool, target_dir: []const u8) !void {
    const abs_work_dir = try std.fs.cwd().realpathAlloc(allocator, target_dir);
    defer allocator.free(abs_work_dir);

    const cfg = ConfigFile{
        .iterations = 20,
        .program_file = DEFAULT_PROGRAM_REL_PATH,
        .work_dir = abs_work_dir,
        .log_dir = DEFAULT_LOG_DIR,
        .model = "",
        .agent = "Sisyphus",
        .provider = "codex",
        .main_branch = "master",
        .max_branches = 10,
        .pool_lease_seconds = 300,
        .pool_max_retries = 2,
    };

    const final_text = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(cfg, .{ .whitespace = .indent_2 })});
    defer allocator.free(final_text);

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, CONFIG_REL_PATH });
    defer allocator.free(config_path);

    try utils.writeFileWithPolicy(config_path, final_text, force);
}

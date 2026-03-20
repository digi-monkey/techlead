const std = @import("std");
const config = @import("../config.zig");
const git = @import("../git.zig");
const template = @import("../template.zig");
const ui = @import("../ui.zig");
const utils = @import("../utils.zig");

const TECHLEAD_DIR_NAME = ".techlead";
const CONFIG_REL_PATH = ".techlead/techlead.json";
const DEFAULT_PROGRAM_REL_PATH = ".techlead/program.md";

pub fn runInitCommand(allocator: std.mem.Allocator, goal: []const u8, force: bool, target_dir: []const u8) !void {
    try git.verifyGitRepo(target_dir, allocator);

    const techlead_dir = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, TECHLEAD_DIR_NAME });
    defer allocator.free(techlead_dir);
    try std.fs.cwd().makePath(techlead_dir);

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, CONFIG_REL_PATH });
    defer allocator.free(config_path);
    const program_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, DEFAULT_PROGRAM_REL_PATH });
    defer allocator.free(program_path);

    if (!force) {
        if (utils.fileExists(config_path)) {
            ui.logError("{s} 已存在，使用 --force 覆盖", .{config_path});
            return error.FileAlreadyExists;
        }
        if (utils.fileExists(program_path)) {
            ui.logError("{s} 已存在，使用 --force 覆盖", .{program_path});
            return error.FileAlreadyExists;
        }
    }

    const program_template = try template.buildProgramTemplate(allocator, goal);
    defer allocator.free(program_template);

    try config.writeDefaultConfig(allocator, force, target_dir);
    try utils.writeFileWithPolicy(program_path, program_template, force);

    ui.logSuccess("初始化完成", .{});
    ui.logInfo("目标目录: {s}", .{target_dir});
    ui.logInfo("已生成: {s}", .{config_path});
    ui.logInfo("已生成: {s}", .{program_path});
    ui.logInfo("下一步执行: zig build run -- run --dir {s}", .{target_dir});
}

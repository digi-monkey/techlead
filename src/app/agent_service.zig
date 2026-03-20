const std = @import("std");
const clipboard_helper = @import("../clipboard_helper.zig");
const git = @import("../git.zig");
const prompt_builder = @import("../prompt_builder.zig");
const tech_detect = @import("../tech_detect.zig");
const ui = @import("../ui.zig");

pub const InitAgentError = error{
    MissingGoal,
    InvalidPath,
    PathNotAccessible,
    GitRepoRequired,
    OutOfMemory,
};

pub fn runInitAgentCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) return InitAgentError.MissingGoal;
    const goal = args[0];

    var target_dir: []const u8 = ".";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dir")) {
            if (i + 1 >= args.len) return InitAgentError.InvalidPath;
            target_dir = args[i + 1];
            i += 1;
        }
    }

    std.fs.cwd().access(target_dir, .{}) catch {
        ui.logError("路径不可访问: {s}", .{target_dir});
        return InitAgentError.PathNotAccessible;
    };

    git.verifyGitRepo(target_dir, allocator) catch {
        ui.logError("目录不是 git 仓库: {s}", .{target_dir});
        return InitAgentError.GitRepoRequired;
    };

    ui.logInfo("正在分析项目...", .{});

    const detection = tech_detect.detectTechStack(allocator, target_dir) catch |err| {
        ui.logError("技术栈检测失败: {s}", .{@errorName(err)});
        return err;
    };
    defer tech_detect.deinitDetection(allocator, &detection);

    var tech_buf: [256]u8 = undefined;
    const tech_str = if (detection.secondary) |sec|
        std.fmt.bufPrint(&tech_buf, "{s}, {s}", .{ detection.primary, sec }) catch detection.primary
    else
        detection.primary;
    ui.logInfo("检测到的技术栈: {s}", .{tech_str});

    ui.logInfo("正在构建代理提示...", .{});
    const prompt = prompt_builder.buildAgentPrompt(allocator, goal, target_dir, detection) catch |err| {
        ui.logError("构建提示失败: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(prompt);

    ui.logInfo("正在复制到剪贴板...", .{});
    clipboard_helper.copyToClipboardOrStdout(prompt);

    ui.logSuccess("init-agent 完成！", .{});
    ui.logInfo("提示已准备就绪。请粘贴到 OpenCode 中开始工作。", .{});
}

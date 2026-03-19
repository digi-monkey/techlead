const std = @import("std");
const builtin = @import("builtin");

/// 获取当前平台对应的剪贴板命令
fn getClipboardCommand() []const []const u8 {
    return switch (builtin.os.tag) {
        .macos => &.{"pbcopy"},
        .linux => &.{ "xclip", "-selection", "clipboard" },
        .windows => &.{"clip"},
        else => &.{"pbcopy"}, // 默认使用 macOS 命令
    };
}

/// 通过 shell 命令将文本复制到剪贴板
/// 返回 true 表示成功，false 表示失败
pub fn copyToClipboard(text: []const u8) bool {
    const cmd = getClipboardCommand();

    var child = std.process.Child.init(cmd, std.heap.page_allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch {
        return false;
    };

    if (child.stdin) |stdin| {
        stdin.writeAll(text) catch {
            _ = child.kill() catch {};
            return false;
        };
        stdin.close();
        child.stdin = null;
    }

    const term = child.wait() catch {
        return false;
    };

    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// 尝试复制到剪贴板，失败则输出到 stdout
/// 使用中文消息保持 CLI 一致性
pub fn copyToClipboardOrStdout(text: []const u8) void {
    if (copyToClipboard(text)) {
        std.log.info("已复制到剪贴板（{d} 字符）", .{text.len});
        return;
    }

    // 剪贴板失败，回退到 stdout
    std.debug.print("\n=== 剪贴板不可用，请手动复制以下内容 ===\n\n", .{});
    std.debug.print("{s}\n", .{text});
    std.debug.print("\n=== 复制结束 ===\n", .{});
}

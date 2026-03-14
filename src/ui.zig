const std = @import("std");
const utils = @import("utils.zig");

/// ANSI color codes for terminal output
pub const Colors = struct {
    pub const red = "\x1b[0;31m";
    pub const green = "\x1b[0;32m";
    pub const yellow = "\x1b[1;33m";
    pub const blue = "\x1b[0;34m";
    pub const nc = "\x1b[0m";
    pub const cyan = "\x1b[0;36m";
    pub const magenta = "\x1b[0;35m";
    pub const white = "\x1b[1;37m";
    pub const gray = "\x1b[0;90m";
};

/// Log an info message with blue [INFO] prefix
pub fn logInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[INFO]{s} " ++ fmt ++ "\n", .{ Colors.blue, Colors.nc } ++ args);
}

/// Log a success message with green [SUCCESS] prefix
pub fn logSuccess(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[SUCCESS]{s} " ++ fmt ++ "\n", .{ Colors.green, Colors.nc } ++ args);
}

/// Log a warning message with yellow [WARN] prefix
pub fn logWarn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[WARN]{s} " ++ fmt ++ "\n", .{ Colors.yellow, Colors.nc } ++ args);
}

/// Log an error message with red [ERROR] prefix
pub fn logError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}[ERROR]{s} " ++ fmt ++ "\n", .{ Colors.red, Colors.nc } ++ args);
}

/// Truncate text to a maximum length for logging
pub fn truncateForLog(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    return text[0..limit];
}

/// Print an event line with a colored label
pub fn printEventLine(comptime label: []const u8, comptime color: []const u8, msg: []const u8) void {
    std.debug.print("{s}[{s}]{s} {s}\n", .{ color, label, Colors.nc, msg });
}

/// Spinner animation frames for AI loader
pub const AI_SPINNER_FRAMES = [_][]const u8{ "|", "/", "-", "\\" };

/// Runtime state for the AI spinner animation
pub const SpinnerRuntime = struct {
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};

/// Render the AI loader spinner at the given frame index
pub fn renderAiLoader(spinner_index: usize) void {
    const frame = AI_SPINNER_FRAMES[spinner_index % AI_SPINNER_FRAMES.len];
    std.debug.print("\r\x1b[2K{s}[AI]{s} 正在工作 {s}", .{ Colors.blue, Colors.nc, frame });
}

/// Main loop for the spinner thread
pub fn spinnerThreadMain(runtime: *SpinnerRuntime) void {
    var spinner_index: usize = 0;
    while (runtime.running.load(.seq_cst)) {
        renderAiLoader(spinner_index);
        spinner_index = (spinner_index + 1) % AI_SPINNER_FRAMES.len;
        std.Thread.sleep(120 * std.time.ns_per_ms);
    }
}

/// Start the AI loader spinner in a background thread
pub fn startAiLoader(runtime: *SpinnerRuntime) void {
    runtime.running.store(true, .seq_cst);
    runtime.thread = std.Thread.spawn(.{}, spinnerThreadMain, .{runtime}) catch {
        runtime.running.store(false, .seq_cst);
        renderAiLoader(0);
        return;
    };
}

/// Stop the AI loader spinner and clean up the thread
pub fn stopAiLoader(runtime: *SpinnerRuntime) void {
    runtime.running.store(false, .seq_cst);
    if (runtime.thread) |thread| {
        thread.join();
        runtime.thread = null;
    }
    std.debug.print("\r\x1b[2K", .{});
}

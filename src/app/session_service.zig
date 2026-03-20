const std = @import("std");
const config = @import("../config.zig");
const ui = @import("../ui.zig");
const utils = @import("../utils.zig");

const Allocator = std.mem.Allocator;

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    ts: i64,
};

pub const SessionFile = struct {
    session_id: []const u8,
    status: []const u8,
    provider: []const u8,
    model: []const u8,
    created_at: i64,
    updated_at: i64,
    messages: []Message,
};

const LoadedSession = struct {
    allocator: Allocator,
    path: []u8,
    raw: []u8,
    parsed: std.json.Parsed(SessionFile),

    fn deinit(self: *LoadedSession) void {
        self.parsed.deinit();
        self.allocator.free(self.raw);
        self.allocator.free(self.path);
    }
};

fn getSessionPath(allocator: Allocator, target_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &[_][]const u8{ target_dir, ".techlead/session_state.json" });
}

fn loadSession(allocator: Allocator, target_dir: []const u8) !LoadedSession {
    const path = try getSessionPath(allocator, target_dir);
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
    const parsed = try std.json.parseFromSlice(SessionFile, allocator, raw, .{});
    return .{
        .allocator = allocator,
        .path = path,
        .raw = raw,
        .parsed = parsed,
    };
}

fn saveSession(allocator: Allocator, target_dir: []const u8, value: SessionFile) !void {
    const path = try getSessionPath(allocator, target_dir);
    defer allocator.free(path);
    const body = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(value, .{ .whitespace = .indent_2 })});
    defer allocator.free(body);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = body });
}

pub fn startSession(
    allocator: Allocator,
    target_dir: []const u8,
    provider_override: ?[]const u8,
    model_override: ?[]const u8,
) ![]u8 {
    const cfg = try config.loadConfigFromJson(allocator, target_dir);
    defer config.deinitConfig(allocator, &cfg);

    const provider = provider_override orelse cfg.provider;
    const model = model_override orelse cfg.model;
    const now = std.time.timestamp();
    const session_id = try std.fmt.allocPrint(allocator, "sess-{d}", .{now});
    errdefer allocator.free(session_id);

    const empty_messages = &[_]Message{};
    const session = SessionFile{
        .session_id = session_id,
        .status = "active",
        .provider = provider,
        .model = model,
        .created_at = now,
        .updated_at = now,
        .messages = empty_messages,
    };
    try saveSession(allocator, target_dir, session);
    return session_id;
}

pub fn getSessionStateJson(allocator: Allocator, target_dir: []const u8) ![]u8 {
    const path = try getSessionPath(allocator, target_dir);
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
}

pub fn sendMessage(allocator: Allocator, target_dir: []const u8, text: []const u8) ![]u8 {
    var loaded = try loadSession(allocator, target_dir);
    defer loaded.deinit();

    if (!std.mem.eql(u8, loaded.parsed.value.status, "active")) return error.SessionNotActive;

    var cfg = try config.loadConfigFromJson(allocator, target_dir);
    defer config.deinitConfig(allocator, &cfg);

    var msgs: std.ArrayList(Message) = .empty;
    defer msgs.deinit(allocator);
    try msgs.appendSlice(allocator, loaded.parsed.value.messages);
    try msgs.append(allocator, .{
        .role = "user",
        .content = text,
        .ts = std.time.timestamp(),
    });

    const assistant = try generateAssistantReply(allocator, cfg.work_dir, loaded.parsed.value.provider, loaded.parsed.value.model, msgs.items);
    errdefer allocator.free(assistant);
    try msgs.append(allocator, .{
        .role = "assistant",
        .content = assistant,
        .ts = std.time.timestamp(),
    });

    const updated = SessionFile{
        .session_id = loaded.parsed.value.session_id,
        .status = loaded.parsed.value.status,
        .provider = loaded.parsed.value.provider,
        .model = loaded.parsed.value.model,
        .created_at = loaded.parsed.value.created_at,
        .updated_at = std.time.timestamp(),
        .messages = msgs.items,
    };
    try saveSession(allocator, target_dir, updated);
    return assistant;
}

fn generateAssistantReply(
    allocator: Allocator,
    work_dir: []const u8,
    provider: []const u8,
    model: []const u8,
    messages: []const Message,
) ![]u8 {
    if (!std.mem.eql(u8, provider, "codex")) {
        return error.ProviderNotSupportedForSession;
    }
    if (!utils.commandExists(allocator, "codex")) return error.MissingCodex;

    const prompt = try buildConversationPrompt(allocator, messages);
    defer allocator.free(prompt);

    const out_path = try std.fmt.allocPrint(allocator, "{s}/.techlead/session-last-message.txt", .{work_dir});
    defer allocator.free(out_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &[_][]const u8{
        "codex",
        "exec",
        "--cd",
        work_dir,
        "--sandbox",
        "danger-full-access",
        "--output-last-message",
        out_path,
    });
    if (model.len > 0) {
        try argv.append(allocator, "--model");
        try argv.append(allocator, model);
    }
    try argv.append(allocator, prompt);

    const run_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = work_dir,
        .max_output_bytes = 32 * 1024 * 1024,
    });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    if (!utils.isExitedZero(run_result.term)) {
        ui.logWarn("session codex exec exited non-zero", .{});
    }

    const reply = std.fs.cwd().readFileAlloc(allocator, out_path, 4 * 1024 * 1024) catch {
        const fallback = std.mem.trim(u8, run_result.stdout, " \t\r\n");
        return allocator.dupe(u8, fallback);
    };
    defer allocator.free(reply);
    return allocator.dupe(u8, std.mem.trim(u8, reply, " \t\r\n"));
}

fn buildConversationPrompt(allocator: Allocator, messages: []const Message) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator,
        \\You are a coding agent in an ongoing remote session.
        \\Respond concisely and continue the conversation naturally.
        \\If code changes are requested, explain what you would do and ask for confirmation only when risky.
        \\
        \\Conversation:
        \\
    );

    const start_idx = if (messages.len > 20) messages.len - 20 else 0;
    for (messages[start_idx..]) |m| {
        try out.writer(allocator).print("[{s}] {s}\n", .{ m.role, m.content });
    }
    try out.appendSlice(allocator, "\nReply to the latest user message.\n");
    return out.toOwnedSlice(allocator);
}

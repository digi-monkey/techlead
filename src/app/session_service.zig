const std = @import("std");
const config = @import("../config.zig");
const ui = @import("../ui.zig");
const utils = @import("../utils.zig");

const Allocator = std.mem.Allocator;

pub const Message = struct {
    id: u64 = 0,
    role: []const u8,
    content: []const u8,
    ts: i64,
    request_id: ?[]const u8 = null,
};

pub const SessionFile = struct {
    session_id: []const u8,
    status: []const u8,
    provider: []const u8,
    model: []const u8,
    provider_session_id: ?[]const u8 = null,
    last_message_id: u64 = 0,
    in_flight_request_id: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
    created_at: i64,
    updated_at: i64,
    messages: []Message,
};

pub const SendMessageResult = struct {
    status: []const u8,
    deduplicated: bool,
    reply: ?[]u8 = null,
};

pub const EnqueueMessageResult = struct {
    status: []const u8,
    deduplicated: bool,
    reply: ?[]u8 = null,
    accepted: bool,
};

pub const EndSessionResult = struct {
    status: []const u8,
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

    const provider_raw = std.mem.trim(u8, provider_override orelse cfg.provider, " \t\r\n");
    const provider = if (std.ascii.eqlIgnoreCase(provider_raw, "codex"))
        "codex"
    else if (std.ascii.eqlIgnoreCase(provider_raw, "opencode"))
        "opencode"
    else
        return error.ProviderNotSupportedForSession;
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
        .provider_session_id = null,
        .last_message_id = 0,
        .in_flight_request_id = null,
        .last_error = null,
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

pub fn endSession(allocator: Allocator, target_dir: []const u8) !EndSessionResult {
    var loaded = loadSession(allocator, target_dir) catch |err| switch (err) {
        error.FileNotFound => return .{ .status = "not_found" },
        else => return err,
    };
    defer loaded.deinit();

    const now = std.time.timestamp();
    const ended = SessionFile{
        .session_id = loaded.parsed.value.session_id,
        .status = "ended",
        .provider = loaded.parsed.value.provider,
        .model = loaded.parsed.value.model,
        .provider_session_id = loaded.parsed.value.provider_session_id,
        .last_message_id = computeLastMessageId(loaded.parsed.value),
        .in_flight_request_id = null,
        .last_error = null,
        .created_at = loaded.parsed.value.created_at,
        .updated_at = now,
        .messages = loaded.parsed.value.messages,
    };
    try saveSession(allocator, target_dir, ended);
    return .{ .status = "ended" };
}

pub fn sendMessage(allocator: Allocator, target_dir: []const u8, text: []const u8, request_id: []const u8) !SendMessageResult {
    const queued = try enqueueMessage(allocator, target_dir, text, request_id);
    if (!queued.accepted) {
        return .{
            .status = queued.status,
            .deduplicated = queued.deduplicated,
            .reply = queued.reply,
        };
    }
    return processInFlightMessage(allocator, target_dir, request_id);
}

pub fn enqueueMessage(allocator: Allocator, target_dir: []const u8, text: []const u8, request_id: []const u8) !EnqueueMessageResult {
    var loaded = try loadSession(allocator, target_dir);
    defer loaded.deinit();

    const rid = std.mem.trim(u8, request_id, " \t\r\n");
    if (rid.len == 0) return error.RequestIdRequired;
    if (!isSessionWritableStatus(loaded.parsed.value.status)) return error.SessionNotActive;
    if (std.mem.eql(u8, loaded.parsed.value.status, "processing")) {
        if (loaded.parsed.value.in_flight_request_id) |in_flight| {
            if (!std.mem.eql(u8, in_flight, rid)) return error.SessionBusy;
        }
    }

    var cfg = try config.loadConfigFromJson(allocator, target_dir);
    defer config.deinitConfig(allocator, &cfg);

    var msgs: std.ArrayList(Message) = .empty;
    defer msgs.deinit(allocator);
    try msgs.appendSlice(allocator, loaded.parsed.value.messages);

    if (findReplyByRequestId(msgs.items, rid)) |reply| {
        return .{
            .status = "completed",
            .deduplicated = true,
            .reply = try allocator.dupe(u8, reply),
            .accepted = false,
        };
    }
    if (isRequestInFlight(loaded.parsed.value, rid)) {
        return .{
            .status = "processing",
            .deduplicated = true,
            .reply = null,
            .accepted = false,
        };
    }

    var last_message_id = computeLastMessageId(loaded.parsed.value);
    last_message_id += 1;
    const now = std.time.timestamp();
    try msgs.append(allocator, .{
        .id = last_message_id,
        .role = "user",
        .content = text,
        .ts = now,
        .request_id = rid,
    });

    const processing_state = SessionFile{
        .session_id = loaded.parsed.value.session_id,
        .status = "processing",
        .provider = loaded.parsed.value.provider,
        .model = loaded.parsed.value.model,
        .provider_session_id = loaded.parsed.value.provider_session_id,
        .last_message_id = last_message_id,
        .in_flight_request_id = rid,
        .last_error = null,
        .created_at = loaded.parsed.value.created_at,
        .updated_at = now,
        .messages = msgs.items,
    };
    try saveSession(allocator, target_dir, processing_state);

    return .{
        .status = "processing",
        .deduplicated = false,
        .reply = null,
        .accepted = true,
    };
}

pub fn processInFlightMessage(allocator: Allocator, target_dir: []const u8, request_id: []const u8) !SendMessageResult {
    var loaded = try loadSession(allocator, target_dir);
    defer loaded.deinit();

    const rid = std.mem.trim(u8, request_id, " \t\r\n");
    if (rid.len == 0) return error.RequestIdRequired;

    if (findReplyByRequestId(loaded.parsed.value.messages, rid)) |reply| {
        return .{
            .status = "completed",
            .deduplicated = true,
            .reply = try allocator.dupe(u8, reply),
        };
    }

    if (!std.mem.eql(u8, loaded.parsed.value.status, "processing")) {
        return error.SessionNotProcessing;
    }
    const in_flight = loaded.parsed.value.in_flight_request_id orelse return error.SessionNotProcessing;
    if (!std.mem.eql(u8, in_flight, rid)) return error.SessionBusy;

    const user_text = findLatestUserMessageByRequestId(loaded.parsed.value.messages, rid) orelse return error.MessageNotFound;

    var cfg = try config.loadConfigFromJson(allocator, target_dir);
    defer config.deinitConfig(allocator, &cfg);

    var msgs: std.ArrayList(Message) = .empty;
    defer msgs.deinit(allocator);
    try msgs.appendSlice(allocator, loaded.parsed.value.messages);

    var last_message_id = computeLastMessageId(loaded.parsed.value);

    const assistant = generateAssistantReply(
        allocator,
        cfg.work_dir,
        cfg.opencode_url,
        cfg.agent,
        loaded.parsed.value.provider,
        loaded.parsed.value.model,
        loaded.parsed.value.provider_session_id,
        user_text,
    ) catch |err| {
        const err_name = @errorName(err);
        const fail_text = try std.fmt.allocPrint(allocator, "session send failed: {s}", .{err_name});
        defer allocator.free(fail_text);

        last_message_id += 1;
        try msgs.append(allocator, .{
            .id = last_message_id,
            .role = "system",
            .content = fail_text,
            .ts = std.time.timestamp(),
            .request_id = rid,
        });

        const failed_state = SessionFile{
            .session_id = loaded.parsed.value.session_id,
            .status = "error",
            .provider = loaded.parsed.value.provider,
            .model = loaded.parsed.value.model,
            .provider_session_id = loaded.parsed.value.provider_session_id,
            .last_message_id = last_message_id,
            .in_flight_request_id = null,
            .last_error = err_name,
            .created_at = loaded.parsed.value.created_at,
            .updated_at = std.time.timestamp(),
            .messages = msgs.items,
        };
        try saveSession(allocator, target_dir, failed_state);
        return err;
    };
    defer if (assistant.provider_session_id) |sid| allocator.free(sid);

    last_message_id += 1;
    const done_ts = std.time.timestamp();
    try msgs.append(allocator, .{
        .id = last_message_id,
        .role = "assistant",
        .content = assistant.reply,
        .ts = done_ts,
        .request_id = rid,
    });

    const next_provider_session_id = assistant.provider_session_id orelse loaded.parsed.value.provider_session_id;
    const updated = SessionFile{
        .session_id = loaded.parsed.value.session_id,
        .status = "active",
        .provider = loaded.parsed.value.provider,
        .model = loaded.parsed.value.model,
        .provider_session_id = next_provider_session_id,
        .last_message_id = last_message_id,
        .in_flight_request_id = null,
        .last_error = null,
        .created_at = loaded.parsed.value.created_at,
        .updated_at = done_ts,
        .messages = msgs.items,
    };
    try saveSession(allocator, target_dir, updated);
    return .{
        .status = "completed",
        .deduplicated = false,
        .reply = assistant.reply,
    };
}

const AssistantOutput = struct {
    reply: []u8,
    provider_session_id: ?[]u8 = null,
};

fn generateAssistantReply(
    allocator: Allocator,
    work_dir: []const u8,
    opencode_url: []const u8,
    opencode_agent: []const u8,
    provider: []const u8,
    model: []const u8,
    provider_session_id: ?[]const u8,
    text: []const u8,
) !AssistantOutput {
    if (std.mem.eql(u8, provider, "codex")) {
        if (!utils.commandExists(allocator, "codex")) return error.MissingCodex;

        const out_path = try std.fmt.allocPrint(allocator, "{s}/.techlead/session-last-message.txt", .{work_dir});
        defer allocator.free(out_path);
        // Avoid reading stale content if provider fails before writing a new output file.
        std.fs.cwd().deleteFile(out_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);

        if (provider_session_id) |sid| {
            if (sid.len > 0) {
                try argv.appendSlice(allocator, &[_][]const u8{
                    "codex",
                    "exec",
                    "resume",
                    "--json",
                    "--output-last-message",
                    out_path,
                });
                if (model.len > 0) {
                    try argv.append(allocator, "--model");
                    try argv.append(allocator, model);
                }
                try argv.append(allocator, sid);
                try argv.append(allocator, text);
            } else {
                const prompt = try buildInitialPrompt(allocator, text);
                defer allocator.free(prompt);
                try argv.appendSlice(allocator, &[_][]const u8{
                    "codex",
                    "exec",
                    "--json",
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
            }
        } else {
            const prompt = try buildInitialPrompt(allocator, text);
            defer allocator.free(prompt);
            try argv.appendSlice(allocator, &[_][]const u8{
                "codex",
                "exec",
                "--json",
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
        }

        const run_result = try runChildWithUtf8Env(allocator, work_dir, argv.items, 32 * 1024 * 1024);
        defer allocator.free(run_result.stdout);
        defer allocator.free(run_result.stderr);

        if (!utils.isExitedZero(run_result.term)) {
            ui.logWarn("session codex exec exited non-zero", .{});
        }

        const reply = blk: {
            const reply_raw = std.fs.cwd().readFileAlloc(allocator, out_path, 4 * 1024 * 1024) catch {
                const fallback = std.mem.trim(u8, run_result.stdout, " \t\r\n");
                if (fallback.len == 0) return error.EmptyAssistantReply;
                break :blk try allocator.dupe(u8, fallback);
            };
            defer allocator.free(reply_raw);

            const reply_trimmed = std.mem.trim(u8, reply_raw, " \t\r\n");
            if (reply_trimmed.len == 0) return error.EmptyAssistantReply;
            break :blk try allocator.dupe(u8, reply_trimmed);
        };
        errdefer allocator.free(reply);

        var next_provider_session_id: ?[]u8 = null;
        if (provider_session_id) |sid| {
            if (sid.len > 0) next_provider_session_id = try allocator.dupe(u8, sid);
        }
        if (next_provider_session_id == null) {
            if (extractThreadIdFromJsonl(run_result.stdout)) |tid| {
                next_provider_session_id = try allocator.dupe(u8, tid);
            }
        }

        return .{
            .reply = reply,
            .provider_session_id = next_provider_session_id,
        };
    }

    if (std.mem.eql(u8, provider, "opencode")) {
        if (!utils.commandExists(allocator, "opencode")) return error.MissingOpencode;

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try appendOpencodeRunArgs(
            allocator,
            &argv,
            work_dir,
            opencode_url,
            model,
            opencode_agent,
            provider_session_id,
            text,
            true,
        );

        var run_result = try runChildWithUtf8Env(allocator, work_dir, argv.items, 32 * 1024 * 1024);
        var need_retry_without_attach = !utils.isExitedZero(run_result.term) and opencode_url.len > 0;
        if (need_retry_without_attach) {
            ui.logWarn("session opencode run with --attach exited non-zero, retrying without attach", .{});
        }

        var parsed_opt: ?AssistantOutput = null;
        if (!need_retry_without_attach) {
            parsed_opt = parseOpencodeRunOutput(allocator, run_result.stdout) catch |err| switch (err) {
                error.EmptyAssistantReply => blk: {
                    if (opencode_url.len > 0) {
                        ui.logWarn("session opencode run with --attach returned empty reply, retrying without attach", .{});
                        need_retry_without_attach = true;
                        break :blk null;
                    }
                    return err;
                },
                else => return err,
            };
        }

        if (need_retry_without_attach) {
            allocator.free(run_result.stdout);
            allocator.free(run_result.stderr);

            var retry_argv: std.ArrayList([]const u8) = .empty;
            defer retry_argv.deinit(allocator);
            try appendOpencodeRunArgs(
                allocator,
                &retry_argv,
                work_dir,
                opencode_url,
                model,
                opencode_agent,
                provider_session_id,
                text,
                false,
            );
            run_result = try runChildWithUtf8Env(allocator, work_dir, retry_argv.items, 32 * 1024 * 1024);
            parsed_opt = try parseOpencodeRunOutput(allocator, run_result.stdout);
        }
        defer allocator.free(run_result.stdout);
        defer allocator.free(run_result.stderr);

        if (!utils.isExitedZero(run_result.term)) {
            ui.logWarn("session opencode run exited non-zero", .{});
        }

        var parsed = parsed_opt orelse try parseOpencodeRunOutput(allocator, run_result.stdout);
        errdefer {
            allocator.free(parsed.reply);
            if (parsed.provider_session_id) |sid| allocator.free(sid);
        }

        if (parsed.provider_session_id == null) {
            if (provider_session_id) |sid| {
                if (sid.len > 0) parsed.provider_session_id = try allocator.dupe(u8, sid);
            }
        }
        return parsed;
    }

    return error.ProviderNotSupportedForSession;
}

fn buildInitialPrompt(allocator: Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\You are a coding agent in an ongoing remote session.
        \\Respond concisely and continue the conversation naturally.
        \\If code changes are requested, explain what you would do and ask for confirmation only when risky.
        \\
        \\User message:
        \\{s}
        \\
        \\Reply to the latest user message.
    , .{text});
}

fn runChildWithUtf8Env(allocator: Allocator, cwd: []const u8, argv: []const []const u8, max_output_bytes: usize) !std.process.Child.RunResult {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("LANG", "C.UTF-8");
    try env_map.put("LC_ALL", "C.UTF-8");
    try env_map.put("LC_CTYPE", "C.UTF-8");

    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .env_map = &env_map,
        .max_output_bytes = max_output_bytes,
    });
}

fn appendOpencodeRunArgs(
    allocator: Allocator,
    argv: *std.ArrayList([]const u8),
    work_dir: []const u8,
    opencode_url: []const u8,
    model: []const u8,
    opencode_agent: []const u8,
    provider_session_id: ?[]const u8,
    text: []const u8,
    use_attach: bool,
) !void {
    try argv.appendSlice(allocator, &[_][]const u8{
        "opencode",
        "run",
        "--format",
        "json",
        "--dir",
        work_dir,
    });
    if (use_attach and opencode_url.len > 0) {
        try argv.append(allocator, "--attach");
        try argv.append(allocator, opencode_url);
    }
    if (provider_session_id) |sid| {
        if (sid.len > 0) {
            try argv.append(allocator, "--session");
            try argv.append(allocator, sid);
        }
    }
    if (model.len > 0) {
        try argv.append(allocator, "--model");
        try argv.append(allocator, model);
    }
    if (opencode_agent.len > 0) {
        try argv.append(allocator, "--agent");
        try argv.append(allocator, opencode_agent);
    }
    try argv.append(allocator, text);
}

fn parseOpencodeRunOutput(allocator: Allocator, stdout_jsonl: []const u8) !AssistantOutput {
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(allocator);

    var session_id: ?[]u8 = null;
    errdefer if (session_id) |sid| allocator.free(sid);

    var lines = std.mem.splitScalar(u8, stdout_jsonl, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0 or line[0] != '{') continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const root = parsed.value.object;

        if (root.get("sessionID")) |sid_v| {
            if (jsonValueAsString(sid_v)) |sid| {
                if (sid.len > 0) {
                    if (session_id) |old| allocator.free(old);
                    session_id = try allocator.dupe(u8, sid);
                }
            }
        } else if (root.get("sessionId")) |sid_v| {
            if (jsonValueAsString(sid_v)) |sid| {
                if (sid.len > 0) {
                    if (session_id) |old| allocator.free(old);
                    session_id = try allocator.dupe(u8, sid);
                }
            }
        }

        const type_v = root.get("type") orelse continue;
        const event_type = jsonValueAsString(type_v) orelse continue;
        if (!std.mem.eql(u8, event_type, "text")) continue;

        const part_v = root.get("part") orelse continue;
        if (part_v != .object) continue;
        const part = part_v.object;

        const text_v = part.get("text") orelse continue;
        const piece = jsonValueAsString(text_v) orelse continue;
        try text_buf.appendSlice(allocator, piece);
    }

    const reply_trimmed = std.mem.trim(u8, text_buf.items, " \t\r\n");
    if (reply_trimmed.len == 0) return error.EmptyAssistantReply;

    return .{
        .reply = try allocator.dupe(u8, reply_trimmed),
        .provider_session_id = session_id,
    };
}

fn jsonValueAsString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn isSessionWritableStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "active") or std.mem.eql(u8, status, "error") or std.mem.eql(u8, status, "processing");
}

fn isRequestInFlight(session: SessionFile, request_id: []const u8) bool {
    if (!std.mem.eql(u8, session.status, "processing")) return false;
    const in_flight = session.in_flight_request_id orelse return false;
    return std.mem.eql(u8, in_flight, request_id);
}

fn computeLastMessageId(session: SessionFile) u64 {
    var max_id = session.last_message_id;
    for (session.messages) |m| {
        if (m.id > max_id) max_id = m.id;
    }
    if (max_id == 0 and session.messages.len > 0) {
        max_id = @intCast(session.messages.len);
    }
    return max_id;
}

fn findReplyByRequestId(messages: []const Message, request_id: []const u8) ?[]const u8 {
    var seen_user = false;
    for (messages) |m| {
        if (m.request_id) |rid| {
            if (std.mem.eql(u8, rid, request_id) and std.mem.eql(u8, m.role, "assistant")) {
                return m.content;
            }
        }
        if (!seen_user) {
            if (std.mem.eql(u8, m.role, "user")) {
                if (m.request_id) |rid| {
                    if (std.mem.eql(u8, rid, request_id)) seen_user = true;
                }
            }
            continue;
        }
        if (std.mem.eql(u8, m.role, "assistant")) return m.content;
        if (std.mem.eql(u8, m.role, "user")) break;
    }
    return null;
}

fn findLatestUserMessageByRequestId(messages: []const Message, request_id: []const u8) ?[]const u8 {
    var i: usize = messages.len;
    while (i > 0) : (i -= 1) {
        const m = messages[i - 1];
        if (!std.mem.eql(u8, m.role, "user")) continue;
        const rid = m.request_id orelse continue;
        if (std.mem.eql(u8, rid, request_id)) return m.content;
    }
    return null;
}

fn extractThreadIdFromJsonl(stdout_jsonl: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stdout_jsonl, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "\"type\":\"thread.started\"") == null) continue;
        if (extractJsonStringField(line, "thread_id")) |tid| return tid;
    }
    return null;
}

fn extractJsonStringField(line: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, line, pattern) orelse return null;
    const from = start + pattern.len;
    var escaped = false;
    var i = from;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\') {
            escaped = true;
            continue;
        }
        if (ch == '"') {
            return line[from..i];
        }
    }
    return null;
}

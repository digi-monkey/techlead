const std = @import("std");
const config = @import("../config.zig");
const ui = @import("../ui.zig");
const utils = @import("../utils.zig");
const sqlite_session_store = @import("../storage/sqlite_session_store.zig");

const Allocator = std.mem.Allocator;
const SESSION_AGENT_TIMEOUT_SECONDS: u32 = 2 * 60 * 60;

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

// Global SQLite store instance (lazy initialization)
var g_store: ?sqlite_session_store.SqliteSessionStore = null;
var g_store_mutex: std.Thread.Mutex = .{};
var g_session_ops_mutex: std.Thread.Mutex = .{};

fn getStore(allocator: Allocator, target_dir: []const u8) !*sqlite_session_store.SqliteSessionStore {
    g_store_mutex.lock();
    defer g_store_mutex.unlock();

    if (g_store == null) {
        g_store = try sqlite_session_store.SqliteSessionStore.init(allocator, target_dir);
    }
    return &g_store.?;
}

pub fn deinitStore() void {
    g_store_mutex.lock();
    defer g_store_mutex.unlock();

    if (g_store) |*store| {
        store.deinit();
        g_store = null;
    }
}

pub fn startSession(
    allocator: Allocator,
    target_dir: []const u8,
    provider_override: ?[]const u8,
    model_override: ?[]const u8,
) ![]u8 {
    const provider_raw = std.mem.trim(u8, provider_override orelse "opencode", " \t\r\n");
    const provider = if (std.ascii.eqlIgnoreCase(provider_raw, "codex"))
        "codex"
    else if (std.ascii.eqlIgnoreCase(provider_raw, "opencode"))
        "opencode"
    else
        return error.ProviderNotSupportedForSession;
    const model = model_override orelse "";

    g_session_ops_mutex.lock();
    defer g_session_ops_mutex.unlock();

    var store = try getStore(allocator, target_dir);
    return store.createSession(provider, model);
}

pub fn getSessionStateJson(allocator: Allocator, target_dir: []const u8) ![]u8 {
    var store = try getStore(allocator, target_dir);
    const maybe_session = try store.getCurrentSession();
    if (maybe_session == null) return error.FileNotFound;

    var session = maybe_session.?;
    defer session.deinit(store.allocator);

    return store.getSessionStateJson(allocator, session.session_id);
}

pub fn endSession(allocator: Allocator, target_dir: []const u8) !EndSessionResult {
    g_session_ops_mutex.lock();
    defer g_session_ops_mutex.unlock();

    var store = try getStore(allocator, target_dir);
    const maybe_session = try store.getCurrentSession();
    if (maybe_session == null) return .{ .status = "not_found" };

    var session = maybe_session.?;
    defer session.deinit(store.allocator);

    try store.endSession(session.session_id);
    try store.setLastError(session.session_id, null);
    return .{ .status = "ended" };
}

pub fn getCurrentInFlightRequestId(allocator: Allocator, target_dir: []const u8) !?[]u8 {
    g_session_ops_mutex.lock();
    defer g_session_ops_mutex.unlock();

    var store = try getStore(allocator, target_dir);
    const maybe_session = try store.getCurrentSession();
    if (maybe_session == null) return null;

    var session = maybe_session.?;
    defer session.deinit(store.allocator);

    if (!std.mem.eql(u8, session.status, "processing")) return null;
    const rid = session.in_flight_request_id orelse return null;
    if (rid.len == 0) return null;
    return try allocator.dupe(u8, rid);
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
    g_session_ops_mutex.lock();
    defer g_session_ops_mutex.unlock();

    var store = try getStore(allocator, target_dir);
    const maybe_session = try store.getCurrentSession();
    if (maybe_session == null) return error.SessionNotFound;
    var session = maybe_session.?;
    defer session.deinit(store.allocator);

    const rid = std.mem.trim(u8, request_id, " \t\r\n");
    if (rid.len == 0) return error.RequestIdRequired;
    if (!isSessionWritableStatus(session.status)) return error.SessionNotActive;
    if (std.mem.eql(u8, session.status, "processing")) {
        if (session.in_flight_request_id) |in_flight| {
            if (!std.mem.eql(u8, in_flight, rid)) return error.SessionBusy;
        }
    }

    if (try store.findReplyByRequestId(session.session_id, rid)) |reply| {
        defer store.allocator.free(reply);
        return .{
            .status = "completed",
            .deduplicated = true,
            .reply = try allocator.dupe(u8, reply),
            .accepted = false,
        };
    }
    if (std.mem.eql(u8, session.status, "processing") and session.in_flight_request_id != null and std.mem.eql(u8, session.in_flight_request_id.?, rid)) {
        return .{
            .status = "processing",
            .deduplicated = true,
            .reply = null,
            .accepted = false,
        };
    }

    _ = try store.addMessage(session.session_id, "user", text, rid);
    try store.updateSessionStatus(session.session_id, "processing");
    try store.setInFlightRequestId(session.session_id, rid);
    try store.setLastError(session.session_id, null);

    return .{
        .status = "processing",
        .deduplicated = false,
        .reply = null,
        .accepted = true,
    };
}

pub fn processInFlightMessage(allocator: Allocator, target_dir: []const u8, request_id: []const u8) !SendMessageResult {
    g_session_ops_mutex.lock();
    defer g_session_ops_mutex.unlock();

    var store = try getStore(allocator, target_dir);
    const maybe_session = try store.getCurrentSession();
    if (maybe_session == null) return error.SessionNotFound;
    var session = maybe_session.?;
    defer session.deinit(store.allocator);

    const rid = std.mem.trim(u8, request_id, " \t\r\n");
    if (rid.len == 0) return error.RequestIdRequired;

    if (try store.findReplyByRequestId(session.session_id, rid)) |reply| {
        defer store.allocator.free(reply);
        return .{
            .status = "completed",
            .deduplicated = true,
            .reply = try allocator.dupe(u8, reply),
        };
    }

    if (!std.mem.eql(u8, session.status, "processing")) {
        return error.SessionNotProcessing;
    }
    const in_flight = session.in_flight_request_id orelse return error.SessionNotProcessing;
    if (!std.mem.eql(u8, in_flight, rid)) return error.SessionBusy;

    const user_text = (try store.getLatestUserMessageByRequestId(session.session_id, rid)) orelse return error.MessageNotFound;
    defer store.allocator.free(user_text);

    const assistant = generateAssistantReply(
        allocator,
        target_dir,
        "",
        "",
        session.provider,
        session.model,
        session.provider_session_id,
        user_text,
    ) catch |err| {
        const err_name = @errorName(err);
        const fail_text = std.fmt.allocPrint(allocator, "session send failed: {s}", .{err_name}) catch "session send failed";
        defer if (!std.mem.eql(u8, fail_text, "session send failed")) allocator.free(fail_text);

        _ = store.addMessage(session.session_id, "system", fail_text, rid) catch {};
        store.updateSessionStatus(session.session_id, "error") catch {};
        store.setInFlightRequestId(session.session_id, null) catch {};
        store.setLastError(session.session_id, err_name) catch {};
        return err;
    };
    errdefer allocator.free(assistant.reply);
    defer if (assistant.provider_session_id) |sid| allocator.free(sid);

    // The in-flight request may have been canceled/ended by another process
    // while provider execution was running; never overwrite newer session state.
    if (!try isCurrentRequestStillInFlight(store, session.session_id, rid)) {
        return error.SessionNoLongerInFlight;
    }

    _ = try store.addMessage(session.session_id, "assistant", assistant.reply, rid);
    if (assistant.provider_session_id) |sid| {
        try store.setProviderSessionId(session.session_id, sid);
    }
    try store.updateSessionStatus(session.session_id, "active");
    try store.setInFlightRequestId(session.session_id, null);
    try store.setLastError(session.session_id, null);

    return .{
        .status = "completed",
        .deduplicated = false,
        .reply = assistant.reply,
    };
}

pub fn failInFlightMessage(allocator: Allocator, target_dir: []const u8, request_id: []const u8, reason: []const u8) !void {
    g_session_ops_mutex.lock();
    defer g_session_ops_mutex.unlock();

    var store = try getStore(allocator, target_dir);
    const maybe_session = try store.getCurrentSession();
    if (maybe_session == null) return;
    var session = maybe_session.?;
    defer session.deinit(store.allocator);

    const rid = std.mem.trim(u8, request_id, " \t\r\n");
    if (rid.len == 0) return;

    if (!std.mem.eql(u8, session.status, "processing")) return;
    const in_flight = session.in_flight_request_id orelse return;
    if (!std.mem.eql(u8, in_flight, rid)) return;

    if (try store.findReplyByRequestId(session.session_id, rid)) |reply| {
        defer store.allocator.free(reply);
        try store.updateSessionStatus(session.session_id, "active");
        try store.setInFlightRequestId(session.session_id, null);
        try store.setLastError(session.session_id, null);
        return;
    }

    const fail_text = try std.fmt.allocPrint(allocator, "session worker aborted before completion: {s}", .{reason});
    defer allocator.free(fail_text);
    _ = try store.addMessage(session.session_id, "system", fail_text, rid);
    try store.updateSessionStatus(session.session_id, "error");
    try store.setInFlightRequestId(session.session_id, null);
    try store.setLastError(session.session_id, reason);
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
                    "--dangerously-bypass-approvals-and-sandbox",
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
                try argv.appendSlice(allocator, &[_][]const u8{
                    "codex",
                    "exec",
                    "--json",
                    "--cd",
                    work_dir,
                    "--dangerously-bypass-approvals-and-sandbox",
                    "--output-last-message",
                    out_path,
                });
                if (model.len > 0) {
                    try argv.append(allocator, "--model");
                    try argv.append(allocator, model);
                }
                try argv.append(allocator, text);
            }
        } else {
            try argv.appendSlice(allocator, &[_][]const u8{
                "codex",
                "exec",
                "--json",
                "--cd",
                work_dir,
                "--dangerously-bypass-approvals-and-sandbox",
                "--output-last-message",
                out_path,
            });
            if (model.len > 0) {
                try argv.append(allocator, "--model");
                try argv.append(allocator, model);
            }
            try argv.append(allocator, text);
        }

        const run_result = try runChildWithUtf8Env(allocator, work_dir, argv.items, 32 * 1024 * 1024, SESSION_AGENT_TIMEOUT_SECONDS);
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

        var run_result = try runChildWithUtf8Env(allocator, work_dir, argv.items, 32 * 1024 * 1024, SESSION_AGENT_TIMEOUT_SECONDS);
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
            run_result = try runChildWithUtf8Env(allocator, work_dir, retry_argv.items, 32 * 1024 * 1024, SESSION_AGENT_TIMEOUT_SECONDS);
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

fn runChildWithUtf8Env(
    allocator: Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    max_output_bytes: usize,
    timeout_seconds: u32,
) !std.process.Child.RunResult {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("LANG", "C.UTF-8");
    try env_map.put("LC_ALL", "C.UTF-8");
    try env_map.put("LC_CTYPE", "C.UTF-8");

    var effective_argv: std.ArrayList([]const u8) = .empty;
    defer effective_argv.deinit(allocator);

    if (timeout_seconds > 0 and utils.commandExists(allocator, "timeout")) {
        var timeout_buf: [32]u8 = undefined;
        const timeout_spec = try std.fmt.bufPrint(&timeout_buf, "{d}s", .{timeout_seconds});
        try effective_argv.appendSlice(allocator, &[_][]const u8{
            "timeout",
            "--kill-after=5s",
            timeout_spec,
        });
        try effective_argv.appendSlice(allocator, argv);
    } else {
        try effective_argv.appendSlice(allocator, argv);
    }

    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = effective_argv.items,
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

fn isCurrentRequestStillInFlight(
    store: *sqlite_session_store.SqliteSessionStore,
    session_id: []const u8,
    request_id: []const u8,
) !bool {
    const latest_opt = try store.getSession(session_id);
    if (latest_opt == null) return false;

    var latest = latest_opt.?;
    defer latest.deinit(store.allocator);

    if (!std.mem.eql(u8, latest.status, "processing")) return false;
    const latest_rid = latest.in_flight_request_id orelse return false;
    return std.mem.eql(u8, latest_rid, request_id);
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

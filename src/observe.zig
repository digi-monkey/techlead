const std = @import("std");
const http = std.http;

const config = @import("config.zig");
const ui = @import("ui.zig");
const runner = @import("runner.zig");
const replay = @import("storage/replay.zig");
const session_service = @import("app/session_service.zig");

const Allocator = std.mem.Allocator;
const TOKEN_TTL_SECONDS: i64 = 7 * 24 * 60 * 60;
const CONTROL_MIN_INTERVAL_MS: i64 = 300;
const REQUEST_ID_TTL_SECONDS: i64 = 5 * 60;
const OBSERVE_UI_DIST_DIR = "web/observe-ui/dist";

const TokenFile = struct {
    observe_token: []const u8,
    control_token: []const u8,
    observe_expires_at: i64,
    control_expires_at: i64,
};

const ServerContext = struct {
    allocator: Allocator,
    target_dir: []const u8,
    log_dir: []const u8,
    host: []const u8,
    port: u16,
    observe_token: []const u8,
    control_token: []const u8,
    observe_expires_at: i64,
    control_expires_at: i64,
    last_control_ms: i64 = 0,
    request_ids: std.StringHashMap(i64),
};

const ControlBody = struct {
    action: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
};

const StartRunBody = struct {
    mode: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
};

const StartSessionBody = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
};

const SessionMessageBody = struct {
    message: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
};

const RunState = struct {
    run_id: []const u8,
    mode: []const u8,
    status: []const u8,
    updated_at: i64,
};

pub fn runObserveStartCommand(allocator: Allocator, target_dir: []const u8, host: []const u8, port: u16) !void {
    const cfg = try config.loadConfigFromJson(allocator, target_dir);
    defer config.deinitConfig(allocator, &cfg);

    const tokens = try ensureTokens(allocator, target_dir);
    defer allocator.free(tokens.observe_token);
    defer allocator.free(tokens.control_token);

    var ctx = ServerContext{
        .allocator = allocator,
        .target_dir = try allocator.dupe(u8, target_dir),
        .log_dir = try allocator.dupe(u8, cfg.log_dir),
        .host = try allocator.dupe(u8, host),
        .port = port,
        .observe_token = try allocator.dupe(u8, tokens.observe_token),
        .control_token = try allocator.dupe(u8, tokens.control_token),
        .observe_expires_at = tokens.observe_expires_at,
        .control_expires_at = tokens.control_expires_at,
        .request_ids = std.StringHashMap(i64).init(allocator),
    };
    defer allocator.free(ctx.target_dir);
    defer allocator.free(ctx.log_dir);
    defer allocator.free(ctx.host);
    defer allocator.free(ctx.observe_token);
    defer allocator.free(ctx.control_token);
    defer {
        var it = ctx.request_ids.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        ctx.request_ids.deinit();
    }

    const address = try std.net.Address.parseIp(host, port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    ui.logSuccess("observe 服务已启动: http://{s}:{d}", .{ host, server.listen_address.getPort() });
    ui.logInfo("observe token: {s}", .{ctx.observe_token});
    ui.logInfo("control token: {s}", .{ctx.control_token});
    ui.logInfo("扫码/分享入口: http://{s}:{d}/?token={s}", .{ host, server.listen_address.getPort(), ctx.observe_token });

    while (true) {
        const conn = server.accept() catch |err| {
            ui.logWarn("accept 失败: {s}", .{@errorName(err)});
            continue;
        };
        defer conn.stream.close();
        try handleConnection(&ctx, conn);
    }
}

pub fn runObserveRotateTokensCommand(allocator: Allocator, target_dir: []const u8) !void {
    const tokens = try ensureTokensInternal(allocator, target_dir, true);
    defer allocator.free(tokens.observe_token);
    defer allocator.free(tokens.control_token);
    ui.logSuccess("tokens 已轮换", .{});
    ui.logInfo("observe token: {s}", .{tokens.observe_token});
    ui.logInfo("control token: {s}", .{tokens.control_token});
}

fn handleConnection(ctx: *ServerContext, conn: std.net.Server.Connection) !void {
    var send_buffer: [8192]u8 = undefined;
    var recv_buffer: [8192]u8 = undefined;
    var conn_reader = conn.stream.reader(&recv_buffer);
    var conn_writer = conn.stream.writer(&send_buffer);
    var server: http.Server = .init(conn_reader.interface(), &conn_writer.interface);

    while (true) {
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return,
        };
        try serveRequest(ctx, &req);
    }
}

fn serveRequest(ctx: *ServerContext, req: *http.Server.Request) !void {
    const target = req.head.target;
    if (try serveObserveUiAsset(ctx, req, target)) return;
    if (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?")) {
        return respondHtml(req, dashboardHtml());
    }

    if (std.mem.eql(u8, target, "/health")) {
        return respondJson(req, .ok, "{\"ok\":true}");
    }

    if (std.mem.startsWith(u8, target, "/auth/qr/bootstrap")) {
        if (!authorized(req, ctx.observe_token, ctx.observe_expires_at)) {
            return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
        }
        const body = try std.fmt.allocPrint(ctx.allocator, "{{\"url\":\"http://{s}:{d}/?token={s}\"}}", .{ ctx.host, ctx.port, ctx.observe_token });
        defer ctx.allocator.free(body);
        return respondJson(req, .ok, body);
    }

    if (std.mem.startsWith(u8, target, "/events")) {
        if (!authorized(req, ctx.observe_token, ctx.observe_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
        const after = parseAfterQuery(target);
        const events = replay.readEventsAfter(ctx.allocator, ctx.target_dir, ctx.log_dir, after) catch "{\"events\":[],\"last_event_id\":0}";
        defer if (events.ptr != "{\"events\":[],\"last_event_id\":0}".ptr) ctx.allocator.free(events);
        return respondJson(req, .ok, events);
    }

    if (std.mem.startsWith(u8, target, "/runs/") and std.mem.endsWith(u8, target, "/events/stream")) {
        if (!authorized(req, ctx.observe_token, ctx.observe_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
        if (!try validateRequestedRunId(ctx.allocator, ctx.target_dir, target)) {
            return respondJson(req, .conflict, "{\"error\":\"run_id_mismatch\"}");
        }
        const after = parseAfterFromRequest(req);
        return streamEvents(req, ctx, after);
    }

    if (std.mem.startsWith(u8, target, "/runs/current/events/stream")) {
        if (!authorized(req, ctx.observe_token, ctx.observe_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
        const after = parseAfterFromRequest(req);
        return streamEvents(req, ctx, after);
    }

    if (std.mem.startsWith(u8, target, "/runs/") and std.mem.endsWith(u8, target, "/events")) {
        if (!authorized(req, ctx.observe_token, ctx.observe_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
        if (!try validateRequestedRunId(ctx.allocator, ctx.target_dir, target)) {
            return respondJson(req, .conflict, "{\"error\":\"run_id_mismatch\"}");
        }
        const after = parseAfterQuery(target);
        const events = replay.readEventsAfter(ctx.allocator, ctx.target_dir, ctx.log_dir, after) catch "{\"events\":[],\"last_event_id\":0}";
        defer if (events.ptr != "{\"events\":[],\"last_event_id\":0}".ptr) ctx.allocator.free(events);
        return respondJson(req, .ok, events);
    }

    if (std.mem.startsWith(u8, target, "/runs/current/events")) {
        if (!authorized(req, ctx.observe_token, ctx.observe_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
        const after = parseAfterQuery(target);
        const events = replay.readEventsAfter(ctx.allocator, ctx.target_dir, ctx.log_dir, after) catch "{\"events\":[],\"last_event_id\":0}";
        defer if (events.ptr != "{\"events\":[],\"last_event_id\":0}".ptr) ctx.allocator.free(events);
        return respondJson(req, .ok, events);
    }

    if (std.mem.startsWith(u8, target, "/tasks")) {
        if (!authorized(req, ctx.observe_token, ctx.observe_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
        const tasks = readTasks(ctx.allocator, ctx.target_dir) catch "{\"tasks\":[]}";
        defer if (tasks.ptr != "{\"tasks\":[]}".ptr) ctx.allocator.free(tasks);
        return respondJson(req, .ok, tasks);
    }

    if (std.mem.startsWith(u8, target, "/sessions/current")) {
        if (std.mem.eql(u8, target, "/sessions/current") and req.head.method == .GET) {
            if (!authorized(req, ctx.observe_token, ctx.observe_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
            const state = session_service.getSessionStateJson(ctx.allocator, ctx.target_dir) catch "{\"error\":\"session_not_found\"}";
            defer if (state.ptr != "{\"error\":\"session_not_found\"}".ptr) ctx.allocator.free(state);
            return respondJson(req, .ok, state);
        }
        if (std.mem.eql(u8, target, "/sessions/current/message")) {
            if (!authorized(req, ctx.control_token, ctx.control_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
            if (req.head.method != .POST) return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
            if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

            var request_id: ?[]u8 = requestIdFromHeader(ctx.allocator, req);
            defer if (request_id) |rid| ctx.allocator.free(rid);
            var message: ?[]u8 = null;
            defer if (message) |m| ctx.allocator.free(m);

            if (try parseSessionMessageBody(req, ctx.allocator)) |body| {
                defer {
                    if (body.message) |m| ctx.allocator.free(m);
                    if (body.request_id) |rid| ctx.allocator.free(rid);
                }
                if (body.message) |m| message = try ctx.allocator.dupe(u8, m);
                if (body.request_id) |rid| {
                    if (request_id) |old| ctx.allocator.free(old);
                    request_id = try ctx.allocator.dupe(u8, rid);
                }
            }
            if (message == null or std.mem.trim(u8, message.?, " \t\r\n").len == 0) {
                return respondJson(req, .bad_request, "{\"error\":\"message_required\"}");
            }
            if (request_id) |rid| {
                if (isDuplicateRequestId(ctx, rid)) return respondJson(req, .conflict, "{\"error\":\"duplicate_request_id\"}");
            }

            const reply = session_service.sendMessage(ctx.allocator, ctx.target_dir, message.?) catch |err| {
                ui.logWarn("session send failed: {any}", .{err});
                return respondJson(req, .bad_request, "{\"error\":\"session_send_failed\"}");
            };
            defer ctx.allocator.free(reply);
            const body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"reply\":{f}}}", .{std.json.fmt(reply, .{})});
            defer ctx.allocator.free(body);
            return respondJson(req, .ok, body);
        }
    }

    if (std.mem.startsWith(u8, target, "/sessions/start")) {
        if (!authorized(req, ctx.control_token, ctx.control_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
        if (req.head.method != .POST) return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
        if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

        var request_id: ?[]u8 = requestIdFromHeader(ctx.allocator, req);
        defer if (request_id) |rid| ctx.allocator.free(rid);
        var provider: ?[]u8 = null;
        defer if (provider) |p| ctx.allocator.free(p);
        var model: ?[]u8 = null;
        defer if (model) |m| ctx.allocator.free(m);

        if (try parseStartSessionBody(req, ctx.allocator)) |body| {
            defer {
                if (body.provider) |p| ctx.allocator.free(p);
                if (body.model) |m| ctx.allocator.free(m);
                if (body.request_id) |rid| ctx.allocator.free(rid);
            }
            if (body.provider) |p| provider = try ctx.allocator.dupe(u8, p);
            if (body.model) |m| model = try ctx.allocator.dupe(u8, m);
            if (body.request_id) |rid| {
                if (request_id) |old| ctx.allocator.free(old);
                request_id = try ctx.allocator.dupe(u8, rid);
            }
        }
        if (request_id) |rid| {
            if (isDuplicateRequestId(ctx, rid)) return respondJson(req, .conflict, "{\"error\":\"duplicate_request_id\"}");
        }

        const session_id = session_service.startSession(ctx.allocator, ctx.target_dir, provider, model) catch |err| {
            ui.logWarn("session start failed: {any}", .{err});
            return respondJson(req, .bad_request, "{\"error\":\"session_start_failed\"}");
        };
        defer ctx.allocator.free(session_id);
        const body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"session_id\":{f}}}", .{std.json.fmt(session_id, .{})});
        defer ctx.allocator.free(body);
        return respondJson(req, .ok, body);
    }

    if (std.mem.startsWith(u8, target, "/runs/start")) {
        if (!authorized(req, ctx.control_token, ctx.control_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
        if (req.head.method != .POST) {
            return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
        }
        if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

        var mode: []const u8 = "optimize";
        var mode_owned: ?[]u8 = null;
        defer if (mode_owned) |m| ctx.allocator.free(m);
        var request_id: ?[]u8 = requestIdFromHeader(ctx.allocator, req);
        defer if (request_id) |rid| ctx.allocator.free(rid);

        if (try parseStartRunBody(req, ctx.allocator)) |body| {
            defer {
                if (body.mode) |m| ctx.allocator.free(m);
                if (body.request_id) |rid| ctx.allocator.free(rid);
            }
            if (body.mode) |m| {
                mode_owned = try ctx.allocator.dupe(u8, m);
                mode = mode_owned.?;
            }
            if (body.request_id) |rid| request_id = try ctx.allocator.dupe(u8, rid);
        }
        if (request_id) |rid| {
            if (isDuplicateRequestId(ctx, rid)) return respondJson(req, .conflict, "{\"error\":\"duplicate_request_id\"}");
        }

        if (!std.mem.eql(u8, mode, "optimize") and !std.mem.eql(u8, mode, "pool")) {
            return respondJson(req, .bad_request, "{\"error\":\"invalid_mode\"}");
        }

        const pid = startRunDetached(ctx.allocator, ctx.target_dir, mode) catch |err| {
            ui.logWarn("启动 run 失败: {any}", .{err});
            return respondJson(req, .bad_request, "{\"error\":\"start_failed\"}");
        };
        const body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"pid\":{d},\"mode\":{f}}}", .{ pid, std.json.fmt(mode, .{}) });
        defer ctx.allocator.free(body);
        return respondJson(req, .ok, body);
    }

    if (std.mem.startsWith(u8, target, "/runs/") and std.mem.endsWith(u8, target, "/control")) {
        if (!authorized(req, ctx.control_token, ctx.control_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
        if (!try validateRequestedRunId(ctx.allocator, ctx.target_dir, target)) {
            return respondJson(req, .conflict, "{\"error\":\"run_id_mismatch\"}");
        }
        if (req.head.method != .POST and req.head.method != .GET) {
            return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
        }
        if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

        var action: []const u8 = queryValue(target, "action") orelse "none";
        var action_owned: ?[]u8 = null;
        defer if (action_owned) |a| ctx.allocator.free(a);
        var prompt: ?[]u8 = null;
        defer if (prompt) |p| ctx.allocator.free(p);
        var request_id: ?[]u8 = requestIdFromHeader(ctx.allocator, req);
        defer if (request_id) |rid| ctx.allocator.free(rid);

        if (queryValue(target, "prompt")) |p| {
            prompt = try decodeUrlComponent(ctx.allocator, p);
        }
        if (queryValue(target, "request_id")) |rid| {
            request_id = try decodeUrlComponent(ctx.allocator, rid);
        }
        if (req.head.method == .POST) {
            if (try parseControlBody(req, ctx.allocator)) |body| {
                defer {
                    if (body.action) |a| ctx.allocator.free(a);
                    if (body.prompt) |p| ctx.allocator.free(p);
                    if (body.request_id) |rid| ctx.allocator.free(rid);
                }
                if (body.action) |a| {
                    action_owned = try ctx.allocator.dupe(u8, a);
                    action = action_owned.?;
                }
                if (body.prompt) |p| {
                    if (prompt) |old| ctx.allocator.free(old);
                    prompt = try ctx.allocator.dupe(u8, p);
                }
                if (body.request_id) |rid| {
                    if (request_id) |old| ctx.allocator.free(old);
                    request_id = try ctx.allocator.dupe(u8, rid);
                }
            }
        }
        const rid = request_id orelse "unknown";
        if (request_id) |r| {
            if (isDuplicateRequestId(ctx, r)) return respondJson(req, .conflict, "{\"error\":\"duplicate_request_id\"}");
        }
        try runner.runControlCommandWithMetaAndRequestId(ctx.allocator, ctx.target_dir, action, prompt, "observe-user", "observe-api", rid);
        return respondJson(req, .ok, "{\"ok\":true}");
    }

    if (std.mem.startsWith(u8, target, "/control") or std.mem.startsWith(u8, target, "/runs/current/control")) {
        if (!authorized(req, ctx.control_token, ctx.control_expires_at)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
        if (req.head.method != .POST and req.head.method != .GET) {
            return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
        }
        if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

        var action: []const u8 = queryValue(target, "action") orelse "none";
        var action_owned: ?[]u8 = null;
        defer if (action_owned) |a| ctx.allocator.free(a);
        var prompt: ?[]u8 = null;
        defer if (prompt) |p| ctx.allocator.free(p);
        var request_id: ?[]u8 = requestIdFromHeader(ctx.allocator, req);
        defer if (request_id) |rid| ctx.allocator.free(rid);

        if (queryValue(target, "prompt")) |p| {
            prompt = try decodeUrlComponent(ctx.allocator, p);
        }
        if (queryValue(target, "request_id")) |rid| {
            request_id = try decodeUrlComponent(ctx.allocator, rid);
        }

        // Standardized POST JSON body:
        // {"action":"pause|resume|abort|inject_prompt","prompt":"...optional..."}
        if (req.head.method == .POST) {
            if (try parseControlBody(req, ctx.allocator)) |body| {
                defer {
                    if (body.action) |a| ctx.allocator.free(a);
                    if (body.prompt) |p| ctx.allocator.free(p);
                    if (body.request_id) |rid| ctx.allocator.free(rid);
                }
                if (body.action) |a| {
                    action_owned = try ctx.allocator.dupe(u8, a);
                    action = action_owned.?;
                }
                if (body.prompt) |p| {
                    if (prompt) |old| ctx.allocator.free(old);
                    prompt = try ctx.allocator.dupe(u8, p);
                }
                if (body.request_id) |rid| {
                    if (request_id) |old| ctx.allocator.free(old);
                    request_id = try ctx.allocator.dupe(u8, rid);
                }
            }
        }
        const rid = request_id orelse "unknown";
        if (request_id) |r| {
            if (isDuplicateRequestId(ctx, r)) return respondJson(req, .conflict, "{\"error\":\"duplicate_request_id\"}");
        }
        try runner.runControlCommandWithMetaAndRequestId(ctx.allocator, ctx.target_dir, action, prompt, "observe-user", "observe-api", rid);
        return respondJson(req, .ok, "{\"ok\":true}");
    }

    return respondJson(req, .not_found, "{\"error\":\"not_found\"}");
}

fn serveObserveUiAsset(ctx: *ServerContext, req: *http.Server.Request, target: []const u8) !bool {
    if (req.head.method != .GET) return false;

    const path_no_query = blk: {
        if (std.mem.indexOfScalar(u8, target, '?')) |q| break :blk target[0..q];
        break :blk target;
    };

    if (!(std.mem.eql(u8, path_no_query, "/") or std.mem.startsWith(u8, path_no_query, "/assets/"))) {
        return false;
    }

    const rel_path = if (std.mem.eql(u8, path_no_query, "/")) "index.html" else path_no_query[1..];
    if (std.mem.indexOf(u8, rel_path, "..") != null) return false;

    const full_path = try std.fs.path.join(ctx.allocator, &[_][]const u8{ OBSERVE_UI_DIST_DIR, rel_path });
    defer ctx.allocator.free(full_path);

    const data = std.fs.cwd().readFileAlloc(ctx.allocator, full_path, 8 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer ctx.allocator.free(data);

    const content_type = contentTypeForPath(rel_path);
    try respondBody(req, .ok, data, content_type, "no-store");
    return true;
}

fn contentTypeForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    return "application/octet-stream";
}

fn respondBody(req: *http.Server.Request, status: http.Status, body: []const u8, content_type: []const u8, cache_control: []const u8) !void {
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = cache_control },
    };
    try req.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &headers,
    });
}

fn respondJson(req: *http.Server.Request, status: http.Status, body: []const u8) !void {
    try respondBody(req, status, body, "application/json; charset=utf-8", "no-store");
}

fn respondHtml(req: *http.Server.Request, body: []const u8) !void {
    try respondBody(req, .ok, body, "text/html; charset=utf-8", "no-store");
}

fn streamEvents(req: *http.Server.Request, ctx: *ServerContext, after_start: usize) !void {
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "text/event-stream" },
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "connection", .value = "close" },
    };

    var buf: [2048]u8 = undefined;
    var body = try req.respondStreaming(&buf, .{
        .respond_options = .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &headers,
        },
    });

    var after = after_start;
    var ticks: usize = 0;
    while (ticks < 30) : (ticks += 1) {
        const payload = replay.readEventsAfter(ctx.allocator, ctx.target_dir, ctx.log_dir, after) catch "{\"events\":[],\"last_event_id\":0}";
        defer if (payload.ptr != "{\"events\":[],\"last_event_id\":0}".ptr) ctx.allocator.free(payload);

        const last_id = parseLastEventId(payload, after);
        if (last_id > after) {
            try body.writer.print("id: {d}\n", .{last_id});
            try body.writer.writeAll("event: events\n");
            try body.writer.print("data: {s}\n\n", .{payload});
            try body.writer.flush();
            try body.flush();
            after = last_id;
        } else {
            try body.writer.writeAll(": keepalive\n\n");
            try body.writer.flush();
            try body.flush();
        }

        std.Thread.sleep(1 * std.time.ns_per_s);
    }

    try body.end();
}

fn authorized(req: *const http.Server.Request, expected_token: []const u8, expires_at: i64) bool {
    if (std.time.timestamp() > expires_at) return false;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "authorization")) continue;
        if (h.value.len < 8) continue;
        if (!std.ascii.startsWithIgnoreCase(h.value, "Bearer ")) continue;
        const got = std.mem.trim(u8, h.value[7..], " \t\r\n");
        return std.mem.eql(u8, got, expected_token);
    }
    return false;
}

fn allowControlRequest(ctx: *ServerContext) bool {
    const now_ms: i64 = std.time.milliTimestamp();
    if (ctx.last_control_ms != 0 and (now_ms - ctx.last_control_ms) < CONTROL_MIN_INTERVAL_MS) return false;
    ctx.last_control_ms = now_ms;
    return true;
}

fn requestIdFromHeader(allocator: Allocator, req: *const http.Server.Request) ?[]u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "x-request-id")) continue;
        const v = std.mem.trim(u8, h.value, " \t\r\n");
        if (v.len == 0) return null;
        return allocator.dupe(u8, v) catch null;
    }
    return null;
}

fn isDuplicateRequestId(ctx: *ServerContext, request_id: []const u8) bool {
    const now = std.time.timestamp();

    var stale_keys: std.ArrayList([]const u8) = .empty;
    defer stale_keys.deinit(ctx.allocator);
    var it = ctx.request_ids.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* + REQUEST_ID_TTL_SECONDS < now) {
            stale_keys.append(ctx.allocator, entry.key_ptr.*) catch {};
        }
    }
    for (stale_keys.items) |k| {
        _ = ctx.request_ids.remove(k);
        ctx.allocator.free(k);
    }

    if (ctx.request_ids.contains(request_id)) return true;
    const key = ctx.allocator.dupe(u8, request_id) catch return false;
    ctx.request_ids.put(key, now) catch {
        ctx.allocator.free(key);
    };
    return false;
}

fn readTasks(allocator: Allocator, target_dir: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, ".techlead/tasks.json" });
    defer allocator.free(path);
    const raw = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "{\"tasks\":[]}"),
        else => return err,
    };
    defer allocator.free(raw);
    return allocator.dupe(u8, raw);
}

fn parseAfterQuery(target: []const u8) usize {
    const after_raw = queryValue(target, "after") orelse return 0;
    return std.fmt.parseInt(usize, after_raw, 10) catch 0;
}

fn parseAfterFromRequest(req: *const http.Server.Request) usize {
    const query_after = parseAfterQuery(req.head.target);
    if (query_after > 0) return query_after;

    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "last-event-id")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, h.value, " \t\r\n"), 10) catch 0;
    }
    return 0;
}

fn validateRequestedRunId(allocator: Allocator, target_dir: []const u8, target: []const u8) !bool {
    const requested = requestedRunId(target) orelse return true;
    if (std.mem.eql(u8, requested, "current")) return true;

    const state = readRunState(allocator, target_dir) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer {
        allocator.free(state.run_id);
        allocator.free(state.mode);
        allocator.free(state.status);
    }
    return std.mem.eql(u8, requested, state.run_id);
}

fn requestedRunId(target: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, target, "/runs/")) return null;
    const rest = target["/runs/".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return rest[0..slash];
}

fn readRunState(allocator: Allocator, target_dir: []const u8) !RunState {
    const path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, ".techlead/run_state.json" });
    defer allocator.free(path);

    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(raw);
    const parsed = try std.json.parseFromSlice(RunState, allocator, raw, .{});
    defer parsed.deinit();
    return .{
        .run_id = try allocator.dupe(u8, parsed.value.run_id),
        .mode = try allocator.dupe(u8, parsed.value.mode),
        .status = try allocator.dupe(u8, parsed.value.status),
        .updated_at = parsed.value.updated_at,
    };
}

fn parseLastEventId(payload: []const u8, fallback: usize) usize {
    const key = "\"last_event_id\":";
    const pos = std.mem.indexOf(u8, payload, key) orelse return fallback;
    const rest = payload[pos + key.len ..];
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {}
    var j = i;
    while (j < rest.len and rest[j] >= '0' and rest[j] <= '9') : (j += 1) {}
    if (j == i) return fallback;
    return std.fmt.parseInt(usize, rest[i..j], 10) catch fallback;
}

fn parseControlBody(req: *http.Server.Request, allocator: Allocator) !?ControlBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [1024]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(ControlBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();

    return .{
        .action = if (parsed.value.action) |a| try allocator.dupe(u8, a) else null,
        .prompt = if (parsed.value.prompt) |p| try allocator.dupe(u8, p) else null,
        .request_id = if (parsed.value.request_id) |rid| try allocator.dupe(u8, rid) else null,
    };
}

fn parseStartRunBody(req: *http.Server.Request, allocator: Allocator) !?StartRunBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [1024]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(StartRunBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();
    return .{
        .mode = if (parsed.value.mode) |m| try allocator.dupe(u8, m) else null,
        .request_id = if (parsed.value.request_id) |rid| try allocator.dupe(u8, rid) else null,
    };
}

fn parseStartSessionBody(req: *http.Server.Request, allocator: Allocator) !?StartSessionBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [1024]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(StartSessionBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();
    return .{
        .provider = if (parsed.value.provider) |p| try allocator.dupe(u8, p) else null,
        .model = if (parsed.value.model) |m| try allocator.dupe(u8, m) else null,
        .request_id = if (parsed.value.request_id) |rid| try allocator.dupe(u8, rid) else null,
    };
}

fn parseSessionMessageBody(req: *http.Server.Request, allocator: Allocator) !?SessionMessageBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [1024]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(SessionMessageBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();
    return .{
        .message = if (parsed.value.message) |m| try allocator.dupe(u8, m) else null,
        .request_id = if (parsed.value.request_id) |rid| try allocator.dupe(u8, rid) else null,
    };
}

fn startRunDetached(allocator: Allocator, target_dir: []const u8, mode: []const u8) !i32 {
    const exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe);

    var child = std.process.Child.init(
        &[_][]const u8{
            exe,
            "run",
            "--dir",
            target_dir,
            "--mode",
            mode,
        },
        allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    return child.id;
}

fn ensureTokens(allocator: Allocator, target_dir: []const u8) !TokenFile {
    return ensureTokensInternal(allocator, target_dir, false);
}

fn ensureTokensInternal(allocator: Allocator, target_dir: []const u8, force_rotate: bool) !TokenFile {
    const techlead_dir = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, ".techlead" });
    defer allocator.free(techlead_dir);
    try std.fs.cwd().makePath(techlead_dir);

    const token_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, ".techlead/observe_tokens.json" });
    defer allocator.free(token_path);

    const existing = std.fs.cwd().readFileAlloc(allocator, token_path, 4096) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (existing) |raw| {
        defer allocator.free(raw);
        if (!force_rotate) {
            const parsed = std.json.parseFromSlice(TokenFile, allocator, raw, .{}) catch null;
            if (parsed) |p| {
                defer p.deinit();
                if (p.value.observe_expires_at > std.time.timestamp() and p.value.control_expires_at > std.time.timestamp()) {
                    return .{
                        .observe_token = try allocator.dupe(u8, p.value.observe_token),
                        .control_token = try allocator.dupe(u8, p.value.control_token),
                        .observe_expires_at = p.value.observe_expires_at,
                        .control_expires_at = p.value.control_expires_at,
                    };
                }
            } else {
                const LegacyTokenFile = struct {
                    observe_token: []const u8,
                    control_token: []const u8,
                };
                const legacy = std.json.parseFromSlice(LegacyTokenFile, allocator, raw, .{}) catch null;
                if (legacy) |p| {
                    defer p.deinit();
                    const now = std.time.timestamp();
                    return .{
                        .observe_token = try allocator.dupe(u8, p.value.observe_token),
                        .control_token = try allocator.dupe(u8, p.value.control_token),
                        .observe_expires_at = now + TOKEN_TTL_SECONDS,
                        .control_expires_at = now + TOKEN_TTL_SECONDS,
                    };
                }
            }
        }
    }

    const observe = try generateToken(allocator);
    defer allocator.free(observe);
    const control = try generateToken(allocator);
    defer allocator.free(control);

    const now = std.time.timestamp();
    const observe_expires_at = now + TOKEN_TTL_SECONDS;
    const control_expires_at = now + TOKEN_TTL_SECONDS;

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"observe_token\":{f},\"control_token\":{f},\"observe_expires_at\":{d},\"control_expires_at\":{d}}}\n",
        .{ std.json.fmt(observe, .{}), std.json.fmt(control, .{}), observe_expires_at, control_expires_at },
    );
    defer allocator.free(body);
    try std.fs.cwd().writeFile(.{ .sub_path = token_path, .data = body });

    return .{
        .observe_token = try allocator.dupe(u8, observe),
        .control_token = try allocator.dupe(u8, control),
        .observe_expires_at = observe_expires_at,
        .control_expires_at = control_expires_at,
    };
}

fn generateToken(allocator: Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}

fn queryValue(target: []const u8, key: []const u8) ?[]const u8 {
    const qpos = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[qpos + 1 ..];
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        const v = pair[eq + 1 ..];
        if (std.mem.eql(u8, k, key)) return v;
    }
    return null;
}

fn decodeUrlComponent(allocator: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '+') {
            try out.append(allocator, ' ');
            continue;
        }
        if (c == '%' and i + 2 < raw.len) {
            const hi = std.fmt.charToDigit(raw[i + 1], 16) catch {
                try out.append(allocator, c);
                continue;
            };
            const lo = std.fmt.charToDigit(raw[i + 2], 16) catch {
                try out.append(allocator, c);
                continue;
            };
            try out.append(allocator, @as(u8, @intCast(hi * 16 + lo)));
            i += 2;
            continue;
        }
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

fn dashboardHtml() []const u8 {
    return
        \\<!doctype html>
        \\<html>
        \\<head>
        \\  <meta charset="utf-8" />
        \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
        \\  <title>Techlead Observe</title>
        \\  <style>
        \\    :root { --bg:#0f172a; --card:#111827; --fg:#e5e7eb; --muted:#94a3b8; --ok:#22c55e; --warn:#f59e0b; --bad:#ef4444; }
        \\    body { margin:0; font-family: ui-monospace, Menlo, Consolas, monospace; background:linear-gradient(135deg,#0b1220,#111827); color:var(--fg); }
        \\    .wrap { max-width:1000px; margin:24px auto; padding:0 16px; }
        \\    .grid { display:grid; grid-template-columns:1fr; gap:12px; }
        \\    .card { background:rgba(17,24,39,0.92); border:1px solid #334155; border-radius:10px; padding:12px; }
        \\    h2 { margin:0 0 10px 0; font-size:14px; color:#cbd5e1; letter-spacing:.5px; }
        \\    button { background:#1f2937; color:var(--fg); border:1px solid #334155; border-radius:8px; padding:8px 10px; cursor:pointer; margin-right:8px; margin-bottom:8px; }
        \\    button:hover { border-color:#64748b; }
        \\    input { width:100%; box-sizing:border-box; background:#0b1220; color:var(--fg); border:1px solid #334155; border-radius:8px; padding:8px; margin:8px 0; }
        \\    pre { margin:0; white-space:pre-wrap; word-break:break-word; color:#cbd5e1; max-height:320px; overflow:auto; }
        \\    .events { max-height:380px; overflow:auto; display:flex; flex-direction:column; gap:6px; }
        \\    .evt { border:1px solid #334155; border-left:4px solid #475569; border-radius:8px; padding:8px; background:#0b1220; }
        \\    .evt-head { display:flex; gap:8px; align-items:center; font-size:12px; color:#cbd5e1; margin-bottom:4px; }
        \\    .evt-id { color:#94a3b8; }
        \\    .evt-src { color:#60a5fa; }
        \\    .evt-type { color:#f8fafc; font-weight:600; }
        \\    .evt-time { color:#94a3b8; margin-left:auto; }
        \\    .evt-body { font-size:12px; color:#cbd5e1; white-space:pre-wrap; word-break:break-word; }
        \\    .evt.ok { border-left-color:#22c55e; }
        \\    .evt.warn { border-left-color:#f59e0b; }
        \\    .evt.bad { border-left-color:#ef4444; }
        \\    .muted { color:var(--muted); font-size:12px; }
        \\    .ok { color:var(--ok); } .warn { color:var(--warn); } .bad { color:var(--bad); }
        \\  </style>
        \\</head>
        \\<body>
        \\  <div class="wrap">
        \\    <div class="grid">
        \\      <div class="card">
        \\        <h2>CONTROL</h2>
        \\        <div>
        \\          <button onclick="startRun('optimize')">start optimize</button>
        \\          <button onclick="startRun('pool')">start pool</button>
        \\        </div>
        \\        <div>
        \\          <button onclick="sendControl('pause')">pause</button>
        \\          <button onclick="sendControl('resume')">resume</button>
        \\          <button onclick="sendControl('abort')">abort</button>
        \\        </div>
        \\        <input id="prompt" placeholder="inject prompt..." />
        \\        <button onclick="injectPrompt()">inject_prompt</button>
        \\        <div id="status" class="muted">ready</div>
        \\      </div>
        \\      <div class="card">
        \\        <h2>TASKS</h2>
        \\        <pre id="tasks">loading...</pre>
        \\      </div>
        \\      <div class="card">
        \\        <h2>SESSION CHAT</h2>
        \\        <div>
        \\          <button onclick="startSession()">start session</button>
        \\        </div>
        \\        <div id="session-meta" class="muted">session: (none)</div>
        \\        <pre id="session-chat">(no session)</pre>
        \\        <input id="session-input" placeholder="say something to agent..." />
        \\        <button onclick="sendSessionMessage()">send message</button>
        \\      </div>
        \\      <div class="card">
        \\        <h2>EVENTS (incremental)</h2>
        \\        <div id="events" class="events"><div class="muted">(loading...)</div></div>
        \\      </div>
        \\    </div>
        \\  </div>
        \\<script>
        \\const token = new URLSearchParams(location.search).get('token') || '';
        \\if (token) { history.replaceState({}, '', location.pathname); }
        \\let after = 0;
        \\let sse = null;
        \\let eventRows = [];
        \\const H = token ? { 'Authorization': 'Bearer ' + token } : {};
        \\function newReqId(){ return Date.now().toString(36) + '-' + Math.random().toString(36).slice(2,8); }
        \\function setStatus(s, cls='muted'){ const el=document.getElementById('status'); el.className=cls; el.textContent=s; }
        \\function pretty(v){
        \\  if (v == null) return '';
        \\  if (typeof v === 'string') {
        \\    try { return JSON.stringify(JSON.parse(v)); } catch { return v; }
        \\  }
        \\  try { return JSON.stringify(v); } catch { return String(v); }
        \\}
        \\function classify(type){
        \\  const t = String(type || '');
        \\  if (t.includes('failed') || t.includes('abort') || t.includes('error')) return 'bad';
        \\  if (t.includes('pause') || t.includes('warn') || t.includes('requeued')) return 'warn';
        \\  if (t.includes('succeeded') || t.includes('completed') || t.includes('done')) return 'ok';
        \\  return '';
        \\}
        \\function fmtTs(ts){
        \\  if (!ts) return '-';
        \\  const n = Number(ts) * 1000;
        \\  if (!Number.isFinite(n)) return '-';
        \\  return new Date(n).toLocaleTimeString();
        \\}
        \\function toViewRow(e){
        \\  let inner = {};
        \\  try { inner = JSON.parse(e.event_jsonl || '{}'); } catch { inner = { raw: e.event_jsonl || '' }; }
        \\  const body = pretty(inner.payload || inner.raw || '');
        \\  return {
        \\    id: e.event_id,
        \\    cls: classify(inner.event_type),
        \\    source: inner.source || '-',
        \\    type: inner.event_type || '-',
        \\    time: fmtTs(inner.ts),
        \\    body,
        \\  };
        \\}
        \\function renderEvents(){
        \\  const el = document.getElementById('events');
        \\  if (!eventRows.length) {
        \\    el.innerHTML = '<div class=\"muted\">(no events)</div>';
        \\    return;
        \\  }
        \\  el.innerHTML = eventRows.map(r => `
        \\    <div class=\"evt ${r.cls}\">
        \\      <div class=\"evt-head\">
        \\        <span class=\"evt-id\">#${r.id}</span>
        \\        <span class=\"evt-src\">${r.source}</span>
        \\        <span class=\"evt-type\">${r.type}</span>
        \\        <span class=\"evt-time\">${r.time}</span>
        \\      </div>
        \\      <div class=\"evt-body\">${(r.body || '').replaceAll('<','&lt;').replaceAll('>','&gt;')}</div>
        \\    </div>
        \\  `).join('');
        \\  el.scrollTop = el.scrollHeight;
        \\}
        \\function ingestEvents(obj){
        \\  if (obj.last_event_id) after = obj.last_event_id;
        \\  const rows = (obj.events || []).map(toViewRow);
        \\  if (!rows.length) return;
        \\  eventRows = eventRows.concat(rows).slice(-300);
        \\  renderEvents();
        \\}
        \\async function refreshTasks(){
        \\  const r = await fetch('/tasks', { headers: H });
        \\  const txt = await r.text();
        \\  try { document.getElementById('tasks').textContent = JSON.stringify(JSON.parse(txt), null, 2); }
        \\  catch { document.getElementById('tasks').textContent = txt; }
        \\}
        \\async function refreshSession(){
        \\  if(!token){ return; }
        \\  const r = await fetch('/sessions/current', { headers: H });
        \\  const txt = await r.text();
        \\  try{
        \\    const s = JSON.parse(txt);
        \\    if(!s.session_id){ document.getElementById('session-meta').textContent = 'session: (none)'; document.getElementById('session-chat').textContent='(no session)'; return; }
        \\    document.getElementById('session-meta').textContent = `session: ${s.session_id} | ${s.status} | ${s.provider}`;
        \\    const lines = (s.messages||[]).slice(-80).map(m => `[${m.role}] ${m.content}`);
        \\    document.getElementById('session-chat').textContent = lines.join('\\n\\n') || '(empty)';
        \\  } catch {}
        \\}
        \\async function startSession(){
        \\  if(!token){ setStatus('missing token','bad'); return; }
        \\  const request_id = newReqId();
        \\  setStatus('starting session ...');
        \\  const r = await fetch('/sessions/start', {
        \\    method:'POST',
        \\    headers: { ...H, 'Content-Type':'application/json', 'X-Request-Id': request_id },
        \\    body: JSON.stringify({ provider:'codex', request_id })
        \\  });
        \\  const t = await r.text();
        \\  setStatus(t, r.ok ? 'ok' : 'bad');
        \\  await refreshSession();
        \\}
        \\async function sendSessionMessage(){
        \\  if(!token){ setStatus('missing token','bad'); return; }
        \\  const message = document.getElementById('session-input').value || '';
        \\  if(!message.trim()){ setStatus('message empty','warn'); return; }
        \\  const request_id = newReqId();
        \\  setStatus('sending message ...');
        \\  const r = await fetch('/sessions/current/message', {
        \\    method:'POST',
        \\    headers: { ...H, 'Content-Type':'application/json', 'X-Request-Id': request_id },
        \\    body: JSON.stringify({ message, request_id })
        \\  });
        \\  const t = await r.text();
        \\  setStatus(t, r.ok ? 'ok' : 'bad');
        \\  if(r.ok){ document.getElementById('session-input').value = ''; await refreshSession(); }
        \\}
        \\async function refreshEvents(){
        \\  const r = await fetch('/runs/current/events?after='+after, { headers: H });
        \\  const txt = await r.text();
        \\  try {
        \\    ingestEvents(JSON.parse(txt));
        \\  } catch {
        \\    document.getElementById('events').innerHTML = '<div class=\"bad\">failed to parse events</div>';
        \\  }
        \\}
        \\function startSSE(){
        \\  // EventSource cannot carry Authorization headers reliably; keep polling mode only.
        \\  return;
        \\}
        \\async function sendControl(action){
        \\  if(!token){ setStatus('missing token','bad'); return; }
        \\  const request_id = newReqId();
        \\  setStatus('sending '+action+' ...');
        \\  const r = await fetch('/runs/current/control', {
        \\    method: 'POST',
        \\    headers: { ...H, 'Content-Type': 'application/json', 'X-Request-Id': request_id },
        \\    body: JSON.stringify({ action, request_id })
        \\  });
        \\  setStatus(await r.text(), r.ok ? 'ok' : 'bad');
        \\}
        \\async function startRun(mode){
        \\  if(!token){ setStatus('missing token','bad'); return; }
        \\  const request_id = newReqId();
        \\  setStatus('starting '+mode+' ...');
        \\  const r = await fetch('/runs/start', {
        \\    method: 'POST',
        \\    headers: { ...H, 'Content-Type': 'application/json', 'X-Request-Id': request_id },
        \\    body: JSON.stringify({ mode, request_id })
        \\  });
        \\  const t = await r.text();
        \\  setStatus(t, r.ok ? 'ok' : 'bad');
        \\}
        \\async function injectPrompt(){
        \\  if(!token){ setStatus('missing token','bad'); return; }
        \\  const p = document.getElementById('prompt').value || '';
        \\  if(!p){ setStatus('prompt empty','warn'); return; }
        \\  const request_id = newReqId();
        \\  setStatus('injecting ...');
        \\  const r = await fetch('/runs/current/control', {
        \\    method: 'POST',
        \\    headers: { ...H, 'Content-Type': 'application/json', 'X-Request-Id': request_id },
        \\    body: JSON.stringify({ action: 'inject_prompt', prompt: p, request_id })
        \\  });
        \\  setStatus(await r.text(), r.ok ? 'ok' : 'bad');
        \\}
        \\refreshTasks(); refreshEvents(); refreshSession(); startSSE();
        \\setInterval(refreshTasks, 3000);
        \\setInterval(refreshSession, 2500);
        \\setInterval(() => { if(!sse) refreshEvents(); }, 1500);
        \\</script>
        \\</body>
        \\</html>
    ;
}

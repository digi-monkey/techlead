const std = @import("std");
const http = std.http;

const config = @import("config.zig");
const ui = @import("ui.zig");
const utils = @import("utils.zig");
const runner = @import("runner.zig");
const replay = @import("storage/replay.zig");
const task_store = @import("storage/task_store.zig");
const sqlite_task_store = @import("storage/sqlite_task_store.zig");
const sqlite_runtime_store = @import("storage/sqlite_runtime_store.zig");
const session_service = @import("app/session_service.zig");
const controlplane_store = @import("storage/controlplane_store.zig");
const sqlite_controlplane_store = @import("storage/sqlite_controlplane_store.zig");

const Allocator = std.mem.Allocator;
const TOKEN_TTL_SECONDS: i64 = 7 * 24 * 60 * 60;
const CONTROL_MIN_INTERVAL_MS: i64 = 300;
const REQUEST_ID_TTL_SECONDS: i64 = 5 * 60;
const BOOTSTRAP_TTL_SECONDS: i64 = 60;
const SHARE_BOOTSTRAP_TTL_SECONDS: i64 = 10 * 60;
const AUTH_COOKIE_OBSERVE = "tl_observe";
const AUTH_COOKIE_CONTROL = "tl_control";
const OBSERVE_UI_DIST_DIR = "web/observe-ui/dist";
var g_session_worker_requests: std.StringHashMapUnmanaged(void) = .empty;
var g_session_worker_mutex: std.Thread.Mutex = .{};
const SESSION_WORKER_EXIT_REASON = "SessionWorkerExitedNonZero";

const TokenFile = struct {
    observe_token: []const u8,
    control_token: []const u8,
    observe_expires_at: i64,
    control_expires_at: i64,
};

const BootstrapTicket = struct {
    code: []const u8,
    expires_at: i64,
};

const BootstrapIssue = struct {
    bootstrap_id: []u8,
    code: []u8,
    expires_at: i64,
    url: []u8,
};

// ServerContext for multi-project API
const ServerContext = struct {
    allocator: Allocator,
    store: controlplane_store.ControlPlaneStore,
    log_dir: []const u8,
    host: []const u8,
    port: u16,
    observe_token: []const u8,
    control_token: []const u8,
    observe_expires_at: i64,
    control_expires_at: i64,
    last_control_ms: i64 = 0,
    request_ids: std.StringHashMap(i64),
    bootstrap_tickets: std.StringHashMap(BootstrapTicket),
    external_url: ?[]const u8,
    // Backward compatibility: optional default project_id for legacy endpoints
    default_project_id: ?[]const u8,
};

const ControlBody = struct {
    action: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
};

const BootstrapBody = struct {
    ttl_seconds: ?i64 = null,
};

const TokenExchangeBody = struct {
    bootstrap_id: ?[]const u8 = null,
    code: ?[]const u8 = null,
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

const EndSessionBody = struct {
    request_id: ?[]const u8 = null,
};

const CreateTaskBody = struct {
    title: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    priority: ?i32 = null,
    max_retries: ?u32 = null,
    request_id: ?[]const u8 = null,
};

const PatchTaskBody = struct {
    title: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    priority: ?i32 = null,
    max_retries: ?u32 = null,
    version: ?i64 = null,
    request_id: ?[]const u8 = null,
};

const TaskActionBody = struct {
    action: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
};

// Project API request bodies
const CreateProjectBody = struct {
    project_id: []const u8,
    work_dir: []const u8,
    enabled: ?bool = null,
    test_cmd: ?[]const u8 = null,
    lint_cmd: ?[]const u8 = null,
    max_workers: ?u32 = null,
};

const UpdateProjectBody = struct {
    enabled: ?bool = null,
    test_cmd: ?[]const u8 = null,
    lint_cmd: ?[]const u8 = null,
    max_workers: ?u32 = null,
};

const ProjectAndTaskIds = struct {
    project_id: []const u8,
    task_id: []const u8,
};

// Extract project_id from /projects/:id or /projects/:id/...
fn extractProjectId(target: []const u8) ?[]const u8 {
    const prefix = "/projects/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;

    const rest = target[prefix.len..];
    if (rest.len == 0) return null;

    const slash_idx = std.mem.indexOfScalar(u8, rest, '/');
    if (slash_idx) |idx| {
        if (idx == 0) return null;
        return rest[0..idx];
    }
    // /projects/:id (no trailing slash)
    return rest;
}

// Extract project_id and task_id from /projects/:pid/tasks/:tid/...
fn extractProjectAndTaskIds(target: []const u8) ?ProjectAndTaskIds {
    const prefix = "/projects/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;

    const after_project = target[prefix.len..];
    const slash_idx = std.mem.indexOfScalar(u8, after_project, '/');
    if (slash_idx == null) return null;

    const project_id = after_project[0..slash_idx.?];
    if (project_id.len == 0) return null;

    const after_project_id = after_project[slash_idx.?..];
    const task_prefix = "/tasks/";
    if (!std.mem.startsWith(u8, after_project_id, task_prefix)) return null;

    const task_id = after_project_id[task_prefix.len..];
    const next_slash = std.mem.indexOfScalar(u8, task_id, '/');
    const clean_task_id = if (next_slash) |idx| task_id[0..idx] else task_id;

    if (clean_task_id.len == 0) return null;

    return .{
        .project_id = project_id,
        .task_id = clean_task_id,
    };
}

// Validate project exists and is enabled
fn validateProject(ctx: *ServerContext, project_id: []const u8) !?controlplane_store.Project {
    const project = try ctx.store.getProject(project_id, ctx.allocator);
    if (project) |p| {
        if (!p.enabled) {
            p.deinit(ctx.allocator);
            return error.ProjectDisabled;
        }
    }
    return project;
}

pub fn runObserveStartCommand(allocator: Allocator, target_dir: ?[]const u8, host: []const u8, port: u16) !void {
    // Initialize control plane store
    var sqlite_store = try sqlite_controlplane_store.SqliteControlPlaneStore.init(allocator);
    errdefer sqlite_store.deinit();

    var store = sqlite_store.asControlPlaneStore();

    // If target_dir provided, register as default project
    var default_project_id: ?[]u8 = null;
    if (target_dir) |dir| {
        // Verify directory exists
        std.fs.cwd().access(dir, .{}) catch |err| {
            ui.logError("target_dir does not exist: {s}", .{dir});
            return err;
        };

        // Generate project_id from directory name
        const project_id = std.fs.path.basename(dir);

        // Register project
        store.registerProject(.{
            .project_id = project_id,
            .work_dir = dir,
            .enabled = true,
            .max_workers = 1,
        }) catch |err| {
            // Project may already exist, that's ok
            if (err != error.ProjectIdExists) {
                ui.logWarn("Failed to register default project: {any}", .{err});
            }
        };

        default_project_id = try allocator.dupe(u8, project_id);
    }
    errdefer if (default_project_id) |pid| allocator.free(pid);

    const tokens = try ensureTokens(allocator, &store);
    defer allocator.free(tokens.observe_token);
    defer allocator.free(tokens.control_token);

    const external_url = std.process.getEnvVarOwned(allocator, "TECHLEAD_EXTERNAL_URL") catch null;

    var ctx = ServerContext{
        .allocator = allocator,
        .store = store,
        .log_dir = try getDefaultLogDir(allocator),
        .host = try allocator.dupe(u8, host),
        .port = port,
        .observe_token = try allocator.dupe(u8, tokens.observe_token),
        .control_token = try allocator.dupe(u8, tokens.control_token),
        .observe_expires_at = tokens.observe_expires_at,
        .control_expires_at = tokens.control_expires_at,
        .request_ids = std.StringHashMap(i64).init(allocator),
        .bootstrap_tickets = std.StringHashMap(BootstrapTicket).init(allocator),
        .external_url = external_url,
        .default_project_id = default_project_id,
    };
    defer allocator.free(ctx.log_dir);
    defer allocator.free(ctx.host);
    defer allocator.free(ctx.observe_token);
    defer allocator.free(ctx.control_token);
    defer if (ctx.external_url) |url| allocator.free(url);
    defer if (ctx.default_project_id) |pid| allocator.free(pid);
    defer {
        var it = ctx.request_ids.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        ctx.request_ids.deinit();
    }
    defer {
        var it = ctx.bootstrap_tickets.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.code);
        }
        ctx.bootstrap_tickets.deinit();
    }
    defer ctx.store.close();

    const address = try std.net.Address.parseIp(host, port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    if (ctx.external_url) |ext_url| {
        ui.logSuccess("observe 服务已启动: http://{s}:{d} (外部地址: {s})", .{ host, server.listen_address.getPort(), ext_url });
    } else {
        ui.logSuccess("observe 服务已启动: http://{s}:{d}", .{ host, server.listen_address.getPort() });
    }
    ui.logInfo("observe token: {s}", .{ctx.observe_token});
    ui.logInfo("control token: {s}", .{ctx.control_token});
    if (default_project_id) |pid| {
        ui.logInfo("默认项目: {s}", .{pid});
    }
    const share_issue = try issueBootstrapTicket(&ctx, SHARE_BOOTSTRAP_TTL_SECONDS);
    defer allocator.free(share_issue.bootstrap_id);
    defer allocator.free(share_issue.code);
    defer allocator.free(share_issue.url);
    ui.logInfo("扫码/分享入口: {s}", .{share_issue.url});
    printStartupQr(allocator, share_issue.url);
    if (std.mem.eql(u8, host, "0.0.0.0") and ctx.external_url == null) {
        ui.logWarn("当前 host=0.0.0.0；扫码前请将链接中的主机替换为本机局域网 IP", .{});
    }
    if (ctx.external_url) |ext_url| {
        ui.logInfo("兼容入口: {s}/?token={s}", .{ ext_url, ctx.observe_token });
    } else {
        ui.logInfo("兼容入口: http://{s}:{d}/?token={s}", .{ host, server.listen_address.getPort(), ctx.observe_token });
    }

    while (true) {
        const conn = server.accept() catch |err| {
            ui.logWarn("accept 失败: {s}", .{@errorName(err)});
            continue;
        };
        defer conn.stream.close();
        try handleConnection(&ctx, conn);
    }
}

fn getDefaultLogDir(allocator: Allocator) ![]u8 {
    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch "/tmp";
    defer if (home_dir.ptr != "/tmp".ptr) allocator.free(home_dir);

    return try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".config", "techlead", "logs" });
}

pub fn runObserveRotateTokensCommand(allocator: Allocator) !void {
    var sqlite_store = try sqlite_controlplane_store.SqliteControlPlaneStore.init(allocator);
    defer sqlite_store.deinit();
    var store = sqlite_store.asControlPlaneStore();

    const tokens = try ensureTokensInternal(allocator, &store, true);
    defer allocator.free(tokens.observe_token);
    defer allocator.free(tokens.control_token);
    ui.logSuccess("tokens 已轮换", .{});
    ui.logInfo("observe token: {s}", .{tokens.observe_token});
    ui.logInfo("control token: {s}", .{tokens.control_token});
}

fn printStartupQr(allocator: Allocator, url: []const u8) void {
    ui.logInfo("二维码（终端扫码）:", .{});

    if (!utils.commandExists(allocator, "qrencode")) {
        ui.logWarn("未检测到 qrencode，无法直接输出终端二维码", .{});
        ui.logInfo("安装示例: sudo apt-get install -y qrencode", .{});
        return;
    }

    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "qrencode", "-t", "ANSIUTF8", "-m", "1", url },
        .max_output_bytes = 1024 * 1024,
    }) catch |err| {
        ui.logWarn("二维码渲染失败: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    if (!utils.isExitedZero(run_result.term)) {
        const err_trimmed = std.mem.trim(u8, run_result.stderr, " \r\n\t");
        if (err_trimmed.len > 0) {
            ui.logWarn("二维码渲染失败: {s}", .{err_trimmed});
        } else {
            ui.logWarn("二维码渲染失败: qrencode exited non-zero", .{});
        }
        return;
    }

    if (run_result.stdout.len == 0) {
        ui.logWarn("二维码渲染失败: empty output", .{});
        return;
    }

    std.debug.print("{s}\n", .{run_result.stdout});
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
    const target_path = pathNoQuery(target);

    if (try serveObserveUiAsset(ctx, req, target)) return;
    if (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?") or std.mem.eql(u8, target_path, "/connect")) {
        return respondHtml(req, dashboardHtml());
    }

    if (std.mem.eql(u8, target, "/health")) {
        return respondJson(req, .ok, "{\"ok\":true}");
    }

    if (std.mem.startsWith(u8, target, "/auth/qr/bootstrap")) {
        return handleAuthQrBootstrap(ctx, req);
    }

    if (std.mem.startsWith(u8, target, "/auth/token/exchange")) {
        return handleAuthTokenExchange(ctx, req);
    }

    // === Projects API (Multi-project) ===

    // POST /projects - Register new project
    if (std.mem.eql(u8, target_path, "/projects") and req.head.method == .POST) {
        return handleCreateProject(ctx, req);
    }

    // GET /projects - List projects
    if (std.mem.eql(u8, target_path, "/projects") and req.head.method == .GET) {
        return handleListProjects(ctx, req, target);
    }

    // Project-specific endpoints: /projects/:id, /projects/:id/...
    if (std.mem.startsWith(u8, target_path, "/projects/")) {
        const project_id = extractProjectId(target) orelse {
            return respondJson(req, .bad_request, "{\"error\":\"invalid_project_id\"}");
        };

        // Check path after project_id
        const after_project = target_path["/projects/".len + project_id.len ..];

        // /projects/:id (project-level operations)
        if (after_project.len == 0) {
            switch (req.head.method) {
                .GET => return handleGetProject(ctx, req, project_id),
                .PATCH => return handleUpdateProject(ctx, req, project_id),
                .DELETE => return handleDeleteProject(ctx, req, project_id),
                else => return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}"),
            }
        }

        // /projects/:id/runs/*
        if (std.mem.startsWith(u8, after_project, "/runs")) {
            return handleRunsApi(ctx, req, target, project_id);
        }

        // /projects/:id/tasks/*
        if (std.mem.startsWith(u8, after_project, "/tasks")) {
            return handleTasksApi(ctx, req, target, project_id);
        }

        // /projects/:id/sessions/*
        if (std.mem.startsWith(u8, after_project, "/sessions")) {
            return handleSessionsApi(ctx, req, target, project_id);
        }

        // /projects/:id/events
        if (std.mem.eql(u8, after_project, "/events")) {
            return handleProjectEvents(ctx, req, target, project_id);
        }
    }

    // === Legacy API (Backward Compatibility) ===
    // These endpoints use the default_project_id if available

    if (std.mem.eql(u8, target_path, "/events")) {
        // Support ?project_id=xxx query parameter
        if (queryValue(target, "project_id")) |pid| {
            return handleProjectEvents(ctx, req, target, pid);
        }
        // Fall back to default_project_id for backward compatibility
        if (ctx.default_project_id) |pid| {
            return handleProjectEvents(ctx, req, target, pid);
        }
        return respondJson(req, .not_found, "{\"error\":\"project_id_required\"}");
    }

    if (std.mem.startsWith(u8, target, "/runs/") and std.mem.endsWith(u8, target, "/events/stream")) {
        if (ctx.default_project_id) |pid| {
            return handleRunsEventsStream(ctx, req, target, pid);
        }
        return respondJson(req, .not_found, "{\"error\":\"no_default_project\"}");
    }

    if (std.mem.startsWith(u8, target, "/runs/current/events/stream")) {
        if (ctx.default_project_id) |pid| {
            return streamProjectEvents(req, ctx, pid, parseAfterFromRequest(req));
        }
        return respondJson(req, .not_found, "{\"error\":\"no_default_project\"}");
    }

    if (std.mem.startsWith(u8, target, "/runs/") and std.mem.endsWith(u8, target, "/events")) {
        if (ctx.default_project_id) |pid| {
            return handleProjectEvents(ctx, req, target, pid);
        }
        return respondJson(req, .not_found, "{\"error\":\"no_default_project\"}");
    }

    if (std.mem.startsWith(u8, target, "/runs/current/events")) {
        if (ctx.default_project_id) |pid| {
            return handleProjectEvents(ctx, req, target, pid);
        }
        return respondJson(req, .not_found, "{\"error\":\"no_default_project\"}");
    }

    if (std.mem.startsWith(u8, target, "/tasks")) {
        if (ctx.default_project_id) |pid| {
            return handleTasksApi(ctx, req, target, pid);
        }
        return respondJson(req, .not_found, "{\"error\":\"no_default_project\"}");
    }

    if (std.mem.startsWith(u8, target, "/sessions/current")) {
        if (ctx.default_project_id) |pid| {
            return handleSessionsApi(ctx, req, target, pid);
        }
        return respondJson(req, .not_found, "{\"error\":\"no_default_project\"}");
    }

    if (std.mem.startsWith(u8, target, "/sessions/start")) {
        if (ctx.default_project_id) |pid| {
            return handleSessionStart(ctx, req, pid);
        }
        return respondJson(req, .not_found, "{\"error\":\"no_default_project\"}");
    }

    if (std.mem.startsWith(u8, target, "/runs/start")) {
        if (ctx.default_project_id) |pid| {
            return handleRunStart(ctx, req, pid);
        }
        return respondJson(req, .not_found, "{\"error\":\"no_default_project\"}");
    }

    if (std.mem.startsWith(u8, target, "/runs/") and std.mem.endsWith(u8, target, "/control")) {
        if (ctx.default_project_id) |pid| {
            return handleRunControl(ctx, req, target, pid);
        }
        return respondJson(req, .not_found, "{\"error\":\"no_default_project\"}");
    }

    if (std.mem.startsWith(u8, target, "/control") or std.mem.startsWith(u8, target, "/runs/current/control")) {
        if (ctx.default_project_id) |pid| {
            return handleRunControlCurrent(ctx, req, pid);
        }
        return respondJson(req, .not_found, "{\"error\":\"no_default_project\"}");
    }

    return respondJson(req, .not_found, "{\"error\":\"not_found\"}");
}

// === Project Management Handlers ===

fn handleCreateProject(ctx: *ServerContext, req: *http.Server.Request) !void {
    if (!authorizedControl(ctx, req)) {
        return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    }
    if (!allowControlRequest(ctx)) {
        return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");
    }

    const body = (try parseCreateProjectBody(req, ctx.allocator)) orelse {
        return respondJson(req, .bad_request, "{\"error\":\"invalid_body\"}");
    };
    defer {
        ctx.allocator.free(body.project_id);
        ctx.allocator.free(body.work_dir);
        if (body.test_cmd) |v| ctx.allocator.free(v);
        if (body.lint_cmd) |v| ctx.allocator.free(v);
    }

    // Verify work_dir exists
    std.fs.cwd().access(body.work_dir, .{}) catch {
        return respondJson(req, .bad_request, "{\"error\":\"work_dir_not_exist\"}");
    };

    ctx.store.registerProject(.{
        .project_id = body.project_id,
        .work_dir = body.work_dir,
        .enabled = body.enabled orelse true,
        .test_cmd = body.test_cmd,
        .lint_cmd = body.lint_cmd,
        .max_workers = body.max_workers orelse 1,
    }) catch |err| switch (err) {
        error.ProjectIdExists => return respondJson(req, .conflict, "{\"error\":\"project_id_exists\"}"),
        else => return respondJson(req, .bad_request, "{\"error\":\"create_failed\"}"),
    };

    // Get the created project
    const project = ctx.store.getProject(body.project_id, ctx.allocator) catch {
        return respondJson(req, .created, "{\"ok\":true}");
    };
    if (project) |p| {
        defer p.deinit(ctx.allocator);
        const response = try formatProjectJson(ctx.allocator, p);
        defer ctx.allocator.free(response);
        return respondJson(req, .created, response);
    }
    return respondJson(req, .created, "{\"ok\":true}");
}

fn handleListProjects(ctx: *ServerContext, req: *http.Server.Request, target: []const u8) !void {
    if (!authorizedObserve(ctx, req)) {
        return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    }

    const enabled_only = if (queryValue(target, "enabled")) |v| std.mem.eql(u8, v, "true") else false;
    const limit = parseLimitQuery(target, 50);
    const cursor = parseCursorQuery(target);

    const projects = ctx.store.listProjects(.{
        .enabled_only = enabled_only,
        .limit = limit,
        .cursor = cursor,
    }, ctx.allocator) catch {
        return respondJson(req, .bad_request, "{\"error\":\"list_failed\"}");
    };
    defer {
        for (projects) |*p| p.deinit(ctx.allocator);
        ctx.allocator.free(projects);
    }

    const response = try formatProjectsListJson(ctx.allocator, projects, cursor, limit);
    defer ctx.allocator.free(response);
    return respondJson(req, .ok, response);
}

fn handleGetProject(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8) !void {
    if (!authorizedObserve(ctx, req)) {
        return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    }

    const project = ctx.store.getProject(project_id, ctx.allocator) catch {
        return respondJson(req, .bad_request, "{\"error\":\"get_failed\"}");
    } orelse {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    };
    defer project.deinit(ctx.allocator);

    const response = try formatProjectJson(ctx.allocator, project);
    defer ctx.allocator.free(response);
    return respondJson(req, .ok, response);
}

fn handleUpdateProject(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8) !void {
    if (!authorizedControl(ctx, req)) {
        return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    }
    if (!allowControlRequest(ctx)) {
        return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");
    }

    const body = (try parseUpdateProjectBody(req, ctx.allocator)) orelse {
        return respondJson(req, .bad_request, "{\"error\":\"invalid_body\"}");
    };
    defer {
        if (body.test_cmd) |v| ctx.allocator.free(v);
        if (body.lint_cmd) |v| ctx.allocator.free(v);
    }

    ctx.store.updateProject(project_id, .{
        .enabled = body.enabled,
        .test_cmd = body.test_cmd,
        .lint_cmd = body.lint_cmd,
        .max_workers = body.max_workers,
    }) catch |err| switch (err) {
        error.ProjectNotFound => return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}"),
        else => return respondJson(req, .bad_request, "{\"error\":\"update_failed\"}"),
    };

    const project = ctx.store.getProject(project_id, ctx.allocator) catch {
        return respondJson(req, .ok, "{\"ok\":true}");
    } orelse {
        return respondJson(req, .ok, "{\"ok\":true}");
    };
    defer project.deinit(ctx.allocator);

    const response = try formatProjectJson(ctx.allocator, project);
    defer ctx.allocator.free(response);
    return respondJson(req, .ok, response);
}

fn handleDeleteProject(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8) !void {
    if (!authorizedControl(ctx, req)) {
        return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    }
    if (!allowControlRequest(ctx)) {
        return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");
    }

    ctx.store.deleteProject(project_id) catch |err| switch (err) {
        error.ProjectNotFound => return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}"),
        else => return respondJson(req, .bad_request, "{\"error\":\"delete_failed\"}"),
    };

    return respondJson(req, .ok, "{\"ok\":true}");
}

// === Runs API Handlers ===

fn handleRunsApi(ctx: *ServerContext, req: *http.Server.Request, target: []const u8, project_id: []const u8) !void {
    const path = pathNoQuery(target);

    // POST /projects/:id/runs/start
    if (std.mem.endsWith(u8, path, "/runs/start")) {
        return handleRunStart(ctx, req, project_id);
    }

    // GET /projects/:id/runs/current
    if (std.mem.endsWith(u8, path, "/runs/current")) {
        return handleRunCurrent(ctx, req, project_id);
    }

    // GET /projects/:id/runs/current/events/stream
    if (std.mem.endsWith(u8, path, "/runs/current/events/stream")) {
        return streamProjectEvents(req, ctx, project_id, parseAfterFromRequest(req));
    }

    // GET /projects/:id/runs/current/events
    if (std.mem.endsWith(u8, path, "/runs/current/events")) {
        return handleProjectEvents(ctx, req, target, project_id);
    }

    // POST /projects/:id/runs/current/control
    if (std.mem.endsWith(u8, path, "/runs/current/control")) {
        return handleRunControlCurrent(ctx, req, project_id);
    }

    // Specific run control: /projects/:id/runs/:run_id/control
    if (std.mem.indexOf(u8, path, "/runs/") != null and std.mem.endsWith(u8, path, "/control")) {
        return handleRunControl(ctx, req, target, project_id);
    }

    return respondJson(req, .not_found, "{\"error\":\"not_found\"}");
}

fn handleRunStart(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8) !void {
    if (!authorizedControl(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (req.head.method != .POST) {
        return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
    }
    if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

    // Validate project
    const project = validateProject(ctx, project_id) catch |err| switch (err) {
        error.ProjectDisabled => return respondJson(req, .forbidden, "{\"error\":\"project_disabled\"}"),
        else => return respondJson(req, .bad_request, "{\"error\":\"validation_failed\"}"),
    };
    if (project == null) {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    }
    defer if (project) |p| p.deinit(ctx.allocator);

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

    // Check for active runs
    const runs = ctx.store.listRunsByProject(project_id, 1, ctx.allocator) catch null;
    if (runs) |r| {
        defer {
            for (r) |*run| run.deinit(ctx.allocator);
            ctx.allocator.free(r);
        }
        for (r) |run| {
            if (std.mem.eql(u8, run.status, "running")) {
                return respondJson(req, .conflict, "{\"error\":\"run_already_active\"}");
            }
        }
    }

    const pid = startRunDetached(ctx.allocator, project.?.work_dir, mode) catch |err| {
        ui.logWarn("启动 run 失败: {any}", .{err});
        return respondJson(req, .bad_request, "{\"error\":\"start_failed\"}");
    };

    // Create run record
    const run_id = try std.fmt.allocPrint(ctx.allocator, "run-{d}-{d}", .{ std.time.timestamp(), std.crypto.random.int(u32) });
    defer ctx.allocator.free(run_id);

    ctx.store.createRun(run_id, project_id, mode, null) catch |err| {
        ui.logWarn("记录 run 失败: {any}", .{err});
    };

    const body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"run_id\":\"{s}\",\"pid\":{d},\"mode\":\"{s}\"}}", .{ run_id, pid, mode });
    defer ctx.allocator.free(body);
    return respondJson(req, .ok, body);
}

fn handleRunCurrent(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8) !void {
    if (!authorizedObserve(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (req.head.method != .GET) return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");

    const runs = ctx.store.listRunsByProject(project_id, 1, ctx.allocator) catch {
        return respondJson(req, .bad_request, "{\"error\":\"query_failed\"}");
    };
    defer {
        for (runs) |*r| r.deinit(ctx.allocator);
        ctx.allocator.free(runs);
    }

    if (runs.len == 0) {
        return respondJson(req, .not_found, "{\"error\":\"no_active_run\"}");
    }

    const run = runs[0];
    const body = try std.fmt.allocPrint(ctx.allocator, "{{\"run_id\":\"{s}\",\"project_id\":\"{s}\",\"mode\":\"{s}\",\"status\":\"{s}\",\"started_at\":{d}}}", .{ run.run_id, run.project_id, run.mode, run.status, run.started_at });
    defer ctx.allocator.free(body);
    return respondJson(req, .ok, body);
}

fn handleRunControl(ctx: *ServerContext, req: *http.Server.Request, target: []const u8, project_id: []const u8) !void {
    if (!authorizedControl(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

    // Get project work_dir
    const project = ctx.store.getProject(project_id, ctx.allocator) catch {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    } orelse {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    };
    defer project.deinit(ctx.allocator);

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
    try runner.runControlCommandWithMetaAndRequestId(ctx.allocator, project.work_dir, action, prompt, "observe-user", "observe-api", rid);
    return respondJson(req, .ok, "{\"ok\":true}");
}

fn handleRunControlCurrent(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8) !void {
    if (!authorizedControl(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (req.head.method != .POST and req.head.method != .GET) {
        return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
    }
    if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

    // Get project work_dir
    const project = ctx.store.getProject(project_id, ctx.allocator) catch {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    } orelse {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    };
    defer project.deinit(ctx.allocator);

    var action: []const u8 = queryValue(req.head.target, "action") orelse "none";
    var action_owned: ?[]u8 = null;
    defer if (action_owned) |a| ctx.allocator.free(a);
    var prompt: ?[]u8 = null;
    defer if (prompt) |p| ctx.allocator.free(p);
    var request_id: ?[]u8 = requestIdFromHeader(ctx.allocator, req);
    defer if (request_id) |rid| ctx.allocator.free(rid);

    if (queryValue(req.head.target, "prompt")) |p| {
        prompt = try decodeUrlComponent(ctx.allocator, p);
    }
    if (queryValue(req.head.target, "request_id")) |rid| {
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
    try runner.runControlCommandWithMetaAndRequestId(ctx.allocator, project.work_dir, action, prompt, "observe-user", "observe-api", rid);
    return respondJson(req, .ok, "{\"ok\":true}");
}

fn handleRunsEventsStream(ctx: *ServerContext, req: *http.Server.Request, target: []const u8, project_id: []const u8) !void {
    if (!authorizedObserve(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    _ = target;
    const after = parseAfterFromRequest(req);
    return streamProjectEvents(req, ctx, project_id, after);
}

fn handleProjectEvents(ctx: *ServerContext, req: *http.Server.Request, target: []const u8, project_id: []const u8) !void {
    if (!authorizedObserve(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    const after = parseAfterI64Query(target);
    const events = ctx.store.getTaskEvents(project_id, after, 200, ctx.allocator) catch {
        return respondJson(req, .ok, "{\"events\":[],\"last_event_id\":0}");
    };
    defer ctx.allocator.free(events);
    return respondJson(req, .ok, events);
}

// === Tasks API Handlers ===

fn handleTasksApi(ctx: *ServerContext, req: *http.Server.Request, target: []const u8, project_id: []const u8) !void {
    const path = pathNoQuery(target);

    // /projects/:id/tasks/events
    if (std.mem.endsWith(u8, path, "/tasks/events")) {
        return handleProjectEvents(ctx, req, target, project_id);
    }

    // /projects/:id/tasks (list or create)
    if (std.mem.endsWith(u8, path, "/tasks")) {
        if (req.head.method == .GET) {
            return handleListTasks(ctx, req, target, project_id);
        }
        if (req.head.method == .POST) {
            return handleCreateTask(ctx, req, project_id);
        }
        return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
    }

    // Get task_id from path
    const ids = extractProjectAndTaskIds(target) orelse {
        return respondJson(req, .not_found, "{\"error\":\"not_found\"}");
    };

    // /projects/:id/tasks/:task_id/actions
    if (std.mem.endsWith(u8, path, "/actions")) {
        return handleTaskAction(ctx, req, project_id, ids.task_id);
    }

    // /projects/:id/tasks/:task_id
    if (req.head.method == .GET) {
        return handleGetTask(ctx, req, project_id, ids.task_id);
    }
    if (req.head.method == .PATCH) {
        return handlePatchTask(ctx, req, project_id, ids.task_id);
    }

    return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
}

fn handleListTasks(ctx: *ServerContext, req: *http.Server.Request, target: []const u8, project_id: []const u8) !void {
    if (!authorizedObserve(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");

    const status_text = queryValue(target, "status");
    const q = queryValue(target, "q");
    const limit = parseLimitQuery(target, 50);
    const cursor = parseCursorQuery(target);

    const status: ?task_store.TaskStatus = if (status_text) |s|
        task_store.taskStatusFromString(s) catch null
    else
        null;

    const out = ctx.store.listTasksByProject(.{
        .project_id = project_id,
        .status = status,
        .limit = limit,
        .cursor = cursor,
        .q = q,
    }, ctx.allocator) catch {
        return respondJson(req, .bad_request, "{\"error\":\"list_failed\"}");
    };
    defer ctx.allocator.free(out);
    return respondJson(req, .ok, out);
}

fn handleCreateTask(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8) !void {
    if (!authorizedControl(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

    // Validate project
    const project = validateProject(ctx, project_id) catch |err| switch (err) {
        error.ProjectDisabled => return respondJson(req, .forbidden, "{\"error\":\"project_disabled\"}"),
        else => return respondJson(req, .bad_request, "{\"error\":\"validation_failed\"}"),
    };
    if (project == null) {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    }
    defer if (project) |p| p.deinit(ctx.allocator);

    var request_id: ?[]u8 = requestIdFromHeader(ctx.allocator, req);
    defer if (request_id) |rid| ctx.allocator.free(rid);
    const body = (try parseCreateTaskBody(req, ctx.allocator)) orelse return respondJson(req, .bad_request, "{\"error\":\"invalid_body\"}");
    defer {
        if (body.title) |v| ctx.allocator.free(v);
        if (body.prompt) |v| ctx.allocator.free(v);
        if (body.request_id) |v| ctx.allocator.free(v);
    }
    if (body.request_id) |rid| {
        if (request_id) |old| ctx.allocator.free(old);
        request_id = try ctx.allocator.dupe(u8, rid);
    }
    if (request_id) |rid| {
        if (isDuplicateRequestId(ctx, rid)) return respondJson(req, .conflict, "{\"error\":\"duplicate_request_id\"}");
    }
    const title = body.title orelse return respondJson(req, .bad_request, "{\"error\":\"title_required\"}");
    if (std.mem.trim(u8, title, " \t\r\n").len == 0) return respondJson(req, .bad_request, "{\"error\":\"title_required\"}");
    const task_id = try std.fmt.allocPrint(ctx.allocator, "task-{d}-{d}", .{ std.time.timestamp(), std.crypto.random.int(u32) });
    defer ctx.allocator.free(task_id);

    ctx.store.createTask(project_id, .{
        .task_id = task_id,
        .title = title,
        .prompt = body.prompt,
        .priority = body.priority orelse 0,
        .max_retries = body.max_retries,
    }, .{
        .operator = "observe-user",
        .source = "observe-api",
        .request_id = request_id,
    }) catch |err| {
        ui.logWarn("创建任务失败: {any}", .{err});
        return respondJson(req, .bad_request, "{\"error\":\"create_failed\"}");
    };

    const response = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"task_id\":\"{s}\",\"project_id\":\"{s}\"}}", .{ task_id, project_id });
    defer ctx.allocator.free(response);
    return respondJson(req, .created, response);
}

fn handleGetTask(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8, task_id: []const u8) !void {
    if (!authorizedObserve(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");

    const out = ctx.store.getTaskDetail(project_id, task_id, ctx.allocator) catch |err| switch (err) {
        error.TaskNotFound => return respondJson(req, .not_found, "{\"error\":\"task_not_found\"}"),
        else => return respondJson(req, .bad_request, "{\"error\":\"detail_failed\"}"),
    };
    defer ctx.allocator.free(out);
    return respondJson(req, .ok, out);
}

fn handlePatchTask(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8, task_id: []const u8) !void {
    if (!authorizedControl(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

    var request_id: ?[]u8 = requestIdFromHeader(ctx.allocator, req);
    defer if (request_id) |rid| ctx.allocator.free(rid);
    const body = (try parsePatchTaskBody(req, ctx.allocator)) orelse return respondJson(req, .bad_request, "{\"error\":\"invalid_body\"}");
    defer {
        if (body.title) |v| ctx.allocator.free(v);
        if (body.prompt) |v| ctx.allocator.free(v);
        if (body.request_id) |v| ctx.allocator.free(v);
    }
    if (body.request_id) |rid| {
        if (request_id) |old| ctx.allocator.free(old);
        request_id = try ctx.allocator.dupe(u8, rid);
    }
    if (request_id) |rid| {
        if (isDuplicateRequestId(ctx, rid)) return respondJson(req, .conflict, "{\"error\":\"duplicate_request_id\"}");
    }

    // Validate version is provided
    const version = body.version orelse return respondJson(req, .bad_request, "{\"error\":\"version_required\"}");

    const input = task_store.PatchTaskInput{
        .title = body.title,
        .prompt = body.prompt,
        .priority = body.priority,
        .max_retries = body.max_retries,
        .version = version,
    };

    ctx.store.patchTask(project_id, task_id, input, .{
        .operator = "observe-user",
        .source = "observe-api",
        .request_id = request_id,
    }) catch |err| switch (err) {
        error.TaskNotFound => return respondJson(req, .not_found, "{\"error\":\"task_not_found\"}"),
        error.VersionConflict => return respondJson(req, .conflict, "{\"error\":\"version_conflict\"}"),
        else => return respondJson(req, .bad_request, "{\"error\":\"patch_failed\"}"),
    };

    // Return updated task data
    const out = ctx.store.getTaskDetail(project_id, task_id, ctx.allocator) catch |err| switch (err) {
        error.TaskNotFound => return respondJson(req, .not_found, "{\"error\":\"task_not_found\"}"),
        else => return respondJson(req, .bad_request, "{\"error\":\"detail_failed\"}"),
    };
    defer ctx.allocator.free(out);
    return respondJson(req, .ok, out);
}

fn handleTaskAction(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8, task_id: []const u8) !void {
    if (!authorizedControl(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (req.head.method != .POST) return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
    if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

    var request_id: ?[]u8 = requestIdFromHeader(ctx.allocator, req);
    defer if (request_id) |rid| ctx.allocator.free(rid);
    const body = (try parseTaskActionBody(req, ctx.allocator)) orelse return respondJson(req, .bad_request, "{\"error\":\"invalid_body\"}");
    defer {
        if (body.action) |v| ctx.allocator.free(v);
        if (body.request_id) |v| ctx.allocator.free(v);
    }
    if (body.request_id) |rid| {
        if (request_id) |old| ctx.allocator.free(old);
        request_id = try ctx.allocator.dupe(u8, rid);
    }
    if (request_id) |rid| {
        if (isDuplicateRequestId(ctx, rid)) return respondJson(req, .conflict, "{\"error\":\"duplicate_request_id\"}");
    }
    const action_text = body.action orelse return respondJson(req, .bad_request, "{\"error\":\"action_required\"}");
    const action = parseTaskAction(action_text) orelse return respondJson(req, .bad_request, "{\"error\":\"invalid_action\"}");

    ctx.store.applyAction(project_id, task_id, action, .{
        .operator = "observe-user",
        .source = "observe-api",
        .request_id = request_id,
    }) catch |err| switch (err) {
        error.ActionRejected => return respondJson(req, .conflict, "{\"error\":\"action_rejected\"}"),
        error.ForceMergeDisabled => return respondJson(req, .bad_request, "{\"error\":\"force_merge_disabled\"}"),
        else => return respondJson(req, .bad_request, "{\"error\":\"action_failed\"}"),
    };
    return respondJson(req, .ok, "{\"ok\":true}");
}

// === Sessions API Handlers ===

fn handleSessionsApi(ctx: *ServerContext, req: *http.Server.Request, target: []const u8, project_id: []const u8) !void {
    const path = pathNoQuery(target);

    // GET /projects/:id/sessions/current
    if (std.mem.eql(u8, path, "/sessions/current")) {
        return handleSessionCurrent(ctx, req, project_id);
    }

    // POST /projects/:id/sessions/current/end
    if (std.mem.eql(u8, path, "/sessions/current/end")) {
        return handleSessionEnd(ctx, req, project_id);
    }

    // POST /projects/:id/sessions/current/message
    if (std.mem.eql(u8, path, "/sessions/current/message")) {
        return handleSessionMessage(ctx, req, project_id);
    }

    // POST /projects/:id/sessions/start
    if (std.mem.eql(u8, path, "/sessions/start")) {
        return handleSessionStart(ctx, req, project_id);
    }

    return respondJson(req, .not_found, "{\"error\":\"not_found\"}");
}

fn handleSessionCurrent(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8) !void {
    if (!authorizedObserve(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (req.head.method != .GET) return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");

    // Get project work_dir
    const project = ctx.store.getProject(project_id, ctx.allocator) catch {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    } orelse {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    };
    defer project.deinit(ctx.allocator);

    const state = session_service.getSessionStateJson(ctx.allocator, project.work_dir) catch "{\"error\":\"session_not_found\"}";
    defer if (state.ptr != "{\"error\":\"session_not_found\"}".ptr) ctx.allocator.free(state);
    return respondJson(req, .ok, state);
}

fn handleSessionEnd(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8) !void {
    if (!authorizedControl(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (req.head.method != .POST) return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
    if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

    // Get project work_dir
    const project = ctx.store.getProject(project_id, ctx.allocator) catch {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    } orelse {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    };
    defer project.deinit(ctx.allocator);

    var request_id: ?[]u8 = requestIdFromHeader(ctx.allocator, req);
    defer if (request_id) |rid| ctx.allocator.free(rid);
    if (try parseEndSessionBody(req, ctx.allocator)) |body| {
        defer if (body.request_id) |rid| ctx.allocator.free(rid);
        if (body.request_id) |rid| {
            if (request_id) |old| ctx.allocator.free(old);
            request_id = try ctx.allocator.dupe(u8, rid);
        }
    }
    if (request_id) |rid| {
        if (isDuplicateRequestId(ctx, rid)) return respondJson(req, .conflict, "{\"error\":\"duplicate_request_id\"}");
    }

    const end_result = session_service.endSession(ctx.allocator, project.work_dir) catch |err| {
        ui.logWarn("session end failed: {any}", .{err});
        return respondJson(req, .bad_request, "{\"error\":\"session_end_failed\"}");
    };
    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"ok\":true,\"status\":\"{s}\"}}",
        .{end_result.status},
    );
    defer ctx.allocator.free(body);
    return respondJson(req, .ok, body);
}

fn handleSessionMessage(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8) !void {
    if (!authorizedControl(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (req.head.method != .POST) return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");

    // Get project work_dir
    const project = ctx.store.getProject(project_id, ctx.allocator) catch {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    } orelse {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    };
    defer project.deinit(ctx.allocator);

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
    const rid = request_id orelse return respondJson(req, .bad_request, "{\"error\":\"request_id_required\"}");

    const queue_result = session_service.enqueueMessage(ctx.allocator, project.work_dir, message.?, rid) catch |err| {
        switch (err) {
            error.RequestIdRequired => return respondJson(req, .bad_request, "{\"error\":\"request_id_required\"}"),
            error.SessionBusy => return respondJson(req, .conflict, "{\"error\":\"session_busy\"}"),
            error.SessionNotActive => return respondJson(req, .conflict, "{\"error\":\"session_not_active\"}"),
            else => {
                ui.logWarn("session enqueue failed: {any}", .{err});
                return respondJson(req, .bad_request, "{\"error\":\"session_send_failed\"}");
            },
        }
    };
    defer if (queue_result.reply) |reply| ctx.allocator.free(reply);

    if (queue_result.accepted) {
        const started = startSessionMessageWorker(ctx.allocator, project.work_dir, rid) catch |spawn_err| {
            ui.logWarn("session worker spawn failed, fallback sync: {any}", .{spawn_err});
            const send_result = session_service.processInFlightMessage(ctx.allocator, project.work_dir, rid) catch |err| {
                ui.logWarn("session send failed after fallback: {any}", .{err});
                return respondJson(req, .bad_request, "{\"error\":\"session_send_failed\"}");
            };
            defer if (send_result.reply) |reply| ctx.allocator.free(reply);
            const sync_body = if (send_result.reply) |reply|
                try std.fmt.allocPrint(
                    ctx.allocator,
                    "{{\"ok\":true,\"status\":\"{s}\",\"deduplicated\":{{}},\"reply\":\"{s}\"}}",
                    .{ send_result.status, reply },
                )
            else
                try std.fmt.allocPrint(
                    ctx.allocator,
                    "{{\"ok\":true,\"status\":\"{s}\",\"deduplicated\":{{}},\"reply\":null}}",
                    .{send_result.status},
                );
            defer ctx.allocator.free(sync_body);
            return respondJson(req, .ok, sync_body);
        };
        if (!started) {
            ui.logWarn("session worker already running for request_id={s}", .{rid});
        }
    }

    const body = if (queue_result.reply) |reply|
        try std.fmt.allocPrint(
            ctx.allocator,
            "{{\"ok\":true,\"status\":\"{s}\",\"deduplicated\":{{}},\"reply\":\"{s}\"}}",
            .{ queue_result.status, reply },
        )
    else
        try std.fmt.allocPrint(
            ctx.allocator,
            "{{\"ok\":true,\"status\":\"{s}\",\"deduplicated\":{{}},\"reply\":null}}",
            .{queue_result.status},
        );
    defer ctx.allocator.free(body);
    return respondJson(req, .ok, body);
}

fn handleSessionStart(ctx: *ServerContext, req: *http.Server.Request, project_id: []const u8) !void {
    if (!authorizedControl(ctx, req)) return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    if (req.head.method != .POST) return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
    if (!allowControlRequest(ctx)) return respondJson(req, .too_many_requests, "{\"error\":\"rate_limited\"}");

    // Get project work_dir
    const project = ctx.store.getProject(project_id, ctx.allocator) catch {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    } orelse {
        return respondJson(req, .not_found, "{\"error\":\"project_not_found\"}");
    };
    defer project.deinit(ctx.allocator);

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

    const session_id = session_service.startSession(ctx.allocator, project.work_dir, provider, model) catch |err| {
        ui.logWarn("session start failed: {any}", .{err});
        return respondJson(req, .bad_request, "{\"error\":\"session_start_failed\"}");
    };
    defer ctx.allocator.free(session_id);
    const body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"session_id\":\"{s}\"}}", .{session_id});
    defer ctx.allocator.free(body);
    return respondJson(req, .ok, body);
}

// === Auth Handlers ===

fn handleAuthQrBootstrap(ctx: *ServerContext, req: *http.Server.Request) !void {
    if (req.head.method != .POST and req.head.method != .GET) {
        return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
    }
    if (!authorizedObserve(ctx, req) and !authorizedControl(ctx, req)) {
        return respondJson(req, .unauthorized, "{\"error\":\"unauthorized\"}");
    }
    var ttl_seconds: i64 = BOOTSTRAP_TTL_SECONDS;
    if (req.head.method == .POST) {
        if (try parseBootstrapBody(req, ctx.allocator)) |body| {
            if (body.ttl_seconds) |ttl| {
                if (ttl > 0 and ttl <= 30 * 60) ttl_seconds = ttl;
            }
        }
    }
    const issue = try issueBootstrapTicket(ctx, ttl_seconds);
    defer ctx.allocator.free(issue.bootstrap_id);
    defer ctx.allocator.free(issue.code);
    defer ctx.allocator.free(issue.url);
    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"url\":\"{s}\",\"bootstrap_id\":\"{s}\",\"expires_at\":{d}}}",
        .{ issue.url, issue.bootstrap_id, issue.expires_at },
    );
    defer ctx.allocator.free(body);
    return respondJson(req, .ok, body);
}

fn handleAuthTokenExchange(ctx: *ServerContext, req: *http.Server.Request) !void {
    if (req.head.method != .POST) return respondJson(req, .bad_request, "{\"error\":\"method_not_allowed\"}");
    const payload = (try parseTokenExchangeBody(req, ctx.allocator)) orelse return respondJson(req, .bad_request, "{\"error\":\"invalid_body\"}");
    defer {
        if (payload.bootstrap_id) |v| ctx.allocator.free(v);
        if (payload.code) |v| ctx.allocator.free(v);
    }
    const bootstrap_id = payload.bootstrap_id orelse return respondJson(req, .bad_request, "{\"error\":\"bootstrap_id_required\"}");
    const code = payload.code orelse return respondJson(req, .bad_request, "{\"error\":\"code_required\"}");
    if (bootstrap_id.len == 0 or code.len == 0) return respondJson(req, .bad_request, "{\"error\":\"invalid_body\"}");

    cleanupBootstrapTickets(ctx);
    const removed = ctx.bootstrap_tickets.fetchRemove(bootstrap_id) orelse {
        return respondJson(req, .unauthorized, "{\"error\":\"invalid_or_expired_bootstrap\"}");
    };
    defer {
        ctx.allocator.free(removed.key);
        ctx.allocator.free(removed.value.code);
    }
    if (std.time.timestamp() > removed.value.expires_at) {
        return respondJson(req, .unauthorized, "{\"error\":\"bootstrap_expired\"}");
    }
    if (!std.mem.eql(u8, removed.value.code, code)) {
        return respondJson(req, .unauthorized, "{\"error\":\"invalid_bootstrap_code\"}");
    }
    const now = std.time.timestamp();
    const observe_age = @max(@as(i64, 0), ctx.observe_expires_at - now);
    const control_age = @max(@as(i64, 0), ctx.control_expires_at - now);
    if (observe_age == 0 or control_age == 0) {
        return respondJson(req, .unauthorized, "{\"error\":\"token_expired\"}");
    }

    const observe_cookie = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}",
        .{ AUTH_COOKIE_OBSERVE, ctx.observe_token, observe_age },
    );
    defer ctx.allocator.free(observe_cookie);
    const control_cookie = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}",
        .{ AUTH_COOKIE_CONTROL, ctx.control_token, control_age },
    );
    defer ctx.allocator.free(control_cookie);

    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"ok\":true,\"observe_expires_at\":{d},\"control_expires_at\":{d}}}",
        .{ ctx.observe_expires_at, ctx.control_expires_at },
    );
    defer ctx.allocator.free(body);
    return respondJsonWithCookies(req, .ok, body, observe_cookie, control_cookie);
}

// === Helper Functions ===

fn serveObserveUiAsset(ctx: *ServerContext, req: *http.Server.Request, target: []const u8) !bool {
    if (req.head.method != .GET) return false;

    const path_no_query = blk: {
        if (std.mem.indexOfScalar(u8, target, '?')) |q| break :blk target[0..q];
        break :blk target;
    };

    const is_spa_entry = std.mem.eql(u8, path_no_query, "/") or std.mem.eql(u8, path_no_query, "/connect") or std.mem.startsWith(u8, path_no_query, "/connect/");
    if (!(is_spa_entry or std.mem.startsWith(u8, path_no_query, "/assets/"))) {
        return false;
    }

    const rel_path = if (is_spa_entry) "index.html" else path_no_query[1..];
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

fn respondJsonWithCookies(req: *http.Server.Request, status: http.Status, body: []const u8, observe_cookie: []const u8, control_cookie: []const u8) !void {
    const headers = [_]http.Header{
        .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "set-cookie", .value = observe_cookie },
        .{ .name = "set-cookie", .value = control_cookie },
    };
    try req.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &headers,
    });
}

fn respondHtml(req: *http.Server.Request, body: []const u8) !void {
    try respondBody(req, .ok, body, "text/html; charset=utf-8", "no-store");
}

fn streamProjectEvents(req: *http.Server.Request, ctx: *ServerContext, project_id: []const u8, after_start: usize) !void {
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

    var after: usize = after_start;
    var ticks: usize = 0;
    while (ticks < 30) : (ticks += 1) {
        const payload = ctx.store.getTaskEvents(project_id, @intCast(after), 100, ctx.allocator) catch "{\"events\":[],\"last_event_id\":0}";
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

fn authorizedObserve(ctx: *const ServerContext, req: *const http.Server.Request) bool {
    return authorized(req, ctx.observe_token, ctx.observe_expires_at, AUTH_COOKIE_OBSERVE);
}

fn authorizedControl(ctx: *const ServerContext, req: *const http.Server.Request) bool {
    return authorized(req, ctx.control_token, ctx.control_expires_at, AUTH_COOKIE_CONTROL);
}

fn authorized(req: *const http.Server.Request, expected_token: []const u8, expires_at: i64, cookie_name: []const u8) bool {
    if (std.time.timestamp() > expires_at) return false;

    if (cookieValue(req, cookie_name)) |cookie_token| {
        if (std.mem.eql(u8, cookie_token, expected_token)) return true;
    }

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

fn cookieValue(req: *const http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "cookie")) continue;
        var pairs = std.mem.splitScalar(u8, h.value, ';');
        while (pairs.next()) |pair_raw| {
            const pair = std.mem.trim(u8, pair_raw, " \t\r\n");
            if (pair.len <= name.len + 1) continue;
            if (!std.mem.startsWith(u8, pair, name)) continue;
            if (pair[name.len] != '=') continue;
            const value = std.mem.trim(u8, pair[name.len + 1 ..], " \t\r\n");
            if (value.len > 0) return value;
        }
    }
    return null;
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

fn pathNoQuery(target: []const u8) []const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..q];
}

fn parseTaskAction(text: []const u8) ?task_store.Action {
    if (std.mem.eql(u8, text, "requeue")) return .requeue;
    if (std.mem.eql(u8, text, "cancel")) return .cancel;
    if (std.mem.eql(u8, text, "resume")) return .@"resume";
    if (std.mem.eql(u8, text, "force_fail")) return .force_fail;
    if (std.mem.eql(u8, text, "retry_review")) return .retry_review;
    if (std.mem.eql(u8, text, "force_merge")) return .force_merge;
    return null;
}

fn parseAfterI64Query(target: []const u8) i64 {
    const after_raw = queryValue(target, "after") orelse return 0;
    return std.fmt.parseInt(i64, after_raw, 10) catch 0;
}

fn parseLimitQuery(target: []const u8, default_value: usize) usize {
    const raw = queryValue(target, "limit") orelse return default_value;
    return std.fmt.parseInt(usize, raw, 10) catch default_value;
}

fn parseCursorQuery(target: []const u8) usize {
    const raw = queryValue(target, "cursor") orelse return 0;
    return std.fmt.parseInt(usize, raw, 10) catch 0;
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

fn cleanupBootstrapTickets(ctx: *ServerContext) void {
    const now = std.time.timestamp();
    var stale_keys: std.ArrayList([]const u8) = .empty;
    defer stale_keys.deinit(ctx.allocator);
    var it = ctx.bootstrap_tickets.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.expires_at <= now) {
            stale_keys.append(ctx.allocator, entry.key_ptr.*) catch {};
        }
    }
    for (stale_keys.items) |k| {
        if (ctx.bootstrap_tickets.fetchRemove(k)) |removed| {
            ctx.allocator.free(removed.key);
            ctx.allocator.free(removed.value.code);
        }
    }
}

fn issueBootstrapTicket(ctx: *ServerContext, ttl_seconds: i64) !BootstrapIssue {
    cleanupBootstrapTickets(ctx);
    const now = std.time.timestamp();
    const ttl = @max(@as(i64, 30), ttl_seconds);

    const bootstrap_id = try generateToken(ctx.allocator);
    errdefer ctx.allocator.free(bootstrap_id);
    const code = try generateToken(ctx.allocator);
    errdefer ctx.allocator.free(code);

    const key_copy = try ctx.allocator.dupe(u8, bootstrap_id);
    errdefer ctx.allocator.free(key_copy);
    const code_copy = try ctx.allocator.dupe(u8, code);
    errdefer ctx.allocator.free(code_copy);

    const expires_at = now + ttl;
    ctx.bootstrap_tickets.put(key_copy, .{
        .code = code_copy,
        .expires_at = expires_at,
    }) catch |err| {
        ctx.allocator.free(key_copy);
        ctx.allocator.free(code_copy);
        return err;
    };

    const url = if (ctx.external_url) |ext_url|
        try std.fmt.allocPrint(
            ctx.allocator,
            "{s}/connect?bootstrap_id={s}&code={s}",
            .{ ext_url, bootstrap_id, code },
        )
    else
        try std.fmt.allocPrint(
            ctx.allocator,
            "http://{s}:{d}/connect?bootstrap_id={s}&code={s}",
            .{ ctx.host, ctx.port, bootstrap_id, code },
        );
    errdefer ctx.allocator.free(url);

    return .{
        .bootstrap_id = bootstrap_id,
        .code = code,
        .expires_at = expires_at,
        .url = url,
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

fn ensureTokens(allocator: Allocator, store: *controlplane_store.ControlPlaneStore) !TokenFile {
    return ensureTokensInternal(allocator, store, false);
}

fn ensureTokensInternal(allocator: Allocator, store: *controlplane_store.ControlPlaneStore, force_rotate: bool) !TokenFile {
    // For now, generate new tokens each time (store doesn't persist tokens yet)
    _ = force_rotate;
    _ = store;

    const observe = try generateToken(allocator);
    defer allocator.free(observe);
    const control = try generateToken(allocator);
    defer allocator.free(control);

    const now = std.time.timestamp();
    const observe_expires_at = now + TOKEN_TTL_SECONDS;
    const control_expires_at = now + TOKEN_TTL_SECONDS;

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

// === JSON Formatting Helpers ===

fn formatProjectJson(allocator: Allocator, project: controlplane_store.Project) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{{\"project_id\":\"{s}\",\"work_dir\":\"{s}\",\"enabled\":{},\"test_cmd\":{s},\"lint_cmd\":{s},\"max_workers\":{d},\"created_at\":{d},\"updated_at\":{d}}}", .{
        project.project_id,
        project.work_dir,
        project.enabled,
        if (project.test_cmd) |v| try std.fmt.allocPrint(allocator, "\"{s}\"", .{v}) else "null",
        if (project.lint_cmd) |v| try std.fmt.allocPrint(allocator, "\"{s}\"", .{v}) else "null",
        project.max_workers,
        project.created_at,
        project.updated_at,
    });
}

fn formatProjectsListJson(allocator: Allocator, projects: []controlplane_store.Project, cursor: usize, limit: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var w = out.writer(allocator);

    try w.writeAll("{\"projects\":[");
    for (projects, 0..) |project, idx| {
        if (idx > 0) try w.writeByte(',');
        const pj = try formatProjectJson(allocator, project);
        defer allocator.free(pj);
        try w.writeAll(pj);
    }
    try w.print("],\"total\":{d},\"cursor\":{d},\"limit\":{d}}}", .{ projects.len, cursor, limit });

    return out.toOwnedSlice(allocator);
}

// === Request Body Parsers ===

fn parseCreateProjectBody(req: *http.Server.Request, allocator: Allocator) !?CreateProjectBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [4096]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(CreateProjectBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();

    return .{
        .project_id = try allocator.dupe(u8, parsed.value.project_id),
        .work_dir = try allocator.dupe(u8, parsed.value.work_dir),
        .enabled = parsed.value.enabled,
        .test_cmd = if (parsed.value.test_cmd) |v| try allocator.dupe(u8, v) else null,
        .lint_cmd = if (parsed.value.lint_cmd) |v| try allocator.dupe(u8, v) else null,
        .max_workers = parsed.value.max_workers,
    };
}

fn parseUpdateProjectBody(req: *http.Server.Request, allocator: Allocator) !?UpdateProjectBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [4096]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(UpdateProjectBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();

    return .{
        .enabled = parsed.value.enabled,
        .test_cmd = if (parsed.value.test_cmd) |v| try allocator.dupe(u8, v) else null,
        .lint_cmd = if (parsed.value.lint_cmd) |v| try allocator.dupe(u8, v) else null,
        .max_workers = parsed.value.max_workers,
    };
}

fn parseBootstrapBody(req: *http.Server.Request, allocator: Allocator) !?BootstrapBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [1024]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(BootstrapBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();

    return .{
        .ttl_seconds = parsed.value.ttl_seconds,
    };
}

fn parseTokenExchangeBody(req: *http.Server.Request, allocator: Allocator) !?TokenExchangeBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [1024]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(TokenExchangeBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();

    return .{
        .bootstrap_id = if (parsed.value.bootstrap_id) |v| try allocator.dupe(u8, v) else null,
        .code = if (parsed.value.code) |v| try allocator.dupe(u8, v) else null,
    };
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

fn parseEndSessionBody(req: *http.Server.Request, allocator: Allocator) !?EndSessionBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [1024]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(EndSessionBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();
    return .{
        .request_id = if (parsed.value.request_id) |rid| try allocator.dupe(u8, rid) else null,
    };
}

fn parseCreateTaskBody(req: *http.Server.Request, allocator: Allocator) !?CreateTaskBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [1024]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(CreateTaskBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();
    return .{
        .title = if (parsed.value.title) |v| try allocator.dupe(u8, v) else null,
        .prompt = if (parsed.value.prompt) |v| try allocator.dupe(u8, v) else null,
        .priority = parsed.value.priority,
        .max_retries = parsed.value.max_retries,
        .request_id = if (parsed.value.request_id) |v| try allocator.dupe(u8, v) else null,
    };
}

fn parsePatchTaskBody(req: *http.Server.Request, allocator: Allocator) !?PatchTaskBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [1024]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(PatchTaskBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();
    return .{
        .title = if (parsed.value.title) |v| try allocator.dupe(u8, v) else null,
        .prompt = if (parsed.value.prompt) |v| try allocator.dupe(u8, v) else null,
        .priority = parsed.value.priority,
        .max_retries = parsed.value.max_retries,
        .version = parsed.value.version,
        .request_id = if (parsed.value.request_id) |v| try allocator.dupe(u8, v) else null,
    };
}

fn parseTaskActionBody(req: *http.Server.Request, allocator: Allocator) !?TaskActionBody {
    const len_u64 = req.head.content_length orelse return null;
    if (len_u64 == 0) return null;
    if (len_u64 > 1024 * 1024) return error.RequestBodyTooLarge;

    var buf: [1024]u8 = undefined;
    var reader = req.readerExpectNone(&buf);
    const body_raw = try reader.readAlloc(allocator, @intCast(len_u64));
    defer allocator.free(body_raw);

    const parsed = std.json.parseFromSlice(TaskActionBody, allocator, body_raw, .{}) catch return null;
    defer parsed.deinit();
    return .{
        .action = if (parsed.value.action) |v| try allocator.dupe(u8, v) else null,
        .request_id = if (parsed.value.request_id) |v| try allocator.dupe(u8, v) else null,
    };
}

// === Session Worker ===

fn registerSessionWorker(request_id: []const u8) !?[]const u8 {
    g_session_worker_mutex.lock();
    defer g_session_worker_mutex.unlock();

    if (g_session_worker_requests.contains(request_id)) return null;
    const key = try std.heap.c_allocator.dupe(u8, request_id);
    errdefer std.heap.c_allocator.free(key);
    try g_session_worker_requests.put(std.heap.c_allocator, key, {});
    return key;
}

fn unregisterSessionWorker(request_id: []const u8) void {
    g_session_worker_mutex.lock();
    defer g_session_worker_mutex.unlock();

    if (g_session_worker_requests.fetchRemove(request_id)) |entry| {
        std.heap.c_allocator.free(entry.key);
    }
}

const SessionWorkerReaperArgs = struct {
    child: std.process.Child,
    target_dir: []const u8,
    request_id: []const u8,
};

fn startSessionMessageWorker(allocator: Allocator, target_dir: []const u8, request_id: []const u8) !bool {
    const tracked_request_id = (try registerSessionWorker(request_id)) orelse return false;
    errdefer unregisterSessionWorker(tracked_request_id);

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &[_][]const u8{
        exe_path,
        "session",
        "process-message",
        "--dir",
        target_dir,
        "--request-id",
        request_id,
    });

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = target_dir;
    try child.spawn();

    const target_dir_copy = try std.heap.c_allocator.dupe(u8, target_dir);
    errdefer std.heap.c_allocator.free(target_dir_copy);
    const reaper = try std.Thread.spawn(.{}, reapSessionWorkerProcess, .{SessionWorkerReaperArgs{
        .child = child,
        .target_dir = target_dir_copy,
        .request_id = tracked_request_id,
    }});
    reaper.detach();
    return true;
}

fn reapSessionWorkerProcess(args_in: SessionWorkerReaperArgs) void {
    var args = args_in;
    defer std.heap.c_allocator.free(args.target_dir);

    const term = args.child.wait() catch {
        const reason = "SessionWorkerWaitFailed";
        session_service.failInFlightMessage(std.heap.c_allocator, args.target_dir, args.request_id, reason) catch |err| {
            ui.logWarn("session worker wait failed cleanup error for request_id={s}: {any}", .{ args.request_id, err });
        };
        unregisterSessionWorker(args.request_id);
        return;
    };
    if (!utils.isExitedZero(term)) {
        ui.logWarn("session worker exited non-zero for request_id={s}", .{args.request_id});
        session_service.failInFlightMessage(std.heap.c_allocator, args.target_dir, args.request_id, SESSION_WORKER_EXIT_REASON) catch |err| {
            ui.logWarn("session worker non-zero cleanup error for request_id={s}: {any}", .{ args.request_id, err });
        };
    }
    unregisterSessionWorker(args.request_id);
}

// === Dashboard HTML ===

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
    \\</body>
    \\</html>
    ;
}

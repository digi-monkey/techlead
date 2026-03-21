# Observe UI (Vite + React + TypeScript + Tailwind)

工程化版前端控制台，聚焦 `Agent Session` 远程操控：
- Session 对话（启动会话、发送消息）
- Run 控制（start/pause/resume/abort/ask）
- 事件流观察（增量刷新）

## 启动开发

1. 启动后端 observe 服务（示例）

```bash
zig build run -- observe start --dir /path/to/project --host 0.0.0.0 --port 7788
```

2. 启动前端

```bash
cd web/observe-ui
pnpm install
pnpm dev
```

默认前端地址：`http://localhost:5173`

## API 代理

开发模式下 Vite 会把这些路径代理到后端：
- `/auth`
- `/health`
- `/events`
- `/tasks`
- `/runs`
- `/sessions`

默认代理目标：`http://127.0.0.1:7788`

可通过环境变量覆盖：

```bash
VITE_BACKEND_URL=http://127.0.0.1:7810 pnpm dev
```

## 扫码连接（推荐）

后端启动后会输出扫码链接（`/connect?...`），移动端打开后前端会自动：

1. 调用 `POST /auth/token/exchange`
2. 写入 HttpOnly Cookie（observe/control）
3. 清理 URL 中的敏感参数

默认不需要手动填写 token。

## Token 兼容模式（调试）

- 页面仍兼容 `?token=` / `?observe_token=` / `?control_token=`。
- 如需手工指定 token，可在页面里打开 `Show Token Debug`。

## 构建

```bash
pnpm build
pnpm preview
```

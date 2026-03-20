# Observe UI (Vite + React + TypeScript + Tailwind)

工程化版前端控制台，覆盖三个模式：
- `Observe`：事件流与任务面板
- `Control`：run 启动与 pause/resume/abort/ask 控制
- `Session`：远程 agent 会话启动与消息交互

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

## Token 用法

- 页面会自动读取 URL 参数 `?token=...` 作为初始 token。
- UI 顶部支持分别填写 `observe token` 与 `control token`。
- 若你只粘贴一个 token，到需要另一类权限的操作会返回 `401`。

## 构建

```bash
pnpm build
pnpm preview
```

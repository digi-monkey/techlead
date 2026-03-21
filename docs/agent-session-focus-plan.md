# Agent Session 聚焦计划（V1）

更新时间：2026-03-20

## 1. 产品收敛决策

从当前版本开始，产品主线统一收敛到 `agent session` 模式，优先打磨“浏览器远程操控电脑 AI”这一条闭环路径。

主路径定义：

1. 电脑侧启动服务
2. 手机/远端浏览器扫码进入
3. 浏览器直接连接并可观测 + 控制 + 对话
4. 控制动作可审计、可追溯

降级优先级（暂不作为主线迭代）：

- `pool` 任务管理深度能力
- 多模式并行 UI（observe/control/tasks/session 并列）
- 复杂 RBAC 与多租户

## 2. 北极星目标

在同一局域网或可达网络内，让用户在 3 分钟内完成远程接入并开始操控本机 AI session。

关键指标（P0）：

1. 首次接入成功率（扫码到看到 session）>= 95%
2. 首次接入时间（TTFC）<= 30 秒
3. 远程控制成功率（pause/resume/abort/ask/message）>= 99%
4. 核心链路 e2e 通过率 = 100%

## 3. 当前现状（与代码一致）

已具备：

1. 前端可从 URL 读取 `?token=` 并初始化 observe/control token
2. 后端启动时会输出扫码链接 `/?token=<observe_token>`
3. session 基础 API 已有：`/sessions/start`、`/sessions/current`、`/sessions/current/message`

当前缺口：

1. 用户仍感知“token”概念（UI 有 token 输入框）
2. 扫码仅天然覆盖 observe；控制动作依赖 `control_token`
3. `/auth/qr/bootstrap` 仍不是完整“无感换票”流程

结论：当前是“半无感接入”，未达到“扫码即连即控”产品体验。

## 4. 目标体验（P0）

统一为单入口 Session Console：

1. 进入页面后自动完成认证握手
2. 无需手填 token
3. 直接看到 session 状态、消息流、事件流
4. 可执行控制动作（start/pause/resume/abort/ask/send message）
5. 权限异常时给出可理解提示，不暴露内部细节

## 5. 范围定义

P0（必须做）：

1. 产品与 UI 聚焦 `agent session` 单模式
2. 扫码即连（不需要手填 token）
3. 远程对话与运行控制稳定可用
4. 审计字段贯通：`operator/source/request_id/ts`
5. 最小安全边界：短期票据 + 过期 + 一次性消费 + 速率限制

P1（后续）：

1. 任务池管理高级能力（批量任务、复杂筛选、租约可视化）
2. 多会话并发与会话切换
3. 更细粒度权限与设备管理

不做（本阶段）：

1. 全面 RBAC
2. 云端账户体系
3. 跨项目统一控制台

## 6. 技术方案（P0）

## 6.1 认证与扫码链路

新增/完善两段式授权：

1. `POST /auth/qr/bootstrap`
- 生成一次性 `bootstrap_id`（短 TTL，如 60 秒）
- 返回 `qr_url`（仅含 bootstrap 信息，不含长期 token）

2. `POST /auth/token/exchange`
- 客户端提交 `bootstrap_id + one_time_code`
- 服务端校验后发放会话凭据（建议 HttpOnly Cookie；若保留 Bearer 则仅短期）

3. 鉴权兼容
- API 层支持 `Authorization: Bearer` 与 `Cookie` 双通道（优先 cookie）
- 老 token 方式保留兼容，但前端主流程不再暴露输入框

## 6.2 前端收敛（observe-ui）

1. 入口改为 Session Console（session-first）
2. 默认隐藏/移除 token 输入区域（仅 debug 开关可见）
3. 首屏状态机：`connecting -> ready -> degraded -> expired`
4. 控制入口聚焦：
- 启动 session
- 发送消息
- run 控制（pause/resume/abort/ask）
5. 统一错误文案：
- `expired`：凭据过期，提示重新扫码
- `unauthorized`：权限不足，提示重新授权
- `rate_limited`：请求过快，提示稍后重试

## 6.3 后端能力补齐

1. 一次性票据存储（内存 map + TTL + single-use）
2. `authorized()` 扩展为可读取 cookie
3. 控制类 API 保持最小间隔限制与请求幂等（`request_id`）
4. 审计日志写入 control/event 流（便于回放）

## 7. 分阶段执行计划

## 阶段 A：产品与界面收敛（1 天）

交付：

1. UI 聚焦 session 模式，弱化非主线模块入口
2. token 输入默认不可见（保留调试开关）
3. 文案统一为“扫码连接”心智

验收：

1. 新用户进入页面不需要理解 observe/control token
2. 核心操作路径在 2 次点击内到达

## 阶段 B：扫码即连认证闭环（2 天）

交付：

1. 完成 `qr/bootstrap + token/exchange`
2. 前端接入自动 exchange
3. cookie/bearer 双通道鉴权

验收：

1. 扫码后不手填 token 即可进入可用态
2. 过期与复用票据均正确拒绝

## 阶段 C：远程控制稳定性（2 天）

交付：

1. session + control 主流程异常处理
2. 请求幂等与节流策略统一
3. 错误可观察（状态栏 + 事件）

验收：

1. 连续 50 次控制调用无状态错乱
2. 弱网场景可恢复（轮询重试）

## 阶段 D：验证与发布准备（1 天）

交付：

1. e2e：启动服务 -> 扫码授权 -> start session -> send message -> pause/resume -> abort
2. 文档更新（使用说明 + 排障）
3. 发布清单与回滚预案

验收：

1. e2e 全绿
2. 主流程无手工 token 步骤

## 8. 风险与应对

1. 风险：扫码链路被重放
- 应对：一次性票据、短 TTL、exchange 后立刻失效

2. 风险：cookie 鉴权引入跨域问题
- 应对：先同源部署；开发态保留 bearer 兼容

3. 风险：现有多模式用户认知切换成本
- 应对：保留 debug 入口，但默认收起并标注“高级模式”

4. 风险：控制接口误触发
- 应对：保留 rate limit + request_id 去重 + 审计追踪

## 9. Done 标准（本轮）

1. 文档与实现都以 `agent session` 为唯一主线
2. 浏览器远程操控电脑 AI 可在无手填 token 条件下完成闭环
3. 控制动作可审计、可重放、可定位
4. 核心链路具备自动化 e2e 验证


# Copilot 指令 — Pi Agent iOS Remote

## 项目概览

iPhone 作为 Pi Agent 的远程终端。三层架构：
- `pi-ios-app/` — SwiftUI 客户端（iOS 16+）
- `pi-ios-extension/` — TypeScript 扩展（Pi Extension API + WebSocket 服务器）
- 通信协议见 `docs/通信协议.md`（JSON over WebSocket，端口 3001）

## 代码规范

### TypeScript（pi-ios-extension）
- 事件字段名用 `args`（不是 `input`）：`tool_execution_*` 事件的参数在 `event.args`
- `tool_execution_end` **没有** `args` 字段，文件路径通过 `toolArgsCache`（`Map<toolCallId, args>`）在 start 缓存、end 提取
- WS 服务器生命周期：`session_start` 启动 / `session_shutdown` 关闭
- 事件推送统一走 `ProtocolHandler.create*()` 生成协议消息，用 `wsServer.broadcast()`
- 修改后务必保持 `export default function (pi)` 的闭合括号（历史教训：缺 `}` 导致 ParseError）

### Swift（pi-ios-app）
- 协议模型在 `Networking/ProtocolMessage.swift`，新增消息类型需同步：
  1. `PiEvent` 枚举
  2. `Payload` 字段（可选字段全为 `nil` 默认）
  3. `WebSocketManager.parse()` 分支
- Session 状态用 `SessionInfo` 模型（`Networking/ProtocolMessage.swift`）
- 通知统一走 `Services/NotificationManager.swift`
- 真机连接需 `Info.plist` 保留 `NSAppTransportSecurity/NSAllowsArbitraryLoads`

## 约定
- 不引入模拟键盘 / 远程桌面方案，一律走 Pi Extension API
- Phase 3 按单设备设计（多设备已取消）
- 协议变更必须同步更新 `docs/通信协议.md`

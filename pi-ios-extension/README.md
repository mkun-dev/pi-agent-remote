# pi-ios 插件 - 让 iPhone 成为 Pi 的远程终端

## 安装（一条命令）

```bash
# 从 git 仓库安装（推荐）
pi install git:github.com/mkun-dev/pi-agent-remote

# 或本地目录安装
pi install D:/Desktop/demo/pi-link/pi-ios-extension
```

## 配置（安装后运行一次）

在 pi 中输入：

```text
/ios-config wss://你的域名 <至少24字符的TOKEN>  # 公网中继（推荐 WSS）
/ios-config local <至少24字符的TOKEN>           # 仅局域网
```

其他用法：

```text
/ios-config                 # 查看脱敏配置
/ios-config off             # 关闭中继，保留 Token 用于安全局域网
```

配置保存在 `~/.pi/pi-ios-relay.json`，文件权限尽可能设为 `0600`。Token 不进入仓库或日志。

## 使用

配置后**直接在终端输入 `pi`**：插件自动加载、自动连接中继、iOS 无缝使用。无需 `-e` 和环境变量。

局域网模式同样要求 Token；未配置 Token 时，扩展不会开放 3001 端口。iOS 连接 `ws://<PC IP>:3001` 并填写相同 Token。

**配置优先级**：环境变量 `RELAY_URL` + `RELAY_TOKEN`（局域网可只设 `PI_IOS_TOKEN`）> `~/.pi/pi-ios-relay.json`。

---

## Phase 3 Session 管理功能说明

- **会话持久化**：`session_start` 时通过 `pi.appendEntry("ios-session", info)` 写入会话状态，重启后仍可恢复
- **断线重连**：iOS 连接后自动发送 `session.resume`，扩展端回复 `session.info`（sessionId / sessionFile / leafId / entries）
- **历史回放**：`session.resume` 时同时回 `session.history`（主分支最近 100 条对话，含 compaction 处理）
- **分支恢复**：`/tree` 导航时通过 `session_tree` 事件广播 `session.update` 给 iOS
- **会话切换**：`/new`、`/resume`、`/fork` 时通过 `session_start` / `session_info_changed` 事件广播更新

### 协议消息

| 消息 | 方向 | 说明 |
|------|------|------|
| `session.info` | Pi → iOS | 完整会话信息（响应 resume 请求） |
| `session.update` | Pi → iOS | 会话变化通知（启动/切换/改名/分支导航） |
| `session.history` | Pi → iOS | 对话历史回放（随 resume 发送） |
| `session.resume` | iOS → Pi | 请求恢复会话 |

### 调试命令

在 Pi TUI 中执行 `/ios-session` 查看当前会话信息。

---

## Phase 4 多窗口 / 多会话管理

PC 端打开**多个 Pi 窗口**时，iOS 可以管理会话、选择跟哪个窗口对话：

- **窗口注册**：每个扩展实例用窗口稳定 ID（`win-xxxxxxxx`，进程内生成）连接中继，并上报会话名/工作目录；会话切换不改变窗口 ID
- **目标对话**：iOS 发送的所有消息带 `targetAgentId`，中继路由到指定窗口
- **历史会话列表**：iOS 请求 `session.list` → 扩展用 `SessionManager.list(ctx.cwd)` 列出磁盘上的历史会话 → `session.list_result`
- **切换会话**：iOS 发送 `session.switch { sessionFile }` → 扩展执行 `ctx.switchSession(path)` 让**当前窗口**切到指定历史会话（重启后窗口 ID 不变，iOS 目标不失效）

### 协议消息（Phase 4）

| 消息 | 方向 | 说明 |
|------|------|------|
| `session.list` | iOS → Pi | 请求历史会话列表 |
| `session.list_result` | Pi → iOS | 历史会话列表（path/id/name/cwd/messageCount/firstMessage/modified） |
| `session.switch` | iOS → Pi | 切换当前窗口到指定会话文件 |
| `session.switch_ack` | Pi → iOS | 切换结果（iOS 随后自动 resume 拉新历史） |
| `relay.agents` | 中继 → iOS | 在线窗口完整列表 |
| `relay.agent_join` / `relay.agent_leave` | 中继 → iOS | 窗口上下线增量 |

---

## 已验证闭环（实测日志）

```
📋 Session started (startup): id=019fdc14-... entries=2
✅ pi-ios WebSocket listening on ws://0.0.0.0:3001
📱 iOS client connected (1 total)
🔄 [iOS → Pi] session.resume (sessionId=any)
📤 [Pi → iOS] session.info (sessionId=019fdc14-...)
📤 [iOS → Pi] Forwarding: "用一句话介绍你自己"
📝 流式思考 → 最终回复 → idle
```

---

## Phase 3 剩余项（单设备版）

- ✅ Push 通知（Agent 有回复/完成时通知 iOS）— **已实现（本地通知方案）**
- ⏳ NAT 穿透/服务器中继（iOS 在外网也能连到 PC）

## Phase 3 Push 通知说明

**方案**：iOS 本地通知（`UNUserNotificationCenter`），无需服务器/账号。

- 触发时机：Agent 回复完成（收到 `agent.output` type=message）时
- 仅当 App 不在前台时弹出，避免打扰
- Settings 中有「Test Notification」按钮可验证
- 新增文件：`Services/NotificationManager.swift`

需要我继续实现哪一项？直接告诉我！

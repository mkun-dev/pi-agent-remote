# pi-ios Relay Server — NAT 穿透中继

让 iPhone 在**外网**（4G/5G/其他 WiFi）也能连接 PC 上的 Pi Agent。

```text
iPhone ──wss://域名/?role=client&client_id=xxx + Bearer Token──→ Relay
                                                                    ↑↓
PC Extension ──wss://域名/?role=agent&agentId=xxx + Bearer Token ──┘
```

Relay 进程本身监听内部 `ws://:3002`；公网推荐由 Caddy/Nginx 终止 TLS，只暴露 `wss://`。

## 部署到腾讯云（一次性）

### 1. 上传代码

把 `relay-server/` 目录上传到腾讯云（如 `/opt/pi-relay`）。可用 scp 或宝塔面板。

### 2. 安装 Node.js + 依赖

```bash
cd /opt/pi-relay
# 如果没装 Node.js（Ubuntu/Debian）:
# curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
# sudo apt-get install -y nodejs

npm install   # 只需 ws 包
```

### 3. 生成强 Token

```bash
openssl rand -hex 16    # 生成 32 位十六进制 token，记下来
```

### 4. 启动中继服务（pm2 守护）

```bash
sudo npm install -g pm2
RELAY_TOKEN=<上面生成的token> ALLOW_QUERY_TOKEN=0 pm2 start server.mjs --name pi-relay
pm2 save
pm2 startup    # 开机自启（按提示执行输出的命令）
```

### 5. 公网启用 WSS（推荐）

Relay 保持监听本机 3002，由 Caddy/Nginx 反向代理。例如 Caddy：

```caddyfile
pi.example.com {
    reverse_proxy 127.0.0.1:3002
}
```

公网安全组只开放 443，并把 iOS/Extension Host 改为 `wss://pi.example.com`。如果暂时继续旧 `ws://IP:3002` 部署，功能不会中断，但 Token 和聊天内容仍是明文。

### 6. 验证服务

```bash
curl -s http://<腾讯云IP>:3002/   # 应返回 400/426 之类（说明端口通）
pm2 logs pi-relay                  # 看到 "🚀 pi-ios relay server listening"
```

---

## PC 端配置（pi-ios-extension）

启动扩展时带中继环境变量：

```bash
cd "D:/Desktop/demo/pi-link/pi-ios-extension"
RELAY_URL=wss://<你的域名> RELAY_TOKEN=<token> pi -e src/index.ts
```

看到以下输出即中继连接成功：
```
🔌 中继模式已启用: ws://<腾讯云IP>:3002
✅ 已连接中继服务器: ws://<腾讯云IP>:3002
```

> 局域网模式使用 `PI_IOS_TOKEN=<token>`，无 Token 时 Extension 不会开放本地 3001 端口。

## iOS 端配置

App → Settings：
- **Host**：`wss://你的域名`（旧部署可继续使用 IP）
- **Port**：WSS 通常为 443；旧 WS 部署为 3002
- **Token**：与 Relay/Extension 相同，保存在 iOS Keychain
- Apply & Reconnect

> 局域网模式同样必须填写 Token，Host 填 PC 局域网 IP，Port 填 3001。

## 工作原理

| 角色 | 是谁 | 连接方式 |
|------|------|----------|
| `agent` | PC 扩展（每个 Pi 窗口一个） | 反向连接（发起方是 PC） |
| `client` | iOS App | 正向连接 |

中继服务器校验 token 后：
- iOS 发的消息 → 按 `payload.targetAgentId` 路由到指定窗口 → Pi Agent，并回 `relay.ack` 给 iOS；不带 targetAgentId 则转发给第一个窗口（兼容旧版）
- Pi 的事件 → 转发回 iOS

## 多窗口（Phase 4）

PC 端打开多个 Pi 窗口时，每个窗口是一个 agent，用**窗口稳定 ID**（`win-xxxxxxxx`）注册：

```
PC 窗口A (win-abc12345) ─┐
PC 窗口B (win-def67890) ─┼→ 中继 → iOS 选择目标窗口对话
```

- 扩展连接 URL 只含非敏感元数据：`?role=agent&agentId=win-abc12345&name=...&cwd=...`；Token 放在 `Authorization: Bearer` Header
- client 连接后中继推送 `relay.agents`（完整窗口列表）；窗口上下线推 `relay.agent_join` / `relay.agent_leave` 增量
- iOS 发消息带 `targetAgentId` 指定对话窗口（`agent.input` / `session.resume` / `session.list` / `session.switch`）
- 同 agentId 重复连接（重连/会话切换）时踢旧连接，窗口身份不变

## 可靠性机制

- **心跳**：每 30s `ping`，60s 无 `pong` 响应 → 踢除连接（清理半开连接，防止消息发到死连接）
- **状态通知**：agent 上线/下线时中继推 `relay.status` 给 iOS（iOS 显示"PC 离线"）
- **消息 ACK**：client 消息转发成功后回 `relay.ack{id}`；agent 离线回 `relay.error{id}`（iOS 10s 超时兜底）

## 安全说明

- Relay 未设置有效 Token 或 Token 少于 24 字符时直接拒绝启动
- iOS/Extension 使用 `Authorization: Bearer`，Token 不再出现在 URL
- iOS 使用稳定 `client_id`；可从 App「设置 → 设备 ID」复制，并设置 `RELAY_CLIENT_ID=<id>` 将 Relay 绑定到指定设备
- 同一时间只允许一个 client；其他 `client_id` 不会踢掉已在线设备
- `MAX_PAYLOAD_BYTES` 默认 20 MB，client 另有轻量速率限制
- 共享 Token 是个人单租户安全边界：其下的 Agent/Session 都属于同一用户
- 建议定期轮换 Token，并在确认旧客户端升级后设置 `ALLOW_QUERY_TOKEN=0`
- 中继只转发、不存储消息，也不会在日志打印 Token
- 公网 `ws://` 仍是明文；应配置 TLS 后使用 `wss://`

## 排障

| 现象 | 排查 |
|------|------|
| 扩展连不上中继 | 腾讯云安全组是否放行 3002；token 是否一致 |
| iOS 显示已连但收不到 | PC 扩展是否在运行且中继已连接 |
| iOS 窗口列表为空 | 扩展版本过旧（不带 agentId）；重新部署新 server.mjs |
| 连接被拒 (4001) | Token 缺失或错误 |
| 连接被拒 (4002) | 缺少 role 参数 |
| 连接被拒 (4003) | client_id 无效或不在绑定列表 |
| 连接被拒 (4004) | 已有其他 iOS 设备在线 |

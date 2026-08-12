# Pi Agent iOS Remote

让 iPhone 成为 **Pi Agent 的远程终端** —— 无缝消息交互，不模拟键盘、不用 SSH。

iOS 发消息 → pi-ios Extension → Pi Agent，Pi 的所有事件（消息、Tool、状态、文件变化、会话）实时同步回 iOS。

## ✨ 功能

| 阶段 | 功能 | 状态 |
|------|------|------|
| Phase 1 | 消息闭环：输入/流式思考/最终回复/Tool 输出/状态 | ✅ 实测通过 |
| Phase 2 | 文件变更事件（`file.change`）+ 聊天内可折叠文件摘要/详情 + 文件同步工具（`file_sync`） | ✅ 已实现 |
| Phase 3 | Session 管理（持久化/断线重连/分支恢复）+ Push 通知 | ✅ 实测通过 |
| Phase 3 | NAT 穿透（中继服务器，外网可用） | ✅ 已实现，待云部署 |

## 📦 目录结构

```
pi-link
├── pi-ios-app/            # iOS SwiftUI 客户端
│   ├── PiAgentRemote/     # App 源码
│   ├── project.yml        # XcodeGen 配置（CI 生成 .xcodeproj）
│   ├── SETUP.md           # Xcode 搭建 & 真机验证指南
│   └── SIDELOAD.md        # 无 Mac 云编译 + 侧载安装指南
├── pi-ios-extension/      # Pi 扩展（TypeScript）
│   └── src/               # 扩展入口 / WS 服务器 / 协议 / 类型
├── relay-server/             # NAT 穿透中继服务器（部署到腾讯云）
│   └── server.mjs             # Node.js 中继（token 鉴权）
├── docs/                  # 设计文档
│   ├── 架构.md
│   └── 通信协议.md
└── .github/               # CI（云编译 .ipa）+ Copilot 指令
```

## 🚀 快速开始

### 1. 启动 Pi 扩展（PC / Windows）

```bash
cd pi-ios-extension
pi -e "D:/Desktop/demo/pi-link/pi-ios-extension/src/index.ts"
```

看到以下输出即成功：
```
✅ pi-ios Extension ready (Phase 1 + Phase 2 + Phase 3 Session 管理)
✅ pi-ios WebSocket listening on ws://0.0.0.0:3001
```

### 2. 连接 iOS

| 场景 | 方法 |
|------|------|
| 有 Mac | Xcode 打开 `pi-ios-app` → ⌘R → 模拟器/真机（见 `pi-ios-app/SETUP.md`） |
| 无 Mac | GitHub Actions 云编译 .ipa → Sideloadly 侧载（见 `pi-ios-app/SIDELOAD.md`） |
| 快速测试 | iPhone Safari 访问网页版客户端（如已部署） |

### 3. NAT 穿透（外网连接，可选）

PC 端启动扩展时带中继配置：

```bash
RELAY_URL=wss://<你的域名> RELAY_TOKEN=<token> pi -e src/index.ts
```

iOS Settings：Host=`wss://你的域名` / Port=443 / Token=<token>。旧版 `ws://IP:3002` 部署仍可使用，详见 `relay-server/README.md`。

真机局域网连接也必须配置共享 Token：PC 执行 `/ios-config local <token>`，App 的 Host 填 PC 局域网 IP、Port 填 3001，并填写相同 Token。

## 📄 文档

- [系统架构](docs/架构.md)
- [通信协议](docs/通信协议.md)
- [iOS 搭建与真机验证](pi-ios-app/SETUP.md)
- [无 Mac 侧载安装](pi-ios-app/SIDELOAD.md)
- [NAT 穿透部署](relay-server/README.md)

## 🛠 常用命令

```bash
# 扩展端（pi-ios-extension/）
pi -e src/index.ts          # 启动扩展（监听 3001）
/ios-session                # Pi TUI 内查看当前会话
/ios-send <msg>             # 手动向 Pi 发消息

# 防火墙放行（真机连接必需，管理员 PowerShell）
netsh advfirewall firewall add rule name="pi-ios-ws-3001" dir=in action=allow protocol=TCP localport=3001
```

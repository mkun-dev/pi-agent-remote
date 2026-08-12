# PiAgentRemote - Xcode Setup & Real Device Guide

## Option A: Quickest (Recommended)

1. On your Mac, create a new project:
   - Xcode → File → New → Project → iOS → App
   - Product Name: `PiAgentRemote`
   - Interface: SwiftUI
   - Language: Swift
   - Storage: None (no Core Data)

2. Delete the generated files:
   - Delete `ContentView.swift`
   - Delete `PiAgentRemoteApp.swift` (keep the project)

3. Copy everything from this folder into your project:
   ```
   PiAgentRemote/          ← drag the whole folder into Xcode
   ```
   ⚠️ **重要**：`PiAgentRemote/Info.plist` 已包含 ATS 放行配置（真机连接必需），
   复制时选择 "Copy items if needed"，然后用它**替换** Xcode 自动生成的 Info.plist
   （或在 Xcode Target → Info 中手动添加下述键）。

4. In the file picker:
   - Check "Create folder references" or just "Add to target"
   - Make sure all `.swift` files are added to the app target

5. **真机签名（必须）**：
   - Xcode → 项目 → TARGETS → Signing & Capabilities
   - Team: 选择你的 Apple ID（免费个人团队即可，无需付费）
   - Bundle Identifier: 改成唯一值（如 `com.yourname.piagentremote`）
   - 连接 iPhone，Xcode → Devices 确认已识别
   - 若弹出 "untrusted developer"，在 iPhone 上：设置 → 通用 → VPN与设备管理 → 信任

6. Build & Run (⌘R) → 选择你的 iPhone

## Option B: Open as Package (for testing)

Some people open the `PiAgentRemote` folder directly, but for full iOS app you need a real `.xcodeproj`.

## ⭐ 真机验证完整流程（Phase 1+2+3）

### 第 1 步：PC 端准备（Windows）

```bash
cd "D:/Desktop/demo/pi-link/pi-ios-extension"

# 启动扩展（新窗口，保持运行）
pi -e "D:/Desktop/demo/pi-link/pi-ios-extension/src/index.ts"
```

看到以下输出即为成功：
```
✅ pi-ios Extension ready (Phase 1 + Phase 2 + Phase 3 Session 管理)
📋 Session started (startup): id=... entries=...
✅ pi-ios WebSocket listening on ws://0.0.0.0:3001
```

获取 PC 局域网 IP：
```bash
ipconfig
# 找 "IPv4 地址"（如 192.168.1.105），无线网卡(WLAN)优先
```

### 第 2 步：Windows 防火墙放行 3001 端口（真机连接必需）

```powershell
# 以管理员身份运行 PowerShell：
netsh advfirewall firewall add rule name="pi-ios-ws-3001" dir=in action=allow protocol=TCP localport=3001
```

或：控制面板 → Windows Defender 防火墙 → 高级设置 → 入站规则 → 新建规则 → 端口 TCP 3001 → 允许连接。

### 第 3 步：iPhone 与 PC 连同一 WiFi

### 第 4 步：App 内配置

1. 打开 App → **Settings** 标签
2. Host 改为 PC 的局域网 IP（如 `192.168.1.105`），Port 保持 `3001`
3. 点 **Apply & Reconnect** → 状态变绿 "Connected"

### 第 5 步：逐项验证

| 功能 | 操作 | 预期 |
|------|------|------|
| Phase 1 消息闭环 | Chat 输入 "用一句话介绍你自己" | 流式思考 → 最终回复 → Timeline 状态变化 |
| Phase 2 文件同步 | Chat 输入 "创建一个 test.txt 内容为 hello" | Terminal 看到工具输出，Timeline 出现 📁 modified test.txt |
| Phase 3 Session | 断开 WiFi → 重连 → Settings 看 Session 区 | 自动重连，Request Session Resume 显示会话信息 |
| Phase 3 通知 | App 切后台 → PC 上让 Pi 回复 → 回到 iPhone | 锁屏/通知中心出现 "🤖 Pi 有回复了" 横幅 |

## Connection

Default:
```
ws://localhost:3001
```

**Simulator**: usually works with `localhost`.

**Real iPhone**:
1. Find your PC IP (Windows: `ipconfig`)
2. Open the app → go to **Settings** tab
3. Change Host to your PC IP (e.g. `192.168.1.105`)
4. Tap "Apply & Reconnect"

## Before Running the App

You **must** have the extension running on PC:

```bash
cd D:/Desktop/demo/pi-link/pi-ios-extension
pi -e ./src/index.ts
```

You should see:
```
✅ pi-ios WebSocket listening on ws://0.0.0.0:3001
```

## Common Issues

| 问题 | 解决 |
|------|------|
| 真机连不上 | ① 防火墙放行 3001（见上）② 确认同一 WiFi ③ 用 PC 真实局域网 IP ④ 确认扩展监听 0.0.0.0 |
| 连上秒断 | 扩展进程退出 → 重新启动 pi；或端口被占用 → `taskkill /F /PID <pid>` |
| 编译报 ATS 错误 | Info.plist 必须包含 NSAppTransportSecurity/NSAllowsArbitraryLoads |
| 通知不弹 | 首次启动允许通知权限；Settings 里 Test Notification 验证 |
| 真机部署失败 | 签名 Team 未选 / Bundle ID 冲突 / 设备未信任开发者 |
| 改了扩展代码 | 在 Pi TUI 里输入 `/reload` |

## Project Structure (after adding)

```
PiAgentRemote/
├── Info.plist                  ← ATS 放行 + 通知文案（真机必需）
├── Models/Message.swift
├── Networking/
│   ├── ProtocolMessage.swift
│   └── WebSocketManager.swift
├── Services/
│   └── NotificationManager.swift  ← Phase 3 Push 通知
├── ViewModels/
│   ├── ChatViewModel.swift
│   └── SettingsStore.swift
└── Views/
    ├── ContentView.swift
    ├── ChatView.swift
    ├── TerminalView.swift
    ├── TimelineView.swift
    ├── SettingsView.swift
    └── QuickActionsView.swift

PiAgentRemoteApp.swift   (the @main one, 含 AppDelegate 请求通知权限)
```

## Build Requirements
- iOS 16.0+
- Xcode 15+
- Swift 5.9+
- 真机：Apple ID（免费开发者签名即可）

## Done!

Send a message from the Chat tab. You should see:
- Your message appear
- Pi streaming thinking text
- Final answer
- Status changes in Timeline
- Tool output in Terminal (if any tool was called)

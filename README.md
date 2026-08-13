# Pi Agent Remote

**移动端 AI Coding Agent Remote Companion** —— 让 iPhone 成为 Pi Agent 的远程伴侣。

电脑上运行 Agent 干活，人在外面随时：
- 查看进度与思考过程
- 审阅代码变化与 Diff
- 浏览 Workspace 文件
- 继续与 Agent 协作

不是远程 IDE，不模拟键盘，不依赖 SSH。通过事件驱动协议，把 Pi Agent 的实时状态同步到手机上。

## 使用场景

```
  电脑（运行 Pi Agent）                手机（人在外面）
        │                                 │
   ┌────────────┐                    ┌──────────┐
   │ Pi Runtime │◄─── 实时事件流 ───►│ iOS App  │
   │ + Extension│                    │ (SwiftUI)│
   └────────────┘                    └──────────┘
        │                                 │
   Agent 继续执行                  查看 / 提问 / 审阅
```

典型场景：

- **出门在外**：Agent 在电脑上继续跑任务，手机上实时看到它读到哪、在想什么、改了哪些文件
- **异步协作**：在地铁上看到 Agent 的提问（问卷），直接回答，任务继续
- **代码审阅**：Agent 改完代码，手机上查看 Diff 和文件变化，发现问题随时提问
- **多任务并行**：PC 开多个 Agent 窗口，手机上切换查看不同任务的进度

## 项目特点

- **Remote Agent Control** — 从手机向 Agent 发消息、回答问题，与 PC 上的 Agent 无缝协作
- **Real-time Streaming Chat** — 流式回复、思考过程、Markdown 渲染、代码块
- **Workspace Explorer** — 远程浏览项目文件树、搜索文件、查看文本/图片/Markdown/SVG 预览
- **Diff Review** — Agent 每次文件变更都带增删行统计，可查看变更详情
- **Multi Session** — 多会话管理：切换、历史回放、断线重连恢复
- **Multi Agent** — 多 Agent 窗口在线列表，事件按 Agent 隔离，切换目标
- **Model / Usage 同步** — 实时查看当前模型、上下文占用、token 与费用统计
- **Tool & Trace** — 工具调用卡片（正在执行什么）、Agent 执行轨迹
- **Event-driven Architecture** — 全链路基于统一事件协议，展示层只订阅状态投影
- **Safe Context Isolation** — 内部日志（workspace/model/usage/relay）绝不进入聊天，白名单过滤

## 系统架构

```
┌─────────────┐      WebSocket       ┌──────────────┐
│   iOS App   │◄───────────────────►│ Relay Server │
│  (SwiftUI)  │   wss / ws + token  │ (NAT 中继)   │
└─────────────┘                     └──────┬───────┘
                                           │ WebSocket + token
                                           ▼
                                   ┌──────────────┐
                                   │ Pi Extension │
                                   │ (TypeScript) │
                                   └──────┬───────┘
                                          │ pi hooks / SessionManager
                                          ▼
                                   ┌──────────────┐
                                   │Pi Agent Run- │
                                   │    time     │
                                   └──────────────┘
```

**数据流（iOS 侧）**：

```
RemoteEvent (统一事件协议)
      │
      ▼
ConversationMessageFilter   ← 白名单：conversation / systemEvent / debugLog
      │
      ▼
ConversationStore           ← 单一业务状态源（@Published 状态投影）
      │
      ▼
SwiftUI (Chat / Workspace / Activity / Settings)
```

- **WebSocketManager** 只是传输层：负责连接、重连、心跳，不持有业务状态
- **ConversationStore** 是唯一状态源：所有 RemoteEvent 经它投影为 UI 状态
- **ConversationMessageFilter** 在入口拦截：只允许对话类事件进入消息列表，系统事件只更新状态，调试日志只进 Console

## 核心模块

### Chat

实时流式对话：消息增量渲染 + 权威全文收口；支持 Markdown、代码块、打字机效果；工具调用以卡片折叠展示；Agent 文件变更以独立卡片呈现，可展开 Diff。

### Workspace Explorer

只读远程文件浏览：文件树懒加载、文件名模糊搜索、文件内容预览（文本 / 图片 / Markdown / SVG / 二进制识别）；首页展示最近修改文件；任意文件可「询问 Agent」——附带文件路径上下文发起提问，不传输文件内容。

### Session System

多会话管理：会话列表、切换、历史回放、断线重连后按会话恢复。事件携带会话作用域，切换会话时旧会话的迟到事件被隔离。

### Model / Usage

实时同步当前模型、上下文占用、累计 token 与费用；从手机发起模型切换，成功/失败均有确认回执；状态按事件驱动更新，无本地复制。

### Agent Status

Agent 状态机实时驱动：思考中 / 执行工具 / 流式回复中 / 完成 / 出错，完成或出错后自动回到空闲。

## 技术架构

| 层 | 技术 | 职责 |
|----|------|------|
| **iOS** | SwiftUI · Combine · Starscream (WebSocket) | 展示层；ConversationStore 单一状态源；ConversationMessageFilter 事件过滤；ChatScrollController 滚动状态机 |
| **Extension** | TypeScript · Pi Extension API · ws | 连接 Pi Runtime；监听 pi hooks；转发事件（本地 WS + Relay 双通道）；提供 Workspace / Model / Usage / 会话能力 |
| **Relay** | Node.js · ws | 单租户 NAT 中继；agent / client 双角色；token 认证；心跳保活；消息速率限制 |

iOS 部署目标 iOS 16+；Extension 通过 `pi -e` 加载；Relay 可部署到公网（TLS 由反向代理终止）。

## Event Protocol

事件统一为 `{ id, type, timestamp, payload, scope }`，scope 携带 agentId / sessionId / sessionFile 作用域。

```
RemoteEvent
├── agent.*         用户消息、Agent 功能反馈、状态
├── assistant.*     流式回复（start / delta / end）
├── tool.*          工具调用（start / output / end）
├── file.change     文件变化（created / modified / deleted）
├── workspace.*     文件树 / 文件内容 / 搜索结果 / 错误
├── session.*       会话信息 / 历史 / 列表 / 切换确认
├── model.*         模型列表 / 切换确认
├── usage.*         用量统计
├── questionnaire.* Pi 提问 / 回答回传
├── media.*         图片消息
└── relay.*         中继状态 / 在线 Agent 列表
```

**ConversationMessageFilter**：防御性白名单。只有 `agent.input/output`、`assistant.*`、`tool.*`、`file.change`、`media.image`、`session.history` 允许进入消息列表；`workspace.*`、`model.*`、`usage.*`、`relay.*`、`agent.status`、会话元数据、问卷只更新状态投影；未知事件默认拒绝。**内部日志 ≠ Conversation**，未来新增事件必须显式加入白名单才能出现在聊天中。

## Workspace 设计

文件内容通过 Pi Extension 读取（iOS 不直接访问服务器文件系统），按类型路由到不同预览器：

```
workspace.readFile
      │
      ▼
文件类型识别 (text / image / binary)
      │
      ├── .md / .markdown ──► Markdown 预览
      ├── .svg ─────────────► SVG 渲染
      ├── image ────────────► 图片查看器（全屏）
      ├── text ─────────────► 代码 / 文本查看器
      └── binary ───────────► 二进制提示
```

浏览遵循项目 ignore 规则，搜索与浏览范围一致；单文件大小受限，超大文件不传输。

## 开发运行方式

### 环境要求

- Node.js 18+（Extension / Relay）
- Pi Agent（pi-coding-agent）
- iOS 16+（运行 App）；编译需 Xcode 16+，或使用 GitHub Actions 云编译（无需 Mac）

### 启动 Extension（PC）

```bash
cd pi-ios-extension
pi -e src/index.ts
```

看到 `✅ pi-ios WebSocket listening on ws://0.0.0.0:3001` 即成功。

### 启动 Relay（可选，外网连接）

```bash
cd relay-server
RELAY_TOKEN=<至少24字符> node server.mjs
```

部署建议：pm2 托管 + Caddy/Nginx 终止 TLS；详见 `relay-server/README.md`。

### 编译 iOS App

```bash
# 有 Mac：XcodeGen 生成工程后编译
cd pi-ios-app
xcodegen generate
open PiAgentRemote.xcodeproj

# 无 Mac：推 tag 触发 GitHub Actions 云编译，下载 .ipa 用 Sideloadly 侧载
# 详见 pi-ios-app/SIDELOAD.md
```

### 测试

```bash
# Extension 单测 + 类型检查
cd pi-ios-extension
npm test          # node --test test/*.test.ts
npx tsc --noEmit

# e2e 回归（需本地 Pi 环境）
node test/model-usage-generation-e2e.mjs
node test/regression-model-usage.mjs
node test/workspace-search-regression.cjs

# iOS：CI 自动跑 Debug XCTest（103 用例），或本地 xcodebuild test
```

### 连接配置

iOS App 设置页配置 Host / Port / Token：局域网直连填 PC 的 IP:3001；外网填 Relay 地址并配 Token（同一 Token 用于中继与局域网，不创建第二套认证）。

## Design Principles

- **Single Source of Truth** — ConversationStore 是唯一业务状态源；传输层与 UI 层都不持有业务状态，事件驱动更新，无本地状态复制。
- **Event Driven Architecture** — 全链路以统一事件协议（RemoteEvent）为唯一事实来源；新增能力 = 新增事件类型，展示层只订阅状态投影。
- **Separation of Concerns** — WebSocketManager 只管传输，ConversationStore 只管状态，ChatViewModel 只管 UI 协调，滚动状态由独立状态机管理。
- **Safe Context Isolation** — 日志 ≠ Conversation。内部调试日志只能进入 Console / Debug Panel / File Log，白名单过滤保证系统事件永远不会污染用户聊天。

## 目录结构

```
pi-link
├── pi-ios-app/          # iOS SwiftUI 客户端（App + XCTest）
├── pi-ios-extension/    # Pi 扩展（TypeScript：协议 / WS / Relay / Workspace）
├── relay-server/        # NAT 中继服务器（Node.js + ws）
├── docs/                # 设计文档与专项审计报告
├── test/                # e2e 回归测试
└── .github/             # CI：Debug XCTest + Release IPA 云编译
```

## 文档

- [系统架构](docs/架构.md)
- [通信协议](docs/通信协议.md)
- [日志隔离报告](docs/日志隔离报告.md)
- [iOS 搭建与真机验证](pi-ios-app/SETUP.md)
- [无 Mac 侧载安装](pi-ios-app/SIDELOAD.md)
- [NAT 穿透部署](relay-server/README.md)

## Roadmap

### Completed（v1.0.0）

- Remote Chat：流式回复、Markdown、工具卡片、文件变化卡片
- Workspace Explorer：文件树 / 搜索 / 预览 / 询问 Agent
- Session System：多会话、切换、历史回放、断线恢复
- Model / Usage 实时同步
- 多 Agent 隔离与切换
- 问卷问答、语音输入、图片消息
- 日志隔离与事件白名单过滤
- CI 云编译（无 Mac 出 .ipa）

### Exploring

- **Approval** — 手机端审批 Agent 的高风险操作（写文件、执行命令）
- **Terminal 增强** — 交互式远程终端
- **Task System** — 长任务队列与进度跟踪
- **Relay 多租户** — 设备管理、用量配额、多用户隔离
- **通知增强** — 任务完成推送、会话事件订阅

# PiAgentRemote - Quick Start (5 minutes)

## 1. 启动 PC 端的扩展（必须先做）

```bash
cd "D:/Desktop/demo/pi-link/pi-ios-extension"

# 启动扩展（监听 3001 端口）
pi -e ./src/index.ts
```

看到下面这行就成功了：
```
✅ pi-ios WebSocket listening on ws://0.0.0.0:3001
```

## 2. 创建 iOS 项目

1. 打开 Xcode
2. **File → New → Project → iOS → App**
   - Product Name: `PiAgentRemote`
   - Interface: **SwiftUI**
   - Language: **Swift**
3. 删掉 Xcode 自动生成的两个文件：
   - `ContentView.swift`
   - `PiAgentRemoteApp.swift`

4. 把这个文件夹里的内容拖进 Xcode：
   ```
   PiAgentRemote/          （整个文件夹）
   PiAgentRemoteApp.swift
   ```

   拖入时选择：
   - ✅ Copy items if needed
   - ✅ Create groups
   - 勾选你的 target

5. 直接按 **⌘R** 运行（模拟器或真机）

## 3. 连接设置

- **模拟器**：默认就是 `localhost:3001`，通常直接可用
- **真机**：
  1. 打开 App → 切换到 **Settings** 标签
  2. 把 Host 改成你电脑的局域网 IP（Windows 运行 `ipconfig` 查看）
  3. 点击 **Apply & Reconnect**

## 4. 测试闭环

在 iOS 的 Chat 标签输入：
```
列出当前目录文件
```

或者点击下面的快捷按钮。

你应该能看到：
- 自己的消息立刻出现
- Pi 流式 thinking（橙色）
- 最终回复（白色气泡）
- Terminal 标签里看到工具输出
- Timeline 里看到完整事件时间线

## 常见问题

| 问题 | 解决 |
|------|------|
| 连不上 | 确认 PC 端 `pi -e` 正在运行 |
| 端口被占用 | `taskkill /F /PID <pid>` |
| 真机连不上 | 同一 WiFi + 用 PC 的真实 IP |
| 改了扩展代码 | 在 Pi TUI 里输入 `/reload` |

## 下一步

- 想看更多事件 → 让 Pi 执行带工具的命令（如 `npm test`）
- 想改端口 → Settings 里直接改
- 想持久化会话 → 后面 Phase 2/3 再加

准备好了就运行 Xcode 项目吧！

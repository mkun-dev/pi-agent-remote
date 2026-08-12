# 📱 无 Mac 安装到 iPhone：云编译 .ipa + Sideloadly 侧载

> 完整流程：GitHub Actions（macOS 云）编译 .ipa → Windows 下载 → Sideloadly 签名安装 → 真机验证

## 为什么不能直接装？

iOS App 的编译（生成 .ipa）只能在 macOS/Xcode 上完成。没有 Mac 时用 **GitHub Actions 免费云编译** + **Sideloadly（Windows 侧载工具）** 即可绕过。

## 前提

- GitHub 账号（免费）
- Apple ID（免费个人签名即可，无需 $99 开发者账号）
- Windows 电脑 + USB 数据线 + iPhone
- 免费 Apple ID 签名的 App **7 天过期**，需重新侧载（AltStore 可自动续签）

---

## 第 1 步：推送代码到 GitHub

1. 在 GitHub 上新建仓库（如 `pi-agent-remote`）
2. 把项目推上去（手动执行 git 命令，在 Git Bash 中）：

```bash
cd "D:/Desktop/demo/pi-link"

# 初始化并推送到你的仓库（替换为你的仓库地址）
git init
git add pi-ios-app pi-ios-extension 方案1.md 提示词.md
git commit -m "pi-ios remote: Phase 1+2+3"
git branch -M main
git remote add origin https://github.com/<你的用户名>/pi-agent-remote.git
git push -u origin main
```

> ⚠️ 如果仓库根目录是 `pi-ios-app` 本身，请把
> `.github/workflows/build-ipa.yml` 和 `project.yml` 放到仓库根目录对应位置。

## 第 2 步：触发云编译

GitHub 网页 → 你的仓库 → **Actions** → 左侧 **Build IPA** → **Run workflow** → 确认

（或打 tag 自动触发：`git tag v1.0 && git push origin v1.0`）

等待 5-10 分钟（首次安装依赖较慢）。

## 第 3 步：下载 .ipa

Actions 运行成功后，进入该次运行 → **Artifacts** → 下载 **PiAgentRemote.ipa**

## 第 4 步：Windows 安装 Sideloadly

1. 下载：https://sideloadly.io （Windows 版）
2. 安装 **iTunes**（Windows 商店版或官网版）——Sideloadly 依赖其驱动
3. 运行 Sideloadly

## 第 5 步：侧载到 iPhone

1. iPhone 用 USB 连接电脑
2. iPhone 上弹窗"信任此电脑"→ 信任
3. Sideloadly 界面：
   - 左上角选择你的 iPhone
   - 拖入 `PiAgentRemote.ipa`
   - Apple ID 填你的 Apple ID（首次会要求 App 专用密码，可在 appleid.apple.com 生成）
   - 点 **Start**，等待安装完成
4. iPhone 桌面出现 PiAgentRemote 图标

## 第 6 步：信任开发者

iPhone → 设置 → 通用 → **VPN与设备管理** → 你的 Apple ID → **信任**

## 第 7 步：真机验证

按 [SETUP.md](SETUP.md) 的「真机验证完整流程」：

1. PC 端启动扩展 + 防火墙放行 3001 + `ipconfig` 查 IP
2. iPhone 与 PC 连同一 WiFi
3. App 内 Settings → Host 填 PC 局域网 IP → Apply & Reconnect
4. 逐项验证 Phase 1/2/3

---

## 常见问题

| 问题 | 解决 |
|------|------|
| Actions 编译失败 | 查看 Actions 日志；常见于 project.yml 路径不对（确认在 pi-ios-app/ 下执行 xcodegen） |
| Sideloadly 报 Apple ID 错误 | 用 App 专用密码；或换个 Apple ID（新注册的更稳） |
| 安装后闪退 | 证书问题 → 重新侧载；免费签名 7 天到期需重装 |
| 真机连不上 PC | 防火墙放行 3001 / 同一 WiFi / 用 PC 局域网 IP |
| 想自动续签 | 改用 AltStore（Windows AltServer 常驻，到期自动重签） |

## 备选：AltStore（自动续签）

1. Windows 安装 AltServer：https://altstore.io
2. 用 AltStore 的"安装 .ipa"功能侧载
3. AltServer 常驻运行，App 到期前自动重签

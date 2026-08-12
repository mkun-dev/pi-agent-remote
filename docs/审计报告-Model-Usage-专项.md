# Pi Agent Remote — Model / Usage 专项故障审计报告

> 审计范围：Model（模型列表 / 切换）与 Usage（用量累计 / 展示）全链路。
> 方法：以当前源码为准（不基于旧报告假设），静态逐文件审计 + 7 个重点嫌疑点验证。
> 结论性质：`CONFIRMED` = 源码可直接证明；`NEEDS_RUNTIME_VERIFICATION` = 静态无法完全闭环，需真机/网络环境验证。
> 审计基线 commit：`09a90ef`（v1.0.0，含 throws 修复，工作区另有日志静默未提交改动，不影响本审计）。

---

## 一、真实架构链路（按源码核实）

```
┌─ Extension (pi-ios-extension/src/index.ts) ─────────────────────────────┐
│ 状态源:                                                                    │
│   usageAcc: UsageAccumulator      (turn_end → accumulateUsage 增量累计)   │
│   usageSessionKey: string|null    (session 绑定，防跨 Session 泄漏)       │
│   lastModel: string|null          (最近一次已知模型)                       │
│   sessionProvider / sessionCtx    (scope 与模型来源)                       │
│                                                                           │
│ 事件出口:                                                                  │
│   broadcastUsageInfo() → broadcast() → scopeEvent()                       │
│     (agentId/sessionId/sessionFile 注入 payload)                          │
│     → wsServer.broadcast(局域网) + relay.send(中继)                        │
│   handleUsageRequest / handleModelRequest / handleModelSelect             │
│     → respond(scopeEvent(...))    (emit 包装，同样带 scope)               │
│   sendRelaySnapshot()             (PC→Relay 重连后主动推快照，带 scope)    │
└───────────────┬───────────────────────────────────────────────────────────┘
                │  WebSocket（中继转发 / 局域网直连）
                ▼
┌─ Relay (relay-server/server.mjs) ─────────────────────────────────────────┐
│  inbound(client msg): 校验 payload.targetAgentId → 更新 currentTargetAgentId │
│                       → 转发给目标 agent（agent_offline → relay.error）     │
│  outbound(agent msg): 仅当 agentId === currentTargetAgentId 才转发给 iOS    │
│                       （多窗口防串流：非目标窗口事件直接丢弃）                │
└───────────────┬───────────────────────────────────────────────────────────┘
                │  WebSocket
                ▼
┌─ iOS Transport (WebSocketManager.swift) ─────────────────────────────────┐
│  纯 Transport：解码(RemoteEventDecoder) → onRemoteEvent → Store            │
│  handle() 中 relay.agents → 同步 Transport 层 currentAgentId               │
│  出站：requestUsage/requestModelList/selectModel/session.resume           │
│        均携带 targetAgentId + generation(+selectionRequestId)             │
└───────────────┬───────────────────────────────────────────────────────────┘
                │  RemoteEvent（带 scope / generation / selectionRequestId）
                ▼
┌─ ConversationStore.swift（单一业务状态源）────────────────────────────────┐
│  accept() → shouldIgnore(agent/session scope) → shouldIgnoreStaleGeneration │
│  handleModel  : .list → availableModels；.selectionAcknowledged →          │
│                 currentModel + modelSelectionLock（requestId+generation）  │
│  handleUsage  : usageInfo = value；model 回滚防护（lock 校验）              │
│  handleRelay  : agents → currentAgentId（fallback + reset）                │
│  @Published: availableModels / currentModel / usageInfo /                 │
│              modelPickerRequested / agents / currentAgentId                │
└───────────────┬───────────────────────────────────────────────────────────┘
                │  @Published
                ▼
┌─ SwiftUI（只读展示，无业务 @State 复制）──────────────────────────────────┐
│  ChatView      : ModelPickerView(纯 props，sheet 呈现时从 store 快照)      │
│  AgentStatusHeader : store.currentModel ?? store.usageInfo?.model          │
│  SettingsView  : 直接读 store.usageInfo / store.currentModel               │
│  ChatViewModel : 仅 isSwitchingModel / showModelPicker 两个 UI 协调状态     │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 二、11 个核心问题逐项回答

| # | 问题 | 结论 | 依据 |
|---|------|------|------|
| 1 | Model 来源 | **Extension 权威**：`resolveAvailableModels()`（`sessionCtx.scopedModels` → `modelRegistry`）→ `model.list` 事件；切换 `pi.setModel()` → `model.select_ack`。iOS 只消费事件，不本地猜测 | `index.ts:432-471`；`ConversationStore.handleModel` |
| 2 | Usage 来源 | **Extension 权威**：`usageAcc`（turn_end 增量 `accumulateUsage` + 请求时 `accumulateFromSession` 历史重算）+ `getContextUsage()` 实时上下文 → `usage.info` | `index.ts:127-152,1052-1081` |
| 3 | 作用域（Agent/Session/Pi context/全局） | 所有业务事件带 `scope{agentId, sessionId, sessionFile}`（`scopeEvent`/`withScope`）；iOS `shouldIgnore` 按 agent + session 双重过滤；relay/unknown 事件例外 | `index.ts:70-90`；`ConversationStore.shouldIgnore` |
| 4 | Session A/B 隔离 | **已隔离**：Extension `usageSessionKey` 绑定 session（`maxUsage` 合并而非相加）；iOS `clearSessionScopedProjection` 清空 model/usage；`pendingSessionFile` 屏蔽旧会话迟到事件 | `index.ts:98-130`；`ConversationStore` |
| 5 | 多 Agent 串数据 | **已隔离**：relay 仅转发当前目标窗口事件（`agentId === currentTargetAgentId`）；iOS `shouldIgnore` 丢弃 agentId 不匹配事件；`switchTarget`/fallback 时 `reset()` | `server.mjs:162-168`；`handleRelay` |
| 6 | reconnect/background 旧数据 | **已处理**：断连清空 model/usage（`updateConnectionState(false)`）；`onConnected`/`background-resume` 事件驱动重请求；stale generation 丢弃 | `ChatViewModel.onConnected`；`shouldIgnoreStaleGeneration` |
| 7 | Extension Usage 重复累计 | **无重复**：`accumulateFromSession` 用 `maxUsage(summary, inMemory)` 取每字段 max；`usageSessionKey` 跨 session 自动重算 | `usage-accumulator.ts:maxUsage` |
| 8 | UI stale state | **无业务 @State 复制**：ModelPicker 纯 props、Header/Settings 直接读 store；仅 `isSwitchingModel`/`showModelPicker` 为 UI 协调状态（事件驱动） | `ChatView.swift:391-405,709+`；`SettingsView.swift:155+` |
| 9 | model.select_ack 晚到覆盖 | **已防护**：`selectionRequestId` 匹配 + `modelSelectionLock`（含 generation）阻止旧 usage.info/model 回滚 | `handleModel.selectionAcknowledged`；`handleUsage` |
| 10 | currentAgentId 不同步 | **已修复**：`relay.agents` → Transport 同步；Store `$currentAgentId` sink → `ws.setPreferredTargetAgentId`；`onConnected` 先行恢复 | `WebSocketManager.handle`；`ChatViewModel.bind` |
| 11 | reconnect 请求早于 relay.agents | **已缓解**：`onConnected` 立即发快照请求，携带 store.currentAgentId（断连不清空）→ relay 按 targetAgentId 直接路由；relay.agents 到达后 `agent-bootstrap` 兜底；stale generation 丢弃双份请求的旧响应 | `ChatViewModel`；`ConversationStore.beginSnapshot` |

---

## 三、7 个重点嫌疑点优先验证结果

| # | 嫌疑点 | 判定 | 详细证据 |
|---|--------|------|----------|
| S1 | **固定延迟重请求** | ✅ **已消除（CONFIRMED FIXED）** | 全仓 `asyncAfter`/`Task.sleep` 扫描：无任何 model/usage 固定延时刷新。现存 asyncAfter 均为 UI 兜底（8s 切换中标志、0.3s picker 关闭、5s 会话列表 loading、10s 消息送达超时、图片上传超时）。model/usage 刷新已全部改为事件驱动 `requestTargetSnapshot(reason:)`（connect / first-agent-sync / agent-bootstrap / session-switch / background-resume / manual）。 |
| S2 | **usage/model 无 session scope** | ✅ **已覆盖（CONFIRMED）** | 所有出站事件经 `scopeEvent`/`withScope` 注入 `agentId/sessionId/sessionFile`；`handleClientMessage` 的 `emit` 同样包装 respond 响应（model.list / usage.info / select_ack 均带 scope）。iOS `shouldIgnore` 在有会话身份时丢弃无 scope 事件。 |
| S3 | **model.select_ack 晚到覆盖** | ✅ **已防护（CONFIRMED）** | ① 无 requestId 的 ack 在有 pending 时丢弃；② requestId 不匹配丢弃；③ 孤儿 ack（无 pending 且无 lock）丢弃；④ 成功 ack 建立 `modelSelectionLock(requestId, modelId, generation)`；⑤ `handleUsage` 在 lock 生效且 `generation ≤ lock.generation` 时拒绝 model 回滚。 |
| S4 | **usage 重复累计** | ✅ **无重复（CONFIRMED）** | 唯一累计点是 `turn_end → accumulateUsage`（每 turn 一次）；`accumulateFromSession` 只做 `max(summary, inMemory)` 不累加；`usageSessionKey` 保证跨 session 重算。历史上重复累计根因（add 而非 max）已修复。 |
| S5 | **currentAgentId 不同步** | ✅ **已修复（CONFIRMED）** | 双向同步：relay.agents → Transport（`WebSocketManager.handle`）；Store currentAgentId 变化 → `ws.setPreferredTargetAgentId`（`ChatViewModel.bind`）；`onConnected` 先恢复 store 值再发请求；断连时 Transport 清空但 Store 保留（供重连恢复）。 |
| S6 | **reconnect 请求早于 relay.agents** | ⚠️ **已缓解，留一洞（NEEDS_RUNTIME_VERIFICATION）** | `onConnected` 请求携带 store.currentAgentId；若该窗口断连期间下线 → relay `agent_offline`（relay.error）→ 等 relay.agents fallback 到新窗口 + `$currentAgentId` sink 触发 bootstrap 重请求。链路自愈，但**依赖窗口未下线**；窗口下线场景的完整日志链（agent_offline → fallback → bootstrap）需真机验证。 |
| S7 | **UI 本地 state** | ✅ **无复制（CONFIRMED）** | ModelPickerView 是纯函数组件（models/currentModel 作 props）；AgentStatusHeader/SettingsView 直接 `store.currentModel ?? store.usageInfo?.model`；无 `@State` 缓存业务值。仅 `isSwitchingModel`（8s 超时 + lastModelSelection 双清）、`showModelPicker`（store.modelPickerRequested 驱动）为 UI 协调状态。 |

---

## 四、专项检查

### 4.1 Model 全链路

| 环节 | 检查项 | 结论 |
|------|--------|------|
| 列表获取 | `model.request` → `handleModelRequest` → `resolveAvailableModels()` | ✅ scopedModels 优先、modelRegistry 兜底 |
| 列表消费 | `.list` → `availableModels`；generation 回写 `latestAcceptedModelGeneration`；pending 配对清除 | ✅ |
| 无 generation 的 list | `pendingModelGeneration != nil` 时丢弃 | ✅ 防御性（正常路径不存在无 generation 的 list） |
| 切换触发 | iOS `selectModel` → `beginModelSelection(requestId)` → `ws.selectModel(id, requestId)` | ✅ requestId 全程透传 |
| ack 消费 | requestId 三重校验 + lock 建立 + `currentModel` 更新 | ✅ |
| 失败路径 | `ok=false` → 不建 lock、`lastModelSelection.success=false`、系统日志 | ✅ |
| ack 丢失 | pending 滞留、lock 保持旧值；8s 超时清 isSwitchingModel；UI 回退显示旧模型 | ⚠️ NEEDS_RUNTIME_VERIFICATION（低危，运输层 ack 丢失极罕见） |

### 4.2 Usage 全链路

| 环节 | 检查项 | 结论 |
|------|--------|------|
| 增量累计 | `turn_end` → `accumulateUsage(message.usage)`；`message.model` 缓存 lastModel | ✅ 唯一增量点 |
| 历史重算 | `usage.request`/session 建立 → `accumulateFromSession()` → `maxUsage(summary, inMemory)` | ✅ 单调不减，无重复加 |
| 上下文占比 | `sessionCtx.getContextUsage()` 实时 | ✅ |
| 广播时机 | turn_end（`recalculateFromSession=false` 防覆盖未落盘 turn）；agent_end 同；model.select 成功/会话切换后立即广播 | ✅ |
| 消费 | `handleUsage` → `usageInfo`；model 字段受 lock 防回滚 | ✅ |
| 双端一致性 | Extension 每次广播/响应均经 scopeEvent | ✅ |
| 跨 Session | `usageSessionKey` 变化 → 重算新会话 branch | ✅ |

### 4.3 Session 切换生命周期

- iOS `switchToSession(path)` → `sendSessionSwitch(path)` → Extension `switchSession.withSession` 重置 `lastModel=null` + `resetUsageAccumulator(新key)` + 重绑 `sessionProvider` → `switch_ack(ok)` → iOS `beginSessionSwitch(expectedSessionFile)` 设置 `pendingSessionFile` → `requestTargetSnapshot("session-switch")`（新 generation）→ session.resume/usage.request/model.request → Extension 以新 scope 响应 → iOS `handleSession .info` 的 `pendingMatched` 解除屏蔽。
- 全程无固定延时；快照 generation 保证旧响应被丢弃。
- **已确认**：`handleSession` 中 identity 变化（非 pending 驱动，如 PC 端主动切会话）也会 `clearSessionScopedProjection`，随后 Extension 广播的新 usage.info（无 generation、新 scope）自愈恢复。

### 4.4 Reconnect 顺序

```
断连: WSManager.currentAgentId=nil; Store.currentAgentId 保留; Store model/usage 清空
重连: onConnected → ws.setPreferredTargetAgentId(store.currentAgentId)
      → requestTargetSnapshot("connect")   ← 请求携带旧 target（可能 stale）
relay.agents → Store currentAgentId 校正（fallback）+ reset()（若窗口变化）
$currentAgentId sink → 若 store 仍空 → requestTargetSnapshot("agent-bootstrap")（新 generation）
旧 generation 响应 → shouldIgnoreStaleGeneration 丢弃
```

### 4.5 Background / Foreground

- `handleAppBecameActive()`：已连接 → `requestTargetSnapshot("background-resume")`（2s 节流）；未连接 → `connect()`。
- 断连期间后台事件无丢失路径（事件在重连后由快照 + `sendRelaySnapshot` 双保险恢复）。

### 4.6 多 Agent 路由

- relay 出站只转发 `currentTargetAgentId` 窗口（多窗口防串流）；
- iOS 出站全部携带 `targetAgentId`；
- `switchTarget` → `setCurrentAgentId` + `reset()` + 快照 → relay 通过首个携带新 target 的请求更新 `currentTargetAgentId`；
- `relay.agent_leave` → 窗口离开 → Store fallback + reset；Transport 侧 `agent_leave` 处理为空操作（依赖 relay.agents 兜底）——**注意**：Transport 的 `agent_leave` 分支只注释未实现，但 Store 的 `handleRelay(.agentLeft)` 已正确 fallback，且 relay 同时会推 `relay.agents`，功能闭环。

### 4.7 RemoteEvent 作用域过滤（shouldIgnore 全分支）

| 分支 | 行为 | 判定 |
|------|------|------|
| relay/unknown | 不过滤 | ✅ |
| 有 currentAgentId 但事件无 agent scope | 丢弃 | ✅ |
| event.agentId ≠ currentAgentId | 丢弃 | ✅ |
| session 事件（pendingSessionFile 或已有 identity 时）无 scope | 丢弃 | ✅ |
| pendingSessionFile 期间 event.sessionFile ≠ expected | 丢弃 | ✅ |
| pendingSessionFile 期间 event 无 sessionFile 且无 sessionId | 丢弃 | ✅ |
| 非 pending 时 sessionId/sessionFile 与当前不一致 | 丢弃 | ✅ |
| **pendingSessionFile 期间 event 有 sessionId 但无 sessionFile** | **放行**（潜在洞，见 Bug B3） | ⚠️ |

### 4.8 Store 状态清单（Model/Usage 相关）

`isConnected / connectionStatus / currentSnapshotGeneration / pendingUsageGeneration / pendingModelGeneration / latestAcceptedUsageGeneration / latestAcceptedModelGeneration / availableModels / currentModel / usageInfo / modelPickerRequested / agents / currentAgentId / lastModelSelection` + 私有 `pendingModelSelectionRequestId / modelSelectionLock`。全部 `@Published private(set)`（除 modelPickerRequested 为 UI 触发入口），单一数据源成立。

### 4.9 日志增强现状

`[MODEL]` / `[USAGE]` / `[SESSION]` / `[SNAPSHOT]` / `[STORE]` / `[EVENT]` / `[AGENT]` 前缀全覆盖：请求发出、响应接收、stale 丢弃、rollback 拦截、agent 校正、generation 开始/接受。真机可用 `#if DEBUG` 日志直接追踪每一条 model/usage 事件的来去。

### 4.10 Race Condition 审计

| 竞态 | 防护 | 判定 |
|------|------|------|
| 旧 response 覆盖新 state | generation 单调递增 + stale 丢弃 | ✅ |
| 并发 refresh（connect + agents + bootstrap 双快照） | 新 generation 胜出，旧响应丢弃；仅冗余流量 | ✅（低危冗余） |
| select_ack 晚到 | requestId + lock | ✅ |
| usage.info(model=旧) 回滚 | lock + generation 比较 | ✅ |
| 会话切换迟到事件 | pendingSessionFile 屏蔽 | ✅ |
| 窗口下线竞态 | relay.error → fallback → bootstrap | ⚠️ 需真机 |

---

## 五、Bug 列表

### CONFIRMED（源码可直接证明，均为低危/非阻断）

| ID | 严重度 | 描述 | 影响 | 建议 |
|----|--------|------|------|------|
| B1 | 低 | `ChatViewModel.didInitialModelSync` 标志永不重置：agent 切换后 `$agents` sink 不再触发首次同步（已被 `$currentAgentId` bootstrap + onConnected 快照覆盖，冗余但无害） | 每次 agent 切换多发一轮快照（≈4 条请求 + 响应被丢弃） | 重命名为 `lastSyncedAgentId` 或在 switchTarget 时重置；或直接删除该 sink |
| B2 | 低 | `switchTarget(to:)` 触发双快照：`setCurrentAgentId` 的 sink 与 `switchTarget` 内显式 `requestTargetSnapshot` 各发一轮 | 冗余网络流量；无状态污染（generation 丢弃旧响应） | 去掉 sink 中 bootstrap 条件，或 switchTarget 不再显式请求 |
| B3 | 低 | `shouldIgnore` pendingSessionFile 分支：event 有 `sessionId` 但无 `sessionFile` 时放行，可能让旧会话（仅 id 无文件）事件在切换窗口期进入 | 极小概率 UI 短暂串入旧会话消息 | 改为：pending 期间要求 `sessionFile == expected || sessionId == 新会话 id` 才放行 |
| B4 | 信息 | Transport `relay.agent_leave` 分支为空实现（仅注释） | 无实际影响（Store `handleRelay(.agentLeft)` 已 fallback；relay 也会推 relay.agents） | 可删除空分支或补注释说明 |

### NEEDS_RUNTIME_VERIFICATION（静态无法闭环，需真机日志）

| ID | 严重度 | 场景 | 验证方法 |
|----|--------|------|----------|
| N1 | 中 | 断连期间当前目标窗口下线：重连后 `onConnected` 请求携带 stale target → `relay.error agent_offline` → 依赖 relay.agents fallback + bootstrap 自愈 | 真机断开→杀掉 PC 窗口→重连，观察 `[EVENT]`/`[SESSION]`/`[SNAPSHOT]` 日志链 |
| N2 | 中 | turn_end 重复触发（Pi 重试/重复事件）→ `accumulateUsage` 同 turn 加两次；随后 `accumulateFromSession` 取 max 时 in-memory 更大 → 数值偏高一次 | 观察 Extension 日志中 `turn_end` 是否对同一 messageId 出现两次 |
| N3 | 低 | model.select_ack 在 relay 层丢失 → 无任何重试；UI 静默回退旧模型 | 抓包/`[MODEL]` 日志确认 ack 到达率 |
| N4 | 低 | 新会话无 sessionId 且无 sessionFile 的极端场景 → pendingSessionFile 永不解除，会话事件被永久屏蔽 | 临时会话（无文件）切换测试 |
| N5 | 信息 | 多窗口下非目标窗口的 turn_end/usage.info 被 relay 丢弃后，切回该窗口是否立即补齐（依赖快照请求） | 双窗口轮换测试 |

---

## 六、修复优先级

| 优先级 | Bug | 理由 |
|--------|-----|------|
| P2 | N1（stale target 自愈验证） | 唯一可能产生"连接成功但模型/用量为空"的路径，需真机确认自愈 |
| P3 | B1、B2（冗余双快照） | 无状态污染，仅流量浪费；可顺手清理 |
| P3 | B3（pending 放行洞） | 极低频；修复成本一行，值得顺手做 |
| P4 | B4、N2、N3、N4、N5 | 信息级/验证级，不阻断 |

---

## 七、建议修改文件（如后续修复）

| 文件 | 改动 |
|------|------|
| `pi-ios-app/PiAgentRemote/ViewModels/ChatViewModel.swift` | 删/重置 `didInitialModelSync`；精简 switchTarget 双快照 |
| `pi-ios-app/PiAgentRemote/ViewModels/ConversationStore.swift` | `shouldIgnore` pendingSessionFile 分支收紧（B3） |
| `pi-ios-app/PiAgentRemote/Networking/WebSocketManager.swift` | 删除空 `agent_leave` 分支或补实现（B4） |
| `pi-ios-extension/src/index.ts` | 无改动（本审计未发现 Extension 侧缺陷） |
| `relay-server/server.mjs` | 无改动 |

---

## 八、测试方案

### 已覆盖（现有测试）
- `PiAgentRemoteTests/ModelUsageStateTests.swift`：列表、成功/失败 ack、usage 覆盖、断连清空、stale generation、rollback 防护（6+ 用例）
- `PiAgentRemoteTests/ConversationStoreTests.swift`：session 切换清空 model/usage、stale model.list 丢弃、scope 隔离
- `test/model-usage-generation-e2e.mjs`：**13/13 通过**（generation 全链路、selectionRequestId 透传、跨 agent 隔离）
- `test/regression-model-usage.mjs`：15/15 通过

### 建议补充
1. **Unit（iOS）**：`shouldIgnore` pendingSessionFile + sessionId-only 事件放行/收紧用例（B3）
2. **E2E（Node）**：`switchTarget` 双快照下 stale 响应被丢弃的 wire 级断言
3. **真机清单**：N1 场景（杀窗口重连）、N2 场景（重复 turn_end 观察）、模型切换 ack 到达率

---

## 九、最终结论

| 维度 | 结论 | 依据 |
|------|------|------|
| **Model：Agent-safe** | ✅ **是** | scope 过滤 + relay 目标窗口转发 + switch/reset；select_ack 三重防回滚 |
| **Model：Session-safe** | ✅ **是** | clearSessionScopedProjection + pendingSessionFile + generation；remote 会话变更可自愈 |
| **Model：Reconnect-safe** | ✅ **是**（N1 真机待最终确认） | 断连清空 + onConnected 事件驱动重请求 + stale generation 丢弃；自愈链存在 |
| **Usage：Agent-safe** | ✅ **是** | usageSessionKey + maxUsage 合并；多窗口不串数据 |
| **Usage：Session-safe** | ✅ **是** | 跨 session 重算；session.switch 后立即广播权威值 |
| **Usage：Reconnect-safe** | ✅ **是** | sendRelaySnapshot（PC→Relay 重连主动推）+ iOS 快照请求双保险 |
| **总评** | ✅ **可签字稳定**（附 N1 真机验证） | 7 大嫌疑点全部验证；无 P1 级缺陷；残留均为 P2/P3 或需运行环境确认 |

**唯一需要真机关注的残留风险**：N1 —— 断连期间目标窗口下线场景的完整自愈链（agent_offline → fallback → bootstrap）建议在真机上用 `[EVENT] [SESSION] [SNAPSHOT]` 日志走一遍。

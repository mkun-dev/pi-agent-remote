import type { HistoryEntry } from "./types.js";

/**
 * 将 Pi 当前分支投影为 iOS 会话历史。
 * SessionEntry 本身已有稳定 id；同一 SessionEntry 可能拆成正文、Tool、输出多条，
 * 因此在原 id 后追加稳定后缀，而不是在每次 resume 时生成随机 ID。
 */
export function buildHistory(sm: any, max: number = 1000): HistoryEntry[] {
  try {
    // 关键：用完整分支路径（leaf → root），而不是 buildContextEntries()。
    // buildContextEntries 会应用 compaction 截断，只返回最近一次压缩之后的上下文窗口，
    // 导致 UI 看不到完整历史。用户需要看到整条会话分支的所有消息。
    let path: any[] = buildFullSessionPath(sm);
    if (path.length > 1) {
      const firstTs = timestampOf(path[0]?.timestamp);
      const lastTs = timestampOf(path[path.length - 1]?.timestamp);
      if (firstTs > lastTs) path = [...path].reverse();
    }

    const sessionId = String(sm.getSessionId?.() ?? "unknown-session");
    const out: HistoryEntry[] = [];

    const pushAgentMessage = (
      message: any,
      ts: number,
      sourceEntryId: string
    ): void => {
      if (!message || typeof message !== "object") return;

      const push = (
        role: HistoryEntry["role"],
        text: string,
        suffix: string
      ): void => {
        const value = String(text ?? "").trim();
        if (!value) return;
        out.push({
          entryId: `${sourceEntryId}:${suffix}`,
          sessionId,
          role,
          text: value.slice(0, 4000),
          ts
        });
      };

      if (message.role === "user") {
        const text = typeof message.content === "string"
          ? message.content
          : Array.isArray(message.content)
            ? message.content
                .filter((block: any) => block?.type === "text")
                .map((block: any) => block.text)
                .join("")
            : "";
        push("user", text, "user");
        return;
      }

      if (message.role === "assistant") {
        const blocks = Array.isArray(message.content) ? message.content : [];
        const text = blocks
          .filter((block: any) => block?.type === "text")
          .map((block: any) => block.text)
          .join("");
        push("assistant", text, "assistant");
        blocks.forEach((toolCall: any, blockIndex: number) => {
          if (toolCall?.type !== "toolCall") return;
          const args = typeof toolCall.arguments === "string"
            ? toolCall.arguments
            : JSON.stringify(toolCall.arguments ?? {});
          const toolIdentity = String(toolCall.id ?? toolCall.toolCallId ?? blockIndex);
          push("tool", `${toolCall.name ?? "tool"} ${args}`, `tool:${toolIdentity}`);
        });
        return;
      }

      if (message.role === "toolResult") {
        const text = typeof message.content === "string"
          ? message.content
          : Array.isArray(message.content)
            ? message.content
                .filter((block: any) => block?.type === "text")
                .map((block: any) => block.text)
                .join("")
            : "";
        push("terminal", text, "terminal");
        return;
      }

      if (message.role === "bashExecution") {
        if (message.command) push("tool", `bash ${message.command}`, "bash-tool");
        if (message.output) push("terminal", message.output, "bash-output");
      }
    };

    path.forEach((entry, entryIndex) => {
      const ts = timestampOf(entry?.timestamp);
      const sourceEntryId = typeof entry?.id === "string" && entry.id
        ? entry.id
        : `legacy-entry-${entryIndex}`;

      if (entry?.type === "message" && entry.message) {
        pushAgentMessage(entry.message, ts, sourceEntryId);
      } else if (entry?.type === "compaction") {
        // 压缩点：作为独立分隔卡片发给 iOS，UI 用特殊颜色高亮。
        // 旧格式可能带 retainedTail（已在下方兼容），新格式仅存 summary。
        const summary = String(entry.summary ?? entry.compactionSummary ?? "").trim();
        if (summary) {
          out.push({
            entryId: `${sourceEntryId}:compaction`,
            sessionId,
            role: "compaction",
            text: summary.slice(0, 4000),
            ts
          });
        }
        if (Array.isArray(entry.retainedTail)) {
          // 兼容旧 Session 格式中的 retainedTail；使用 compaction id + 数组位置保持稳定。
          entry.retainedTail.forEach((message: any, tailIndex: number) => {
            pushAgentMessage(message, ts, `${sourceEntryId}:retained:${tailIndex}`);
          });
        }
      }
    });

    const limit = Math.max(0, Math.floor(max));
    return limit === 0 ? out : out.slice(-limit);
  } catch (error) {
    console.error("❌ buildHistory failed:", error);
    return [];
  }
}

function timestampOf(value: unknown): number {
  const timestamp = new Date((value as string | number | Date | undefined) ?? 0).getTime();
  return Number.isFinite(timestamp) ? timestamp : 0;
}

/**
 * 遍历完整会话分支路径（leaf → root），不应用 compaction 截断。
 * 复刻 SessionManager 内部 buildSessionPath 逻辑，因为该函数未导出。
 * 返回按时间正序排列的全部条目（含被 compaction 压缩掉的旧消息）。
 */
function buildFullSessionPath(sm: any): any[] {
  try {
    const entries: any[] = sm.getEntries?.() ?? [];
    const leafId = sm.leafId;
    const byId: Map<string, any> = sm.byId ?? new Map();
    if (!entries.length) return [];

    let leaf: any;
    if (leafId) leaf = byId.get(leafId);
    if (!leaf) leaf = entries[entries.length - 1];
    if (!leaf) return [];

    const path: any[] = [];
    let current: any = leaf;
    while (current) {
      path.push(current);
      current = current.parentId ? byId.get(current.parentId) : undefined;
    }
    path.reverse();
    return path;
  } catch (error) {
    console.error("❌ buildFullSessionPath failed:", error);
    return [];
  }
}

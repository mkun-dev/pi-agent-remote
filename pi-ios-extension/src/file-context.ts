/**
 * Workspace 文件上下文注入：把 iOS「询问Agent」附带的文件路径注入到消息文本前，
 * 让 Pi Agent 知道用户在讨论哪个文件。仅注入路径与可选选区，不复制文件内容
 * （内容由 Agent 按需用 read 工具拉取）。
 */

export interface FileMessageContext {
  workspaceFiles?: unknown;
  selection?: unknown;
}

/**
 * @param text 用户原始消息
 * @param context 来自 agent.input.payload.context
 * @returns 注入上下文块后的文本（无上下文则原样返回）
 */
export function injectFileContext(text: string, context: unknown): string {
  if (!context || typeof context !== "object") return text;
  const ctx = context as FileMessageContext;
  const files = Array.isArray(ctx.workspaceFiles)
    ? ctx.workspaceFiles.filter(
        (f): f is string => typeof f === "string" && f.trim().length > 0,
      )
    : [];
  if (files.length === 0) return text;
  const lines: string[] = ["📁 文件上下文（来自 iOS Workspace）"];
  for (const f of files) lines.push(`- ${f}`);
  const sel =
    typeof ctx.selection === "string" && ctx.selection.trim()
      ? ctx.selection.trim()
      : null;
  if (sel) lines.push(`[选区] ${sel}`);
  return `${lines.join("\n")}\n\n${text}`;
}

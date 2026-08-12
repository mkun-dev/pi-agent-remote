export interface ExtensionEvent {
  id: string;
  type: string;
  timestamp: number;
  payload: any;
}

export type ProtocolMessage = {
  id?: string;
  type: string;
  timestamp?: number;
  payload: any;
};

export type ClientToServer = {
  type: "agent.input" | "session.resume" | "session.list" | "session.switch" | "usage.request" | "model.request" | "model.select" | "questionnaire.answer" | "questionnaire.sync" | "media.upload" | "workspace.list" | "workspace.readFile" | "workspace.search";
  payload: {
    text?: string;
    sessionId?: string;
    sessionFile?: string; // session.switch 目标会话文件路径
    modelId?: string;     // model.select 目标模型
    generation?: number;
    selectionRequestId?: string;
    answers?: unknown[];  // questionnaire.answer
    fileName?: string;    // media.upload
    base64?: string;
    dir?: string;
    path?: string;        // workspace.list / workspace.readFile 目标路径
    query?: string;       // workspace.search 搜索关键词
    context?: {           // agent.input 附带的文件上下文（Workspace「询问Agent」）
      workspaceFiles: string[];
      selection?: string;
    };
  };
};

export type SessionInfo = {
  sessionId: string | null;
  sessionFile: string | null;
  name: string | null;
  leafId: string | null;
  entryCount: number;
  reason: string | null;
};

/** 历史会话条目（session.history，Phase 3.5）——iOS 端可直接渲染的简化结构 */
export type HistoryEntry = {
  /** Pi SessionEntry.id + 同一条目内的内容后缀，跨重连稳定。 */
  entryId: string;
  /** 所属 Pi session，避免切换会话后 ID 冲突。 */
  sessionId: string;
  role: "user" | "assistant" | "tool" | "terminal";
  text: string;
  ts: number; // Unix 毫秒
};

/** 历史会话列表项（session.list_result）——SessionManager.list() 的简化结构 */
export type SessionListItem = {
  path: string;          // session 文件路径
  id: string;            // sessionId
  name: string | null;   // 显示名
  cwd: string | null;    // 工作目录
  messageCount: number;
  firstMessage: string;
  modified: number;      // Unix 毫秒
};

/** 模型与用量信息（usage.info）——iOS 端展示 */
export type UsageInfo = {
  generation?: number;
  model: string | null;          // 当前模型 ID
  contextTokens: number | null;  // 上下文已用 tokens
  contextWindow: number;         // 上下文窗口大小
  contextPercent: number | null; // 上下文占比（0-100）
  totalInput: number;            // 累计输入 tokens
  totalOutput: number;           // 累计输出 tokens
  totalCacheRead: number;        // 缓存命中（读）
  totalCacheWrite: number;       // 缓存写入
  totalReasoning: number;        // 思考 tokens
  totalTokens: number;           // 累计总 tokens
  totalCost: number;             // 累计费用（美元）
};

/** 工作区文件树节点（workspace.tree）——iOS 端渲染文件树 */
export type WorkspaceNode = {
  name: string;
  path: string;               // 相对项目根路径（/ 分隔）
  type: "file" | "directory";
  children?: WorkspaceNode[]; // 仅 directory 且已展开时携带
};

/** 工作区文件内容（workspace.file） */
export type WorkspaceFileContent = {
  path: string;
  fileType: "image" | "text" | "binary";
  size: number;               // 字节数
  mimeType?: string;
  content?: string;           // 文本文件
  base64?: string;            // 图片文件（二进制安全）
};

/** 工作区搜索结果项（workspace.searchResult） */
export type WorkspaceSearchHit = {
  path: string;
  filename: string;
  type: "file" | "directory";
};

export type ServerToClient = {
  type: "agent.output" | "assistant.start" | "assistant.delta" | "assistant.end" | "tool.start" | "tool.output" | "tool.end" | "agent.status" | "file.change" | "session.info" | "session.update" | "session.history" | "session.list_result" | "session.switch_ack" | "usage.info" | "model.list" | "model.select_ack" | "questionnaire.show" | "questionnaire.answered" | "media.image" | "workspace.tree" | "workspace.file" | "workspace.error" | "workspace.searchResult";
  payload: any;
};

export type EventType = "agent.input" | "agent.output" | "assistant.start" | "assistant.delta" | "assistant.end" | "tool.start" | "tool.output" | "tool.end" | "agent.status" | "file.change" | "session.info" | "session.update" | "session.history" | "session.list" | "session.list_result" | "session.switch" | "session.switch_ack" | "session.resume" | "usage.request" | "usage.info" | "model.list" | "model.select" | "model.select_ack" | "questionnaire.show" | "questionnaire.answer" | "questionnaire.answered" | "questionnaire.sync" | "media.upload" | "media.image" | "workspace.list" | "workspace.readFile" | "workspace.search" | "workspace.tree" | "workspace.file" | "workspace.error" | "workspace.searchResult";

export const isProtocolMessage = (msg: unknown): msg is ProtocolMessage => {
  return typeof msg === "object" && msg !== null && "type" in msg;
};
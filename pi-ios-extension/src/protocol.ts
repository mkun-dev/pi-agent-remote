import { randomUUID } from "node:crypto";
import type { ProtocolMessage, ClientToServer, ServerToClient, EventType, SessionInfo, HistoryEntry, SessionListItem, UsageInfo, WorkspaceNode, WorkspaceFileContent } from "./types.js";

export type EventScope = {
  agentId?: string | null;
  sessionId?: string | null;
  sessionFile?: string | null;
};

/**
 * 生成时间戳 + 随机后缀的 id，防止同一毫秒多条事件 id 碰撞导致 iOS 端去重丢消息。
 * thinking 增量、tool.output、agent.output 等高频工厂都依赖它。
 */
function uid(): string {
  return `${Date.now()}_${randomUUID().slice(0, 8)}`;
}

export function withScope<T extends ProtocolMessage>(message: T, scope?: EventScope): T {
  if (!scope) return message;
  return {
    ...message,
    payload: {
      ...(message.payload ?? {}),
      ...(scope.agentId ? { agentId: scope.agentId } : {}),
      ...(scope.sessionId ? { sessionId: scope.sessionId } : {}),
      ...(scope.sessionFile ? { sessionFile: scope.sessionFile } : {})
    }
  };
}

export class ProtocolHandler {
  static createInput(text: string): ProtocolMessage {
    return {
      id: `input_${uid()}`,
      type: "agent.input",
      timestamp: Date.now(),
      payload: { text }
    };
  }

  static createAgentOutput(text: string, type: "message" | "thinking" = "message"): ProtocolMessage {
    return {
      id: `output_${uid()}`,
      type: "agent.output",
      timestamp: Date.now(),
      payload: { text, type }
    };
  }

  static createAssistantStart(messageId: string): ProtocolMessage {
    return {
      id: `assistant_start_${messageId}`,
      type: "assistant.start",
      timestamp: Date.now(),
      payload: { messageId }
    };
  }

  static createAssistantDelta(messageId: string, text: string, seq?: number): ProtocolMessage {
    return {
      id: `assistant_delta_${messageId}_${seq ?? uid()}`,
      type: "assistant.delta",
      timestamp: Date.now(),
      payload: { messageId, text, seq }
    };
  }

  static createAssistantEnd(messageId: string, text?: string): ProtocolMessage {
    return {
      id: `assistant_end_${messageId}`,
      type: "assistant.end",
      timestamp: Date.now(),
      payload: { messageId, text }
    };
  }

  static createToolStart(tool: string, command: string, toolCallId?: string): ProtocolMessage {
    return {
      id: `tool_start_${uid()}`,
      type: "tool.start",
      timestamp: Date.now(),
      payload: { tool, command, toolCallId }
    };
  }

  static createToolOutput(data: string): ProtocolMessage {
    return {
      id: `tool_output_${uid()}`,
      type: "tool.output",
      timestamp: Date.now(),
      payload: { data }
    };
  }

  static createToolEnd(success: boolean, toolCallId?: string): ProtocolMessage {
    return {
      id: `tool_end_${uid()}`,
      type: "tool.end",
      timestamp: Date.now(),
      payload: { success, toolCallId }
    };
  }

  static createStatus(
    status: string,
    details?: { tool?: string; description?: string }
  ): ProtocolMessage {
    return {
      id: `status_${uid()}`,
      type: "agent.status",
      timestamp: Date.now(),
      payload: { status, ...details }
    };
  }

  static createFileChange(
    path: string,
    action: "modified" | "created" | "deleted",
    stats?: { additions?: number; deletions?: number }
  ): ProtocolMessage {
    return {
      id: `file_${uid()}`,
      type: "file.change",
      timestamp: Date.now(),
      payload: { path, action, ...stats }
    };
  }

  static createSessionInfo(info: SessionInfo): ProtocolMessage {
    return {
      id: `session_${uid()}`,
      type: "session.info",
      timestamp: Date.now(),
      payload: { ...info }
    };
  }

  static createSessionUpdate(reason: string, info: SessionInfo): ProtocolMessage {
    return {
      id: `session_${uid()}`,
      type: "session.update",
      timestamp: Date.now(),
      payload: { ...info, reason }
    };
  }

  static createSessionResume(sessionId?: string): ProtocolMessage {
    return {
      id: `session_${uid()}`,
      type: "session.resume",
      timestamp: Date.now(),
      payload: { sessionId }
    };
  }

  static createSessionHistory(entries: HistoryEntry[], sessionId?: string | null): ProtocolMessage {
    return {
      id: `session_${uid()}`,
      type: "session.history",
      timestamp: Date.now(),
      payload: { sessionId: sessionId ?? null, entries }
    };
  }

  static createSessionListResult(items: SessionListItem[]): ProtocolMessage {
    return {
      id: `session_${uid()}`,
      type: "session.list_result",
      timestamp: Date.now(),
      payload: { sessions: items }
    };
  }

  static createSessionSwitchAck(path: string, ok: boolean): ProtocolMessage {
    return {
      id: `session_${uid()}`,
      type: "session.switch_ack",
      timestamp: Date.now(),
      payload: { sessionFile: path, ok }
    };
  }

  static createUsageInfo(info: UsageInfo, generation?: number): ProtocolMessage {
    return {
      id: `usage_${uid()}`,
      type: "usage.info",
      timestamp: Date.now(),
      payload: { ...info, ...(generation !== undefined ? { generation } : {}) }
    };
  }

  static createModelList(models: string[], generation?: number): ProtocolMessage {
    return {
      id: `model_${uid()}`,
      type: "model.list",
      timestamp: Date.now(),
      payload: { models, ...(generation !== undefined ? { generation } : {}) }
    };
  }

  static createModelSelectAck(modelId: string, ok: boolean, message?: string, selectionRequestId?: string): ProtocolMessage {
    return {
      id: `model_${uid()}`,
      type: "model.select_ack",
      timestamp: Date.now(),
      payload: {
        modelId,
        ok,
        ...(selectionRequestId ? { selectionRequestId } : {}),
        message: message ?? (ok ? `✅ 已切换到模型: ${modelId}` : `❌ 切换模型失败: ${modelId}`)
      }
    };
  }

  static createQuestionnaireShow(questions: any[]): ProtocolMessage {
    return {
      id: `q_${uid()}`,
      type: "questionnaire.show",
      timestamp: Date.now(),
      payload: { questions }
    };
  }

  static createMediaImage(fileName: string, base64: string): ProtocolMessage {
    return {
      id: `img_${uid()}`,
      type: "media.image",
      timestamp: Date.now(),
      payload: { fileName, base64 }
    };
  }

  static createWorkspaceTree(path: string, name: string, children: WorkspaceNode[]): ProtocolMessage {
    return {
      id: `ws_tree_${uid()}`,
      type: "workspace.tree",
      timestamp: Date.now(),
      payload: { path, name, children }
    };
  }

  static createWorkspaceFile(file: WorkspaceFileContent): ProtocolMessage {
    return {
      id: `ws_file_${uid()}`,
      type: "workspace.file",
      timestamp: Date.now(),
      payload: { ...file }
    };
  }

  static createWorkspaceError(path: string | undefined, message: string): ProtocolMessage {
    return {
      id: `ws_err_${uid()}`,
      type: "workspace.error",
      timestamp: Date.now(),
      payload: { path, message }
    };
  }

  static createWorkspaceSearchResult(query: string, hits: { path: string; filename: string; type: "file" | "directory" }[]): ProtocolMessage {
    return {
      id: `ws_search_${uid()}`,
      type: "workspace.searchResult",
      timestamp: Date.now(),
      payload: { query, hits }
    };
  }

  /**
   * P4 git 式撤回：通知 iOS 已把 leaf 移到目标用户消息之前。
   * rewoundContent 是被撤回的那条用户消息原文（供 iOS 回填输入框）；
   * removedMessageCount 是从本地应删除的用户消息条数（含目标及之后）。
   */
  static createHistoryRewound(rewoundContent: string, removedMessageCount: number): ProtocolMessage {
    return {
      id: `rewind_${uid()}`,
      type: "history.rewound",
      timestamp: Date.now(),
      payload: { text: rewoundContent, removedMessageCount }
    };
  }
}

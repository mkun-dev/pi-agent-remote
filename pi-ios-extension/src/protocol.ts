import type { ProtocolMessage, ClientToServer, ServerToClient, EventType, SessionInfo, HistoryEntry, SessionListItem, UsageInfo, WorkspaceNode, WorkspaceFileContent } from "./types.js";

export type EventScope = {
  agentId?: string | null;
  sessionId?: string | null;
  sessionFile?: string | null;
};

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
      id: `input_${Date.now()}`,
      type: "agent.input",
      timestamp: Date.now(),
      payload: { text }
    };
  }

  static createAgentOutput(text: string, type: "message" | "thinking" = "message"): ProtocolMessage {
    return {
      id: `output_${Date.now()}`,
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
      id: `assistant_delta_${messageId}_${seq ?? Date.now()}`,
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
      id: `tool_start_${Date.now()}`,
      type: "tool.start",
      timestamp: Date.now(),
      payload: { tool, command, toolCallId }
    };
  }

  static createToolOutput(data: string): ProtocolMessage {
    return {
      id: `tool_output_${Date.now()}`,
      type: "tool.output",
      timestamp: Date.now(),
      payload: { data }
    };
  }

  static createToolEnd(success: boolean, toolCallId?: string): ProtocolMessage {
    return {
      id: `tool_end_${Date.now()}`,
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
      id: `status_${Date.now()}`,
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
      id: `file_${Date.now()}`,
      type: "file.change",
      timestamp: Date.now(),
      payload: { path, action, ...stats }
    };
  }

  static createSessionInfo(info: SessionInfo): ProtocolMessage {
    return {
      id: `session_${Date.now()}`,
      type: "session.info",
      timestamp: Date.now(),
      payload: { ...info }
    };
  }

  static createSessionUpdate(reason: string, info: SessionInfo): ProtocolMessage {
    return {
      id: `session_${Date.now()}`,
      type: "session.update",
      timestamp: Date.now(),
      payload: { ...info, reason }
    };
  }

  static createSessionResume(sessionId?: string): ProtocolMessage {
    return {
      id: `session_${Date.now()}`,
      type: "session.resume",
      timestamp: Date.now(),
      payload: { sessionId }
    };
  }

  static createSessionHistory(entries: HistoryEntry[], sessionId?: string | null): ProtocolMessage {
    return {
      id: `session_${Date.now()}`,
      type: "session.history",
      timestamp: Date.now(),
      payload: { sessionId: sessionId ?? null, entries }
    };
  }

  static createSessionListResult(items: SessionListItem[]): ProtocolMessage {
    return {
      id: `session_${Date.now()}`,
      type: "session.list_result",
      timestamp: Date.now(),
      payload: { sessions: items }
    };
  }

  static createSessionSwitchAck(path: string, ok: boolean): ProtocolMessage {
    return {
      id: `session_${Date.now()}`,
      type: "session.switch_ack",
      timestamp: Date.now(),
      payload: { sessionFile: path, ok }
    };
  }

  static createUsageInfo(info: UsageInfo, generation?: number): ProtocolMessage {
    return {
      id: `usage_${Date.now()}`,
      type: "usage.info",
      timestamp: Date.now(),
      payload: { ...info, ...(generation !== undefined ? { generation } : {}) }
    };
  }

  static createModelList(models: string[], generation?: number): ProtocolMessage {
    return {
      id: `model_${Date.now()}`,
      type: "model.list",
      timestamp: Date.now(),
      payload: { models, ...(generation !== undefined ? { generation } : {}) }
    };
  }

  static createModelSelectAck(modelId: string, ok: boolean, message?: string, selectionRequestId?: string): ProtocolMessage {
    return {
      id: `model_${Date.now()}`,
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
      id: `q_${Date.now()}`,
      type: "questionnaire.show",
      timestamp: Date.now(),
      payload: { questions }
    };
  }

  static createMediaImage(fileName: string, base64: string): ProtocolMessage {
    return {
      id: `img_${Date.now()}`,
      type: "media.image",
      timestamp: Date.now(),
      payload: { fileName, base64 }
    };
  }

  static createWorkspaceTree(path: string, name: string, children: WorkspaceNode[]): ProtocolMessage {
    return {
      id: `ws_tree_${Date.now()}`,
      type: "workspace.tree",
      timestamp: Date.now(),
      payload: { path, name, children }
    };
  }

  static createWorkspaceFile(file: WorkspaceFileContent): ProtocolMessage {
    return {
      id: `ws_file_${Date.now()}`,
      type: "workspace.file",
      timestamp: Date.now(),
      payload: { ...file }
    };
  }

  static createWorkspaceError(path: string | undefined, message: string): ProtocolMessage {
    return {
      id: `ws_err_${Date.now()}`,
      type: "workspace.error",
      timestamp: Date.now(),
      payload: { path, message }
    };
  }

  static createWorkspaceSearchResult(query: string, hits: { path: string; filename: string; type: "file" | "directory" }[]): ProtocolMessage {
    return {
      id: `ws_search_${Date.now()}`,
      type: "workspace.searchResult",
      timestamp: Date.now(),
      payload: { query, hits }
    };
  }
}
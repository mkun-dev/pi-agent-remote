import Foundation

/// 迁移期间让旧处理链复用同一次 JSON 解码；新代码只消费 event。
struct RemoteEventDecodingResult {
    let event: RemoteEvent
    let protocolMessage: ProtocolMessage
}

/// 只负责 Wire JSON → 类型化 RemoteEvent；不保存状态、不创建 UI、不更新 View。
enum RemoteEventDecoder {
    static func decode(text: String) -> RemoteEvent? {
        decodeWithCompatibility(text: text)?.event
    }
    
    static func decode(data: Data) -> RemoteEvent? {
        decodeWithCompatibility(data: data)?.event
    }
    
    static func decodeWithCompatibility(text: String) -> RemoteEventDecodingResult? {
        guard let data = text.data(using: .utf8) else { return nil }
        return decodeWithCompatibility(data: data)
    }
    
    static func decodeWithCompatibility(data: Data) -> RemoteEventDecodingResult? {
        guard let message = try? JSONDecoder().decode(ProtocolMessage.self, from: data) else {
            return nil
        }
        return RemoteEventDecodingResult(event: decode(message), protocolMessage: message)
    }
    
    static func decode(_ message: ProtocolMessage) -> RemoteEvent {
        let timestamp = message.timestamp.map {
            Date(timeIntervalSince1970: Double($0) / 1000)
        } ?? Date()
        let eventID = message.id ?? "\(message.type):\(UUID().uuidString)"
        return RemoteEvent(
            id: eventID,
            timestamp: timestamp,
            payload: payload(for: message, eventID: eventID),
            scope: RemoteEvent.Scope(
                agentId: message.payload.agentId,
                sessionId: message.payload.sessionId,
                sessionFile: message.payload.sessionFile.map(normalizeSlashes),
                targetAgentId: message.payload.targetAgentId
            ),
            generation: message.payload.generation,
            selectionRequestId: message.payload.selectionRequestId
        )
    }
    
    private static func payload(for message: ProtocolMessage, eventID: String) -> RemoteEvent.Payload {
        let value = message.payload
        switch message.type {
        case "agent.input":
            return .agent(.input(text: value.text ?? ""))
        case "agent.output":
            return .agent(.output(text: value.text ?? "", isThinking: value.type == "thinking"))
        case "agent.status":
            return .agent(.status(RemoteAgentStatus(
                value: value.status ?? "unknown",
                tool: value.tool,
                description: value.description
            )))
        case "agent.completed":
            // 兼容可能由旧/第三方桥接层发送的独立完成事件；当前 Extension 使用 agent.status=completed。
            return .agent(.status(RemoteAgentStatus(
                value: "completed",
                tool: nil,
                description: value.description
            )))
        case "assistant.start":
            return .assistant(.start(messageId: value.messageId ?? eventID))
        case "assistant.delta":
            return .assistant(.delta(messageId: value.messageId ?? eventID, text: value.text ?? "", seq: value.seq))
        case "assistant.end":
            return .assistant(.end(messageId: value.messageId ?? eventID, text: value.text))
        case "tool.start":
            return .tool(.start(RemoteToolCall(
                id: value.toolCallId ?? eventID,
                name: value.tool ?? "tool",
                input: value.command
            )))
        case "tool.output", "tool.update":
            // 当前协议名称为 tool.output；tool.update 作为兼容别名走同一语义。
            return .tool(.output(data: value.data ?? value.text ?? ""))
        case "tool.end":
            return .tool(.end(
                toolCallId: value.toolCallId ?? eventID,
                success: value.success == true
            ))
        case "file.change":
            let action: RemoteFileEvent.Action
            switch value.action?.lowercased() {
            case "created", "added": action = .created
            case "deleted", "removed": action = .deleted
            default: action = .modified
            }
            return .file(RemoteFileEvent(
                path: value.path ?? "",
                action: action,
                additions: value.additions,
                deletions: value.deletions
            ))
        case "session.info":
            return .session(.info(sessionInfo(value)))
        case "session.update":
            return .session(.update(sessionInfo(value)))
        case "session.history":
            let entries = (value.entries ?? []).compactMap { entry -> RemoteHistoryEntry? in
                guard let role = entry.role, let text = entry.text else { return nil }
                let date = Date(timeIntervalSince1970: Double(entry.ts ?? 0) / 1000)
                return RemoteHistoryEntry(
                    entryId: entry.entryId,
                    sessionId: entry.sessionId,
                    role: role,
                    text: text,
                    timestamp: date
                )
            }
            return .session(.history(sessionId: value.sessionId, entries: entries))
        case "session.list_result":
            return .session(.list((value.sessions ?? []).map {
                RemoteSessionListItem(
                    path: $0.path.map(normalizeSlashes),
                    id: $0.id,
                    name: $0.name,
                    cwd: $0.cwd,
                    messageCount: $0.messageCount,
                    firstMessage: $0.firstMessage,
                    modified: $0.modified.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                )
            }))
        case "session.switch_ack":
            return .session(.switchAcknowledged(
                sessionFile: value.sessionFile,
                success: value.ok == true
            ))
        case "history.rewound":
            return .history(.rewound(
                rewoundContent: value.text ?? "",
                removedUserMessageCount: value.removedMessageCount ?? 1
            ))
        case "usage.info":
            return .usage(RemoteUsageEvent(
                model: value.model,
                contextTokens: value.contextTokens,
                contextWindow: value.contextWindow ?? 0,
                contextPercent: value.contextPercent,
                totalInput: value.totalInput ?? 0,
                totalOutput: value.totalOutput ?? 0,
                totalCacheRead: value.totalCacheRead ?? 0,
                totalCacheWrite: value.totalCacheWrite ?? 0,
                totalReasoning: value.totalReasoning ?? 0,
                totalTokens: value.totalTokens ?? 0,
                totalCost: value.totalCost ?? 0
            ))
        case "model.list":
            return .model(.list(value.models ?? []))
        case "model.select_ack":
            return .model(.selectionAcknowledged(
                modelId: value.modelId ?? "",
                success: value.ok == true,
                message: value.message
            ))
        case "questionnaire.show":
            let questions = (value.questions ?? []).map { question in
                RemoteQuestion(
                    question: question.question,
                    header: question.header,
                    multiSelect: question.multiSelect == true,
                    options: (question.options ?? []).map {
                        RemoteQuestion.Option(
                            label: $0.label,
                            description: $0.description,
                            hasPreview: $0.hasPreview
                        )
                    }
                )
            }
            return .questionnaire(.show(id: message.id, questions: questions))
        case "questionnaire.answered":
            return .questionnaire(.answered(
                source: value.source,
                answers: (value.answers ?? []).map {
                    RemoteQuestionAnswer(
                        question: $0.question,
                        answer: $0.answer,
                        selected: $0.selected,
                        notes: $0.notes
                    )
                }
            ))
        case "media.image":
            return .media(.image(
                fileName: value.fileName ?? "image.png",
                base64: value.base64 ?? ""
            ))
        case "relay.status":
            return .relay(.status(value.status ?? "unknown"))
        case "relay.ack":
            return .relay(.acknowledged(messageId: value.id ?? ""))
        case "relay.error":
            return .relay(.failed(messageId: value.id, code: value.code))
        case "relay.agents":
            return .relay(.agents((value.agents ?? []).compactMap(agentDescriptor)))
        case "relay.agent_join":
            if let agent = value.agent, let descriptor = agentDescriptor(agent) {
                return .relay(.agentJoined(descriptor))
            }
            return .unknown(type: message.type)
        case "relay.agent_leave":
            return .relay(.agentLeft(agentId: value.agentId ?? ""))
        case "workspace.tree":
            return .workspace(.tree(RemoteWorkspaceTree(
                path: normalizeSlashes(value.path ?? ""),
                name: value.name ?? "",
                children: (value.children ?? []).compactMap { child in
                    guard let name = child.name, let path = child.path else { return nil }
                    return RemoteWorkspaceNode(
                        name: name,
                        path: normalizeSlashes(path),
                        type: child.type == "directory" ? .directory : .file
                    )
                }
            )))
        case "workspace.file":
            let normalizedPath = normalizeSlashes(value.path ?? "")
            let decodedType: WorkspaceFileType = {
                switch value.fileType?.lowercased() {
                case "image": return .image
                case "binary": return .binary
                case "text": return .text
                default:
                    if value.base64 != nil { return .image }
                    return (value.content != nil) ? .text : .binary
                }
            }()
            return .workspace(.file(RemoteWorkspaceFile(
                path: normalizedPath,
                type: decodedType,
                content: value.content,
                base64: value.base64,
                size: value.size ?? 0,
                mimeType: value.mimeType
            )))
        case "workspace.error":
            return .workspace(.error(RemoteWorkspaceError(
                path: value.path.map(normalizeSlashes),
                message: value.message ?? "未知错误"
            )))
        case "workspace.searchResult":
            return .workspace(.searchResult(RemoteWorkspaceSearchResult(
                query: value.query ?? "",
                hits: (value.hits ?? []).compactMap { hit in
                    guard let path = hit.path, let filename = hit.filename else { return nil }
                    return RemoteWorkspaceSearchHit(
                        path: normalizeSlashes(path),
                        filename: filename,
                        type: hit.type == "directory" ? .directory : .file
                    )
                }
            )))
        default:
            return .unknown(type: message.type)
        }
    }
    
    private static func sessionInfo(_ value: ProtocolMessage.Payload) -> RemoteSessionInfo {
        RemoteSessionInfo(
            sessionId: value.sessionId,
            sessionFile: value.sessionFile.map(normalizeSlashes),
            name: value.name,
            leafId: value.leafId,
            entryCount: value.entryCount ?? 0,
            reason: value.reason
        )
    }

    /// 把 Windows 反斜杠路径统一成正斜杠，并去掉前导 ./ 或 /。
    /// 确保 iOS 端用 path 作为字典 key 时跨平台一致，避免展开目录时 key 不匹配。
    private static func normalizeSlashes(_ path: String) -> String {
        let cleaned = path.replacingOccurrences(of: "\\", with: "/")
        return cleaned.hasPrefix("./") ? String(cleaned.dropFirst(2)) : cleaned
    }
    
    private static func agentDescriptor(_ value: ProtocolMessage.AgentPayload) -> RemoteAgentDescriptor? {
        guard let id = value.agentId, !id.isEmpty else { return nil }
        return RemoteAgentDescriptor(
            agentId: id,
            name: value.name,
            cwd: value.cwd,
            model: value.model,
            online: value.online ?? true
        )
    }
}

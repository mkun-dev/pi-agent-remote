import SwiftUI

// MARK: - 问卷卡片（内联）

/// 内联问卷卡片：以卡片形式出现在聊天输入框上方，不覆盖全屏。
/// 通过 ChatView 条件渲染（store.showQuestionnaire 为 true 时插入）。
struct QuestionnaireCard: View {
    let questions: [ProtocolMessage.QuestionPayload]
    let onSubmit: ([ProtocolMessage.AnswerPayload]) -> Void
    let onDismiss: () -> Void

    @State private var answers: [String: ProtocolMessage.AnswerPayload] = [:]
    @State private var currentIndex = 0
    @State private var customInputFor: String? = nil   // 当前展开自定义输入的问题 id
    @State private var customText = ""

    private var currentQuestion: ProtocolMessage.QuestionPayload? {
        guard currentIndex < questions.count else { return nil }
        return questions[currentIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 顶部：标题 + 关闭
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(PiDesignSystem.Color.piBrand)
                    .font(.system(size: 16, weight: .medium))
                Text("Pi 有问题需要你回答")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text("\(currentIndex + 1)/\(questions.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭问卷")
            }

            // 进度点
            HStack(spacing: 6) {
                ForEach(Array(questions.enumerated()), id: \.offset) { idx, _ in
                    Capsule()
                        .fill(idx <= currentIndex
                              ? PiDesignSystem.Color.piBrand
                              : Color.gray.opacity(0.3))
                        .frame(width: idx == currentIndex ? 20 : 8, height: 4)
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                }
                Spacer(minLength: 0)
            }

            if let q = currentQuestion {
                // 问题文本
                HStack(spacing: 8) {
                    if q.multiSelect == true {
                        Text("多选")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(PiDesignSystem.Color.piBrand.opacity(0.15), in: Capsule())
                    }
                    Text(q.question ?? "")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 选项列表（紧凑卡片样式）
                VStack(spacing: 6) {
                    ForEach(q.options ?? []) { opt in
                        optionRow(for: q, option: opt)
                    }
                    // 自定义输入
                    customInputRow(for: q)
                }

                // 底部导航
                HStack(spacing: 10) {
                    if currentIndex > 0 {
                        Button {
                            currentIndex -= 1
                        } label: {
                            Label("上一步", systemImage: "chevron.left")
                                .font(.footnote.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                    if currentIndex < questions.count - 1 {
                        Button {
                            currentIndex += 1
                        } label: {
                            Text("下一步")
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(currentAnswer(for: q) == nil)
                    } else {
                        Button {
                            submitAnswers()
                        } label: {
                            Label("提交", systemImage: "paperplane.fill")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(answers.isEmpty)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PiDesignSystem.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PiDesignSystem.Color.piBrand.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
    }

    // MARK: - 子视图

    @ViewBuilder
    private func optionRow(for q: ProtocolMessage.QuestionPayload, option: ProtocolMessage.OptionPayload) -> some View {
        let selected = isSelected(q, option)
        Button {
            selectOption(for: q, option: option)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: q.multiSelect == true
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundColor(selected ? PiDesignSystem.Color.piBrand : .gray)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? PiDesignSystem.Color.piBrand.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? PiDesignSystem.Color.piBrand.opacity(0.4) : Color.secondary.opacity(0.15),
                            lineWidth: selected ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.label ?? "")\(selected ? "，已选" : "")")
    }

    @ViewBuilder
    private func customInputRow(for q: ProtocolMessage.QuestionPayload) -> some View {
        if customInputFor == q.id {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    TextField("输入自定义答案...", text: $customText)
                        .font(.subheadline)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(UIColor.tertiarySystemBackground))
                        )
                    Button {
                        saveCustomInput(for: q)
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(PiDesignSystem.Color.piBrand)
                    }
                    .buttonStyle(.plain)
                    .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        customInputFor = nil
                        customText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PiDesignSystem.Color.piBrand.opacity(0.06))
            )
        } else {
            Button {
                customInputFor = q.id
                customText = customAnswer(for: q) ?? ""
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14))
                    if let savedAnswer = customAnswer(for: q) {
                        Text(savedAnswer)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    } else {
                        Text("输入自定义答案...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(customAnswer(for: q).map { "自定义答案：\($0)，点按可编辑" } ?? "输入自定义答案")
        }
    }

    // MARK: - 逻辑

    /// 返回当前问题是否已有任意答案（用于「下一步」按钮可用性）。
    private func currentAnswer(for q: ProtocolMessage.QuestionPayload) -> ProtocolMessage.AnswerPayload? {
        answers[q.id]
    }

    /// 返回已保存的自定义答案；选项答案不作为自定义内容显示。
    private func customAnswer(for q: ProtocolMessage.QuestionPayload) -> String? {
        guard let answer = answers[q.id]?.answer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !answer.isEmpty else { return nil }
        let optionLabels = Set((q.options ?? []).compactMap(\.label))
        return optionLabels.contains(answer) ? nil : answer
    }

    private func isSelected(_ q: ProtocolMessage.QuestionPayload, _ opt: ProtocolMessage.OptionPayload) -> Bool {
        let key = q.id
        guard let a = answers[key] else { return false }
        if let selected = a.selected {
            return selected.contains(opt.label ?? "")
        }
        return a.answer == opt.label
    }

    private func selectOption(for q: ProtocolMessage.QuestionPayload, option: ProtocolMessage.OptionPayload) {
        let key = q.id
        let label = option.label ?? ""

        if q.multiSelect == true {
            let existing = answers[key] ?? ProtocolMessage.AnswerPayload(question: q.question, answer: nil, selected: [], notes: nil)
            var sel = existing.selected ?? []
            if sel.contains(label) {
                sel.removeAll { $0 == label }
            } else {
                sel.append(label)
            }
            answers[key] = ProtocolMessage.AnswerPayload(question: q.question, answer: nil, selected: sel, notes: existing.notes)
        } else {
            answers[key] = ProtocolMessage.AnswerPayload(question: q.question, answer: label, selected: nil, notes: nil)
        }
    }

    private func saveCustomInput(for q: ProtocolMessage.QuestionPayload) {
        let text = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let key = q.id
        answers[key] = ProtocolMessage.AnswerPayload(question: q.question, answer: text, selected: nil, notes: nil)
        customInputFor = nil
        customText = ""
    }

    private func submitAnswers() {
        let result = questions.compactMap { q in answers[q.id] }
        onSubmit(result)
    }
}

import SwiftUI

// MARK: - 问卷卡片

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
        NavigationStack {
            ZStack {
                PiDesignSystem.Color.background
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        ForEach(Array(questions.enumerated()), id: \.offset) { idx, _ in
                            Capsule()
                                .fill(idx < currentIndex ? PiDesignSystem.Color.completed : (idx == currentIndex ? PiDesignSystem.Color.accent : PiDesignSystem.Color.border))
                                .frame(width: idx == currentIndex ? 20 : 8, height: 8)
                        }
                        Spacer()
                        Text("\(currentIndex + 1)/\(questions.count)")
                            .font(PiDesignSystem.Font.caption)
                            .foregroundStyle(PiDesignSystem.Color.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    
                    if let q = currentQuestion {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(q.question ?? "")
                                    .font(PiDesignSystem.Font.headline)
                                    .foregroundStyle(PiDesignSystem.Color.primary)
                                
                                if q.multiSelect == true {
                                    Text("多选")
                                        .font(PiDesignSystem.Font.caption)
                                        .foregroundStyle(PiDesignSystem.Color.accent)
                                }
                        
                                ForEach(q.options ?? []) { opt in
                                    Button {
                                        selectOption(for: q, option: opt)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: isSelected(q, opt) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(isSelected(q, opt) ? PiDesignSystem.Color.accent : PiDesignSystem.Color.secondary)
                                                .font(.system(size: 20))
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(opt.label ?? "")
                                                    .font(PiDesignSystem.Font.body)
                                                    .foregroundStyle(PiDesignSystem.Color.primary)
                                                if let desc = opt.description {
                                                    Text(desc)
                                                        .font(PiDesignSystem.Font.caption)
                                                        .foregroundStyle(PiDesignSystem.Color.secondary)
                                                }
                                            }
                                            Spacer()
                                        }
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(PiDesignSystem.Color.panelElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isSelected(q, opt) ? PiDesignSystem.Color.accent.opacity(0.5) : PiDesignSystem.Color.border, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                        
                                if customInputFor == q.id {
                                    VStack(spacing: 10) {
                                        TextField("输入自定义答案...", text: $customText)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 12)
                                            .piInputSurface()
                                        HStack(spacing: 10) {
                                            Button("确定") {
                                                saveCustomInput(for: q)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 40)
                                            .piPrimaryButton(radius: 12)
                                            .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                            
                                            Button("取消") {
                                                customInputFor = nil
                                                customText = ""
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 40)
                                            .piSecondaryButton(radius: 12)
                                        }
                                    }
                                } else {
                            Button {
                                customInputFor = q.id
                                customText = customAnswer(for: q) ?? ""
                            } label: {
                                if let savedAnswer = customAnswer(for: q) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(PiDesignSystem.Color.accent)
                                            .padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("自定义答案")
                                                .font(PiDesignSystem.Font.caption)
                                                .foregroundStyle(PiDesignSystem.Color.secondary)
                                            Text(savedAnswer)
                                                .font(PiDesignSystem.Font.body)
                                                .foregroundStyle(PiDesignSystem.Color.primary)
                                                .multilineTextAlignment(.leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "pencil")
                                            .foregroundStyle(PiDesignSystem.Color.secondary)
                                            .padding(.top, 2)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .piInputSurface()
                                } else {
                                    HStack {
                                        Image(systemName: "pencil")
                                        Text("输入自定义答案...")
                                    }
                                    .font(PiDesignSystem.Font.body)
                                    .foregroundStyle(PiDesignSystem.Color.secondary)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .piInputSurface()
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(customAnswer(for: q).map { "自定义答案：\($0)，点按可编辑" } ?? "输入自定义答案")
                        }
                            }
                            .padding(16)
                            .piCard(color: PiDesignSystem.Color.surface)
                            .padding(16)
                        }
                    }
                    
                    Spacer()
                    
                    HStack {
                        if currentIndex > 0 {
                            Button("上一步") { currentIndex -= 1 }
                                .frame(minWidth: 88, minHeight: 44)
                                .piSecondaryButton()
                        }
                        Spacer()
                        if currentIndex < questions.count - 1 {
                            Button("下一步") { currentIndex += 1 }
                                .frame(minWidth: 88, minHeight: 44)
                                .piPrimaryButton()
                        } else {
                            Button("提交") {
                                submitAnswers()
                            }
                            .frame(minWidth: 88, minHeight: 44)
                            .piPrimaryButton()
                            .disabled(answers.isEmpty)
                            .opacity(answers.isEmpty ? 0.55 : 1)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("模型提问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onDismiss() }
                        .tint(PiDesignSystem.Color.accent)
                }
            }
        }
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

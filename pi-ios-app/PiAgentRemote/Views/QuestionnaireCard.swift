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
            VStack(spacing: 0) {
                // 进度指示器
                HStack(spacing: 6) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { idx, q in
                        Circle()
                            .fill(idx < currentIndex ? Color.green : (idx == currentIndex ? Color.blue : Color.gray.opacity(0.3)))
                            .frame(width: 8, height: 8)
                    }
                    Spacer()
                    Text("\(currentIndex + 1)/\(questions.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                
                if let q = currentQuestion {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(q.question ?? "")
                            .font(.headline)
                            .padding(.horizontal)
                        
                        if q.multiSelect == true {
                            Text("多选")
                                .font(.caption)
                                .foregroundColor(.blue)
                                .padding(.horizontal)
                        }
                        
                        // 选项列表
                        ForEach(q.options ?? []) { opt in
                            Button {
                                selectOption(for: q, option: opt)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected(q, opt) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(isSelected(q, opt) ? .blue : .gray)
                                        .font(.system(size: 20))
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(opt.label ?? "")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        if let desc = opt.description {
                                            Text(desc)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        // 自定义输入（SwiftUI 原生内联，替代不可靠的 UIAlertController）
                        if customInputFor == q.id {
                            HStack(spacing: 8) {
                                TextField("输入自定义答案...", text: $customText)
                                    .textFieldStyle(.roundedBorder)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                                Button("确定") {
                                    saveCustomInput(for: q)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("取消") {
                                    customInputFor = nil
                                    customText = ""
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.horizontal)
                            .padding(.top, 4)
                        } else {
                            Button {
                                customInputFor = q.id
                                customText = customAnswer(for: q) ?? ""
                            } label: {
                                if let savedAnswer = customAnswer(for: q) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                            .padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("自定义答案")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            Text(savedAnswer)
                                                .font(.body)
                                                .foregroundColor(.primary)
                                                .multilineTextAlignment(.leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "pencil")
                                            .foregroundColor(.secondary)
                                            .padding(.top, 2)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .background(Color.blue.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .padding(.horizontal)
                                } else {
                                    HStack {
                                        Image(systemName: "pencil")
                                        Text("输入自定义答案...")
                                    }
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal)
                                    .frame(minHeight: 44)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(customAnswer(for: q).map { "自定义答案：\($0)，点按可编辑" } ?? "输入自定义答案")
                        }
                    }
                    .padding(.vertical)
                }
                
                Spacer()
                
                // 底部按钮
                HStack {
                    if currentIndex > 0 {
                        Button("上一步") { currentIndex -= 1 }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                    if currentIndex < questions.count - 1 {
                        Button("下一步") { currentIndex += 1 }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("提交") {
                            submitAnswers()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(answers.isEmpty)
                    }
                }
                .padding()
            }
            .navigationTitle("模型提问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onDismiss() }
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

import XCTest
@testable import PiAgentRemote

/// 问卷（questionnaire）链路测试：RemoteEvent → ConversationStore → UI 状态。
final class QuestionnaireStoreTests: XCTestCase {

    private func makeQuestionnaireEvent(id: String, questions: [RemoteQuestion]) -> RemoteEvent {
        RemoteEvent(
            id: id,
            timestamp: Date(),
            payload: .questionnaire(.show(id: id, questions: questions))
        )
    }

    func testShowOpensQuestionnaire() {
        let store = ConversationStore()
        let q = RemoteQuestion(
            question: "要修改哪个文件？",
            header: "文件选择",
            multiSelect: false,
            options: [
                RemoteQuestion.Option(label: "README.md", description: nil, hasPreview: false),
                RemoteQuestion.Option(label: "main.swift", description: "主入口", hasPreview: true)
            ]
        )
        store.accept(makeQuestionnaireEvent(id: "q1", questions: [q]))

        XCTAssertTrue(store.showQuestionnaire)
        XCTAssertEqual(store.questionnaireQuestions.count, 1)
        XCTAssertEqual(store.questionnaireQuestions.first?.question, "要修改哪个文件？")
        XCTAssertEqual(store.questionnaireQuestions.first?.options?.count, 2)
        XCTAssertEqual(store.questionnaireQuestions.first?.options?.first?.label, "README.md")
        XCTAssertEqual(store.activeQuestionnaireId, "q1")
    }

    func testEmptyQuestionsDoesNotOpen() {
        let store = ConversationStore()
        store.accept(makeQuestionnaireEvent(id: "q2", questions: []))
        XCTAssertFalse(store.showQuestionnaire)
        XCTAssertTrue(store.questionnaireQuestions.isEmpty)
    }

    func testAnsweredClosesQuestionnaire() {
        let store = ConversationStore()
        let q = RemoteQuestion(question: "确认？", header: nil, multiSelect: true, options: [
            RemoteQuestion.Option(label: "是", description: nil, hasPreview: false)
        ])
        store.accept(makeQuestionnaireEvent(id: "q3", questions: [q]))
        XCTAssertTrue(store.showQuestionnaire)

        // PC 端已回答
        let answered = RemoteEvent(
            id: "q3-answer",
            timestamp: Date(),
            payload: .questionnaire(.answered(
                source: "pc",
                answers: [RemoteQuestionAnswer(question: "确认？", answer: "是", selected: ["是"], notes: nil)]
            ))
        )
        store.accept(answered)

        XCTAssertFalse(store.showQuestionnaire)
        // 答案应记录到日志
        XCTAssertTrue(store.logs.contains { $0.content.contains("是") })
    }

    func testIosSelfAnswerNotLoggedTwice() {
        let store = ConversationStore()
        let answered = RemoteEvent(
            id: "self-answer",
            timestamp: Date(),
            payload: .questionnaire(.answered(
                source: "ios",
                answers: [RemoteQuestionAnswer(question: "Q", answer: "A", selected: nil, notes: nil)]
            ))
        )
        store.accept(answered)
        // iOS 自身提交的答案不重复记录
        XCTAssertTrue(store.logs.allSatisfy { !$0.content.contains("Q: A") })
    }

    // MARK: - Wire-level end-to-end（模拟 Pi 实际发送的 JSON）

    func testEndToEndShowFromWire() throws {
        let store = ConversationStore()
        // 模拟 Extension 在 tool_execution_start 拦截 ask_user_question 后广播的原始消息
        let json = #"""
        {"id":"q_call_123","type":"questionnaire.show","timestamp":1750000000000,
         "payload":{"questions":[
           {"question":"继续执行吗？","header":"确认","multiSelect":false,
            "options":[{"label":"继续","description":null,"hasPreview":false},
                       {"label":"暂停","description":"稍后继续","hasPreview":false}]}
         ]}}
        """#
        let event = try XCTUnwrap(RemoteEventDecoder.decode(text: json))
        store.accept(event)

        XCTAssertTrue(store.showQuestionnaire)
        XCTAssertEqual(store.activeQuestionnaireId, "q_call_123")
        XCTAssertEqual(store.questionnaireQuestions.count, 1)
        XCTAssertEqual(store.questionnaireQuestions.first?.question, "继续执行吗？")
        XCTAssertEqual(store.questionnaireQuestions.first?.options?.count, 2)
        XCTAssertEqual(store.questionnaireQuestions.first?.options?.last?.label, "暂停")
        XCTAssertEqual(store.questionnaireQuestions.first?.options?.last?.description, "稍后继续")
    }

    func testEndToEndSubmitBuildsAnswerPayload() {
        // 模拟 iOS 提交路径：ChatViewModel.submitQuestionnaire → ws.submitQuestionnaire
        // 验证 AnswerPayload 可构造（与 QuestionnaireCard 提交的 answers 结构一致）
        let answer = ProtocolMessage.AnswerPayload(
            question: "继续执行吗？",
            answer: "继续",
            selected: ["继续"],
            notes: nil
        )
        XCTAssertEqual(answer.question, "继续执行吗？")
        XCTAssertEqual(answer.selected, ["继续"])
    }
}

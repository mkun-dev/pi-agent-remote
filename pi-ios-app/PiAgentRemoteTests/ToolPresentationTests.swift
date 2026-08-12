import XCTest
@testable import PiAgentRemote

final class ToolPresentationTests: XCTestCase {
    func testSharedToolRules() {
        XCTAssertEqual(ToolPresentation.resolve(name: "functions.read").displayName, "读取文件")
        XCTAssertEqual(ToolPresentation.resolve(name: "bash", input: "npm test").semantic, .test)
        XCTAssertEqual(ToolPresentation.resolve(name: "bash", input: "ls").category, .command)
        XCTAssertEqual(ToolPresentation.resolve(name: "edit").category, .modify)
    }
}

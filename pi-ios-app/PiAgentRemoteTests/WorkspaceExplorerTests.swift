import XCTest
@testable import PiAgentRemote

/// Workspace Explorer 链路测试：解码 + ConversationStore 状态投影。
final class WorkspaceExplorerTests: XCTestCase {

    // MARK: - Decoder

    func testWorkspaceTreeDecodes() throws {
        let json = #"""
        {"id":"1","type":"workspace.tree","timestamp":1000,
         "payload":{"path":"","name":"pi-link",
           "children":[
             {"name":"src","path":"src","type":"directory"},
             {"name":"README.md","path":"README.md","type":"file"}
           ]}}
        """#
        let event = try XCTUnwrap(RemoteEventDecoder.decode(text: json))
        XCTAssertEqual(event.payload, .workspace(.tree(RemoteWorkspaceTree(
            path: "",
            name: "pi-link",
            children: [
                RemoteWorkspaceNode(name: "src", path: "src", type: .directory),
                RemoteWorkspaceNode(name: "README.md", path: "README.md", type: .file)
            ]
        ))))
    }

    func testWorkspaceFileDecodes() throws {
        let json = #"""
        {"id":"2","type":"workspace.file","timestamp":1000,
         "payload":{"path":"src/index.ts","fileType":"text","content":"export const a = 1;","size":24}}
        """#
        let event = try XCTUnwrap(RemoteEventDecoder.decode(text: json))
        XCTAssertEqual(event.payload, .workspace(.file(RemoteWorkspaceFile(
            path: "src/index.ts",
            type: .text,
            content: "export const a = 1;",
            size: 24
        ))))
    }

    func testWorkspaceImageFileDecodes() throws {
        let json = #"""
        {"id":"2i","type":"workspace.file","timestamp":1000,
         "payload":{"path":"assets/logo.png","fileType":"image","mimeType":"image/png","base64":"aGVsbG8=","size":5}}
        """#
        let event = try XCTUnwrap(RemoteEventDecoder.decode(text: json))
        XCTAssertEqual(event.payload, .workspace(.file(RemoteWorkspaceFile(
            path: "assets/logo.png",
            type: .image,
            content: nil,
            base64: "aGVsbG8=",
            size: 5,
            mimeType: "image/png"
        ))))
    }

    func testWorkspaceBinaryFileDecodes() throws {
        let json = #"""
        {"id":"2b","type":"workspace.file","timestamp":1000,
         "payload":{"path":"bin/app.dat","fileType":"binary","size":128}}
        """#
        let event = try XCTUnwrap(RemoteEventDecoder.decode(text: json))
        XCTAssertEqual(event.payload, .workspace(.file(RemoteWorkspaceFile(
            path: "bin/app.dat",
            type: .binary,
            size: 128
        ))))
    }

    func testPreviewKindRoutesMarkdownAndSVG() {
        let markdown = RemoteWorkspaceFile(path: "docs/README.md", type: .text, content: "# Hi", size: 4)
        XCTAssertEqual(markdown.previewKind, .markdown)

        let svg = RemoteWorkspaceFile(path: "assets/logo.svg", type: .text, content: "<svg/>", size: 6, mimeType: "image/svg+xml")
        XCTAssertEqual(svg.previewKind, .svg)

        let image = RemoteWorkspaceFile(path: "assets/logo.png", type: .image, base64: "aGVsbG8=", size: 5, mimeType: "image/png")
        XCTAssertEqual(image.previewKind, .image)
    }

    func testWorkspaceErrorDecodes() throws {
        let json = #"""
        {"id":"3","type":"workspace.error","timestamp":1000,
         "payload":{"path":"src/secret","message":"路径超出项目范围"}}
        """#
        let event = try XCTUnwrap(RemoteEventDecoder.decode(text: json))
        XCTAssertEqual(event.payload, .workspace(.error(RemoteWorkspaceError(
            path: "src/secret",
            message: "路径超出项目范围"
        ))))
    }

    // MARK: - ConversationStore projection

    func testTreeProjectedToStore() {
        let store = ConversationStore()
        store.accept(RemoteEvent(
            id: "ws1",
            timestamp: Date(),
            payload: .workspace(.tree(RemoteWorkspaceTree(
                path: "",
                name: "my-project",
                children: [
                    RemoteWorkspaceNode(name: "src", path: "src", type: .directory),
                    RemoteWorkspaceNode(name: "main.swift", path: "main.swift", type: .file)
                ]
            )))
        ))
        XCTAssertEqual(store.workspaceRootName, "my-project")
        XCTAssertEqual(store.workspaceChildren[""]?.count, 2)
        XCTAssertTrue(store.workspaceChildren[""]?.contains { $0.name == "main.swift" } == true)
        XCTAssertNil(store.workspaceErrors[""])
    }

    func testSubdirectoryTreeStoredByPath() {
        let store = ConversationStore()
        store.accept(RemoteEvent(
            id: "ws2",
            timestamp: Date(),
            payload: .workspace(.tree(RemoteWorkspaceTree(
                path: "src",
                name: "src",
                children: [
                    RemoteWorkspaceNode(name: "Views", path: "src/Views", type: .directory),
                    RemoteWorkspaceNode(name: "App.swift", path: "src/App.swift", type: .file)
                ]
            )))
        ))
        // 子目录用完整相对路径作为 key
        XCTAssertEqual(store.workspaceChildren["src"]?.count, 2)
        XCTAssertEqual(store.workspaceChildren["src"]?.first?.path, "src/Views")
    }

    func testFileContentProjectedToStore() {
        let store = ConversationStore()
        store.accept(RemoteEvent(
            id: "ws3",
            timestamp: Date(),
            payload: .workspace(.file(RemoteWorkspaceFile(
                path: "src/App.swift",
                content: "import SwiftUI\nstruct App: App {}",
                size: 40
            )))
        ))
        XCTAssertEqual(store.workspaceFileContent["src/App.swift"], "import SwiftUI\nstruct App: App {}")
        XCTAssertEqual(store.workspaceFiles["src/App.swift"]?.type, .text)
    }

    func testImageFileProjectedToStoreWithoutTextContent() {
        let store = ConversationStore()
        store.accept(RemoteEvent(
            id: "ws3i",
            timestamp: Date(),
            payload: .workspace(.file(RemoteWorkspaceFile(
                path: "assets/logo.png",
                type: .image,
                base64: "aGVsbG8=",
                size: 5,
                mimeType: "image/png"
            )))
        ))
        XCTAssertEqual(store.workspaceFiles["assets/logo.png"]?.type, .image)
        XCTAssertNil(store.workspaceFileContent["assets/logo.png"], "图片不应进入文本缓存")
    }

    func testBinaryFileProjectedToStoreWithoutTextContent() {
        let store = ConversationStore()
        store.accept(RemoteEvent(
            id: "ws3b",
            timestamp: Date(),
            payload: .workspace(.file(RemoteWorkspaceFile(
                path: "bin/blob.dat",
                type: .binary,
                size: 16
            )))
        ))
        XCTAssertEqual(store.workspaceFiles["bin/blob.dat"]?.type, .binary)
        XCTAssertNil(store.workspaceFileContent["bin/blob.dat"], "二进制不应进入文本缓存")
    }

    func testErrorProjectedToStore() {
        let store = ConversationStore()
        store.accept(RemoteEvent(
            id: "ws4",
            timestamp: Date(),
            payload: .workspace(.error(RemoteWorkspaceError(
                path: "config/secret",
                message: "路径超出项目范围"
            )))
        ))
        XCTAssertEqual(store.workspaceErrors["config/secret"], "路径超出项目范围")
    }

    func testErrorClearedOnSuccessfulTree() {
        let store = ConversationStore()
        store.accept(RemoteEvent(
            id: "e1",
            timestamp: Date(),
            payload: .workspace(.error(RemoteWorkspaceError(path: "src", message: "暂不可用")))
        ))
        XCTAssertEqual(store.workspaceErrors["src"], "暂不可用")

        store.accept(RemoteEvent(
            id: "e2",
            timestamp: Date(),
            payload: .workspace(.tree(RemoteWorkspaceTree(
                path: "src", name: "src", children: []
            )))
        ))
        XCTAssertNil(store.workspaceErrors["src"])
    }

    // MARK: - 全局搜索（workspace.searchResult）

    func testSearchResultDecodes() throws {
        let json = #"""
        {"id":"4","type":"workspace.searchResult","timestamp":1000,
         "payload":{"query":"swift","hits":[
           {"path":"src/App.swift","filename":"App.swift","type":"file"},
           {"path":"src/Views","filename":"Views","type":"directory"}
         ]}}
        """#
        let event = try XCTUnwrap(RemoteEventDecoder.decode(text: json))
        XCTAssertEqual(event.payload, .workspace(.searchResult(RemoteWorkspaceSearchResult(
            query: "swift",
            hits: [
                RemoteWorkspaceSearchHit(path: "src/App.swift", filename: "App.swift", type: .file),
                RemoteWorkspaceSearchHit(path: "src/Views", filename: "Views", type: .directory)
            ]
        ))))
    }

    func testSearchResultProjectedToStore() {
        let store = ConversationStore()
        store.beginWorkspaceSearch()
        XCTAssertTrue(store.workspaceSearching)
        store.accept(RemoteEvent(
            id: "s1",
            timestamp: Date(),
            payload: .workspace(.searchResult(RemoteWorkspaceSearchResult(
                query: "App",
                hits: [RemoteWorkspaceSearchHit(path: "src/App.swift", filename: "App.swift", type: .file)]
            )))
        ))
        XCTAssertEqual(store.workspaceSearchResult?.hits.count, 1)
        XCTAssertFalse(store.workspaceSearching, "结果到达后应清除 loading")
    }

    // MARK: - file.change → Workspace 缓存失效

    func testFileModifiedClearsFileContentCache() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "f1", timestamp: Date(),
            payload: .workspace(.file(RemoteWorkspaceFile(path: "src/main.swift", content: "old", size: 3)))))
        XCTAssertEqual(store.workspaceFileContent["src/main.swift"], "old")

        store.accept(RemoteEvent(id: "fc1", timestamp: Date(),
            payload: .file(RemoteFileEvent(path: "src/main.swift", action: .modified, additions: nil, deletions: nil))))
        XCTAssertNil(store.workspaceFileContent["src/main.swift"], "modified 应失效文件内容缓存")
    }

    func testFileDeletedClearsContentAndParentDir() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "f1", timestamp: Date(),
            payload: .workspace(.file(RemoteWorkspaceFile(path: "src/a.swift", content: "x", size: 1)))))
        store.accept(RemoteEvent(id: "t1", timestamp: Date(),
            payload: .workspace(.tree(RemoteWorkspaceTree(path: "src", name: "src",
                children: [RemoteWorkspaceNode(name: "a.swift", path: "src/a.swift", type: .file)])))))

        store.accept(RemoteEvent(id: "del", timestamp: Date(),
            payload: .file(RemoteFileEvent(path: "src/a.swift", action: .deleted, additions: nil, deletions: nil))))

        XCTAssertNil(store.workspaceFileContent["src/a.swift"], "deleted 清内容缓存")
        XCTAssertNil(store.workspaceChildren["src"], "deleted 清父目录 children")
    }

    func testFileCreatedClearsParentDir() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "t1", timestamp: Date(),
            payload: .workspace(.tree(RemoteWorkspaceTree(path: "src", name: "src", children: [])))))

        store.accept(RemoteEvent(id: "new", timestamp: Date(),
            payload: .file(RemoteFileEvent(path: "src/new.swift", action: .created, additions: nil, deletions: nil))))

        XCTAssertNil(store.workspaceChildren["src"], "created 应失效父目录 children，下次展开重新加载")
    }

    func testFileChangeDoesNotBreakChatFileChange() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "fc", timestamp: Date(),
            payload: .file(RemoteFileEvent(path: "a.swift", action: .modified, additions: 5, deletions: 2))))
        // Chat 的文件变更卡片仍然生成
        XCTAssertTrue(store.messages.contains { $0.kind == .fileChanges })
    }

    // MARK: - 文件内容 LRU 上限

    func testFileContentLRUEvictsOldest() {
        let store = ConversationStore()
        // 写入 51 个文件（上限 50），最早的应被淘汰
        for i in 0..<51 {
            let p = "f/file\(i).txt"
            store.accept(RemoteEvent(id: "f\(i)", timestamp: Date(),
                payload: .workspace(.file(RemoteWorkspaceFile(path: p, content: "c\(i)", size: 2)))))
        }
        XCTAssertNil(store.workspaceFileContent["f/file0.txt"], "最早的应被 LRU 淘汰")
        XCTAssertNotNil(store.workspaceFileContent["f/file50.txt"], "最新的应保留")
        XCTAssertNotNil(store.workspaceFileContent["f/file25.txt"], "中间的应保留")
        XCTAssertLessThanOrEqual(store.workspaceFileContent.count, 50)
    }

    func testFileContentLRUTouchReorders() {
        let store = ConversationStore()
        for i in 0..<50 {
            store.accept(RemoteEvent(id: "f\(i)", timestamp: Date(),
                payload: .workspace(.file(RemoteWorkspaceFile(path: "f\(i)", content: "c", size: 1)))))
        }
        // 重新访问 file0，使其变为最近使用
        store.accept(RemoteEvent(id: "touch", timestamp: Date(),
            payload: .workspace(.file(RemoteWorkspaceFile(path: "f0", content: "c", size: 1)))))
        // 再写入一个，淘汰的应是 f1（最旧的）而非 f0
        store.accept(RemoteEvent(id: "new", timestamp: Date(),
            payload: .workspace(.file(RemoteWorkspaceFile(path: "f51", content: "c", size: 1)))))
        XCTAssertNotNil(store.workspaceFileContent["f0"], "重新访问后不应被淘汰")
        XCTAssertNil(store.workspaceFileContent["f1"], "最旧的 f1 应被淘汰")
    }

    // MARK: - Workspace 3.0 联动

    /// 第一+二阶段：文件上下文（询问Agent）
    func testSetAndConsumePendingFileContext() {
        let store = ConversationStore()
        store.setPendingFileContext(files: ["src/Auth.swift"], selection: "第 10 行")
        XCTAssertEqual(store.pendingFileContext?.workspaceFiles, ["src/Auth.swift"])
        XCTAssertEqual(store.pendingFileContext?.selection, "第 10 行")
        let consumed = store.consumePendingFileContext()
        XCTAssertEqual(consumed?.workspaceFiles, ["src/Auth.swift"])
        XCTAssertNil(store.pendingFileContext, "消费后应清除")
        XCTAssertNil(store.consumePendingFileContext(), "再次消费返回 nil")
    }

    func testClearPendingFileContext() {
        let store = ConversationStore()
        store.setPendingFileContext(files: ["a.swift"])
        store.clearPendingFileContext()
        XCTAssertNil(store.pendingFileContext)
    }

    /// 第三阶段：Diff「在Workspace打开」
    func testSetAndConsumePendingWorkspaceFile() {
        let store = ConversationStore()
        store.setPendingWorkspaceFile("src/Views/Auth.swift")
        XCTAssertEqual(store.pendingWorkspaceFile, "src/Views/Auth.swift")
        XCTAssertEqual(store.consumePendingWorkspaceFile(), "src/Views/Auth.swift")
        XCTAssertNil(store.pendingWorkspaceFile, "消费后应清除")
    }

    /// 第四阶段：file.change 写入 recentChanges
    func testRecentChangeRecordedOnFileChange() {
        let store = ConversationStore()
        let ts = Date()
        store.accept(RemoteEvent(id: "fc1", timestamp: ts,
            payload: .file(RemoteFileEvent(path: "src/main.swift", action: .modified, additions: 3, deletions: 1))))
        XCTAssertEqual(store.recentChanges.count, 1)
        XCTAssertEqual(store.recentChanges.first?.path, "src/main.swift")
        XCTAssertEqual(store.recentChanges.first?.changeType, .modified)
        XCTAssertEqual(store.recentChanges.first?.additions, 3)
    }

    func testRecentChangeDeduplicatesByPath() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "fc1", timestamp: Date(timeIntervalSinceNow: -60),
            payload: .file(RemoteFileEvent(path: "a.swift", action: .modified, additions: 1, deletions: nil))))
        store.accept(RemoteEvent(id: "fc2", timestamp: Date(),
            payload: .file(RemoteFileEvent(path: "a.swift", action: .modified, additions: 2, deletions: nil))))
        // 同路径只保留最新一条
        XCTAssertEqual(store.recentChanges.count, 1)
        XCTAssertEqual(store.recentChanges.first?.additions, 2, "应保留最新")
    }

    func testRecentChangeCappedAt50() {
        let store = ConversationStore()
        for i in 0..<55 {
            store.accept(RemoteEvent(id: "fc\(i)", timestamp: Date(timeIntervalSinceNow: Double(i)),
                payload: .file(RemoteFileEvent(path: "file\(i).swift", action: .modified, additions: nil, deletions: nil))))
        }
        XCTAssertEqual(store.recentChanges.count, 50, "最近修改上限 50")
    }

    func testRecentChangeRecordsAllActionTypes() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "c", timestamp: Date(),
            payload: .file(RemoteFileEvent(path: "new.swift", action: .created, additions: 10, deletions: nil))))
        store.accept(RemoteEvent(id: "m", timestamp: Date(),
            payload: .file(RemoteFileEvent(path: "mod.swift", action: .modified, additions: 2, deletions: 1))))
        store.accept(RemoteEvent(id: "d", timestamp: Date(),
            payload: .file(RemoteFileEvent(path: "old.swift", action: .deleted, additions: nil, deletions: 5))))
        let types = store.recentChanges.map(\.changeType)
        XCTAssertTrue(types.contains(.added))
        XCTAssertTrue(types.contains(.modified))
        XCTAssertTrue(types.contains(.deleted))
    }

    func testResetClearsRecentChangesAndContext() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "fc", timestamp: Date(),
            payload: .file(RemoteFileEvent(path: "a.swift", action: .modified, additions: 1, deletions: nil))))
        store.setPendingFileContext(files: ["a.swift"])
        store.setPendingWorkspaceFile("a.swift")
        store.reset()
        XCTAssertTrue(store.recentChanges.isEmpty)
        XCTAssertNil(store.pendingFileContext)
        XCTAssertNil(store.pendingWorkspaceFile)
    }

    func testLatestChangeHelpersResolveFromRecentChangesAndMessages() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "fc", timestamp: Date(),
            payload: .file(RemoteFileEvent(path: "src/Auth.swift", action: .modified, additions: 2, deletions: 1))))
        XCTAssertEqual(store.latestChangeType(for: "src/Auth.swift"), .modified)
        XCTAssertEqual(store.latestFileChange(for: "src/Auth.swift")?.type, .modified)
    }
}

import SwiftUI

// MARK: - Workspace Explorer

/// 工作区文件浏览器（只读）。
/// 数据流：ChatViewModel.loadWorkspaceDirectory → WebSocketManager.requestWorkspaceList
///        → Extension → workspace.tree → RemoteEvent → ConversationStore.workspaceChildren
struct WorkspaceExplorerView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var store: ConversationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var selectedFile: RemoteWorkspaceNode?
    @State private var loadedRoots: Set<String> = []
    /// 已展开的目录（就地递归展开树）
    @State private var expandedDirs: Set<String> = [""]
    /// 正在加载子目录的路径（防止重复请求）
    @State private var loadingDirs: Set<String> = []
    /// 服务端搜索防抖任务（避免每次按键都发请求）
    @State private var searchDebounce: DispatchWorkItem?
    /// 上一次已发起服务端搜索的关键词（避免重复请求相同 query）
    @State private var lastSearchedQuery: String = ""
    /// 搜索结果转成可点击的节点（复用 FileRow 渲染）
    private var searchHitNodes: [RemoteWorkspaceNode] {
        (store.workspaceSearchResult?.hits ?? []).map {
            RemoteWorkspaceNode(name: $0.filename, path: $0.path, type: $0.type)
        }
    }
    /// 是否正在服务端搜索（含本地 debounce 等待）
    private var isSearching: Bool {
        store.workspaceSearching || searchDebounce != nil
    }
    
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        _store = ObservedObject(wrappedValue: viewModel.conversationStore)
    }
    
    private var isConnected: Bool {
        store.isConnected && store.isAgentOnline
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                PiDesignSystem.Color.background.ignoresSafeArea()
                Group {
                    if !isConnected {
                        offlineView
                    } else if store.workspaceChildren.isEmpty && loadedRoots.isEmpty {
                        loadingView
                    } else {
                        explorerContent
                    }
                }
            }
            .navigationTitle("Workspace")
            .preferredColorScheme(.dark)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新")
                    .disabled(!isConnected)
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索文件名")
        }
        .sheet(item: $selectedFile) { node in
            if let file = store.workspaceFiles[node.path] {
                FileViewerView(file: file, viewModel: viewModel)
            } else {
                // 内容尚未返回时显示加载
                NavigationStack {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("加载 \(node.name)...")
                            .font(PiDesignSystem.Font.caption)
                            .foregroundStyle(PiDesignSystem.Color.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(node.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { selectedFile = nil }
                        }
                    }
                }
            }
        }
        .onAppear {
            if loadedRoots.isEmpty && isConnected {
                loadRoot()
            }
            consumePendingWorkspaceFileIfNeeded()
        }
        .onChange(of: store.pendingWorkspaceFile) { _ in
            consumePendingWorkspaceFileIfNeeded()
        }
        .onChange(of: store.sessionProjectionRevision) { _ in
            resetForSessionScopeChange()
        }
        .onChange(of: viewModel.conversationStore.isConnected) { connected in
            if connected && loadedRoots.isEmpty {
                loadRoot()
            }
        }
        // 子目录数据到达 → 清除对应 loading 标记
        .onChange(of: store.workspaceChildren.count) { _ in
            clearFinishedLoading()
        }
        .onChange(of: store.workspaceErrors.count) { _ in
            clearFinishedLoading()
        }
        // 搜索框输入 → 防抖触发服务端全局搜索
        .onChange(of: searchText) { newValue in
            handleSearchInput(newValue)
        }
    }
    
    // MARK: - Content
    
    private var explorerContent: some View {
        List {
            if !searchText.isEmpty {
                searchResultsSection
            } else {
                recentChangesSection
                treeSection
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: expandedDirs)
    }
    
    /// 最近修改文件（来自 file.change）。Agent 改文件后这里即时更新，作为 Workspace 入口。
    private var recentChangesSection: some View {
        Group {
            if !store.recentChanges.isEmpty {
                Section {
                    ForEach(store.recentChanges) { change in
                        Button {
                            openRecentChange(change)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: recentChangeIcon(change.changeType))
                                    .foregroundStyle(recentChangeColor(change.changeType))
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.fileName)
                                        .font(PiDesignSystem.Font.subheadline)
                                        .foregroundStyle(PiDesignSystem.Color.primary)
                                        .lineLimit(1)
                                    Text(change.path)
                                        .font(PiDesignSystem.Font.monoDigit)
                                        .foregroundStyle(PiDesignSystem.Color.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(change.timestamp, style: .relative)
                                        .font(PiDesignSystem.Font.caption2)
                                        .foregroundStyle(PiDesignSystem.Color.secondary)
                                    if change.additions != nil || change.deletions != nil {
                                        Text("+\(change.additions ?? 0) −\(change.deletions ?? 0)")
                                            .font(PiDesignSystem.Font.monoDigit)
                                            .foregroundStyle(PiDesignSystem.Color.secondary)
                                    }
                                }
                            }
                        }
                        .accessibilityLabel("\(recentChangeLabel(change.changeType)) \(change.fileName)")
                    }
                } header: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("最近修改")
                    }
                    .textCase(nil)
                }
            }
        }
    }
    
    private func openRecentChange(_ change: RecentFileChange) {
        if change.changeType == .deleted {
            // 已删除文件无法查看内容，仅展开其原父目录
            searchText = ""
            store.clearWorkspaceSearch()
            ensureParentExpanded(change.path)
        } else {
            selectedFile = RemoteWorkspaceNode(name: change.fileName, path: change.path, type: .file)
            if store.workspaceFiles[change.path] == nil {
                viewModel.loadWorkspaceFile(path: change.path)
            }
        }
    }
    
    private func recentChangeIcon(_ type: FileChangeType) -> String {
        switch type {
        case .added: return "doc.badge.plus"
        case .modified: return "doc.badge.gearshape"
        case .deleted: return "doc.badge.minus"
        }
    }
    
    private func recentChangeColor(_ type: FileChangeType) -> Color {
        switch type {
        case .added: return PiDesignSystem.Color.diffAdd
        case .modified: return PiDesignSystem.Color.thinking
        case .deleted: return PiDesignSystem.Color.diffRemove
        }
    }
    
    private func recentChangeLabel(_ type: FileChangeType) -> String {
        switch type {
        case .added: return "新增"
        case .modified: return "修改"
        case .deleted: return "删除"
        }
    }
    
    /// 根目录树（递归展开）
    private var treeSection: some View {
        Section {
            let rootNodes = store.workspaceChildren[""] ?? []
            if rootNodes.isEmpty && loadingDirs.contains("") {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("加载中...")
                        .font(PiDesignSystem.Font.caption)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                }
            } else if rootNodes.isEmpty {
                Text("空目录")
                    .font(PiDesignSystem.Font.caption)
                    .foregroundStyle(PiDesignSystem.Color.secondary)
            } else {
                ForEach(rootNodes) { node in
                    nodeRow(node, depth: 0)
                }
            }
        } header: {
            Text(store.workspaceRootName.isEmpty ? "项目根目录" : store.workspaceRootName)
                .textCase(nil)
        }
    }
    
    private var searchResultsSection: some View {
        Section {
            // 合并：服务端全局结果 + 本地已加载目录里的即时匹配（覆盖服务端尚未返回的瞬间）
            let results = mergedSearchResults
            if isSearching && results.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("搜索整个项目...")
                        .font(PiDesignSystem.Font.caption)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                }
            } else if results.isEmpty {
                Text("无匹配文件")
                    .font(PiDesignSystem.Font.caption)
                    .foregroundStyle(PiDesignSystem.Color.secondary)
            } else {
                ForEach(results) { node in
                    Button {
                        openSearchHit(node)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: node.type == .directory ? "folder" : "doc")
                                .foregroundStyle(node.type == .directory ? PiDesignSystem.Color.thinking : PiDesignSystem.Color.tool)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(node.name)
                                        .foregroundStyle(PiDesignSystem.Color.primary)
                                    if let type = node.type == .file ? store.latestChangeType(for: node.path) : nil {
                                        FileStatusDot(type: type)
                                    }
                                }
                                if !node.path.isEmpty && node.path != node.name {
                                    Text(node.path)
                                        .font(PiDesignSystem.Font.caption2)
                                        .foregroundStyle(PiDesignSystem.Color.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
        } header: {
            if isSearching {
                Text("搜索中…")
            } else {
                Text("搜索结果 (\(resultsCount))")
            }
        }
    }

    /// 合并服务端全局结果与本地即时匹配，去重（服务端结果优先）。
    private var mergedSearchResults: [RemoteWorkspaceNode] {
        var seen = Set<String>()
        var out: [RemoteWorkspaceNode] = []
        for node in searchHitNodes {
            if !seen.contains(node.path) { seen.insert(node.path); out.append(node) }
        }
        for node in localSearchResults {
            if !seen.contains(node.path) { seen.insert(node.path); out.append(node) }
        }
        return out
    }

    private var resultsCount: Int {
        let s = store.workspaceSearchResult?.hits.count ?? 0
        return max(s, localSearchResults.count)
    }

    /// 打开搜索命中项：文件直接查看内容；目录跳转到树并展开（需先加载其子目录）。
    private func openSearchHit(_ node: RemoteWorkspaceNode) {
        if node.type == .directory {
            searchText = ""
            cancelSearchDebounce()
            store.clearWorkspaceSearch()
            // 加载该目录并展开
            if store.workspaceChildren[node.path] == nil && !loadingDirs.contains(node.path) {
                loadingDirs.insert(node.path)
                viewModel.loadWorkspaceDirectory(path: node.path)
            }
            expandedDirs.insert(node.path)
            // 同时确保父目录链都已展开，让递归树能渲染到目标层
            ensureParentExpanded(node.path)
        } else {
            selectedFile = node
            if store.workspaceFiles[node.path] == nil {
                viewModel.loadWorkspaceFile(path: node.path)
            }
        }
    }

    /// 确保从根到目标目录的每一级都已展开，递归树才能渲染命中目录。
    private func ensureParentExpanded(_ path: String) {
        let parts = path.split(separator: "/").map(String.init)
        var current = ""
        for part in parts {
            let next = current.isEmpty ? part : "\(current)/\(part)"
            expandedDirs.insert(current)  // 展开上一级
            current = next
        }
    }
    
    // MARK: - Row

    /// 树节点行（递归）：目录可展开/收起，展开后渲染子节点
    /// 返回 AnyView 擦除类型，避免递归 `some View` 的 opaque 自引用错误。
    private func nodeRow(_ node: RemoteWorkspaceNode, depth: Int) -> AnyView {
        if node.type == .directory {
            let isExpanded = expandedDirs.contains(node.path)
            return AnyView(
                Group {
                    DirectoryRow(
                        node: node,
                        depth: depth,
                        isExpanded: isExpanded,
                        isLoading: loadingDirs.contains(node.path),
                        onToggle: { toggleDirectory(node) }
                    )
                    if isExpanded {
                        if let children = store.workspaceChildren[node.path] {
                            if children.isEmpty {
                                emptyRow(depth: depth + 1)
                            } else {
                                ForEach(children) { child in
                                    nodeRow(child, depth: depth + 1)
                                }
                            }
                        } else if loadingDirs.contains(node.path) {
                            loadingRow(depth: depth + 1)
                        } else if let error = store.workspaceErrors[node.path] {
                            errorRow(error, depth: depth + 1)
                        }
                    }
                }
            )
        } else {
            return AnyView(FileRow(node: node, depth: depth, changeType: store.latestChangeType(for: node.path)) { openFile(node) })
        }
    }
    
    /// 空目录占位行
    private func emptyRow(depth: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.dashed")
                .foregroundStyle(PiDesignSystem.Color.tertiary)
            Text("空目录")
                .font(PiDesignSystem.Font.caption)
                .foregroundStyle(PiDesignSystem.Color.tertiary)
        }
        .padding(.leading, CGFloat(16 + depth * 20) + 8)
    }
    
    /// 加载中占位行
    private func loadingRow(depth: Int) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("加载中...")
                .font(PiDesignSystem.Font.caption)
                .foregroundStyle(PiDesignSystem.Color.secondary)
        }
        .padding(.leading, CGFloat(16 + depth * 20) + 8)
    }
    
    /// 错误提示行
    private func errorRow(_ message: String, depth: Int) -> some View {
        Text("⚠️ \(message)")
            .font(PiDesignSystem.Font.caption)
            .foregroundStyle(PiDesignSystem.Color.failed)
            .padding(.leading, CGFloat(16 + depth * 20) + 8)
    }
    
    // MARK: - Row 子视图
    
    private struct FileStatusDot: View {
        let type: FileChangeType
        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(PiDesignSystem.Color.border, lineWidth: 0.5))
                .accessibilityLabel(label)
        }
        private var color: Color {
            switch type {
            case .added: return PiDesignSystem.Color.diffAdd
            case .modified: return PiDesignSystem.Color.thinking
            case .deleted: return PiDesignSystem.Color.diffRemove
            }
        }
        private var label: String {
            switch type {
            case .added: return "新增"
            case .modified: return "已修改"
            case .deleted: return "已删除"
            }
        }
    }

    private struct DirectoryRow: View {
        let node: RemoteWorkspaceNode
        let depth: Int
        let isExpanded: Bool
        let isLoading: Bool
        let onToggle: () -> Void
        
        var body: some View {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: "folder" + (isExpanded ? ".fill" : ""))
                        .foregroundStyle(PiDesignSystem.Color.thinking)
                    Text(node.name)
                        .foregroundStyle(PiDesignSystem.Color.primary)
                        .lineLimit(1)
                    Spacer()
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else if isExpanded {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PiDesignSystem.Color.secondary)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PiDesignSystem.Color.tertiary)
                    }
                }
                .padding(.leading, CGFloat(depth * 20))
            }
            .accessibilityLabel("\(node.name)，目录")
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            .accessibilityHint("轻点展开或收起")
        }
    }
    
    private struct FileRow: View {
        let node: RemoteWorkspaceNode
        let depth: Int
        let changeType: FileChangeType?
        let onOpen: () -> Void
        
        var body: some View {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: fileIcon(node.name))
                        .foregroundStyle(PiDesignSystem.Color.tool)
                    Text(node.name)
                        .foregroundStyle(PiDesignSystem.Color.primary)
                        .lineLimit(1)
                    if let changeType {
                        FileStatusDot(type: changeType)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PiDesignSystem.Color.tertiary)
                }
                .padding(.leading, CGFloat(depth * 20))
            }
            .accessibilityLabel(node.name)
            .accessibilityHint("查看文件内容")
        }
        
        private func fileIcon(_ name: String) -> String {
            let lower = name.lowercased()
            if lower.hasSuffix(".swift") { return "swift" }
            if lower.hasSuffix(".py") { return "chevron.left.forwardslash.chevron.right" }
            if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") { return "doc.richtext" }
            if lower.hasSuffix(".svg") { return "photo.on.rectangle" }
            if lower.hasSuffix(".json") || lower.hasSuffix(".yml") || lower.hasSuffix(".yaml") { return "curlybraces" }
            if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".gif") || lower.hasSuffix(".webp") { return "photo" }
            if lower.hasSuffix(".html") || lower.hasSuffix(".css") || lower.hasSuffix(".js") || lower.hasSuffix(".ts") { return "chevron.left.forwardslash.chevron.right" }
            return "doc"
        }
    }
    
    // MARK: - Actions
    
    private func loadRoot() {
        loadedRoots.insert("")
        loadingDirs.insert("")
        viewModel.loadWorkspaceDirectory(path: "")
    }
    
    private func resetForSessionScopeChange() {
        selectedFile = nil
        searchText = ""
        cancelSearchDebounce()
        lastSearchedQuery = ""
        loadedRoots.removeAll()
        loadingDirs.removeAll()
        expandedDirs = [""]
        if isConnected {
            loadRoot()
        }
    }
    
    /// 展开/收起目录（懒加载：首次展开请求子目录）
    private func toggleDirectory(_ node: RemoteWorkspaceNode) {
        if expandedDirs.contains(node.path) {
            expandedDirs.remove(node.path)
        } else {
            // 首次展开：请求子目录
            if store.workspaceChildren[node.path] == nil && !loadingDirs.contains(node.path) {
                loadingDirs.insert(node.path)
                viewModel.loadWorkspaceDirectory(path: node.path)
            }
            expandedDirs.insert(node.path)
        }
    }
    
    private func openFile(_ node: RemoteWorkspaceNode) {
        if store.workspaceFiles[node.path] == nil {
            viewModel.loadWorkspaceFile(path: node.path)
        }
        selectedFile = node
    }
    
    private func refresh() {
        expandedDirs = [""]
        loadingDirs.removeAll()
        loadedRoots.removeAll()
        loadRoot()
    }

    /// 消费 Diff「在Workspace打开」标记的待打开文件：直接弹出 FileViewerView。
    /// 内容可能尚未返回 → sheet 会先显示加载，内容到达后自动替换。
    private func consumePendingWorkspaceFileIfNeeded() {
        guard let path = store.consumePendingWorkspaceFile() else { return }
        let name = (path as NSString).lastPathComponent
        selectedFile = RemoteWorkspaceNode(name: name, path: path, type: .file)
        if store.workspaceFiles[path] == nil {
            viewModel.loadWorkspaceFile(path: path)
        }
    }

    /// 搜索输入处理：空串清除结果，非空则 350ms 防抖后发起服务端全局搜索。
    /// 防抖避免每个按键都打 Extension；短于 2 字符时不发请求（仅本地过滤）以减少噪声。
    private func handleSearchInput(_ newValue: String) {
        cancelSearchDebounce()
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            store.clearWorkspaceSearch()
            lastSearchedQuery = ""
            return
        }
        // 本地即时过滤已经在 mergedSearchResults 中生效，这里只需触发服务端搜索
        guard trimmed.count >= 2, trimmed != lastSearchedQuery else { return }
        let workItem = DispatchWorkItem { [weak viewModel, weak store] in
            guard let viewModel, let store else { return }
            store.beginWorkspaceSearch()
            viewModel.searchWorkspace(query: trimmed)
        }
        searchDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        lastSearchedQuery = trimmed
    }

    private func cancelSearchDebounce() {
        searchDebounce?.cancel()
        searchDebounce = nil
    }

    /// 收到数据后清理已完成的 loading 标记。
    /// 不能在迭代 Set 时直接 remove（未定义行为），先收集再删除。
    private func clearFinishedLoading() {
        guard !loadingDirs.isEmpty else { return }
        let finished = loadingDirs.filter {
            store.workspaceChildren[$0] != nil || store.workspaceErrors[$0] != nil
        }
        for path in finished { loadingDirs.remove(path) }
    }
    
    // MARK: - Derived
    
    /// 本地即时匹配：仅在已加载目录里过滤文件名，作为服务端结果的补充。
    private var localSearchResults: [RemoteWorkspaceNode] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        var results: [RemoteWorkspaceNode] = []
        for nodes in store.workspaceChildren.values {
            for node in nodes {
                if node.name.lowercased().contains(q), !seen.contains(node.path) {
                    seen.insert(node.path)
                    results.append(node)
                }
            }
        }
        return results.prefix(100).map { $0 }
    }
    
    private var offlineView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 40))
                .foregroundStyle(PiDesignSystem.Color.secondary)
            Text("未连接到 Pi")
                .font(.headline)
                .foregroundStyle(PiDesignSystem.Color.primary)
            Text("连接后在电脑上查看项目文件。")
                .font(.caption)
                .foregroundStyle(PiDesignSystem.Color.secondary)
        }
        .padding(20)
        .piCard(color: PiDesignSystem.Color.surface, radius: 20)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(PiDesignSystem.Color.accent)
            Text("加载项目目录...")
                .font(.caption)
                .foregroundStyle(PiDesignSystem.Color.secondary)
        }
        .padding(20)
        .piCard(color: PiDesignSystem.Color.surface, radius: 20)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
// MARK: - Preview

#Preview {
    WorkspaceExplorerView(viewModel: ChatViewModel.preview)
        .environmentObject(SettingsStore())
}
#endif

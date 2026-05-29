import SwiftUI
import Combine
extension String {
  func cleanedPath() -> String {
    return self.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
  }
}

private enum DetailMode: String, CaseIterable {
  case search = "搜索结果"
  case workspace = "工作区"
}

struct FileSearchView: View {
  @State private var searchText = ""
  @State private var files: [FileMetadata] = []
  @State private var selectedFileIDs = Set<FileMetadata.ID>()
  @State private var showingFolderAlert = false
  @State private var showingRebuildAlert = false
  @State private var pendingPath: String = ""
  @State private var searchTask: Task<Void, Never>? = nil
  @State private var totalCount: Int = 0
  @State private var detailMode: DetailMode = .search
  @StateObject private var workspace = WorkspaceManager()

  let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

  private var dbManager: FileDatabase? = try? FileDatabase(name: "easyqfiles.db")

  private var displayedFiles: [FileMetadata] {
    detailMode == .workspace ? workspace.items : files
  }

  var body: some View {
    NavigationSplitView {
      // --- 左侧栏 ---
      VStack(alignment: .leading, spacing: 0) {
        // 搜索区域
        Text("EasyQ")
          .font(.title2.bold())
          .padding(.top, 16)
          .padding(.horizontal)

        TextField("输入关键词搜索...", text: $searchText)
          .textFieldStyle(.roundedBorder)
          .padding(.horizontal)
          .padding(.top, 12)
          .onChange(of: searchText) {
            searchTask?.cancel()
            searchTask = Task {
              try? await Task.sleep(nanoseconds: 150_000_000)
              if !Task.isCancelled {
                performSearch()
              }
            }
          }

        // 操作按钮
        Button(action: { selectFolder() }) {
          Label("强制刷新索引", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .padding(.horizontal)
        .padding(.top, 12)

        Divider()
          .padding(.vertical, 12)

        // 索引统计
        HStack {
          Text("已索引文件")
            .font(.caption)
            .foregroundColor(.secondary)
          Spacer()
          Text("\(totalCount)")
            .font(.system(size: 18, weight: .semibold, design: .monospaced))
            .foregroundColor(.blue)
            .contentTransition(.numericText())
        }
        .padding(.horizontal)
        .onAppear(perform: refreshData)
        .onReceive(timer) { _ in refreshData() }

        Spacer()

        // 底部危险操作
        Divider()
        Button(action: { showingRebuildAlert = true }) {
          Label("重建索引...", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 8)
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 240)
      .alert("确认同步该目录？", isPresented: $showingFolderAlert) {
        Button("开始扫描") { confirmAndSendToAgent() }
        Button("取消", role: .cancel) { }
      } message: {
        Text("即将深度扫描并更新数据库：\n\(pendingPath)")
      }
      .alert("确认重建索引？", isPresented: $showingRebuildAlert) {
        Button("重建", role: .destructive) { rebuildIndex() }
        Button("取消", role: .cancel) { }
      } message: {
        Text("将清空全部索引数据并从头扫描，耗时较长。\n此操作不可撤销。")
      }

    } detail: {
      VStack(spacing: 0) {
        // 顶部切换栏
        Picker("", selection: $detailMode) {
          ForEach(DetailMode.allCases, id: \.self) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)

        // 表格
        Table(displayedFiles, selection: $selectedFileIDs) {
          TableColumn("文件名", value: \.name)
          TableColumn("大小", value: \.sizeString)
          TableColumn("类型") { item in
            Text(item.isDir ? "文件夹" : "文件")
          }
          TableColumn("修改时间") { item in
            Text(item.modificationDate)
          }
        }
        .contextMenu {
          let selectedFiles = displayedFiles.filter { selectedFileIDs.contains($0.id) }
          if !selectedFiles.isEmpty {
            if selectedFiles.count == 1 {
              Button("在 Finder 中显示") {
                revealInFinder(url: selectedFiles[0].parent + "/" + selectedFiles[0].name)
              }
            } else {
              Button("在 Finder 中显示 (\(selectedFiles.count) 项)") {
                for file in selectedFiles {
                  revealInFinder(url: file.parent + "/" + file.name)
                }
              }
            }
            Divider()
            if detailMode == .search {
              Button("添加到工作区 (\(selectedFiles.count) 项)") {
                for file in selectedFiles { workspace.add(file) }
              }
            } else {
              Button("从工作区移除 (\(selectedFiles.count) 项)") {
                for file in selectedFiles { workspace.remove(file) }
              }
            }
          }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          if let first = selectedFileIDs.first,
             let file = displayedFiles.first(where: { $0.id == first }) {
            revealInFinder(url: file.parent + "/" + file.name)
          }
        }
        .onTapGesture {
          if NSEvent.modifierFlags.contains(.command) {
            for id in selectedFileIDs {
              if let file = displayedFiles.first(where: { $0.id == id }) {
                revealInFinder(url: file.parent + "/" + file.name)
              }
            }
          }
        }
        .overlay {
          if displayedFiles.isEmpty {
            Text(detailMode == .workspace ? "工作区为空，右键搜索结果可添加" : "没有找到匹配的文件")
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  func refreshData() {
    DispatchQueue.global(qos: .utility).async {
      let count = self.dbManager?.count() ?? 0
      DispatchQueue.main.async { self.totalCount = count }
    }
  }

  private func selectFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.message = "请选择要强制刷新的文件夹"
    panel.begin { response in
      if response == .OK, let url = panel.url {
        let path = url.path(percentEncoded: false).cleanedPath()
        self.pendingPath = path
        self.showingFolderAlert = true
      }
    }
  }

  private func confirmAndSendToAgent() {
    DistributedNotificationCenter.default().postNotificationName(
      NSNotification.Name("com.easyq.agent.forceScan"),
      object: nil,
      userInfo: ["targetPath": pendingPath],
      deliverImmediately: true
    )
  }

  private func rebuildIndex() {
    DistributedNotificationCenter.default().postNotificationName(
      NSNotification.Name("com.easyq.agent.forceScan"),
      object: nil,
      userInfo: ["rebuild": true],
      deliverImmediately: true
    )
  }

  private var searchKeywords: [String] {
    searchText.split(separator: " ").map { String($0) }.filter { !$0.isEmpty }
  }

  private func performSearch() {
    let kws = searchKeywords
    if kws.isEmpty {
      files = []
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let results = self.dbManager?.searchFiles(keywords: kws) ?? []
      DispatchQueue.main.async {
        self.files = results
        self.detailMode = .search
      }
    }
  }

  func revealInFinder(url: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: url)])
  }
}

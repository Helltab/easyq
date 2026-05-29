import SwiftUI
import Combine
extension String {
  func cleanedPath() -> String {
    // 去空格 + 正则去掉末尾所有斜杠
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
  @State private var files: [FileMetadata] = [] // 这里存放搜索结果
  @State private var selectedFileIDs = Set<FileMetadata.ID>()
  @State private var showingConfirmAlert = false
  @State private var pendingPath: String = ""
  @State private var searchTask: Task<Void, Never>? = nil
  @State private var totalCount: Int = 0
  @State private var detailMode: DetailMode = .search
  @StateObject private var workspace = WorkspaceManager()

  // 定时器：每 5 秒刷新一次界面
  let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

  private var dbManager: FileDatabase? = try? FileDatabase(name: "easyqfiles.db")

  /// 当前显示的文件列表
  private var displayedFiles: [FileMetadata] {
    detailMode == .workspace ? workspace.items : files
  }

  var body: some View {
    NavigationSplitView {
      // --- 左侧搜索栏 ---
      VStack(alignment: .leading) {
        Text("搜索文件")
          .font(.headline)
          .padding([.top, .leading])
          .onChange(of: searchText) {
            newValue in
            // 1. 取消之前的搜索任务
            searchTask?.cancel()

            // 2. 开启新任务
            searchTask = Task {
              // 3. 等待 150 毫秒
              try? await Task.sleep(nanoseconds: 150_000_000)

              // 4. 如果任务没被取消，则执行搜索
              if !Task.isCancelled {
                performSearch()
              }
            }
          }


        TextField("输入关键词...", text: $searchText)
          .textFieldStyle(.roundedBorder)
          .padding()



        Button(action: {
          selectFolder()
        }) {
          HStack {
            Image(systemName: "arrow.clockwise")
            Text("强制刷新索引")
          }
        }
        .padding([.top, .leading])
        .buttonStyle(.borderedProminent)
        .tint(.blue)

        Button(action: {
          rebuildIndex()
        }) {
          HStack {
            Image(systemName: "trash")
            Text("重建索引")
          }
        }
        .padding(.leading)
        .buttonStyle(.bordered)
        .tint(.red)

        VStack(spacing: 10) {
          Text("索引统计")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding([.top, .leading])

          Text("\(totalCount)")
            .font(.system(size: 24, weight: .bold, design: .monospaced))
            .foregroundColor(.blue)
            .contentTransition(.numericText())
            .padding([.top, .leading])
        }
        .onAppear(perform: refreshData)
        .onReceive(timer) { _ in refreshData() }
        Spacer()
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 250)
      .alert("确认同步该目录？", isPresented: $showingConfirmAlert) {
        Button("开始扫描", role: .none) {
          confirmAndSendToAgent()
        }
        Button("取消", role: .cancel) { }
      } message: {
        Text("即将深度扫描并更新数据库：\n\(pendingPath)")
      }

    } detail: {
      VStack(spacing: 0) {
        // --- 顶部切换栏 ---
        Picker("", selection: $detailMode) {
          ForEach(DetailMode.allCases, id: \.self) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)

        // --- 右侧表格 ---
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
                for file in selectedFiles {
                  workspace.add(file)
                }
              }
            } else {
              Button("从工作区移除 (\(selectedFiles.count) 项)") {
                for file in selectedFiles {
                  workspace.remove(file)
                }
              }
            }
          }
        }
        // 双击打开 Finder
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
          if let first = selectedFileIDs.first,
             let file = displayedFiles.first(where: { $0.id == first }) {
            revealInFinder(url: file.parent + "/" + file.name)
          }
        }
        // Cmd+单击打开 Finder
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
        // 清洗路径
        let path = url.path(percentEncoded: false).cleanedPath()
        self.pendingPath = path
        // 第二步：触发 Alert
        self.showingConfirmAlert = true
      }
    }
  }
  private func confirmAndSendToAgent() {
    let dc = DistributedNotificationCenter.default()
    dc.postNotificationName(
      NSNotification.Name("com.easyq.agent.forceScan"),
      object: nil,
      userInfo: ["targetPath": pendingPath],
      deliverImmediately: true
    )
    print("✅ 已确认并发送指令: \(pendingPath)")
  }

  private func rebuildIndex() {
    let dc = DistributedNotificationCenter.default()
    dc.postNotificationName(
      NSNotification.Name("com.easyq.agent.forceScan"),
      object: nil,
      userInfo: ["rebuild": true],
      deliverImmediately: true
    )
    print("✅ 已发送全量重建指令")
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

  // 跳转到 Finder 的核心方法
  func revealInFinder( url: String) {

    let url = URL(fileURLWithPath: url)

    // 使用 NSWorkspace 在 Finder 中选中并打开
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

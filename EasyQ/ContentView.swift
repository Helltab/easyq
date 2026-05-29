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

// MARK: - FocusedValue keys

struct FocusedIndexCountKey: FocusedValueKey { typealias Value = Int }
struct FocusedSelectFolderKey: FocusedValueKey { typealias Value = () -> Void }
struct FocusedRebuildKey: FocusedValueKey { typealias Value = () -> Void }
struct FocusedRebuildViewsKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
  var indexCount: Int? {
    get { self[FocusedIndexCountKey.self] }
    set { self[FocusedIndexCountKey.self] = newValue }
  }
  var selectFolder: (() -> Void)? {
    get { self[FocusedSelectFolderKey.self] }
    set { self[FocusedSelectFolderKey.self] = newValue }
  }
  var rebuildIndex: (() -> Void)? {
    get { self[FocusedRebuildKey.self] }
    set { self[FocusedRebuildKey.self] = newValue }
  }
  var rebuildViews: (() -> Void)? {
    get { self[FocusedRebuildViewsKey.self] }
    set { self[FocusedRebuildViewsKey.self] = newValue }
  }
}

// MARK: - Main View

struct FileSearchView: View {
  @State private var searchText = ""
  @State private var files: [FileMetadata] = []
  @State private var selectedFileIDs = Set<FileMetadata.ID>()
  @State private var showingFolderAlert = false
  @State private var showingRebuildAlert = false
  @State private var showingNewView = false
  @State private var pendingPath: String = ""
  @State private var searchTask: Task<Void, Never>? = nil
  @State private var totalCount: Int = 0
  @State private var detailMode: DetailMode = .search
  @StateObject private var workspace = WorkspaceManager()
  @StateObject private var viewManager = ViewManager()

  let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

  private var dbManager: FileDatabase? = try? FileDatabase(name: "easyqfiles.db")

  private var displayedFiles: [FileMetadata] {
    switch detailMode {
    case .search: return files
    case .workspace: return workspace.items
    }
  }

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        Text("EasyQ")
          .font(.title2.bold())
          .padding(.top, 16)
          .padding(.horizontal)

        // 模式切换
        Picker("", selection: $detailMode) {
          ForEach(DetailMode.allCases, id: \.self) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 12)

        // 搜索框
        TextField("输入关键词搜索...", text: $searchText)
          .textFieldStyle(.roundedBorder)
          .padding(.horizontal)
          .padding(.top, 12)
          .onChange(of: searchText, perform: { _ in
            searchTask?.cancel()
            searchTask = Task {
              try? await Task.sleep(nanoseconds: 150_000_000)
              if !Task.isCancelled {
                performSearch()
              }
            }
          })

        // 视图列表
        viewList

        Spacer()
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 240)
      .sheet(isPresented: $showingNewView) {
        NewViewSheet(viewManager: viewManager, dbManager: dbManager)
      }
      .alert("确认同步该目录？", isPresented: $showingFolderAlert) {
        Button("开始扫描") { confirmAndSendToAgent() }
        Button("取消", role: .cancel) { }
      } message: {
        Text("即将深度扫描并更新数据库：\n\(pendingPath)")
      }
      .alert("确认重建索引？", isPresented: $showingRebuildAlert) {
        Button("重建", role: .destructive) { doRebuildIndex() }
        Button("取消", role: .cancel) { }
      } message: {
        Text("将清空全部索引数据并从头扫描，耗时较长。\n此操作不可撤销。")
      }

    } detail: {
      VStack(spacing: 0) {
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
            } else if detailMode == .workspace {
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
            let msg: String = {
              switch detailMode {
              case .workspace: return "工作区为空，右键搜索结果可添加"
              case .search: return "没有找到匹配的文件"
              }
            }()
            Text(msg).foregroundStyle(.secondary)
          }
        }
      }
    }
    .focusedSceneValue(\.indexCount, totalCount)
    .focusedSceneValue(\.selectFolder, selectFolder)
    .focusedSceneValue(\.rebuildIndex, { showingRebuildAlert = true })
    .focusedSceneValue(\.rebuildViews, rebuildAllViews)
    .onAppear(perform: refreshData)
    .onReceive(timer) { _ in refreshData() }
    .onReceive(DistributedNotificationCenter.default().publisher(for: NSNotification.Name("com.easyq.agent.scanComplete"))) { _ in
      // 扫描完成后自动重建所有视图
      rebuildAllViews()
    }
  }

  // MARK: - 视图列表

  private var viewList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("视图")
          .font(.caption.bold())
          .foregroundColor(.secondary)
        Spacer()
        Button(action: { showingNewView = true }) {
          Image(systemName: "plus")
            .font(.caption)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal)
      .padding(.top, 12)

      ForEach(viewManager.views) { view in
        HStack {
          Image(systemName: "folder")
            .foregroundColor(.blue)
            .font(.caption)
          Text(view.name)
            .font(.system(size: 13))
            .lineLimit(1)
          Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .contextMenu {
          Button("重建") {
            if let db = dbManager {
              viewManager.rebuildView(view, db: db)
            }
          }
          Button("在 Finder 中打开") {
            revealInFinder(url: viewManager.viewDirectory(for: view).path)
          }
          Divider()
          Button("删除", role: .destructive) {
            viewManager.remove(view)
          }
        }
      }
    }
  }

  // MARK: - Actions

  func refreshData() {
    DispatchQueue.global(qos: .utility).async {
      let count = self.dbManager?.count() ?? 0
      DispatchQueue.main.async { self.totalCount = count }
    }
  }

  private func rebuildAllViews() {
    guard let db = dbManager else { return }
    DispatchQueue.global(qos: .utility).async {
      viewManager.rebuildAll(db: db)
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

  private func doRebuildIndex() {
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

// MARK: - 新建视图 Sheet

struct NewViewSheet: View {
  @ObservedObject var viewManager: ViewManager
  var dbManager: FileDatabase?
  @Environment(\.dismiss) var dismiss

  @State private var name = ""
  @State private var extensionsText = ""
  @State private var keywordsText = ""
  @State private var useDateFilter = false
  @State private var daysBack = 7
  @State private var customSQL = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("新建视图")
        .font(.headline)

      TextField("视图名称", text: $name)
        .textFieldStyle(.roundedBorder)

      Divider()

      Text("过滤规则")
        .font(.subheadline.bold())

      HStack {
        Text("扩展名:")
          .frame(width: 70, alignment: .trailing)
        TextField("pdf, docx, pptx", text: $extensionsText)
          .textFieldStyle(.roundedBorder)
      }

      HStack {
        Text("关键词:")
          .frame(width: 70, alignment: .trailing)
        TextField("report, 2024", text: $keywordsText)
          .textFieldStyle(.roundedBorder)
      }

      Toggle(isOn: $useDateFilter) {
        HStack {
          Text("最近修改:")
            .frame(width: 70, alignment: .trailing)
          if useDateFilter {
            TextField("", value: $daysBack, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 50)
            Text("天内")
          }
        }
      }

      VStack(alignment: .leading) {
        Text("自定义 SQL (可选):")
          .font(.caption)
          .foregroundColor(.secondary)
        TextField("size > 1000000", text: $customSQL)
          .textFieldStyle(.roundedBorder)
      }

      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("创建") { createView() }
          .keyboardShortcut(.defaultAction)
          .disabled(name.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 380)
  }

  private func createView() {
    var rules: [ViewRule] = []

    let exts = extensionsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    if !exts.isEmpty {
      rules.append(.extensions(exts))
    }

    let kws = keywordsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if !kws.isEmpty {
      rules.append(.filenameContains(kws))
    }

    if useDateFilter && daysBack > 0 {
      let date = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date())!
      rules.append(.modifiedAfter(date))
    }

    let sql = customSQL.trimmingCharacters(in: .whitespaces)
    if !sql.isEmpty {
      rules.append(.customSQL(sql))
    }

    guard !rules.isEmpty else { return }

    let view = ViewConfig(name: name, rules: rules)
    viewManager.add(view, db: dbManager)
    dismiss()
  }
}

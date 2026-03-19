import SwiftUI
import Combine
extension String {
  func cleanedPath() -> String {
    // 去空格 + 正则去掉末尾所有斜杠
    return self.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
  }
}

struct FileSearchView: View {
  @State private var searchText = ""
  @State private var files: [FileMetadata] = [] // 这里存放搜索结果
  @State private var selectedFileID: FileMetadata.ID?
  @State private var showingConfirmAlert = false
  @State private var pendingPath: String = ""
  @State private var searchTask: Task<Void, Never>? = nil
  @State private var totalCount: Int = 0
  
  // 定时器：每 5 秒刷新一次界面
  let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
  
  private var dbManager: FileDatabase? = try? FileDatabase(name: "easyqfiles.db")
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
              // 3. 等待 300 毫秒 (0.3秒)
              try? await Task.sleep(nanoseconds: 200_000_000)
              
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
      // --- 右侧表格 ---
      Table(filteredFiles, selection: $selectedFileID) {
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
        // 右键菜单跳转
        Button("在 Finder 中显示") {
          if let selectedFile = filteredFiles.first(where: { $0.id == selectedFileID }) {
            revealInFinder(url: selectedFile.parent + "/" + selectedFile.name)
          }
        }
      }
      // 双击某行跳转
      .contentShape(Rectangle()) // 保证整行可点
      .onTapGesture {
        // 检查 Command 键是否被按下
        if NSEvent.modifierFlags.contains(.command) {
          // 执行 Cmd + 单击 的逻辑
          if let selectedFile = filteredFiles.first(where: { $0.id == selectedFileID }) {
            revealInFinder(url: selectedFile.parent + "/" + selectedFile.name)
          }
        } else {
          // 普通单击逻辑：更新选中状态（Table 默认已处理，这里可留空）
          
        }
      }
      .overlay {
        if filteredFiles.isEmpty {
          Text("没有找到匹配的文件").foregroundStyle(.secondary)
        }
      }
    }
  }
  
  func refreshData() {
    self.totalCount = dbManager?.count() ?? 0
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
  
  private func performSearch() {
    if searchText.isEmpty {
      files = []
    } else {
      files = dbManager?.searchFiles(keyword: searchText) ?? []
    }
  }
  // 过滤逻辑
  var filteredFiles: [FileMetadata] {
    if searchText.isEmpty { return files }
    return files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
  }
  
  // 跳转到 Finder 的核心方法
  func revealInFinder( url: String) {
    
    let url = URL(fileURLWithPath: url)
    
    // 使用 NSWorkspace 在 Finder 中选中并打开
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}

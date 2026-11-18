//
//  FileSyncManager.swift
//  EasyQ
//
//  Created by PP on 2026/3/18.
//


//
//  FileSyncManager.swift
//  hellfs
//
//  Created by PP on 2026/3/18.
//


import Foundation

class FileSyncManager {
  // 待处理的“脏路径”池（自动去重）
  private var dirtyPaths = Set<String>()
  weak var delegate: ScannerDelegate?
  // 防抖动任务
  private var pendingWorkItem: DispatchWorkItem?
  private let syncQueue = DispatchQueue(label: "com.app.sync.queue")
  
  // 外部传入的文件监听流
  private var stream: FSEventStreamRef?
  private let excludedPaths: [String] = [
    "\(NSHomeDirectory())/Library",
    "\(NSHomeDirectory())/.Trash",
    "\(NSHomeDirectory())/Downloads/.DS_Store"
  ]
  // --- 1. 启动监听 ---
  func startMonitoring(paths: [String]) {
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil, release: nil, copyDescription: nil
    )
    
    let callback: FSEventStreamCallback = { (stream, clientInfo, numEvents, eventPaths, eventFlags, eventIds) in
      let manager = Unmanaged<FileSyncManager>.fromOpaque(clientInfo!).takeUnretainedValue()
      let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
      // 过滤：检查路径的每一个组件（祖先目录命中忽略名单也跳过），
      // 之前只看最后一级文件名，导致 target/、node_modules/ 内部的海量删除事件全部涌入
      let filteredPaths = paths.filter { path in
        !IgnoreSet.shouldIgnorePath(path)
      }

      // 4. 如果过滤后还有路径，交给 manager 处理
      if !filteredPaths.isEmpty {
        manager.markPathsAsDirty(filteredPaths)
      }
    }
    
    stream = FSEventStreamCreate(
      kCFAllocatorDefault,
      callback,
      &context,
      paths as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      1.0, // 系统层面的合并延迟
      UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
    )
    FSEventStreamSetExclusionPaths(stream!, excludedPaths as CFArray)
    FSEventStreamSetDispatchQueue(stream!, syncQueue)
    FSEventStreamStart(stream!)
  }
  
  // --- 2. 收集路径并防抖 ---
  private func markPathsAsDirty(_ paths: [String]) {
    syncQueue.async {
      for path in paths {
        self.dirtyPaths.insert(path)
      }
      
      self.pendingWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in
        self?.performSync()
      }
      self.pendingWorkItem = workItem
      self.syncQueue.asyncAfter(deadline: .now() + 10.0, execute: workItem)
    }
  }
  
  // --- 3. 核心同步逻辑 ---
  private func performSync() {
    // 1. 拷贝并清空原始池，保证线程安全且不遗漏新事件
    let pathsToProcess = self.dirtyPaths
    self.dirtyPaths.removeAll()
    
    guard !pathsToProcess.isEmpty else { return }
    
    var updateList:[FileMetadata] = []
    var deleteList:[FileMetadata] = []

    let fileManager = FileManager.default

    log("📁 正在分析 \(pathsToProcess.count) 条变更路径...")

    // 2. 物理状态检查与分组
    // 删除项不需要 stat：fileExists 已经确认文件不在了，直接从路径切出 parent/name
    // （此前对 38 万个已删除文件逐个 attributesOfItem，全部抛错刷日志）
    for path in pathsToProcess {
      if fileManager.fileExists(atPath: path) {
        if let metadata = FileMetadata(path: path) {
          updateList.append(metadata)
        }
      } else {
        let url = URL(fileURLWithPath: path)
        deleteList.append(FileMetadata(
          parent: url.deletingLastPathComponent().path,
          name: url.lastPathComponent
        ))
      }
    }

    log("变更分组完成: 更新 \(updateList.count) 项, 删除 \(deleteList.count) 项")

    // 3. 执行批量分发（分片，避免巨型事务把 journal 撑爆）
    let chunkSize = 500
    if !deleteList.isEmpty {
      for start in stride(from: 0, to: deleteList.count, by: chunkSize) {
        let chunk = Array(deleteList[start..<min(start + chunkSize, deleteList.count)])
        delegate?.syncDelete(chunk)
      }
    }
    if !updateList.isEmpty {
      for start in stride(from: 0, to: updateList.count, by: chunkSize) {
        let chunk = Array(updateList[start..<min(start + chunkSize, updateList.count)])
        delegate?.syncUpdate(chunk)
      }
    }

    log("✅ 批处理任务分发完成")
  }
  
  
}

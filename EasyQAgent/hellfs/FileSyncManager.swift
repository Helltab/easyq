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
      
      manager.markPathsAsDirty(paths)
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
    
    print("📁 正在分析 \(pathsToProcess.count) 条变更路径...")
    
    // 2. 物理状态检查与分组
    for path in pathsToProcess {
      // 建议使用 URL 统一处理路径，能更好地处理空格和特殊字符
      if fileManager.fileExists(atPath: path) {
        if let metadata = FileMetadata(path: path) {
          updateList.append(metadata)
        }
        
      } else {
        if let metadata = FileMetadata(path: path) {
          deleteList.append(metadata)
        }
        
      }
    }
    
    // 3. 执行批量分发
    // 使用 DispatchGroup 或直接同步调用，确保数据库事务的完整性
    if !deleteList.isEmpty {
      print("🗑️ 准备删除: \(deleteList.count) 项")
      delegate?.syncDelete(deleteList)
    }
    
    if !updateList.isEmpty {
      print("📝 准备更新/插入: \(updateList.count) 项")
      delegate?.syncUpdate(updateList)
    }
    
    print("✅ 批处理任务分发完成")
  }
  
  
}

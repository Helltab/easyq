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

  // 暂存索引：变更即时入内存（GUI 立即可查），落库走防抖
  let pendingStore = PendingStore()
  // 落库防抖：60 秒批量提交（可查性由暂存层保证，落库只管持久化）
  private let flushInterval: TimeInterval = 60.0

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

  // --- 2. 收集路径：即时入暂存层，落库走防抖 ---
  private func markPathsAsDirty(_ paths: [String]) {
    syncQueue.async {
      // 即时入暂存索引：GUI 立即可搜到，不等落库
      // 删除项不再 stat（文件已不存在），更新项即时取元数据
      for path in paths {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
          if let metadata = FileMetadata(path: path) {
            self.pendingStore.record(file: metadata, deleted: false)
          }
        } else {
          self.pendingStore.record(
            file: FileMetadata(parent: url.deletingLastPathComponent().path, name: url.lastPathComponent),
            deleted: true
          )
        }
        self.dirtyPaths.insert(path)
      }

      self.pendingWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self] in
        self?.performSync()
      }
      self.pendingWorkItem = workItem
      self.syncQueue.asyncAfter(deadline: .now() + self.flushInterval, execute: workItem)
    }
  }

  // --- 3. 核心同步逻辑（防抖周期到：暂存层批量落库） ---
  private func performSync() {
    let pathsToProcess = self.dirtyPaths
    self.dirtyPaths.removeAll()

    guard !pathsToProcess.isEmpty else { return }

    // 从暂存层取出全部变更（取出即清除；失败项由后续 FSEvents 或全量重建兜底）
    let changes = pendingStore.drain()
    guard !changes.isEmpty else { return }

    var updateList:[FileMetadata] = []
    var deleteList:[FileMetadata] = []
    for change in changes {
      if change.deleted {
        deleteList.append(change.file)
      } else {
        updateList.append(change.file)
      }
    }

    log("🔄 防抖周期落库: 更新 \(updateList.count) 项, 删除 \(deleteList.count) 项")

    // 执行批量分发（分片执行，避免巨型事务）
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

    // 通知 GUI：本轮增量已落库，清空暂存缓存（避免墓碑长期残留）
    DistributedNotificationCenter.default().postNotificationName(
      NSNotification.Name("com.easyq.agent.pendingFlushed"),
      object: nil,
      userInfo: [:],
      deliverImmediately: true
    )

    log("✅ 批处理任务分发完成")
  }
}

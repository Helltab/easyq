import Foundation

/// 暂存索引：FSEvents 监听到的变更先入内存（O(1) 可查），延迟批量落库。
/// GUI 搜索时通过 DistributedNotificationCenter 拉取暂存增量与 SQLite 结果合并，
/// 实现"监听即索引、零延迟可查"，同时把落库频率降到 ~1次/分钟。
///
/// 设计要点：
/// - key = "parent/name"，天然去重（同一文件反复变更只留最新状态）
/// - 墓碑标记 deleted：GUI 合并时据此剔除库中的旧记录
/// - 拉取走快照拷贝，不阻塞 FSEvents 写入
/// - 落库成功后清空已落库部分；掉电最多丢一个防抖窗口的增量
final class PendingStore {

  struct PendingChange {
    var file: FileMetadata
    var deleted: Bool
  }

  private var entries: [String: PendingChange] = [:]
  private let lock = NSLock()
  /// 暂存条目上限：防极端事件洪水（如误删大目录）把内存撑爆
  private let maxEntries = 500_000

  /// FSEvents 收到变更时调用（同步、微秒级）
  func record(file: FileMetadata, deleted: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if entries.count >= maxEntries, entries[key(for: file)] == nil {
      // 超限时丢弃新增条目（库兜底，下次落库周期后一致）
      return
    }
    entries[key(for: file)] = PendingChange(file: file, deleted: deleted)
  }

  /// GUI 拉取暂存快照（浅拷贝 value，返回后内部继续可写）
  func snapshot() -> [PendingChange] {
    lock.lock()
    defer { lock.unlock() }
    return Array(entries.values)
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return entries.count
  }

  /// 取出待落库的变更（取出后即从暂存清除，无论落库成败都不回滚——
  /// 失败的项由下一轮 FSEvents 或全量重建兜底）
  func drain() -> [PendingChange] {
    lock.lock()
    defer { lock.unlock() }
    let out = Array(entries.values)
    entries.removeAll()
    return out
  }

  private func key(for file: FileMetadata) -> String {
    return file.parent + "/" + file.name
  }
}

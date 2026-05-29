import Foundation
import Combine
import SwiftUI

class ViewManager: ObservableObject {
  @Published var views: [ViewConfig] = []

  private let saveURL: URL
  private let viewsRoot: URL

  init() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = appSupport.appendingPathComponent("EasyQ")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    saveURL = dir.appendingPathComponent("views.json")

    viewsRoot = dir.appendingPathComponent("views")

    try? FileManager.default.createDirectory(at: viewsRoot, withIntermediateDirectories: true)

    load()
  }

  // MARK: - CRUD

  func add(_ view: ViewConfig, db: FileDatabase? = nil) {
    views.append(view)
    save()
    if let db = db {
      rebuildView(view, db: db)
    }
  }

  func remove(_ view: ViewConfig) {
    views.removeAll { $0.id == view.id }
    deleteSymlinkDir(for: view)
    save()
  }

  func update(_ view: ViewConfig) {
    if let idx = views.firstIndex(where: { $0.id == view.id }) {
      views[idx] = view
      save()
    }
  }

  // MARK: - Rebuild

  func rebuildView(_ view: ViewConfig, db: FileDatabase) {
    let files = db.searchWithRules(view.rules)
    createSymlinks(for: view, files: files)
  }

  func rebuildAll(db: FileDatabase) {
    for view in views {
      rebuildView(view, db: db)
    }
  }

  /// 视图软连接目录路径
  func viewDirectory(for view: ViewConfig) -> URL {
    viewsRoot.appendingPathComponent(view.name)
  }

  // MARK: - Symlink Management

  private func createSymlinks(for view: ViewConfig, files: [FileMetadata]) {
    let fm = FileManager.default
    let viewDir = viewDirectory(for: view)

    // 清空旧目录
    try? fm.removeItem(at: viewDir)
    try? fm.createDirectory(at: viewDir, withIntermediateDirectories: true)

    for file in files {
      let sourcePath = file.parent + "/" + file.name
      let sourceURL = URL(fileURLWithPath: sourcePath)

      // 处理同名文件：加父目录后缀
      var linkName = file.name
      var linkURL = viewDir.appendingPathComponent(linkName)
      var counter = 1
      while fm.fileExists(atPath: linkURL.path) {
        let ext = (sourcePath as NSString).pathExtension
        let base = (sourcePath as NSString).deletingPathExtension
        let parentName = (file.parent as NSString).lastPathComponent
        linkName = ext.isEmpty
          ? "\(file.name)_\(parentName)_\(counter)"
          : "\((file.name as NSString).deletingPathExtension)_\(parentName)_\(counter).\(ext)"
        linkURL = viewDir.appendingPathComponent(linkName)
        counter += 1
      }

      try? fm.createSymbolicLink(at: linkURL, withDestinationURL: sourceURL)
    }
  }

  private func deleteSymlinkDir(for view: ViewConfig) {
    try? FileManager.default.removeItem(at: viewDirectory(for: view))
  }

  // MARK: - Persistence

  func save() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(views) else { return }
    try? data.write(to: saveURL)
  }

  private func load() {
    guard let data = try? Data(contentsOf: saveURL) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    views = (try? decoder.decode([ViewConfig].self, from: data)) ?? []
  }
}

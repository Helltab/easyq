import Foundation

class WorkspaceManager: ObservableObject {
  @Published var items: [FileMetadata] = []

  private let saveURL: URL

  init() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = appSupport.appendingPathComponent("EasyQ")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    saveURL = dir.appendingPathComponent("workspace.json")
    load()
  }

  func add(_ file: FileMetadata) {
    guard !items.contains(where: { $0.id == file.id }) else { return }
    items.append(file)
    save()
  }

  func remove(_ file: FileMetadata) {
    items.removeAll { $0.id == file.id }
    save()
  }

  func remove(atOffsets offsets: IndexSet) {
    items.remove(atOffsets: offsets)
    save()
  }

  func contains(_ file: FileMetadata) -> Bool {
    items.contains(where: { $0.id == file.id })
  }

  func clear() {
    items.removeAll()
    save()
  }

  private func save() {
    let data = items.map { ["parent": $0.parent, "name": $0.name] }
    try? JSONSerialization.data(withJSONObject: data).write(to: saveURL)
  }

  private func load() {
    guard let data = try? Data(contentsOf: saveURL),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return }
    items = arr.compactMap { dict in
      guard let parent = dict["parent"], let name = dict["name"] else { return nil }
      return FileMetadata(parent: parent, name: name, size: 0, mtime: 0, isDir: false)
    }
  }
}

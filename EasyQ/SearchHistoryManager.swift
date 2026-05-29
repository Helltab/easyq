import Foundation
import Combine

class SearchHistoryManager: ObservableObject {
  @Published var history: [String] = []

  private let key = "EasyQ_SearchHistory"
  private let maxCount = 20

  init() {
    load()
  }

  func add(_ keyword: String) {
    let trimmed = keyword.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    history.removeAll { $0 == trimmed }
    history.insert(trimmed, at: 0)
    if history.count > maxCount {
      history = Array(history.prefix(maxCount))
    }
    save()
  }

  func remove(_ keyword: String) {
    history.removeAll { $0 == keyword }
    save()
  }

  func clear() {
    history = []
    save()
  }

  private func save() {
    UserDefaults.standard.set(history, forKey: key)
  }

  private func load() {
    history = UserDefaults.standard.stringArray(forKey: key) ?? []
  }
}

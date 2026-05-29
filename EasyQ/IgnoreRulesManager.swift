import Foundation
import Combine

struct IgnoreRulesConfig: Codable {
  var hardSkip: [String]
  var softSkip: [String]

  static let `default` = IgnoreRulesConfig(
    hardSkip: [
      "node_modules", "bower_components", ".pnpm-store",
      ".git", ".svn", ".hg",
      "envs", "venv", "env", ".tox", "__pycache__", ".mypy_cache",
      ".cargo", ".rustup", ".gradle", ".m2", ".pub-cache",
      ".Trash", "Library", ".DS_Store", ".localized",
      "DerivedData", ".idea", ".vscode", ".fleet",
      "Caches", "Cookies", "Containers",
    ],
    softSkip: [
      "dist", "build", "target", "bin", "obj",
      "out", "output", "release", "debug",
      ".next", ".nuxt", ".turbo", ".cache",
      "coverage", ".nyc_output",
      "vendor", "Pods", ".spm",
    ]
  )
}

class IgnoreRulesManager: ObservableObject {
  @Published var config: IgnoreRulesConfig = .default

  private let configURL: URL

  init() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = appSupport.appendingPathComponent("EasyQ")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    configURL = dir.appendingPathComponent("ignoreRules.json")
    load()
  }

  func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    guard let data = try? encoder.encode(config) else { return }
    try? data.write(to: configURL)
  }

  func resetToDefaults() {
    config = .default
    save()
  }

  func addHardSkip(_ name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty && !config.hardSkip.contains(trimmed) else { return }
    config.hardSkip.append(trimmed)
    save()
  }

  func removeHardSkip(_ name: String) {
    config.hardSkip.removeAll { $0 == name }
    save()
  }

  func addSoftSkip(_ name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty && !config.softSkip.contains(trimmed) else { return }
    config.softSkip.append(trimmed)
    save()
  }

  func removeSoftSkip(_ name: String) {
    config.softSkip.removeAll { $0 == name }
    save()
  }

  /// 获取配置文件路径（供 Agent 端读取）
  static var configFilePath: String {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("EasyQ/ignoreRules.json").path(percentEncoded: false)
  }

  private func load() {
    guard let data = try? Data(contentsOf: configURL) else { return }
    config = (try? JSONDecoder().decode(IgnoreRulesConfig.self, from: data)) ?? .default
  }
}

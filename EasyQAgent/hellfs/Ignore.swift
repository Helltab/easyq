import Foundation

/// 分级过滤策略：
/// - 硬跳过（hardSkip）：完全不进入，如 node_modules、.git 等
/// - 软跳过（softSkip）：进入但限制递归深度（最多 1 层），如 dist、build 等
///
/// 从 ~/Library/Application Support/EasyQ/ignoreRules.json 读取配置，
/// 若文件不存在则使用内置默认值。

struct IgnoreRulesConfig: Codable {
  var hardSkip: [String]
  var softSkip: [String]
}

class IgnoreSet {

  // MARK: - 默认值（配置文件不存在时使用）

  private static let defaultHardSkip: Set<String> = [
    "node_modules", "bower_components", ".pnpm-store",
    ".git", ".svn", ".hg",
    "envs", "venv", "env", ".tox", "__pycache__", ".mypy_cache",
    ".cargo", ".rustup", ".gradle", ".m2", ".pub-cache",
    ".Trash", "Library", ".DS_Store", ".localized",
    "DerivedData", ".idea", ".vscode", ".fleet",
    "Caches", "Cookies", "Containers",
    "easyQ",
  ]

  private static let defaultSoftSkip: Set<String> = [
    "dist", "build", "target", "bin", "obj",
    "out", "output", "release", "debug",
    ".next", ".nuxt", ".turbo", ".cache",
    "coverage", ".nyc_output",
    "vendor", "Pods", ".spm",
  ]

  // MARK: - 运行时配置

  private static var hardSkipNames: Set<String> = defaultHardSkip
  private static var softSkipNames: Set<String> = defaultSoftSkip

  /// 从配置文件加载，若失败则使用默认值
  static func loadConfig() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let configURL = appSupport.appendingPathComponent("EasyQ/ignoreRules.json")

    guard let data = try? Data(contentsOf: configURL),
          let config = try? JSONDecoder().decode(IgnoreRulesConfig.self, from: data) else {
      log("使用默认排除规则")
      return
    }

    hardSkipNames = Set(config.hardSkip)
    softSkipNames = Set(config.softSkip)
    log("已加载自定义排除规则: 硬跳过 \(hardSkipNames.count) 个, 软跳过 \(softSkipNames.count) 个")
  }

  // 硬跳过：名称完全匹配
  static func shouldHardSkip(name: String) -> Bool {
    return hardSkipNames.contains(name)
  }

  // 软跳过：名称完全匹配
  static func shouldSoftSkip(name: String) -> Bool {
    return softSkipNames.contains(name)
  }

  // 综合判断（供 FileSyncManager 等不需要深度控制的场景使用）
  static func shouldIgnore(name: String) -> Bool {
    if shouldHardSkip(name: name) { return true }
    if shouldSoftSkip(name: name) { return true }
    if name.hasPrefix(".") { return true }
    return false
  }

  /// 路径级判断：任何一个祖先目录（或自身）命中忽略名单即忽略。
  /// 供 FSEvents 回调过滤事件使用——此前只看最后一级文件名，
  /// 删除 target/、node_modules/ 内部几十万个文件时事件全部涌入。
  static func shouldIgnorePath(_ path: String) -> Bool {
    // 去掉尾部的"/"，按"/"切分出每一级组件
    var components = path.split(separator: "/").map(String.init)
    // FSEvents 通常给目录路径（末尾无斜杠）；末级组件若是普通文件名，
    // 单独按 shouldIgnore 检查即可；其余组件按目录名单检查
    if let last = components.last {
      if shouldIgnore(name: last) { return true }
      components.removeLast()
    }
    for comp in components {
      if shouldHardSkip(name: comp) { return true }
      if shouldSoftSkip(name: comp) { return true }
      if comp.hasPrefix(".") { return true }
    }
    return false
  }
}

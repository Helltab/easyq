import Foundation

/// 分级过滤策略：
/// - 硬跳过（hardSkip）：完全不进入，如 node_modules、.git 等
/// - 软跳过（softSkip）：进入但限制递归深度（最多 1 层），如 dist、build 等
enum IgnoreSet {

  // MARK: - 硬跳过：完全不递归，已知无价值的目录

  static let hardSkipNames: Set<String> = [
    // 包管理
    "node_modules", "bower_components", ".pnpm-store",
    // 版本控制
    ".git", ".svn", ".hg",
    // 语言生态
    "envs", "venv", "env", ".tox", "__pycache__", ".mypy_cache",
    ".cargo", ".rustup", ".gradle", ".m2", ".pub-cache",
    // 系统/IDE
    ".Trash", "Library", ".DS_Store", ".localized",
    "DerivedData", ".idea", ".vscode", ".fleet",
    "Caches", "Cookies", "Containers",
  ]

  // MARK: - 软跳过：进入但限制递归深度

  static let softSkipNames: Set<String> = [
    "dist", "build", "target", "bin", "obj",
    "out", "output", "release", "debug",
    ".next", ".nuxt", ".turbo", ".cache",
    "coverage", ".nyc_output",
    "vendor", "Pods", ".spm",
  ]

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
}

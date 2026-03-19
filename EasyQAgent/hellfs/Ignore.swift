enum IgnoreSet {
  // 1. 完全匹配的目录/文件名
  static let skipNames: Set<String> = [
    "node_modules", "dist", "build", "target", "bin", "obj",
    ".git", ".svn", "envs", "venv", "env", ".Trash", "Library",
    ".DS_Store", ".localized", "DerivedData", ".idea", ".vscode"
  ]
  


 
  static func shouldIgnore(name: String) -> Bool {
  
    
    if skipNames.contains(name) { return true }

    
    if name.hasPrefix(".") {
      return true
    }
    
    return false
  }
}

import Foundation

struct ViewConfig: Codable, Identifiable, Equatable {
  var id: UUID = UUID()
  var name: String
  var rules: [ViewRule]
  var createdAt: Date = Date()

  static func == (lhs: ViewConfig, rhs: ViewConfig) -> Bool {
    lhs.id == rhs.id
  }
}

enum ViewRule: Codable, Equatable {
  case extensions([String])         // ["pdf", "docx"]
  case filenameContains([String])   // ["report", "2024"]
  case modifiedAfter(Date)          // 最近修改
  case customSQL(String)            // 自定义 WHERE 子句

  var displayText: String {
    switch self {
    case .extensions(let exts):
      return "扩展名: \(exts.joined(separator: ", "))"
    case .filenameContains(let keywords):
      return "关键词: \(keywords.joined(separator: ", "))"
    case .modifiedAfter(let date):
      let formatter = DateFormatter()
      formatter.dateStyle = .medium
      return "修改于: \(formatter.string(from: date)) 之后"
    case .customSQL(let sql):
      return "SQL: \(sql)"
    }
  }
}

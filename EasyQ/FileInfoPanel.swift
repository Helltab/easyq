import SwiftUI

struct FileInfoPanel: View {
  let file: FileMetadata

  private var fullPath: String {
    file.parent + "/" + file.name
  }

  private var fileInfo: (created: String, type: String, permissions: String) {
    let fm = FileManager.default
    let url = URL(fileURLWithPath: fullPath)

    var created = "--"
    var type = file.isDir ? "文件夹" : "文件"
    var permissions = "--"

    if let attrs = try? fm.attributesOfItem(atPath: fullPath) {
      if let cd = attrs[.creationDate] as? Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        created = fmt.string(from: cd)
      }
      if let ft = attrs[.type] as? FileAttributeType {
        switch ft {
        case .typeRegular: type = "文件"
        case .typeDirectory: type = "文件夹"
        case .typeSymbolicLink: type = "符号链接"
        default: type = ft.rawValue
        }
      }
      if let perms = attrs[.posixPermissions] as? NSNumber {
        let p = perms.intValue
        permissions = String(format: "%o", p)
      }
    }

    return (created, type, permissions)
  }

  var body: some View {
    let info = fileInfo

    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 4) {
        infoRow("路径", fullPath)
        infoRow("类型", info.type)
      }
      VStack(alignment: .leading, spacing: 4) {
        infoRow("大小", file.sizeString)
        infoRow("修改时间", file.modificationDate)
      }
      VStack(alignment: .leading, spacing: 4) {
        infoRow("创建时间", info.created)
        infoRow("权限", info.permissions)
      }
      Spacer()
    }
    .font(.caption)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private func infoRow(_ label: String, _ value: String) -> some View {
    HStack(spacing: 4) {
      Text(label + ":")
        .foregroundColor(.secondary)
        .frame(width: 55, alignment: .trailing)
      Text(value)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

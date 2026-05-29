import SwiftUI

struct IgnoreRulesView: View {
  @ObservedObject var manager: IgnoreRulesManager
  @Environment(\.dismiss) var dismiss

  @State private var newHardSkip = ""
  @State private var newSoftSkip = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("排除规则设置")
          .font(.headline)
        Spacer()
        Button("恢复默认") { manager.resetToDefaults() }
          .font(.caption)
      }

      Text("硬跳过 — 完全不扫描的目录（高性能）")
        .font(.subheadline.bold())
        .foregroundColor(.secondary)

      ruleSection(items: $manager.config.hardSkip, newItem: $newHardSkip, add: manager.addHardSkip, remove: manager.removeHardSkip)

      Divider()

      Text("软跳过 — 只扫描一层的目录")
        .font(.subheadline.bold())
        .foregroundColor(.secondary)

      ruleSection(items: $manager.config.softSkip, newItem: $newSoftSkip, add: manager.addSoftSkip, remove: manager.removeSoftSkip)

      HStack {
        Spacer()
        Button("完成") {
          manager.save()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 420, height: 500)
  }

  private func ruleSection(items: Binding<[String]>, newItem: Binding<String>, add: @escaping (String) -> Void, remove: @escaping (String) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(items.wrappedValue, id: \.self) { item in
        HStack {
          Text(item)
            .font(.system(size: 12, design: .monospaced))
          Spacer()
          Button(action: { remove(item) }) {
            Image(systemName: "minus.circle")
              .foregroundColor(.red)
              .font(.caption)
          }
          .buttonStyle(.plain)
        }
        .padding(.vertical, 1)
      }

      HStack {
        TextField("添加目录名...", text: newItem)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 12))
          .onSubmit {
            add(newItem.wrappedValue)
            newItem.wrappedValue = ""
          }
        Button(action: {
          add(newItem.wrappedValue)
          newItem.wrappedValue = ""
        }) {
          Image(systemName: "plus.circle")
            .foregroundColor(.green)
        }
        .buttonStyle(.plain)
        .disabled(newItem.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }
}

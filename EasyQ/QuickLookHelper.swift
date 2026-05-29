import AppKit
import Quartz

/// 包装 AppKit QLPreviewPanel，兼容 macOS 13.5+
class QuickLookHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  static let shared = QuickLookHelper()

  private var previewURL: URL?

  func preview(_ url: URL) {
    previewURL = url

    if let panel = QLPreviewPanel.shared() {
      if panel.isVisible {
        panel.reloadData()
      } else {
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
      }
    }
  }

  func toggle(_ url: URL) {
    if let panel = QLPreviewPanel.shared(), panel.isVisible {
      panel.orderOut(nil)
    } else {
      preview(url)
    }
  }

  func close() {
    QLPreviewPanel.shared()?.orderOut(nil)
  }

  // MARK: - QLPreviewPanelDataSource

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    return previewURL != nil ? 1 : 0
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem {
    return previewURL! as QLPreviewItem
  }
}

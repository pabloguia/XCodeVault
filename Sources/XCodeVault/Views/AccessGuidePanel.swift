import AppKit
import SwiftUI
import XCodeVaultCore

/// The Full Disk Access guide (R5, the user's real-window feedback): a small floating panel beside System Settings, shown
/// when the app opens the pane. XCodeVault sits near the end of the pane's alphabetical list and macOS offers no API to
/// scroll to it or select it, so the panel says where to look, and offers the app's icon to drag into the list if it is
/// not there. It does not take focus from System Settings and stays up when the app is in the background. When it shows and
/// when it closes is `AppModel`'s (`openFullDiskAccessSettings`, `closeAccessGuide`); this only draws it.
@MainActor
final class AccessGuidePanel {
    static let shared = AccessGuidePanel()
    private var panel: NSPanel?

    func show(done: @escaping @MainActor () -> Void) {
        let content = NSHostingView(rootView: AccessGuideView(done: done))
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 24, y: screen.maxY - 24))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.title = L10n.tr("app.access.guide.title")
        panel.isFloatingPanel = true
        panel.level = .floating
        // System Settings is in front while the user follows the guide: the panel must stay up while XCodeVault is not.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

/// The panel's content: the app's icon as a drag source (its bundle as a file URL, which the pane's list accepts as **+**
/// does), the hint, and **Done**.
struct AccessGuideView: View {
    let done: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable().frame(width: 56, height: 56)
                    .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                    .help(L10n.tr("app.access.guide.drag"))
                    .accessibilityLabel(Text(verbatim: AppText.productName))
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: L10n.tr("app.access.fda.hint.inList")).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: L10n.tr("app.access.guide.drag")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(L10n.tr("app.access.guide.done"), action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

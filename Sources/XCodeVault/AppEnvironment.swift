import AppKit
import XCodeVaultCore

/// Everything `AppModel` reaches outside the process, as one value: `.live` in the app, fakes in tests, so a test
/// never scans this Mac, writes its journal, touches launchd or opens System Settings.
struct AppEnvironment: Sendable {
    /// One scan and what is derived from it. Nil in the app, where `AppModel.refresh()` runs the real one; a test
    /// supplies its own.
    var survey: (@Sendable () -> AppModel.Survey)?
    var fullDiskAccess: @Sendable () -> FullDiskAccessState
    var helper: any PrivilegedHelper
    var approvalFlow: @Sendable (any PrivilegedHelper) -> HelperApprovalFlow
    var runner: @Sendable (any PrivilegedHelper) -> PrivilegedActionRunner
    var clean: @Sendable (CleanPlan, Bool) throws -> CleanResult
    var open: @MainActor @Sendable (URL) -> Void
    /// **Copy command** and **Copy log** in the Park, Run externally and Delete views: the string goes to the pasteboard as is.
    var copy: @MainActor @Sendable (String) -> Void
    /// Just before the Full Disk Access pane opens: one attempt at a folder Full Disk Access guards, so macOS lists the
    /// app in the pane (`FullDiskAccessRegistration`, R4). A no-op unless set: a test never touches TCC.
    var registerForFullDiskAccess: @Sendable () -> Void = {}
    /// **Run…** in Park, Run externally and Delete (R3): previews, runs, the second steps and the folder panel. `.inert`
    /// unless set, so a test that does not supply fakes cannot reach Core's operations.
    var operations: OperationServices = .inert

    static let live = AppEnvironment(
        survey: nil, fullDiskAccess: { FullDiskAccessProbe().state() }, helper: LiveHelper(),
        approvalFlow: { HelperApprovalFlow(helper: $0) }, runner: { PrivilegedActionRunner(helper: $0) },
        clean: { plan, useTrash in try CleanExecutor(useTrash: useTrash).execute(plan) },
        open: { url in _ = NSWorkspace.shared.open(url) },
        copy: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        },
        registerForFullDiskAccess: { _ = FullDiskAccessRegistration().attempt() }, operations: .live)
}

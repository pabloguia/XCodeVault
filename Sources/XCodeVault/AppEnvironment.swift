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

    static let live = AppEnvironment(
        survey: nil, fullDiskAccess: { FullDiskAccessProbe().state() }, helper: LiveHelper(),
        approvalFlow: { HelperApprovalFlow(helper: $0) }, runner: { PrivilegedActionRunner(helper: $0) },
        clean: { plan, useTrash in try CleanExecutor(useTrash: useTrash).execute(plan) },
        open: { url in _ = NSWorkspace.shared.open(url) })
}

import AppKit
import SwiftUI
import XCTest

@testable import XCodeVault
@testable import XCodeVaultCore

/// The deliverable 3 and 4 views, rendered in every state those deliverables added. Off screen: an
/// `NSHostingView` with no window, so nothing appears (a window on screen needs the operator's OK). What these
/// check is that each state renders; what it looks like is not checked here. Sheets, alerts and confirmation
/// dialogs render only when presented in a window, so their contents are not reached.
@MainActor
final class AppViewRenderTests: XCTestCase {
    nonisolated override func tearDown() {
        L10n.configure(override: "en", environment: [:], preferred: [])
        super.tearDown()
    }

    @discardableResult
    private func render<V: View>(_ view: V, file: StaticString = #filePath, line: UInt = #line) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        host.layoutSubtreeIfNeeded()
        // No size check: a `List` has no intrinsic size, so `fittingSize` is 0 for the Doctor however it rendered.
        XCTAssertNil(host.window, "rendered without a window", file: file, line: line)
        return host
    }

    private func scannedModel(
        _ state: HelperState, fullDiskAccess: FullDiskAccessState = .granted, survey: AppModel.Survey = sampleSurvey(), journal: TempDir
    ) async -> AppModel {
        let model = makeModel(SwitchableHelper(state), journal: journal, fullDiskAccess: fullDiskAccess, survey: survey)
        await model.refresh()
        return model
    }

    func testTheActionControlRendersInEveryHelperState() {
        for state in HelperState.allCases {
            render(PrivilegedActionControlView(action: .emptyCoreSimulatorDyldCache, state: state) {})
        }
    }

    func testTheOverviewRendersWithAndWithoutTheFullDiskAccessPrompt() {
        for (refusals, access) in [(0, FullDiskAccessState.granted), (3, .notGranted), (3, .unknown), (3, .granted)] {
            let survey = sampleSurvey(refusals: refusals)
            render(OverviewView(report: survey.0, findings: [], fullDiskAccess: access) {})
        }
    }

    func testTheMainViewRendersLoadingScannedAndWaitingForApproval() async {
        let t = TempDir()
        render(MainView(model: makeModel(SwitchableHelper(.notInstalled), journal: t)))
        let scanned = await scannedModel(.enabled, journal: t)
        render(MainView(model: scanned))
        scanned.helperProgress = "Waiting for you to approve XCodeVault…"
        render(MainView(model: scanned))
    }

    func testTheDoctorRendersAFindingThatCarriesAnAction() async {
        let t = TempDir()
        let finding = Finding(
            id: "vault-dir:U", severity: .info, title: "The vault folder could not be created on Drive", detail: "detail",
            path: "/Volumes/Drive/XCodeVault", remediation: "sudo mkdir …", evidence: "journal", action: .createVaultDirectory(volumeUUID: "U"))
        for state in HelperState.allCases {
            render(DoctorView(model: await scannedModel(state, survey: sampleSurvey(findings: [finding]), journal: t)))
        }
    }

    func testCleanRendersTheRowThatNeedsTheHelper() async {
        let t = TempDir()
        let dyld = CleanAction(
            categoryID: "coreSimulatorSystemCaches", categoryName: "CoreSimulator dyld caches", path: PrivilegeRequirement.coreSimulatorDyldCachePath,
            bytes: 1_000_000, isExperimental: true, risk: .low, requiresRoot: true, notes: [])
        let derived = CleanAction(
            categoryID: "derivedData", categoryName: "DerivedData", path: "/Users/tester/Library/Developer/Xcode/DerivedData", bytes: 500,
            isExperimental: true, risk: .low, requiresRoot: false, notes: [])
        for state in HelperState.allCases {
            render(CleanView(model: await scannedModel(state, survey: sampleSurvey(actions: [dyld, derived]), journal: t)))
        }
    }

    func testPermissionsRendersEveryCombination() async {
        let t = TempDir()
        for state in HelperState.allCases {
            for access in FullDiskAccessState.allCases {
                render(PermissionsView(model: await scannedModel(state, fullDiskAccess: access, journal: t)))
            }
        }
    }

    func testTheHelperSheetRendersWithAndWithoutAChosenAction() async {
        let t = TempDir()
        let model = await scannedModel(.notInstalled, journal: t)
        render(HelperRequestSheet(model: model))
        model.pendingPrivilegedAction = .emptyCoreSimulatorDyldCache
        render(HelperRequestSheet(model: model))
    }

    /// Every view, in each of the five languages (S4 Task 2): the strings come from the catalog, so a view that
    /// formats one wrongly fails here rather than on a user's screen.
    func testEveryViewRendersInEveryLanguage() async {
        let t = TempDir()
        let finding = Finding(
            id: "vault-dir:U", severity: .error, title: "The vault folder could not be created on Drive", detail: "detail",
            path: "/Volumes/Drive/XCodeVault", remediation: "sudo mkdir …", evidence: "journal", action: .createVaultDirectory(volumeUUID: "U"))
        let dyld = CleanAction(
            categoryID: "coreSimulatorSystemCaches", categoryName: "CoreSimulator dyld caches", path: PrivilegeRequirement.coreSimulatorDyldCachePath,
            bytes: 1_000_000, isExperimental: true, risk: .low, requiresRoot: true, notes: [])
        var rendered = 0
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            let survey = sampleSurvey(refusals: 3, findings: [finding], actions: [dyld])
            let model = await scannedModel(.notInstalled, fullDiskAccess: .notGranted, survey: survey, journal: t)
            render(MainView(model: model))
            render(OverviewView(report: survey.0, findings: [finding], fullDiskAccess: .notGranted) {})
            render(StorageView(report: survey.0))
            render(DoctorView(model: model))
            render(CleanView(model: model))
            render(VolumesView(report: survey.0, checks: []))
            render(RuntimesView(report: survey.0))
            render(JournalView(entries: []))
            let entry = JournalEntry(
                id: "op", sequence: 1, timestamp: Date(timeIntervalSince1970: 1_800_000_000), kind: .clean, state: .completed, summary: "s", paths: [],
                bytes: nil, detail: [:], toolVersion: "t")
            render(JournalView(entries: [entry]))
            render(PermissionsView(model: model))
            for state in HelperState.allCases { render(PrivilegedActionControlView(action: .emptyCoreSimulatorDyldCache, state: state) {}) }
            render(HelperRequestSheet(model: model))
            model.pendingPrivilegedAction = .emptyCoreSimulatorDyldCache
            render(HelperRequestSheet(model: model))
            rendered += 1
        }
        XCTAssertEqual(rendered, L10n.supportedLocales.count)
    }
}

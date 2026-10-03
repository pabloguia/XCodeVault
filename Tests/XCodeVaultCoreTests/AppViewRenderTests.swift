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

    /// Every Overview state (S4 Task 3): measured, lower bound, zero, not measured, with the runtimes line, with a clamped
    /// bar, with each banner the checklist can produce and with critical findings — in every language.
    func testTheOverviewRendersEveryStateInEveryLanguage() {
        let critical = Finding(id: "f", severity: .critical, title: "Shadow CoreSimulator directory", detail: "d", path: nil, remediation: nil, evidence: nil)
        let surveys = [
            sampleSurvey(savings: sampleSavings()),
            sampleSurvey(savings: sampleSavings(lowerBound: true), runtimeImageBytes: 9_400_000_000),
            sampleSurvey(),
            sampleSurvey(sizesMeasured: false),
            sampleSurvey(savings: sampleSavings(), free: 490_000_000_000),  // free + developer data > volume: clamped
        ]
        var banners: [AccessChecklist.Row?] = [nil]
        for fda in FullDiskAccessState.allCases {
            for helper in HelperState.allCases {
                banners += AccessChecklist.rows(fullDiskAccess: fda, helper: helper, savings: sampleSavings(lowerBound: true), plan: [], privacyRefusalCount: 3)
            }
        }
        var rendered = 0
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for survey in surveys {
                render(OverviewView(report: survey.0, findings: [critical], access: nil))
                rendered += 1
            }
            for banner in banners {
                render(OverviewView(report: surveys[0].0, findings: [], access: banner))
                rendered += 1
            }
        }
        XCTAssertEqual(rendered, L10n.supportedLocales.count * (surveys.count + banners.count))
    }

    func testTheMainViewRendersEverySection() async {
        let t = TempDir()
        for survey in [sampleSurvey(refusals: 2, savings: sampleSavings()), bucketSampleSurvey()] {
            let model = await scannedModel(.notInstalled, fullDiskAccess: .notGranted, survey: survey, journal: t)
            for section in SidebarSection.allCases {
                model.section = section
                render(MainView(model: model))
            }
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

    func testDeleteRendersTheRowThatNeedsTheHelper() async {
        let t = TempDir()
        let dyld = CleanAction(
            categoryID: "coreSimulatorSystemCaches", categoryName: "CoreSimulator dyld caches", path: PrivilegeRequirement.coreSimulatorDyldCachePath,
            bytes: 1_000_000, isExperimental: true, risk: .low, requiresRoot: true, notes: [])
        let derived = CleanAction(
            categoryID: "derivedData", categoryName: "DerivedData", path: "/Users/tester/Library/Developer/Xcode/DerivedData", bytes: 500,
            isExperimental: true, risk: .low, requiresRoot: false, notes: [])
        for state in HelperState.allCases {
            render(DeleteView(model: await scannedModel(state, survey: sampleSurvey(actions: [dyld, derived]), journal: t)))
            // With and without Delete's access row: shown for a root row and a helper that is not enabled.
            let model = await scannedModel(state, survey: bucketSampleSurvey(), journal: t)
            XCTAssertEqual(model.deleteAccessRow == nil, state == .enabled, "\(state)")
            render(DeleteView(model: model))
        }
    }

    /// The bucket views (S4 Task 4) in every language: Delete with groups, the root row and the other-tool rows; Park in
    /// each vault state; Run externally; and both plans empty.
    func testTheBucketViewsRenderInEveryLanguage() async {
        let t = TempDir()
        let v = VaultVolume(volumeUUID: "U", volumeName: "Drive", lastMountPoint: "/Volumes/Drive", registeredAt: Date(), sentinelID: "s")
        let checks: [[VaultVolumeCheck]] = [
            [], [VaultVolumeCheck(volume: v, state: .absent, currentMountPoint: nil, shadowBytes: nil, detail: "")],
            [VaultVolumeCheck(volume: v, state: .verified, currentMountPoint: "/Volumes/Drive", shadowBytes: nil, detail: "")],
            [VaultVolumeCheck(volume: v, state: .foreign, currentMountPoint: "/Volumes/Drive", shadowBytes: nil, detail: "")],
        ]
        var rendered = 0
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for check in checks {
                let model = await scannedModel(.notInstalled, survey: bucketSampleSurvey(checks: check), journal: t)
                XCTAssertFalse(model.deleteList?.groups.isEmpty ?? true)
                render(DeleteView(model: model))
                render(PlanView(bucket: .parkExternally, rows: model.rows(for: .parkExternally), vault: model.vaultStatus) { model.copyCommand($0) })
                render(PlanView(bucket: .runFromExternal, rows: model.rows(for: .runFromExternal), vault: nil) { model.copyCommand($0) })
                rendered += 1
            }
            render(PlanView(bucket: .parkExternally, rows: [], vault: .noVault) { _ in })
            render(PlanView(bucket: .runFromExternal, rows: [], vault: nil) { _ in })
            render(InlineCodeText(L10n.tr("cli.plan.note.rootOnly")))
        }
        XCTAssertEqual(rendered, L10n.supportedLocales.count * checks.count)
    }

    func testAccessRendersEveryCombination() async {
        let t = TempDir()
        render(AccessView(model: makeModel(SwitchableHelper(.notInstalled), journal: t)))  // before any scan
        for state in HelperState.allCases {
            for access in FullDiskAccessState.allCases {
                render(AccessView(model: await scannedModel(state, fullDiskAccess: access, journal: t)))
            }
        }
    }

    /// Every row the checklist can produce, alone (the banner and Delete's row are this view), in every language (S4 Task 5).
    func testEveryAccessRowRendersInEveryLanguage() {
        var rows: [AccessChecklist.Row] = []
        for fda in FullDiskAccessState.allCases {
            for helper in HelperState.allCases {
                for refusals in [0, 3] {
                    rows += AccessChecklist.rows(
                        fullDiskAccess: fda, helper: helper, savings: sampleSavings(lowerBound: refusals > 0), plan: [], privacyRefusalCount: refusals)
                }
            }
        }
        var rendered = 0
        for locale in L10n.supportedLocales {
            L10n.configure(override: locale, environment: [:], preferred: [])
            for row in rows {
                render(AccessRowView(row: row) { _ in })
                rendered += 1
            }
        }
        XCTAssertEqual(rendered, L10n.supportedLocales.count * rows.count)
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
            render(OverviewView(report: survey.0, findings: [finding], access: model.accessBanner))
            render(StorageView(report: survey.0))
            render(DoctorView(model: model))
            render(DeleteView(model: model))
            render(VolumesView(report: survey.0, checks: []))
            render(RuntimesView(report: survey.0))
            render(JournalView(entries: []))
            let entry = JournalEntry(
                id: "op", sequence: 1, timestamp: Date(timeIntervalSince1970: 1_800_000_000), kind: .clean, state: .completed, summary: "s", paths: [],
                bytes: nil, detail: [:], toolVersion: "t")
            render(JournalView(entries: [entry]))
            render(AccessView(model: model))
            for row in model.accessRows { render(AccessRowView(row: row) { _ in }) }
            for state in HelperState.allCases { render(PrivilegedActionControlView(action: .emptyCoreSimulatorDyldCache, state: state) {}) }
            render(HelperRequestSheet(model: model))
            model.pendingPrivilegedAction = .emptyCoreSimulatorDyldCache
            render(HelperRequestSheet(model: model))
            rendered += 1
        }
        XCTAssertEqual(rendered, L10n.supportedLocales.count)
    }
}

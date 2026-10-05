import Foundation
import XCodeVaultCore

/// The guided Plan (R7-C, ADR-0013): derived from what the model already read, every time, and never stored. Its buttons
/// open the existing sheets and screens; nothing here runs anything.
extension AppModel {
    /// The plan for this Mac now; nil before the first scan.
    var plan: Plan? {
        guard let report else { return nil }
        return PlanBuilder.plan(
            report: report, drives: driveAssessments, vaults: vaultChecks, locations: xcodeLocations, parked: parkedRuntimes, findings: findings)
    }

    /// Where a plan action leads: the whole step→sheet mapping, as a value so it is tested case by case.
    enum PlanTarget: Equatable {
        /// A screen of the sidebar.
        case section(SidebarSection)
        /// The preparation sheet (R6) for that drive and option.
        case preparation(DriveAssessment, PreparationOption)
        /// **Use This Drive** (R6/R7-A) for that drive's volume.
        case useDrive(DriveAssessment, Volume)
        /// **Run…** (R3) for that plan row, on the plan's vault.
        case run(SavingsPlanRow, vault: String?)
    }

    /// The target of `action` against the model's current state. A drive, volume or row that is no longer there falls back
    /// to the screen that lists it — the Plan never opens a sheet for something it cannot find.
    func planTarget(_ action: PlanAction, vault: String?) -> PlanTarget {
        switch action {
        case .showDrives:
            return .section(.drives)
        case .prepareDrive(let diskID, let option):
            // Only the drive's recommended option, which erases nothing (ADR-0013, F5): Core proposes no other, and this
            // refuses one if it were ever passed — an erase, or the ownership setting.
            guard !option.erases, let drive = driveAssessments.first(where: { $0.disk.id == diskID }), drive.options.contains(option),
                drive.isRecommended(option)
            else {
                return .section(.drives)
            }
            return .preparation(drive, option)
        case .useDrive(let diskID, let uuid):
            guard let drive = driveAssessments.first(where: { $0.disk.id == diskID }), let volume = drive.volumes.first(where: { $0.volumeUUID == uuid })
            else { return .section(.drives) }
            return .useDrive(drive, volume)
        case .run(let categoryID, let bucket):
            let section = SidebarSection(reviewing: bucket) ?? .overview
            guard let row = rows(for: bucket).first(where: { $0.categoryID == categoryID && canRun($0) }) else { return .section(section) }
            return .run(row, vault: vault)
        case .showBucket(let bucket):
            return .section(SidebarSection(reviewing: bucket) ?? .overview)
        case .showHealth:
            return .section(.health)
        }
    }

    /// A Plan button: opens what `planTarget` names, through the same openers the other screens use, each with its own
    /// review and confirmation. Nothing is chained.
    func performPlanAction(_ action: PlanAction) {
        switch planTarget(action, vault: plan?.vaultUUID) {
        case .section(let s): section = s
        // The sheet offers no erasing option either (F6): erasing stays on the Drives screen.
        case .preparation(let drive, let option): openPreparation(drive, option: option, nonErasingOnly: true)
        case .useDrive(let drive, let volume): openUseDrive(drive, volume: volume)
        case .run(let row, let vault): openRun(row, vault: vault)
        }
    }
}

import ArgumentParser
import Foundation
import XCodeVaultCore

enum PlanKind: String, ExpressibleByArgument, CaseIterable {
    case delete, park, external

    var bucket: SavingsBucket {
        switch self {
        case .delete: .deleteAndRegenerate
        case .park: .parkExternally
        case .external: .runFromExternal
        }
    }
}

struct Plan: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            abstract: L10n.tr("cli.cmd.plan.abstract"),
            discussion: """
                EXAMPLES:
                  xcodevaultctl plan delete    # regenerable data you can delete
                  xcodevaultctl plan park      # copy to a vault drive, bring back later
                  xcodevaultctl plan external --json
                """)
    }
    @OptionGroup var global: GlobalOptions
    @Argument(help: "delete | park | external") var kind: PlanKind

    func run() throws {
        let report = XCodeVaultCore.Scanner().scan()
        let rows = SavingsPlanner.rows(report: report, bucket: kind.bucket)
        try emit(rows, json: global.json) { SavingsPlanner.render(rows: rows, bucket: kind.bucket) }
    }
}

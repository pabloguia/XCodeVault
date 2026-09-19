import ArgumentParser
import Foundation
import XCodeVaultCore

// MARK: - clean

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Plan (default) or apply deletion of regenerable developer data. Never touches Archives or anything non-regenerable.",
        discussion: """
            Without --apply this only prints the plan. Deletions are journaled to \
            ~/Library/Application Support/XCodeVault/journal.jsonl. Root-owned categories are listed \
            but require the privileged helper (not shipped yet). Every category here is labeled \
            experimental until its functional probes are recorded in the compatibility matrix.
            """)
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, parsing: .upToNextOption, help: "Restrict to these category ids (see `compatibility`).")
    var category: [String] = []
    @Flag(name: .long, help: "Actually delete. Without it, only the plan is shown.")
    var apply = false
    @Flag(name: .long, help: "Move to Trash instead of deleting (space is freed only when the Trash is emptied).")
    var trash = false
    @Flag(name: .long, help: "Proceed even if Xcode.app is running.")
    var force = false
    @Flag(name: .long, help: "One action per category instead of per project / OS build.")
    var coarse = false

    struct Output: Encodable { let plan: CleanPlan; let result: CleanResult? }

    func run() throws {
        let report = XCodeVaultCore.Scanner().scan()
        let plan = CleanPlanner().plan(report: report, categories: Set(category), granular: !coarse)
        var result: CleanResult? = nil
        if apply {
            result = try CleanExecutor(useTrash: trash).execute(plan, force: force)
        }
        if global.json { print(try JSONOutput.encode(Output(plan: plan, result: result))); return }
        print("Cleanup plan (\(plan.actions.count) action(s), \(ByteCount.format(plan.totalBytes))):")
        for a in plan.actions {
            print(
                "  \(TextRendererPad.pad(ByteCount.format(a.bytes), 10)) \(TextRendererPad.pad(a.categoryName, 34)) \(a.requiresRoot ? "[root — helper needed] " : "")\(a.isExperimental ? "(exp.) " : "")\(a.path)"
            )
        }
        for s in plan.skipped { print("  skipped: \(s)") }
        for w in plan.warnings { print("  ! \(w)") }
        if let result {
            print("\nDeleted \(result.deleted.count) path(s), freed \(ByteCount.format(result.bytesFreed)).")
            for f in result.failedPairs { print("  FAILED \(f.path): \(f.error)") }
        } else if !plan.userActions.isEmpty {
            print("\nDry run. Re-run with --apply to delete the \(plan.userActions.count) user-level action(s) above.")
        }
    }
}

enum TextRendererPad { static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) } }

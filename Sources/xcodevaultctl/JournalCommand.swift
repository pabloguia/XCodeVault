import ArgumentParser
import Foundation
import XCodeVaultCore

// MARK: - journal

struct JournalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "journal", abstract: "Show the operation journal (every change XCodeVault made, and any interrupted operation).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Show only the last N entries.") var last: Int = 50
    func run() throws {
        let j = Journal()
        let entries = try j.entries().suffix(last)
        let interrupted = try j.interrupted()
        struct Out: Encodable { let entries: [JournalEntry]; let interrupted: [JournalEntry] }
        try emit(Out(entries: Array(entries), interrupted: interrupted), json: global.json) {
            var o = "Journal: \(j.url.path)\n"
            let f = ISO8601DateFormatter()
            for e in entries {
                o +=
                    "  \(e.sequence)  \(f.string(from: e.timestamp))  \(TextRendererPad.pad(e.kind.rawValue, 19)) \(TextRendererPad.pad(e.state.rawValue, 10)) \(e.summary)\n"
            }
            if !interrupted.isEmpty {
                o += "\n! Interrupted operations (started, never completed):\n"; for e in interrupted { o += "  \(e.id)  \(e.kind.rawValue)  \(e.summary)\n" }
            }
            return o
        }
    }
}

import ArgumentParser
import Foundation
import XCodeVaultCore

@main
struct XCodeVaultCTL: ParsableCommand {
    /// Computed, like every command's, so the help is built in the language `main()` chose (spec §5.1).
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "xcodevaultctl",
            abstract: L10n.tr("cli.cmd.root.abstract"),
            discussion: L10n.tr("cli.root.discussion", L10n.supportedLocales.joined(separator: ", ")) + "\n\n" + Self.examples,
            version: XCodeVaultVersion.current,
            groupedSubcommands: [
                CommandGroup(name: L10n.tr("cli.group.see"), subcommands: [Status.self, Scan.self, Plan.self, Report.self]),
                CommandGroup(
                    name: L10n.tr("cli.group.save"), subcommands: [Clean.self, Locations.self, Externalize.self, Restore.self, Runtime.self]),
                CommandGroup(name: L10n.tr("cli.group.drives"), subcommands: [Volumes.self, Vault.self, Bench.self]),
                CommandGroup(name: L10n.tr("cli.group.recover"), subcommands: [Migration.self, JournalCommand.self]),
                CommandGroup(
                    name: L10n.tr("cli.group.diagnose"), subcommands: [DoctorCommand.self, Xcode.self, Compatibility.self, PermissionsCommand.self]),
            ],
            defaultSubcommand: Status.self)
    }

    /// Commands, so English in every language (spec §5.1).
    static let examples = """
        EXAMPLES:
          xcodevaultctl                       # quick status
          xcodevaultctl scan                  # what you can reclaim, temporarily and permanently
          xcodevaultctl plan delete           # what to run to delete regenerable data
          xcodevaultctl clean --apply --trash # after reviewing `xcodevaultctl clean`
          xcodevaultctl --lang pt-BR scan
        """

    /// The language must be known before ArgumentParser builds any help text, so `--lang` is taken out of
    /// the arguments here rather than declared as an option (spec 2026-10-03 §4.2).
    static func main() {
        let env = ProcessInfo.processInfo.environment
        let prepared = prepareLanguage(arguments: Array(CommandLine.arguments.dropFirst()), environment: env, preferred: Locale.preferredLanguages)
        if let warning = prepared.warning { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        main(prepared.remaining)
    }

    static func prepareLanguage(arguments: [String], environment: [String: String], preferred: [String]) -> (remaining: [String], warning: String?) {
        let (flag, remaining) = L10n.extractLanguageOverride(from: arguments)
        // `--json` output embeds formatted byte strings in prose, and it is an API: always English (spec §4.3).
        let wantsJSON = remaining.prefix { $0 != "--" }.contains("--json")
        // `report` is a record for maintainers, like `--json`: always English.
        let wantsReport = remaining.prefix { $0 != "--" }.first { !$0.hasPrefix("-") } == "report"
        if wantsJSON || wantsReport {
            L10n.configure(override: "en", environment: [:], preferred: [])
        } else {
            L10n.configure(override: flag, environment: environment, preferred: preferred)
        }
        let requested = flag ?? environment["XCODEVAULT_LANG"]
        var warning: String?
        if let requested, L10n.match(requested) == nil {
            warning =
                "xcodevaultctl: language '\(requested)' is not available; using \(L10n.locale). Available: \(L10n.supportedLocales.joined(separator: ", "))"
        }
        return (remaining, warning)
    }
}

extension XCodeVaultCTL {
    /// Color only for a person at a terminal: not piped, not under NO_COLOR (no-color.org), not a dumb terminal.
    /// 24-bit only when `COLORTERM` says `truecolor` or `24bit`; every other terminal gets the xterm-256 cube.
    /// `report` and `--json` are records and never ask.
    static func colorDepth(environment: [String: String], isTTY: Bool) -> ColorDepth {
        guard isTTY, environment["NO_COLOR"] == nil, environment["TERM"] != "dumb" else { return .none }
        switch environment["COLORTERM"]?.lowercased() {
        case "truecolor", "24bit": return .trueColor
        default: return .ansi256
        }
    }
}

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit machine-readable JSON instead of text.")
    var json = false
}

// There used to be a `--profile safe|transparent|expert` option here, surfaced on every subcommand
// because GlobalOptions is @OptionGroup'd throughout — and read by nothing. On a tool that deletes
// files, `--profile safe` reads as a constraint on the invocation, so a user who set it and then ran
// `clean --apply` had been told something untrue by the help text. It is gone rather than wired up:
// the concept, if it returns, should return as a flag that does something, not as one that has
// already appeared in a release doing nothing.

extension ParsableCommand {
    func emit<T: Encodable>(_ value: T, json: Bool, text: () -> String) throws {
        if json { print(try JSONOutput.encode(value)) } else { print(text(), terminator: "") }
    }
}

struct Scan: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            abstract: L10n.tr("cli.cmd.scan.abstract"),
            discussion: """
                EXAMPLES:
                  xcodevaultctl scan             # what you can reclaim, each way
                  xcodevaultctl scan --details   # also every category, its size and path
                  xcodevaultctl scan --no-sizes --json
                """)
    }
    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Skip size measurement (fast inventory only).")
    var noSizes = false
    @Flag(name: .long, help: "Also list every storage category found, with its size and path.")
    var details = false
    func run() throws {
        let report = XCodeVaultCore.Scanner(measureSizes: !noSizes).scan()
        try emit(report, json: global.json) {
            TextRenderer.scan(
                report, details: details,
                colors: global.json ? .none : XCodeVaultCTL.colorDepth(environment: ProcessInfo.processInfo.environment, isTTY: isatty(STDOUT_FILENO) != 0))
        }
    }
}

struct Status: ParsableCommand {
    static var configuration: CommandConfiguration { CommandConfiguration(abstract: L10n.tr("cli.cmd.status.abstract")) }
    @OptionGroup var global: GlobalOptions
    func run() throws {
        let report = XCodeVaultCore.Scanner(measureSizes: false).scan()
        try emit(report, json: global.json) {
            TextRenderer.status(report) + TextRenderer.statusFooter(fullDiskAccess: FullDiskAccessProbe().state())
        }
    }
}

struct Report: ParsableCommand {
    static var configuration: CommandConfiguration { CommandConfiguration(abstract: L10n.tr("cli.cmd.report.abstract")) }
    @OptionGroup var global: GlobalOptions
    struct Bundle: Encodable { let scan: ScanReport; let findings: [Finding] }
    func run() throws {
        let report = XCodeVaultCore.Scanner().scan()
        let doctor = XCodeVaultCore.Doctor()
        let findings = doctor.diagnoseAll(report: report)
        // Plain `replacingOccurrences` was both weaker and more destructive than it looked: it had
        // no word boundary on the account name (an account called `dev` turned `devicectl` into
        // `<user>icectl`), no anchor on the home, and nothing at all for volume labels or volume
        // UUIDs — which this report carries, since it embeds the full volume list. See Redaction.
        let redact = Redaction(home: report.host.homeDirectory, user: report.host.userName, volumes: report.volumes)
        if global.json {
            print(redact(try JSONOutput.encode(Bundle(scan: report, findings: findings))))
        } else {
            print(redact(TextRenderer.scan(report, details: true) + "\n" + TextRenderer.findings(findings)), terminator: "")
        }
    }
}

struct DoctorCommand: ParsableCommand {
    static var configuration: CommandConfiguration { CommandConfiguration(commandName: "doctor", abstract: L10n.tr("cli.cmd.doctor.abstract")) }
    @OptionGroup var global: GlobalOptions
    func run() throws {
        let report = XCodeVaultCore.Scanner(measureSizes: false).scan()
        let doctor = XCodeVaultCore.Doctor()
        let findings = doctor.diagnoseAll(report: report)
        try emit(findings, json: global.json) { TextRenderer.findings(findings) }
        if findings.contains(where: { $0.severity >= .error }) { throw ExitCode(2) }
    }
}

struct Xcode: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(abstract: L10n.tr("cli.cmd.xcode.abstract"), subcommands: [List.self], defaultSubcommand: List.self)
    }
    struct List: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let xcodes = XcodeDiscovery.discover()
            try emit(xcodes, json: global.json) { Self.render(xcodes) }
        }

        static func render(_ xcodes: [XcodeInstallation]) -> String {
            var o = ""
            for x in xcodes {
                o += "\(x.isSelected ? "*" : " ") Xcode \(x.version) (\(x.build)) — \(x.path)\n"
                // Every flag reads ✗ when nothing was probed, which would say "unsupported" about what was never asked
                // (ADR-0009).
                guard x.capabilitiesProbed else {
                    o +=
                        x.isSelected
                        ? "    capabilities not probed: its `xcodebuild -help` could not be run\n"
                        : "    capabilities not probed: only the xcode-select'ed Xcode's tools are run\n"
                    continue
                }
                let c = x.capabilities
                let rows: [(String, Bool)] = [
                    ("downloadPlatform", c.downloadPlatform), ("downloadAllPlatforms", c.downloadAllPlatforms),
                    ("-exportPath (Runtime Library export)", c.exportPath), ("-buildVersion", c.buildVersion),
                    ("-architectureVariant", c.architectureVariant), ("importPlatform", c.importPlatform),
                    ("downloadComponent / importComponent / deleteComponent", c.downloadComponent && c.importComponent), ("showComponent", c.showComponent),
                    ("checkForNewerComponents", c.checkForNewerComponents), ("prepareDeviceSupport", c.prepareDeviceSupport),
                    ("simctl runtime add / delete / unmount / verify", c.simctlRuntimeAdd && c.simctlRuntimeDelete),
                ]
                for (n, v) in rows { o += "    \(v ? "✓" : "✗") \(n)\n" }
            }
            return o
        }
    }
}

struct Runtime: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(abstract: L10n.tr("cli.cmd.runtime.abstract"), subcommands: Runtime.extendedSubcommands, defaultSubcommand: List.self)
    }
    struct List: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let rts = try SimulatorDiscovery.runtimes()
            try emit(rts, json: global.json) {
                var o = ""
                for r in rts {
                    o +=
                        "\(r.platformName) \(r.version ?? "?") (\(r.build ?? "?"))  \(r.state ?? "?")  \(ByteCount.format(r.sizeBytes ?? 0))  \(r.kind ?? "")  sig=\(r.signatureState ?? "?")  \(r.isMounted ? "mounted at \(r.mountPath ?? "")" : "NOT mounted")\n"
                    o += "    image: \(r.path ?? "?")\n"
                }
                return o
            }
        }
    }
}

struct Volumes: ParsableCommand {
    static var configuration: CommandConfiguration { CommandConfiguration(abstract: L10n.tr("cli.cmd.volumes.abstract")) }
    @OptionGroup var global: GlobalOptions
    struct Row: Encodable { let volume: Volume; let qualification: VolumeQualification }
    func run() throws {
        let vols = try VolumeDiscovery.mountedVolumes()
        let rows = vols.map { Row(volume: $0, qualification: VolumeQualification.evaluate($0)) }
        try emit(rows, json: global.json) {
            var o = ""
            for r in rows {
                let v = r.volume
                o +=
                    "\(v.volumeName)  \(v.mountPoint ?? "-")  \(v.filesystemPersonality)  \(v.busProtocol)  \(v.isInternal ? "internal" : "external")  uuid=\(v.volumeUUID ?? "-")  free \(ByteCount.format(v.freeBytes)) / \(ByteCount.format(v.totalBytes))  owners=\(v.ownersEnabled ? "on" : "OFF")\n"
                o += "    verdict: \(v.isBootVolume ? "boot volume" : r.qualification.verdict.rawValue)\n"
                for b in r.qualification.blockers { o += "    ✗ \(b)\n" }
                for w in r.qualification.warnings { o += "    ! \(w)\n" }
            }
            return o
        }
    }
}

struct Compatibility: ParsableCommand {
    static var configuration: CommandConfiguration { CommandConfiguration(abstract: L10n.tr("cli.cmd.compatibility.abstract")) }
    @OptionGroup var global: GlobalOptions
    func run() throws {
        let violations = CatalogRules.validate(StorageCatalog.all)
        if !violations.isEmpty { throw ValidationError("catalog invariant violated: \(violations)") }
        try emit(StorageCatalog.all, json: global.json) { TextRenderer.compatibility(StorageCatalog.all) }
    }
}

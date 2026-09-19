import ArgumentParser
import Foundation
import XCodeVaultCore

@main
struct XCodeVaultCTL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcodevaultctl",
        abstract: "Honest accounting and safe relocation of Apple developer tooling storage.",
        discussion: """
            Read commands (scan, status, report, doctor, xcode, runtime list, volumes, journal, compatibility) \
            are always safe and never change anything. Every read command supports --json.

            Strategies marked "(exp.)" / experimental have not met the Definition of Done in \
            docs/product/NON_GOALS_AND_SAFETY.md for your macOS/Xcode combination.

            Experiment IDs that appear in help text (E2, E8b, E11 …) are defined in \
            docs/architecture/EXPERIMENTS.md.
            """,
        version: XCodeVaultVersion.current,
        subcommands: [
            Scan.self, Status.self, Report.self, DoctorCommand.self, Xcode.self, Runtime.self, Volumes.self, Compatibility.self,
            Clean.self, Locations.self, JournalCommand.self, Vault.self, Externalize.self, Restore.self, Migration.self, Bench.self,
        ],
        defaultSubcommand: Status.self)
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
    static let configuration = CommandConfiguration(abstract: "Discover Xcodes, runtimes, volumes and measure every storage category (read-only).")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Skip size measurement (fast inventory only).")
    var noSizes = false
    func run() throws {
        let report = XCodeVaultCore.Scanner(measureSizes: !noSizes).scan()
        try emit(report, json: global.json) { TextRenderer.scan(report) }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Quick environment summary without measuring directory sizes.")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        let report = XCodeVaultCore.Scanner(measureSizes: false).scan()
        try emit(report, json: global.json) { TextRenderer.status(report) }
    }
}

struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Full scan + doctor findings, suitable for a GitHub issue (home directory, account name, volume labels and volume UUIDs redacted).")
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
            print(redact(TextRenderer.scan(report) + "\n" + TextRenderer.findings(findings)), terminator: "")
        }
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Detect broken/unsafe configurations and propose (never execute) repairs.")
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
    static let configuration = CommandConfiguration(
        abstract: "Installed Xcodes and their feature-detected capabilities.", subcommands: [List.self], defaultSubcommand: List.self)
    struct List: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let xcodes = XcodeDiscovery.discover()
            try emit(xcodes, json: global.json) {
                var o = ""
                for x in xcodes {
                    o += "\(x.isSelected ? "*" : " ") Xcode \(x.version) (\(x.build)) — \(x.path)\n"
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
}

struct Runtime: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Simulator runtimes: list, delete, export/import installers (Runtime Library), offload.",
        subcommands: Runtime.extendedSubcommands, defaultSubcommand: List.self)
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
    static let configuration = CommandConfiguration(abstract: "Mounted volumes and whether each qualifies as an XCodeVault destination.")
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
    static let configuration = CommandConfiguration(abstract: "Every storage category with its strategy, evidence status and privilege level.")
    @OptionGroup var global: GlobalOptions
    func run() throws {
        let violations = CatalogRules.validate(StorageCatalog.all)
        if !violations.isEmpty { throw ValidationError("catalog invariant violated: \(violations)") }
        try emit(StorageCatalog.all, json: global.json) { TextRenderer.compatibility(StorageCatalog.all) }
    }
}

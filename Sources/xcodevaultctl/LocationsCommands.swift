import ArgumentParser
import Foundation
import XCodeVaultCore

// MARK: - locations

struct Locations: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            abstract: L10n.tr("cli.cmd.locations.abstract"),
            subcommands: [
                Show.self, SetDerivedData.self, ResetDerivedData.self, SetArchives.self, ResetArchives.self, SetCompilationCache.self,
                ResetCompilationCache.self,
            ], defaultSubcommand: Show.self)
    }
    struct Show: ParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let l = XcodeLocations.read()
            try emit(l, json: global.json) {
                "DerivedData:          \(l.derivedData ?? "(default: ~/Library/Developer/Xcode/DerivedData)")\nBuild location style: \(l.buildLocationStyle ?? "(default: Unique)")\nArchives:             \(l.archives ?? "(default: ~/Library/Developer/Xcode/Archives)")\nCompilation cache:    \(l.compilationCache ?? "(default: <DerivedData>/CompilationCache.noindex)")\n"
            }
        }
    }
    struct SetDerivedData: ParsableCommand {
        static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "set-derived-data",
                abstract: HelpText.experimental(L10n.tr("cli.cmd.locations.setDerivedData.abstract")),
                discussion: """
                    EXAMPLES:
                      xcodevaultctl locations set-derived-data /Volumes/Fast/DerivedData
                      xcodevaultctl locations set-derived-data /Volumes/Fast/DerivedData \\
                          --i-understand-tests-may-fail
                      xcodevaultctl locations reset-derived-data

                    Background: E8b in docs/architecture/EXPERIMENTS.md.
                    """)
        }
        @Argument(help: "Absolute path of an existing, writable directory.") var path: String
        @Flag(
            name: .customLong("i-understand-tests-may-fail"),
            help: "Acknowledge that xcodebuild test cannot load test bundles from a physical external volume (E2).") var acknowledge = false
        func run() throws {
            let volumes = (try? VolumeDiscovery.mountedVolumes()) ?? []
            let warnings = try XcodeLocations.preflightDerivedData(
                path: path, volumes: volumes, xcodeRunning: CleanExecutor.xcodeIsRunning(), acknowledgeExternalTests: acknowledge)
            for w in warnings { print("! \(w)") }
            try XcodeLocations.apply(.init(key: .derivedData, newValue: path))
            print("IDECustomDerivedDataLocation = \(path). Existing DerivedData was not moved (it is regenerable; `clean --category derivedData` reclaims it).")
        }
    }
    struct SetArchives: ParsableCommand {
        static var configuration: CommandConfiguration {
            CommandConfiguration(commandName: "set-archives", abstract: HelpText.experimental(L10n.tr("cli.cmd.locations.setArchives.abstract")))
        }
        @Argument(help: "Absolute path of an existing, writable directory.") var path: String
        func run() throws {
            let volumes = (try? VolumeDiscovery.mountedVolumes()) ?? []
            for w in try XcodeLocations.preflightArchives(path: path, volumes: volumes, xcodeRunning: CleanExecutor.xcodeIsRunning()) { print("! \(w)") }
            try XcodeLocations.apply(.init(key: .archives, newValue: path))
            print("IDECustomDistributionArchivesLocation = \(path). Xcode adds YYYY-MM-DD/<Scheme>.xcarchive folders under it.")
        }
    }
    struct ResetArchives: ParsableCommand {
        static var configuration: CommandConfiguration {
            CommandConfiguration(commandName: "reset-archives", abstract: L10n.tr("cli.cmd.locations.resetArchives.abstract"))
        }
        func run() throws {
            _ = try XcodeLocations.preflightArchives(path: nil, volumes: [], xcodeRunning: CleanExecutor.xcodeIsRunning())
            try XcodeLocations.apply(.init(key: .archives, newValue: nil)); print("Archives location reset to the default.")
        }
    }
    struct SetCompilationCache: ParsableCommand {
        static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "set-compilation-cache", abstract: HelpText.experimental(L10n.tr("cli.cmd.locations.setCompilationCache.abstract")))
        }
        @Argument(help: "Absolute path of an existing, writable directory.") var path: String
        @Flag(name: .customLong("i-understand-tests-may-fail"), help: "Acknowledge the E2 external-volume caveat (build products may be served from here).")
        var acknowledge = false
        func run() throws {
            let xcodes = XcodeDiscovery.discover(detectCapabilities: false)
            guard let x = xcodes.first(where: \.isSelected) ?? xcodes.first, x.majorVersion >= 26 else {
                throw ValidationError("The compilation cache location setting exists in Xcode 26+; selected Xcode is older.")
            }
            let volumes = (try? VolumeDiscovery.mountedVolumes()) ?? []
            for w in try XcodeLocations.preflightDerivedData(
                path: path, volumes: volumes, xcodeRunning: CleanExecutor.xcodeIsRunning(), acknowledgeExternalTests: acknowledge)
            { print("! \(w)") }
            try XcodeLocations.apply(.init(key: .compilationCache, newValue: path))
            print("IDECustomCompilationCacheLocation = \(path).")
        }
    }
    struct ResetCompilationCache: ParsableCommand {
        static var configuration: CommandConfiguration {
            CommandConfiguration(commandName: "reset-compilation-cache", abstract: L10n.tr("cli.cmd.locations.resetCompilationCache.abstract"))
        }
        func run() throws {
            _ = try XcodeLocations.preflightArchives(path: nil, volumes: [], xcodeRunning: CleanExecutor.xcodeIsRunning())
            try XcodeLocations.apply(.init(key: .compilationCache, newValue: nil)); print("Compilation cache location reset to the default.")
        }
    }
    struct ResetDerivedData: ParsableCommand {
        static var configuration: CommandConfiguration {
            CommandConfiguration(commandName: "reset-derived-data", abstract: L10n.tr("cli.cmd.locations.resetDerivedData.abstract"))
        }
        func run() throws {
            _ = try XcodeLocations.preflightDerivedData(path: nil, volumes: [], xcodeRunning: CleanExecutor.xcodeIsRunning(), acknowledgeExternalTests: true)
            try XcodeLocations.apply(.init(key: .derivedData, newValue: nil))
            print("DerivedData location reset to the default.")
        }
    }
}

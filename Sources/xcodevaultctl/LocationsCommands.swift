import ArgumentParser
import Foundation
import XCodeVaultCore

// MARK: - locations

struct Locations: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Xcode ▸ Settings ▸ Locations (DerivedData, Archives) — Apple's supported relocation.",
        subcommands: [
            Show.self, SetDerivedData.self, ResetDerivedData.self, SetArchives.self, ResetArchives.self, SetCompilationCache.self, ResetCompilationCache.self,
        ], defaultSubcommand: Show.self)
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
        static let configuration = CommandConfiguration(
            commandName: "set-derived-data",
            abstract:
                "Point DerivedData at a directory (IDECustomDerivedDataLocation; reproduced on Xcode 26.5, E8b). Experimental until the matrix is complete.")
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
        static let configuration = CommandConfiguration(
            commandName: "set-archives",
            abstract:
                "Point new Archives at a directory (IDECustomDistributionArchivesLocation; reproduced on Xcode 26.5, status: probable/experimental). Existing archives are not moved — use `externalize --category archives`."
        )
        @Argument(help: "Absolute path of an existing, writable directory.") var path: String
        func run() throws {
            let volumes = (try? VolumeDiscovery.mountedVolumes()) ?? []
            for w in try XcodeLocations.preflightArchives(path: path, volumes: volumes, xcodeRunning: CleanExecutor.xcodeIsRunning()) { print("! \(w)") }
            try XcodeLocations.apply(.init(key: .archives, newValue: path))
            print("IDECustomDistributionArchivesLocation = \(path). Xcode adds YYYY-MM-DD/<Scheme>.xcarchive folders under it.")
        }
    }
    struct ResetArchives: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reset-archives", abstract: "Restore Xcode's default Archives location.")
        func run() throws {
            _ = try XcodeLocations.preflightArchives(path: nil, volumes: [], xcodeRunning: CleanExecutor.xcodeIsRunning())
            try XcodeLocations.apply(.init(key: .archives, newValue: nil)); print("Archives location reset to the default.")
        }
    }
    struct SetCompilationCache: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-compilation-cache",
            abstract: "Point the Xcode 26 compilation cache at a directory (IDECustomCompilationCacheLocation). Experimental.")
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
        static let configuration = CommandConfiguration(commandName: "reset-compilation-cache", abstract: "Restore the default compilation cache location.")
        func run() throws {
            _ = try XcodeLocations.preflightArchives(path: nil, volumes: [], xcodeRunning: CleanExecutor.xcodeIsRunning())
            try XcodeLocations.apply(.init(key: .compilationCache, newValue: nil)); print("Compilation cache location reset to the default.")
        }
    }
    struct ResetDerivedData: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reset-derived-data", abstract: "Restore Xcode's default DerivedData location.")
        func run() throws {
            _ = try XcodeLocations.preflightDerivedData(path: nil, volumes: [], xcodeRunning: CleanExecutor.xcodeIsRunning(), acknowledgeExternalTests: true)
            try XcodeLocations.apply(.init(key: .derivedData, newValue: nil))
            print("DerivedData location reset to the default.")
        }
    }
}

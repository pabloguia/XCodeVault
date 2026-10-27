import Foundation

// Category names and outcomes in the chosen language (localization follow-up 3 of S4): what the app shows, sorts and
// searches by. The catalog's `name` and `outcomeLabel` stay English — the CLI, the report, `--json` and records keep them.
// Like `Strategy.localizedName`, these live in Core so the Storage table's sort and search see the text its cells show.

extension StorageCatalog {
    /// A category's plain name in the chosen language; nil for an id the catalog does not have (a test holds every catalog
    /// id to one). The keys are the guided Plan's, where these names were first shown (R7-C).
    public static func localizedName(_ id: String) -> String? {
        switch id {
        case "derivedData": L10n.tr("app.guide.name.derivedData")
        case "archives": L10n.tr("app.guide.name.archives")
        case "deviceSupport": L10n.tr("app.guide.name.deviceSupport")
        case "previews": L10n.tr("app.guide.name.previews")
        case "xcodePackages": L10n.tr("app.guide.name.xcodePackages")
        case "xcodeCaches": L10n.tr("app.guide.name.xcodeCaches")
        case "deviceLogs": L10n.tr("app.guide.name.deviceLogs")
        case "swiftPMCaches": L10n.tr("app.guide.name.swiftPMCaches")
        case "simulatorDevices": L10n.tr("app.guide.name.simulatorDevices")
        case "simulatorDeadContainers": L10n.tr("app.guide.name.simulatorDeadContainers")
        case "simulatorMobileAssets": L10n.tr("app.guide.name.simulatorMobileAssets")
        case "simulatorLogStore": L10n.tr("app.guide.name.simulatorLogStore")
        case "simulatorUserCaches": L10n.tr("app.guide.name.simulatorUserCaches")
        case "xctestDevices": L10n.tr("app.guide.name.xctestDevices")
        case "playgroundDevices": L10n.tr("app.guide.name.playgroundDevices")
        case "coreSimulatorSystemCaches": L10n.tr("app.guide.name.coreSimulatorSystemCaches")
        case "runtimeInbox": L10n.tr("app.guide.name.runtimeInbox")
        case "runtimeBundles": L10n.tr("app.guide.name.runtimeBundles")
        case "runtimeMounts": L10n.tr("app.guide.name.runtimeMounts")
        case "simulatorRuntimeAssets": L10n.tr("app.guide.name.simulatorRuntimeAssets")
        case "runtimeLibrary": L10n.tr("app.guide.name.runtimeLibrary")
        case "developerDiskImages": L10n.tr("app.guide.name.developerDiskImages")
        case "coreDevice": L10n.tr("app.guide.name.coreDevice")
        case "toolchains": L10n.tr("app.guide.name.toolchains")
        case "commandLineTools": L10n.tr("app.guide.name.commandLineTools")
        default: nil
        }
    }
}

extension CategoryOutcome {
    /// The outcome in words, in the chosen language.
    public var localizedName: String {
        switch self {
        case .relocatable: L10n.tr("app.outcome.relocatable")
        case .deleteOnlyOfficialTool: L10n.tr("app.outcome.deleteOnlyOfficialTool")
        case .deleteOnly: L10n.tr("app.outcome.deleteOnly")
        case .mustStayLocal: L10n.tr("app.outcome.mustStayLocal")
        case .informational: L10n.tr("app.outcome.informational")
        }
    }
}

extension StorageRow {
    /// The category's name as the Storage table shows it: localized, or the catalog's English for an unknown id.
    public var localizedCategoryName: String { StorageCatalog.localizedName(item.categoryID) ?? categoryName }
    /// The outcome as the Storage table shows it; empty when the catalog does not know the category.
    public var localizedOutcome: String { outcomeKind?.localizedName ?? outcome }
}

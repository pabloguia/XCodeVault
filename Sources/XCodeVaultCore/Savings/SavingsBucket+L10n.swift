import Foundation

extension SavingsBucket {
    public var localizedTitle: String {
        switch self {
        case .runFromExternal: L10n.tr("savings.bucket.runFromExternal.title")
        case .parkExternally: L10n.tr("savings.bucket.parkExternally.title")
        case .deleteAndRegenerate: L10n.tr("savings.bucket.deleteAndRegenerate.title")
        case .keepLocal: L10n.tr("savings.bucket.keepLocal.title")
        }
    }

    public var localizedPromise: String {
        switch self {
        case .runFromExternal: L10n.tr("savings.bucket.runFromExternal.promise")
        case .parkExternally: L10n.tr("savings.bucket.parkExternally.promise")
        case .deleteAndRegenerate: L10n.tr("savings.bucket.deleteAndRegenerate.promise")
        case .keepLocal: L10n.tr("savings.bucket.keepLocal.promise")
        }
    }

    public var localizedUndoCost: String {
        switch self {
        case .runFromExternal: L10n.tr("savings.bucket.runFromExternal.undoCost")
        case .parkExternally: L10n.tr("savings.bucket.parkExternally.undoCost")
        case .deleteAndRegenerate: L10n.tr("savings.bucket.deleteAndRegenerate.undoCost")
        case .keepLocal: L10n.tr("savings.bucket.keepLocal.undoCost")
        }
    }
}

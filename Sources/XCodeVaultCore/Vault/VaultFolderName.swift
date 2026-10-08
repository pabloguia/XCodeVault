import CryptoKit
import Foundation

/// The name of a vault's folder on its drive: suggested, editable, and one per Mac (ADR-0015).
///
/// A drive can be shared by several Macs, each with its own folder and its own registry; and a Mac can have vaults on
/// several drives. One Mac has at most one vault per volume, so the volume's UUID stays the identity.
public enum VaultFolderName {
    /// What a new vault's folder is called unless the user types another name. Vaults registered before ADR-0015 keep
    /// `VaultVolume.directoryName` — the name the privileged helper knows — which is also what an old registry decodes to.
    public static let suggested = "Vault"
    /// Long enough for any name a person types; short of APFS's 255 UTF-8 bytes, so a derived path never fails on length.
    public static let maxBytes = 200

    public enum Problem: String, Sendable, Equatable {
        case empty, notOneFolder, dotName, tooLong, hiddenSystemName
    }

    /// Why `name` cannot be the folder of a vault, or nil when it can. One folder directly in the drive's root: no `/`, no
    /// NUL or control character, not `.` or `..`, not blank, no leading or trailing space, and not a name macOS keeps
    /// for itself (`.Spotlight-V100`, `.fseventsd`, `.Trashes`, `.TemporaryItems`, `.DocumentRevisions-V100`).
    public static func problem(_ name: String) -> Problem? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        guard trimmed == name else { return .notOneFolder }
        if name == "." || name == ".." { return .dotName }
        guard name.utf8.count <= maxBytes else { return .tooLong }
        // Validated on bytes, not Characters: a "/" carrying a combining mark is not a "/" to String, and is one to the kernel.
        for byte in name.utf8 where byte == 0x2F || byte == 0x3A || byte < 0x20 || byte == 0x7F { return .notOneFolder }
        if reserved.contains(name.lowercased()) { return .hiddenSystemName }
        return nil
    }

    static let reserved: Set<String> = [
        ".spotlight-v100", ".fseventsd", ".trashes", ".temporaryitems", ".documentrevisions-v100", ".ds_store", ".volumeicon.icns",
    ]

    /// The sentence the Use This Drive form shows under the field; nil when the name is fine.
    public static func message(for problem: Problem?) -> String? {
        switch problem {
        case nil: return nil
        case .empty?: return "Type a name for the vault folder."
        case .notOneFolder?: return "The name must be one folder: no “/”, “:” or control characters, and no space at either end."
        case .dotName?: return "“.” and “..” are not folder names."
        case .tooLong?: return "That name is too long."
        case .hiddenSystemName?: return "macOS keeps that name for itself. Choose another."
        }
    }
}

/// Which Mac wrote a vault's sentinel, without naming it: a hash of the hardware identifier, which on a drive shared
/// between Macs tells one Mac's vault folder from another's (ADR-0015). Not a secret and not an identity proof; it only
/// keeps one Mac from taking over another's folder by accident.
public enum HostFingerprint {
    public static func current() -> String? {
        var id = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var wait = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&id, &wait) == 0 else { return nil }
        let bytes = withUnsafeBytes(of: id) { Array($0) }
        let digest = SHA256.hash(data: Data(bytes) + Data("xcodevault-host".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

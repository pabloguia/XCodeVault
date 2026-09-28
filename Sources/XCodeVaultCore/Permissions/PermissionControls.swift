/// What the GUI shows about permissions, decided here so it is testable (spec §4): the app target has
/// no tests, and a decision nobody can test is the one the next refactor gets wrong.
public enum PermissionPrompts {
    /// Ask for Full Disk Access only at the moment of need (ADR-0007): a scan counted a refusal with `EPERM`,
    /// the errno macOS privacy protection returns, and the grant is not known to be there. A scan that counts
    /// no refusal asks for nothing.
    public static func shouldAskForFullDiskAccess(privacyRefusalCount: Int, state: FullDiskAccessState) -> Bool {
        privacyRefusalCount > 0 && state != .granted
    }
}

extension FullDiskAccessState {
    /// Whether the Permissions row offers **Open Settings**: whenever the grant is not known to be there.
    public var offersOpenSettings: Bool { self != .granted }
}

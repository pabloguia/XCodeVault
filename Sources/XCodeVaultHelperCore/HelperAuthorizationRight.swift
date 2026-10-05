// The privileged helper's ONE use of the authorization rights API (R8, ADR-0014; approved by the maintainer on
// 2026-10-05).
//
// `SECURITY_MODEL.md` forbids `AuthorizationCopyRights` in the helper for a concrete reason: a root process that asks
// the rights API about a reference it created itself — or about a NULL one — is told "yes", because it is root. That
// pair, with a helper that runs what it is told, is CVE-2025-65842. This file is the single exemption in both
// `scripts/helper-invariants.sh` and the editor hook, and the script holds its shape: exactly one `AuthorizationCopyRights`
// call, whose first argument is `clientRef`, and `clientRef` assigned only by `AuthorizationCreateFromExternalForm` —
// the reference the CLIENT made and on which the CLIENT's user typed the password. The helper never shows a dialog:
// its flags never ask for one, which the script and the hook both enforce.
//
// **Who defines the right, and why it is the helper.** Stock macOS lets any local user ADD an undefined right (the
// `config.add.` rule); only changing an existing one needs an administrator. If the client defined it, another user
// could define this name first as `allow`, and every later check would pass with no password. The helper is root, is
// the party that relies on the definition, and so owns it: it writes the definition at startup and checks it again on
// every call, and a wrong definition is repaired AND that call is refused — the reference was granted under a rule
// that is not ours. The empty reference used for the write is only ever passed to `AuthorizationRightSet`.

import Foundation
import Security
import XCodeVaultHelperProtocol

/// What checking the client's right gave.
enum RightCheck: Equatable, Sendable {
    case granted
    /// The reference does not hold the right (no password was given, or the rule refused).
    case denied(OSStatus)
    /// Not an externalized reference at all: wrong length, or one the authorization service does not recognize.
    case malformed
}

/// What putting the right's definition in place gave.
enum RightDefinition: Equatable, Sendable {
    /// It was already ours.
    case unchanged
    /// It was missing, and is now defined.
    case defined
    /// It existed with a different rule, and has been rewritten. A check made under the old rule is not trusted.
    case redefined
    case failed(OSStatus)
}

/// The seam the verb asks about the right through. Tests inject a fake; production uses `SecurityRightAuthority`.
protocol OwnershipRightAuthority: Sendable {
    func ensureDefinition() -> RightDefinition
    func check(externalForm: Data) -> RightCheck
}

/// The live authority, through the Security framework. Never run by a test: both calls reach the authorization service,
/// and the first writes to its database.
struct SecurityRightAuthority: OwnershipRightAuthority {
    let rightName: String = HelperIdentity.enableOwnershipRight

    func ensureDefinition() -> RightDefinition {
        var current: CFDictionary?
        let got = AuthorizationRightGet(rightName, &current)
        let existed = got == errAuthorizationSuccess
        if existed, let dict = current as? [String: Any], Self.isOurDefinition(dict) { return .unchanged }

        // An empty reference, used only to write the definition: as root, the write needs no credential.
        var writer: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &writer)
        guard created == errAuthorizationSuccess, let writer else { return .failed(created) }
        defer { AuthorizationFree(writer, []) }
        let prompt = "XCodeVault wants to turn on ownership on an external volume." as CFString
        let set = AuthorizationRightSet(writer, rightName, kAuthorizationRuleAuthenticateAsAdmin as CFString, prompt, nil, nil)
        guard set == errAuthorizationSuccess else { return .failed(set) }
        return existed ? .redefined : .defined
    }

    func check(externalForm data: Data) -> RightCheck {
        guard var form = Self.externalForm(from: data) else { return .malformed }
        var clientRef: AuthorizationRef?
        let imported = AuthorizationCreateFromExternalForm(&form, &clientRef)
        guard imported == errAuthorizationSuccess, let clientRef else { return .malformed }
        // `.destroyRights`: the credential the client obtained is spent by this one check, so the externalized form
        // works once (fix round 1, L3) — a captured form cannot be replayed against a second call.
        defer { AuthorizationFree(clientRef, [.destroyRights]) }
        let status = rightName.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                // `.extendRights` alone: the right may be evaluated against what the client's reference already
                // holds, and nothing may ask anyone for anything here.
                return AuthorizationCopyRights(clientRef, &rights, nil, [.extendRights], nil)
            }
        }
        return status == errAuthorizationSuccess ? .granted : .denied(status)
    }

    /// The 32 bytes of an externalized reference, or nil for anything else. Checked before the authorization service is
    /// asked anything: a form of the wrong length is a forgery or a bug, not a reference.
    static func externalForm(from data: Data) -> AuthorizationExternalForm? {
        guard data.count == Int(kAuthorizationExternalFormLength) else { return nil }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form.bytes) { raw in _ = data.copyBytes(to: raw) }
        return form
    }

    /// Whether a definition read back from the database is the one this helper writes: a rule-class right whose rule is
    /// `authenticate-admin`, nothing that could widen it, and **written by this helper** — the database records the
    /// writer's code identifier, and anything but `com.xcodevault.helper` is someone else's definition, rewritten (fix
    /// round 1, L4). The metadata keys the database adds itself are allowed; any other key — `k`, `allow-root`, `group`,
    /// a `mechanisms` list — makes it not ours, and it is rewritten.
    static func isOurDefinition(_ d: [String: Any]) -> Bool {
        let metadata: Set<String> = ["class", "rule", "version", "created", "modified", "comment", "default-prompt", "identifier", "requirement"]
        guard Set(d.keys).isSubset(of: metadata), d["class"] as? String == "rule" else { return false }
        guard d["identifier"] as? String == HelperIdentity.bundleIdentifier else { return false }
        let admin = kAuthorizationRuleAuthenticateAsAdmin
        if let rule = d["rule"] as? String { return rule == admin }
        if let rules = d["rule"] as? [String] { return rules == [admin] }
        return false
    }
}

/// The daemon's startup step: put the right's definition in place before the listener accepts anything, so the client's
/// first request is evaluated against our rule rather than the database's default. Not fatal when it fails: the verb
/// tries again, and refuses while it cannot.
public enum HelperStartup {
    public static func defineAuthorizationRights() {
        let outcome = SecurityRightAuthority().ensureDefinition()
        HelperAudit.emitStartup(rightDefinition: outcome)
    }
}

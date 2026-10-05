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
    /// The team the build signed this helper with (`main.swift`, substituted by `scripts/bundle-app.sh`). The database
    /// records the writer's code requirement, and a definition counts as ours only when that requirement names this
    /// team (R8 fix round 5, F3). The placeholder is not a usable team, so an unsubstituted build accepts no definition.
    let teamID: String

    func ensureDefinition() -> RightDefinition {
        var current: CFDictionary?
        let got = AuthorizationRightGet(rightName, &current)
        let existed = got == errAuthorizationSuccess
        if existed, let dict = current as? [String: Any], Self.isOurDefinition(dict, teamID: teamID) { return .unchanged }

        // An empty reference, used only to write the definition: as root, the write needs no credential.
        var writer: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &writer)
        guard created == errAuthorizationSuccess, let writer else { return .failed(created) }
        defer { AuthorizationFree(writer, []) }
        let prompt = OwnershipRightRule.prompt as CFString
        let set = AuthorizationRightSet(writer, rightName, OwnershipRightRule.definition as CFDictionary, prompt, nil, nil)
        guard set == errAuthorizationSuccess else { return .failed(set) }
        // Read back: a definition the database stores differently from what was written would be rewritten on every
        // call and refuse every call. Say so once, as a failure, rather than loop.
        var written: CFDictionary?
        guard AuthorizationRightGet(rightName, &written) == errAuthorizationSuccess, let back = written as? [String: Any],
            Self.isOurDefinition(back, teamID: teamID)
        else { return .failed(errAuthorizationInternal) }
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

    /// Whether a definition read back from the database is the one this helper writes (R8 fix rounds 4 and 5): exactly
    /// `OwnershipRightRule`'s security fields — a user-class right for the admin group, a 10-second credential that is
    /// not shared and not given to root — **written by this helper**: the writer's code identifier (L4) and the writer's
    /// code requirement naming this build's team (F3; an ad-hoc binary can claim the identifier, not the team). The keys
    /// the database adds itself are allowed; a key it may add with a default is allowed only at its safe value; `tries`
    /// (authd adds 10000 to every user-class rule, F1) only as a whole number of at least 1; a `default-prompt` only when
    /// every text in it is ours (F3: a squatter's wording is not shown under our name). Any other key, or any other
    /// value, makes it not ours, and it is rewritten. The old definition, which pointed at the shared admin rule, is not
    /// ours. `scripts/helper-invariants.sh` pins this body line for line.
    static func isOurDefinition(_ d: [String: Any], teamID: String) -> Bool {
        let metadata: Set<String> = ["version", "created", "modified", "comment", "default-prompt", "identifier", "requirement", "tries"]
        let fields = Set(OwnershipRightRule.definition.keys)
        let safeDefaults: [String: Bool] = ["authenticate-user": true, "session-owner": false, "extract-password": false, "password-only": false]
        guard Set(d.keys).isSubset(of: metadata.union(fields).union(safeDefaults.keys)) else { return false }
        guard d["identifier"] as? String == HelperIdentity.bundleIdentifier else { return false }
        guard let requirement = d["requirement"] as? String, namesTeam(requirement, teamID: teamID) else { return false }
        guard d["class"] as? String == OwnershipRightRule.ruleClass, d["group"] as? String == OwnershipRightRule.group,
            (d["timeout"] as? NSNumber)?.intValue == OwnershipRightRule.timeoutSeconds, d["shared"] as? Bool == false, d["allow-root"] as? Bool == false
        else { return false }
        for (key, safe) in safeDefaults where d[key] != nil {
            guard d[key] as? Bool == safe else { return false }
        }
        if let tries = d["tries"] {
            guard let n = tries as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n), n.int64Value >= 1 else { return false }
        }
        if let prompts = d["default-prompt"] {
            guard let byLanguage = prompts as? [String: Any], byLanguage.values.allSatisfy({ $0 as? String == OwnershipRightRule.prompt }) else { return false }
        }
        return true
    }

    /// Whether a code requirement, as the database stores it, pins the leaf certificate's team to `teamID`. The
    /// requirement language quotes a value that does not start with a letter (`"0ABCDE1234"`) and may leave one that
    /// does bare, so both spellings count; the bare one only when the team ends there. Never for an unusable team.
    static func namesTeam(_ requirement: String, teamID: String) -> Bool {
        guard HelperIdentity.isUsableTeamID(teamID) else { return false }
        if requirement.contains("subject.OU] = \"\(teamID)\"") { return true }
        guard let range = requirement.range(of: "subject.OU] = \(teamID)") else { return false }
        guard let next = requirement[range.upperBound...].unicodeScalars.first else { return true }
        return !(CharacterSet.alphanumerics.contains(next) || next == "_" || next == "\"")
    }
}

/// The right's own definition (R8 fix round 4, ADR-0014). Measured in a real window on 2026-10-05: with the stock
/// admin rule — `timeout` 0 — the credential the client obtained could not be reused, so the helper's
/// re-check without a dialog failed with `errAuthorizationInteractionNotAllowed` (-60007) every time. This rule keeps the
/// credential valid for `timeoutSeconds` — long enough for the helper's immediate re-check — and never shares it: it lives
/// in the client's one reference, which the client destroys afterwards and the helper frees with `.destroyRights`, so the
/// next click asks for the password again. `allow-root` false: the helper's being root never satisfies the rule.
enum OwnershipRightRule {
    static let ruleClass = "user"
    static let group = "admin"
    static let timeoutSeconds = 10
    /// The text the system dialog shows. Written with the definition, and the only text a read-back may carry (F3).
    static let prompt = "XCodeVault wants to turn on ownership on an external volume."
    /// The dictionary `AuthorizationRightSet` writes. A pure value; `scripts/helper-invariants.sh` pins its lines.
    static var definition: [String: Any] {
        [
            "class": "user",
            "group": "admin",
            "timeout": 10,
            "shared": false,
            "allow-root": false,
            "version": 1,
            "comment": "XCodeVault: turn on ownership for one external volume (ADR-0014). An administrator password on every use.",
        ]
    }
}

/// The daemon's startup step: put the right's definition in place before the listener accepts anything, so the client's
/// first request is evaluated against our rule rather than the database's default. Not fatal when it fails: the verb
/// tries again, and refuses while it cannot.
///
/// It is also the upgrade path (R8 fix round 4): a database still holding the earlier definition is rewritten here, by
/// the new daemon as it starts, so the user's first click after the update is not refused for it.
public enum HelperStartup {
    /// `teamID` is the one `main.swift` validated: the definition counts as ours only when its writer was signed by it.
    public static func defineAuthorizationRights(teamID: String) { _ = defineAuthorizationRights(authority: SecurityRightAuthority(teamID: teamID)) }

    /// The seam: a test passes a fake authority and reads the outcome.
    static func defineAuthorizationRights(authority: any OwnershipRightAuthority) -> RightDefinition {
        let outcome = authority.ensureDefinition()
        HelperAudit.emitStartup(rightDefinition: outcome)
        return outcome
    }
}

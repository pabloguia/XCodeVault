import Foundation

/// An error that renders as the sentence it was constructed with.
///
/// Every error type in this module was declared `Error, CustomStringConvertible` and given a
/// carefully written message. `CustomStringConvertible` only governs `"\(error)"`. The thing that
/// governs `error.localizedDescription` — which is what `catch` handlers log, what the journal
/// records, and what the CLI prints — is `LocalizedError`, and without it Foundation substitutes:
///
///     The operation couldn’t be completed. (XCodeVaultCore.MigrationError error 1.)
///
/// So the messages this project spends its care on were being discarded at exactly the point a
/// user reads them. Found while pinning the issue #25 refusal in `abort`: the test could not tell
/// "refused because the mount question was unanswered" from "tried and was denied", because both
/// arrived as that same placeholder.
///
/// Conforming gives `localizedDescription` the type's own `description`. It changes no control
/// flow and no error identity — only what the text says when something asks for it.
public protocol DescribedError: LocalizedError, CustomStringConvertible {}

extension DescribedError {
    public var errorDescription: String? { description }
}

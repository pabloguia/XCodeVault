import XCodeVaultCore

/// Help text shared by every command (spec 2026-10-03 §5.1).
enum HelpText {
    /// The experimental label in front of an abstract — CLAUDE.md rule 10. One key, put there by one
    /// function, so no language can carry an abstract without it; `CLIExperimentalLabelTests` reads the
    /// rendered abstracts in every language.
    static func experimental(_ text: String) -> String { L10n.tr("cli.label.experimental") + " " + text }
}

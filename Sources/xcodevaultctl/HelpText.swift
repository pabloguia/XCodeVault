import XCodeVaultCore

/// Help text shared by every command (spec 2026-10-03 §5.1).
enum HelpText {
    /// The experimental label in front of an abstract — CLAUDE.md rule 10. One key, put there by one
    /// function, so no language can carry an abstract without it; `CLIExperimentalLabelTests` reads the
    /// rendered abstracts in every language.
    static func experimental(_ text: String) -> String {
        let label = L10n.tr("cli.label.experimental")
        // Japanese and Chinese labels end in a full-width "。", which carries its own space: no ASCII space after it.
        return label + (label.hasSuffix("。") ? "" : " ") + text
    }
}

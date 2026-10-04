import Foundation

/// The Health screen's cards (R4): one per doctor finding, its long text folded. The app shows what this decides — the
/// order, the one short sentence, the size and what goes under "Details" — and decides none of it. The prose is the
/// finding's own English (S2); only the app's labels around it are translated.
public struct HealthCard: Sendable, Equatable, Identifiable {
    public let finding: Finding
    public var id: String { finding.id }
    public var severity: Finding.Severity { finding.severity }
    public var title: String { finding.title }
    /// One short sentence: the first of the explanation (`HealthCard.firstSentence`).
    public let sentence: String
    /// The finding's size, when it has one (`Finding.bytes`).
    public var bytes: UInt64? { finding.bytes }
    /// The first sentence of the fix, shown on the card when the finding has no action button.
    public let fixSentence: String?
    /// What "Details" folds: nil when there is nothing more to say than the card already does.
    public let details: Details?

    public struct Details: Sendable, Equatable {
        /// The whole explanation; nil when it is the card's sentence and nothing more.
        public let explanation: String?
        /// The per-item breakdown (a device and its size), largest first.
        public let lines: [Finding.Line]
        /// Why `clean` does not offer it.
        public let notOfferedByClean: String?
        /// The whole fix; nil when it is the card's fix sentence and nothing more.
        public let fix: String?
        public let path: String?
        public let evidence: String?
    }

    public init(_ finding: Finding) {
        self.finding = finding
        let explanation = finding.parts?.explanation ?? finding.detail
        let sentence = HealthCard.firstSentence(explanation)
        self.sentence = sentence
        // A finding with an action shows the action's control; its remediation is the text fallback and goes in Details.
        let fixSentence = finding.action == nil ? finding.remediation.map(HealthCard.firstSentence) : nil
        self.fixSentence = fixSentence
        let longer = { (whole: String?, shown: String?) -> String? in
            guard let whole, HealthCard.trimmed(whole) != (shown.map(HealthCard.trimmed) ?? "") else { return nil }
            return whole
        }
        let details = Details(
            explanation: longer(explanation, sentence), lines: finding.parts?.lines ?? [], notOfferedByClean: finding.parts?.notOfferedByClean,
            fix: longer(finding.remediation, fixSentence), path: finding.path, evidence: finding.evidence)
        let empty =
            details.explanation == nil && details.lines.isEmpty && details.notOfferedByClean == nil && details.fix == nil
            && details.path == nil && details.evidence == nil
        self.details = empty ? nil : details
    }

    /// The cards in their order: most severe first, then the largest, then as the doctor listed them.
    public static func cards(_ findings: [Finding]) -> [HealthCard] {
        findings.enumerated()
            .sorted { a, b in
                if a.element.severity != b.element.severity { return a.element.severity > b.element.severity }
                let (sa, sb) = (a.element.bytes ?? 0, b.element.bytes ?? 0)
                if sa != sb { return sa > sb }
                return a.offset < b.offset
            }
            .map { HealthCard($0.element) }
    }

    /// The summary line's counts: one per severity present, most severe first.
    public static func counts(_ findings: [Finding]) -> [(severity: Finding.Severity, count: Int)] {
        let order: [Finding.Severity] = [.critical, .error, .warning, .info]
        return order.compactMap { s in
            let n = findings.filter { $0.severity == s }.count
            return n > 0 ? (s, n) : nil
        }
    }

    /// The first sentence of `text`: up to the first `.`, `!` or `?` that is followed by white space or the end, or up to
    /// the first line break, whichever comes first. An abbreviation (`e.g.`, `i.e.`, `etc.`, `vs.`) and a period inside a
    /// name (`TCC.db`, `26.6.2`) do not end it, nor does one inside backticks. Text with no such end is returned whole,
    /// trimmed.
    public static func firstSentence(_ text: String) -> String {
        let chars = Array(trimmed(text))
        var inCode = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "`" { inCode.toggle() }
            if c == "\n" { return trimmed(String(chars[..<i])) }
            if !inCode, c == "." || c == "!" || c == "?" {
                let atEnd = i + 1 == chars.count
                let beforeSpace = !atEnd && chars[i + 1].isWhitespace
                if (atEnd || beforeSpace) && !(c == "." && endsAbbreviation(chars, at: i)) {
                    return trimmed(String(chars[...i]))
                }
            }
            i += 1
        }
        return trimmed(String(chars))
    }

    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "approx", "cf"]

    /// Whether the period at `index` ends one of `abbreviations`.
    private static func endsAbbreviation(_ chars: [Character], at index: Int) -> Bool {
        var start = index
        while start > 0, !chars[start - 1].isWhitespace, chars[start - 1] != "(" { start -= 1 }
        return abbreviations.contains(String(chars[start..<index]).lowercased())
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Finding.Severity {
    /// The severity's SF Symbol, always shown with its word: a severity is never told by color.
    public var symbolName: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .error: "xmark.octagon"
        case .warning: "exclamationmark.triangle"
        case .info: "info.circle"
        }
    }
}

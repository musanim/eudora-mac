import Foundation

/// The user's own auto-correction list — the small, fully-controlled set that
/// backs "Bjork → Björk" in the composer. Distinct from macOS's system spelling
/// dictionary and its text-replacement list: only rules the user adds here
/// apply, and nothing else leaks in.
///
/// Matching is exact and **case-sensitive** by design: "Bjork" corrects, but
/// "bjork" or "BJORK" do not unless the user adds those as their own rules. The
/// replacement is inserted verbatim, exactly as stored.
///
/// Pure and `Codable` so it lives in the testable library; the app owns the
/// UserDefaults persistence and the editor wiring.
public struct TextCorrections: Codable, Equatable, Sendable {
    /// One correction: type `trigger` (as a whole word), get `replacement`.
    public struct Rule: Codable, Equatable, Sendable, Identifiable {
        public var trigger: String
        public var replacement: String
        /// The trigger is the rule's identity — one replacement per trigger.
        public var id: String { trigger }
        public init(trigger: String, replacement: String) {
            self.trigger = trigger
            self.replacement = replacement
        }
    }

    /// In insertion order, so the Settings list stays stable as the user edits.
    public private(set) var rules: [Rule]

    public init(rules: [Rule] = []) { self.rules = rules }

    /// Add a rule, or update the replacement of the one with this exact trigger.
    /// A blank trigger or replacement, or a rule that would swap a word for
    /// itself, is ignored. Returns whether anything was stored.
    @discardableResult
    public mutating func set(trigger: String, replacement: String) -> Bool {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !r.isEmpty, t != r else { return false }
        if let i = rules.firstIndex(where: { $0.trigger == t }) {
            rules[i].replacement = r
        } else {
            rules.append(Rule(trigger: t, replacement: r))
        }
        return true
    }

    /// Forget the rule with this exact trigger.
    public mutating func remove(trigger: String) {
        rules.removeAll { $0.trigger == trigger }
    }

    /// The replacement for a just-completed word, or nil when no exact,
    /// case-sensitive rule applies (or the rule would change nothing).
    public func replacement(for word: String) -> String? {
        guard let rule = rules.first(where: { $0.trigger == word }) else { return nil }
        return rule.replacement == word ? nil : rule.replacement
    }
}

import Foundation

/// A preset the editor offers for an Ask AI request.
public enum NoteAction: String, Sendable, Codable, CaseIterable, Hashable {
    case improve, grammar, shorter, longer, summarize, translate, explain
    case `continue`, brainstorm, outline
}

/// Builds the user turn of an Ask AI request from what the editor sends.
public struct NotePrompt: Sendable, Equatable {
    /// What the user typed (may be empty with an action).
    public var instruction: String
    public var action: NoteAction?
    /// The target language name for `translate` (e.g. "Portuguese").
    public var language: String?
    /// The selected text as Markdown, if any.
    public var selection: String?
    /// The whole note as Markdown, when the user includes it as context.
    public var note: String?
    /// A follow-up in the same conversation: the note was already sent and is not repeated.
    public var followUp: Bool

    public init(
        instruction: String,
        action: NoteAction? = nil,
        language: String? = nil,
        selection: String? = nil,
        note: String? = nil,
        followUp: Bool = false
    ) {
        self.instruction = instruction
        self.action = action
        self.language = language
        self.selection = selection
        self.note = note
        self.followUp = followUp
    }

    /// The text sent to the model.
    public var text: String {
        let selection = Self.nonBlank(selection)
        let note = followUp ? nil : Self.nonBlank(note)
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let note { parts.append("<note>\n\(note)\n</note>") }
        if let selection { parts.append("<selection>\n\(selection)\n</selection>") }
        var task = action.map { actionText($0, hasSelection: selection != nil) } ?? ""
        if !instruction.isEmpty {
            task = task.isEmpty ? instruction : "\(task)\nAdditional instructions from the user: \(instruction)"
        }
        if task.isEmpty, selection != nil { task = "Work on the selected text." }
        parts.append("<request>\n\(task)\n</request>")
        return parts.joined(separator: "\n\n")
    }

    private func actionText(_ action: NoteAction, hasSelection: Bool) -> String {
        let target = hasSelection ? "the selected text" : "the note"
        switch action {
        case .improve:
            return "Improve the writing of \(target): clearer, more fluent and better structured, same meaning and tone. Reply with the rewritten text only."
        case .grammar:
            return "Fix the spelling, grammar and punctuation of \(target). Change nothing else. Reply with the corrected text only."
        case .shorter:
            return "Make \(target) shorter and more concise, keeping the key points. Reply with the rewritten text only."
        case .longer:
            return "Make \(target) longer, expanding it with relevant detail in the same style. Reply with the rewritten text only."
        case .summarize:
            return "Summarize \(target) concisely, as Markdown."
        case .translate:
            let language = Self.nonBlank(language) ?? "English"
            return "Translate \(target) into \(language), keeping its Markdown formatting. Reply with the translation only."
        case .explain:
            return "Explain \(target) clearly and simply, as Markdown."
        case .continue:
            return "Continue writing from where the note ends, in the same language, style and format. "
                + "Reply only with the new text that follows, without repeating what is already there."
        case .brainstorm:
            return "Brainstorm ideas related to \(target) as a Markdown bullet list."
        case .outline:
            return "Write a structured outline for \(target) as Markdown headings and nested lists."
        }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

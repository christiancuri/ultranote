import Foundation

/// Last-resort clean-up of a final answer before it goes into the note. The system prompt already
/// asks for bare Markdown; this only removes the wrappers models still add now and then, and never
/// touches formatting inside the answer.
public enum AnswerCleanup {
    public static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = stripPreamble(result)
        result = stripWrappingFence(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The info strings of a fence that wraps the whole answer as a document (not code).
    static let documentFenceInfos: Set<String> = ["", "markdown", "md", "gfm"]

    /// "```markdown\n...\n```" (the whole answer, a single block) → its body. Code fences in other
    /// languages (```swift, ```mermaid) are content and stay.
    static func stripWrappingFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 else { return text }
        var body = text.dropFirst(3).dropLast(3)
        guard let newline = body.firstIndex(of: "\n") else { return text }
        let info = body[body.startIndex..<newline].trimmingCharacters(in: .whitespaces).lowercased()
        guard documentFenceInfos.contains(info) else { return text }
        body = body[body.index(after: newline)...]
        // A fence inside means several blocks: leave the text alone.
        guard !body.contains("```") else { return text }
        return String(body).trimmingCharacters(in: .newlines)
    }

    /// A one-line "Here is the improved text:" before the answer → dropped.
    static func stripPreamble(_ text: String) -> String {
        guard let newline = text.firstIndex(of: "\n") else { return text }
        let first = text[text.startIndex..<newline].trimmingCharacters(in: .whitespaces)
        guard first.hasSuffix(":"), first.count <= 80 else { return text }
        let lowered = first.lowercased()
        let openers = ["here is", "here's", "here are", "sure", "certainly", "aqui está", "aqui estão", "segue"]
        guard openers.contains(where: lowered.hasPrefix) else { return text }
        return String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@testable import AgentKit
import Testing

@Suite("Note prompt and answer cleanup")
struct NotePromptTests {
    @Test func instructionOnly() {
        #expect(NotePrompt(instruction: "  Write a haiku  ").text == "<request>\nWrite a haiku\n</request>")
    }

    @Test func noteAndSelectionGoInTags() {
        let prompt = NotePrompt(instruction: "Fix it", selection: "sel", note: "# Note\nbody")
        #expect(prompt.text == "<note>\n# Note\nbody\n</note>\n\n<selection>\nsel\n</selection>\n\n<request>\nFix it\n</request>")
    }

    @Test func followUpOmitsTheNote() {
        let prompt = NotePrompt(instruction: "Shorter", selection: "sel", note: "whole note", followUp: true)
        #expect(!prompt.text.contains("<note>") && !prompt.text.contains("whole note"))
        #expect(prompt.text.contains("<selection>\nsel\n</selection>"))
    }

    @Test func blankPartsAreDropped() {
        let prompt = NotePrompt(instruction: "Q", selection: " \n", note: "")
        #expect(prompt.text == "<request>\nQ\n</request>")
        #expect(NotePrompt(instruction: "", selection: "sel").text.hasSuffix("<request>\nWork on the selected text.\n</request>"))
    }

    @Test(arguments: [
        (NoteAction.improve, "Improve the writing of the selected text"),
        (.grammar, "Fix the spelling, grammar and punctuation of the selected text"),
        (.shorter, "Make the selected text shorter"),
        (.longer, "Make the selected text longer"),
        (.summarize, "Summarize the selected text"),
        (.translate, "Translate the selected text into English"),
        (.explain, "Explain the selected text"),
        (.continue, "Continue writing from where the note ends"),
        (.brainstorm, "Brainstorm ideas related to the selected text"),
        (.outline, "Write a structured outline for the selected text"),
    ])
    func actionTemplateWithSelection(action: NoteAction, opening: String) {
        let text = NotePrompt(instruction: "", action: action, selection: "sel").text
        #expect(text.contains("<request>\n\(opening)"))
    }

    @Test func actionWithoutSelectionTargetsTheNote() {
        let text = NotePrompt(instruction: "", action: .improve, note: "body").text
        #expect(text.contains("Improve the writing of the note:"))
        #expect(!text.contains("<selection>"))
    }

    @Test func instructionIsAppendedToTheAction() {
        let text = NotePrompt(instruction: " keep it formal ", action: .shorter, selection: "sel").text
        #expect(text.hasSuffix("Reply with the rewritten text only.\nAdditional instructions from the user: keep it formal\n</request>"))
    }

    @Test func translateUsesTheLanguage() {
        let text = NotePrompt(instruction: "", action: .translate, language: "Portuguese", selection: "Hello").text
        #expect(text.contains("Translate the selected text into Portuguese, keeping its Markdown formatting."))
        #expect(NotePrompt(instruction: "", action: .translate, language: " ", selection: "x").text.contains("into English"))
    }

    // MARK: Answer cleanup

    @Test(arguments: [
        ("**Answer:** 42", "**Answer:** 42"),
        ("use `ls` and `cd`", "use `ls` and `cd`"),
        ("```swift\nlet x = 1\n```", "```swift\nlet x = 1\n```"),
        ("```mermaid\ngraph TD\nA-->B\n```", "```mermaid\ngraph TD\nA-->B\n```"),
        ("```markdown\n# Title\n\n- one\n```", "# Title\n\n- one"),
        ("```md\nbody\n```", "body"),
        ("```\nline one\nline two\n```", "line one\nline two"),
        ("```a```\nmid\n```b```", "```a```\nmid\n```b```"),
        ("```markdown\nx\n```\n\n```markdown\ny\n```", "```markdown\nx\n```\n\n```markdown\ny\n```"),
        ("Here is the improved text:\nBetter **text**.", "Better **text**."),
        ("Sure, here you go:\n\n- a\n- b", "- a\n- b"),
        ("Here is the code:\n```markdown\n# T\n```", "# T"),
        ("Steps:\n1. one", "Steps:\n1. one"),
        ("  plain text  \n", "plain text"),
        ("- one\n- two", "- one\n- two"),
    ])
    func answerCleanup(input: String, expected: String) {
        #expect(AnswerCleanup.clean(input) == expected)
    }
}

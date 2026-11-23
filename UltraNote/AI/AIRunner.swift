import AgentKit
import EditorBridge
import EditorHost
import Foundation

/// Runs the AI panel's requests: one at a time, streaming the provider's events to the page as
/// `aiEvent` calls. Never logs request or answer text.
@MainActor
final class AIRunner {
    private let service: AIService
    private let editor: EditorController

    /// The request being answered.
    private var current: (id: String, task: Task<Void, Never>)?
    /// Whether the provider holds a conversation the next fresh request must not see.
    private var hasConversation = false

    init(service: AIService, editor: EditorController) {
        self.service = service
        self.editor = editor
    }

    func ask(_ payload: AIAskPayload) {
        let requestId = payload.requestId
        guard service.settings.enabled else {
            send(AIEvent(requestId: requestId, type: .failed, error: AIEventError(
                code: "disabled", message: L("AI features are turned off in Settings."), canOpenSettings: true
            )))
            return
        }
        guard current == nil else {
            send(failure(.busy, requestId: requestId))
            return
        }
        let settings = service.settings
        let action = payload.action.flatMap(NoteAction.init(rawValue:))
        // With a preset the editor sends its label as the instruction; the template says it all.
        let prompt = NotePrompt(
            instruction: action == nil ? payload.instruction : "",
            action: action,
            language: payload.language,
            selection: payload.selection,
            note: settings.includeNote ? payload.note : nil,
            followUp: payload.followUp && hasConversation
        )
        let request = AskRequest(prompt: prompt.text, configuration: settings.configuration)
        let startFresh = !payload.followUp && hasConversation
        hasConversation = true
        let task = Task { [weak self, service] in
            await service.settingsApplied()
            let provider = service.provider
            if startFresh { await provider.resetConversation() }
            let stream = await provider.ask(request)
            do {
                for try await event in stream {
                    await self?.forward(event, requestId: requestId)
                }
            } catch {
                await self?.deliver(AIEvent(requestId: requestId, type: .failed, error: AIEventError(
                    code: "other", message: L("The answer could not be read. Try again."), canOpenSettings: false
                )))
            }
            self?.finished(requestId)
        }
        current = (requestId, task)
        Log.app.info("ai request \(requestId, privacy: .public) sent (\(settings.provider.rawValue, privacy: .public))")
    }

    func cancel(requestId: String) {
        guard current?.id == requestId else { return }
        let provider = service.provider
        Task { await provider.cancel() }
    }

    /// The panel closed: the next request starts a fresh conversation.
    func reset() {
        guard hasConversation else { return }
        hasConversation = false
        let provider = service.provider
        Task { await provider.resetConversation() }
    }

    private func finished(_ requestId: String) {
        if current?.id == requestId { current = nil }
    }

    /// Awaited in the stream loop, so events reach the page in order.
    private func forward(_ event: AskEvent, requestId: String) async {
        let aiEvent: AIEvent
        switch event {
        case .thinking: aiEvent = AIEvent(requestId: requestId, type: .thinking)
        case .textDelta(let text): aiEvent = AIEvent(requestId: requestId, type: .delta, text: text)
        case .completed(let text): aiEvent = AIEvent(requestId: requestId, type: .completed, text: text)
        case .cancelled(let partial): aiEvent = AIEvent(requestId: requestId, type: .cancelled, text: partial)
        case .failed(let error):
            Log.app.error("ai request \(requestId, privacy: .public) failed: \(error.code, privacy: .public)")
            aiEvent = failure(error, requestId: requestId)
        }
        await deliver(aiEvent)
    }

    private func failure(_ error: AskError, requestId: String) -> AIEvent {
        AIEvent(requestId: requestId, type: .failed, error: AIEventError(
            code: error.code,
            message: AIPresentation.message(for: error, provider: service.settings.provider),
            canOpenSettings: error.canOpenSettings
        ))
    }

    /// An event outside a stream (the request was refused).
    private func send(_ event: AIEvent) {
        Task { await deliver(event) }
    }

    private func deliver(_ event: AIEvent) async {
        do {
            try await editor.sendAIEvent(event)
        } catch {
            Log.app.error("aiEvent failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

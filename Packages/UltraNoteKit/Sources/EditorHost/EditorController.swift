import EditorBridge
import WebKit

/// Owns one ``EditorWebView`` and exposes the bridge contract as an async Swift API.
///
///     let editor = EditorController(configuration: .init(mode: .edit, resources: resources))
///     editor.load()
///     try await editor.waitUntilReady()
///     try await editor.setNote(noteId: "a", markdown: "# Hello")
///
/// The page announces itself with a `ready` message (`didFinish` can fire earlier, so it is
/// not used); every call before that throws ``EditorError/notReady``.
@MainActor
public final class EditorController {
    public struct Configuration: Sendable {
        public var mode: EditorMode
        /// Where `app://editor/…` is served from.
        public var resources: EditorResourceResolver
        public var frame: CGRect
        /// Web Inspector access. On in Debug builds, off in Release.
        public var isInspectable: Bool
        public var readyTimeout: Duration
        public var callTimeout: Duration

        public init(
            mode: EditorMode,
            resources: EditorResourceResolver,
            frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
            isInspectable: Bool = Configuration.isDebugBuild,
            readyTimeout: Duration = .seconds(15),
            callTimeout: Duration = .seconds(30)
        ) {
            self.mode = mode
            self.resources = resources
            self.frame = frame
            self.isInspectable = isInspectable
            self.readyTimeout = readyTimeout
            self.callTimeout = callTimeout
        }

        public static var isDebugBuild: Bool {
            #if DEBUG
            true
            #else
            false
            #endif
        }
    }

    public let configuration: Configuration
    public let webView: EditorWebView

    /// Debounced autosave from the page.
    public var onContentChanged: ((ContentChangedPayload) -> Void)?
    /// A link the user activated that leaves the app (`http`, `https` or `mailto` only).
    public var onOpenLink: ((URL) -> Void)?
    /// A page-side log line.
    public var onLog: ((LogPayload) -> Void)?
    /// A host-side problem worth seeing during development: a message that was dropped, a
    /// navigation or link that was refused, a resource that was not served. Always logged
    /// (category `editor-host`); this callback is for tools such as the self-test.
    public var onDiagnostic: ((String) -> Void)?
    /// `saveAttachment`: store the image, return its `attachments/<file>` path. A thrown
    /// error rejects the page's promise with its description.
    public var onSaveAttachment: ((SaveAttachmentPayload) async throws -> String)?
    /// `pickImage`: let the user choose an image and store it; `nil` when cancelled.
    public var onPickImage: (() async throws -> String?)?
    /// `aiAsk`: a request from the AI panel (answer with ``sendAIEvent(_:)``).
    public var onAIAsk: ((AIAskPayload) -> Void)?
    /// `aiCancel`: stop the request with this id.
    public var onAICancel: ((AICancelPayload) -> Void)?
    /// `aiReset`: the AI panel closed; forget the conversation.
    public var onAIReset: (() -> Void)?
    /// `aiOpenSettings`: open Settings on the AI tab.
    public var onAIOpenSettings: (() -> Void)?
    /// Image files dropped on the view (from Finder), with the drop point in view
    /// coordinates (top-left origin). Store them and insert with ``insertImage(path:at:)``.
    public var onDropImageFiles: (([URL], CGPoint) -> Void)? {
        get { webView.onDropImageFiles }
        set { webView.onDropImageFiles = newValue }
    }

    /// Where `app://editor/…` is served from now (``Configuration/resources`` at first).
    public var resources: EditorResourceResolver {
        get { schemeHandler.resources }
        set { schemeHandler.resources = newValue }
    }

    public var mode: EditorMode { configuration.mode }
    public var isReady: Bool {
        if case .ready = readyState { true } else { false }
    }

    private enum ReadyState {
        case idle
        case loading
        case ready
        case failed(EditorError)
    }

    private var readyState = ReadyState.idle
    private var readyWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    // The web view holds these weakly or through WebKit; the controller keeps them alive.
    private let schemeHandler: EditorSchemeHandler
    private let messageProxy = ScriptMessageProxy()
    private let navigationDelegate = NavigationDelegate()

    public init(configuration: Configuration) {
        self.configuration = configuration
        schemeHandler = EditorSchemeHandler(resources: configuration.resources)
        webView = EditorWebView(
            frame: configuration.frame,
            schemeHandler: schemeHandler,
            messageHandler: messageProxy,
            isInspectable: configuration.isInspectable
        )
        messageProxy.controller = self
        navigationDelegate.controller = self
        webView.navigationDelegate = navigationDelegate
        schemeHandler.onFailure = { [weak self] statusCode, url in
            self?.diagnose("\(statusCode) for \(url.absoluteString)")
        }
    }

    // MARK: - Loading

    /// Loads (or reloads) the page for this controller's mode. Follow with ``waitUntilReady(timeout:)``.
    public func load() {
        readyState = .loading
        webView.load(URLRequest(url: BridgeContract.entryURL(mode: mode)))
    }

    /// Returns once the page has posted `ready`. Throws when the load failed, the page
    /// reported the wrong mode, or `timeout` (default: the configuration's) elapsed.
    public func waitUntilReady(timeout: Duration? = nil) async throws {
        switch readyState {
        case .ready: return
        case .failed(let error): throw error
        case .idle: throw EditorError.notLoaded
        case .loading: break
        }
        let id = UUID()
        let limit = timeout ?? configuration.readyTimeout
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: limit) } catch { return }
            self?.readyWaiters.removeValue(forKey: id)?.resume(throwing: EditorError.readyTimedOut(limit))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            readyWaiters[id] = continuation
        }
    }

    private func finishLoading(_ state: ReadyState) {
        readyState = state
        let waiters = readyWaiters.values
        readyWaiters.removeAll()
        for waiter in waiters {
            switch state {
            case .failed(let error): waiter.resume(throwing: error)
            case .ready, .idle, .loading: waiter.resume()
            }
        }
    }

    // MARK: - Swift → JS

    /// Replaces the document. The page clears its undo history and emits no `contentChanged`.
    public func setNote(noteId: String, markdown: String) async throws {
        _ = try await perform(.setNote(noteId: noteId, markdown: markdown))
    }

    /// The current document as Markdown.
    public func getMarkdown() async throws -> String {
        try await string(from: .getMarkdown)
    }

    /// The current document as plain text, blocks separated by a blank line.
    public func getText() async throws -> String {
        try await string(from: .getText)
    }

    /// Runs an editor command. Returns whether the page applied it.
    @discardableResult
    public func runCommand(_ command: EditorCommand) async throws -> Bool {
        let call = EditorCall.runCommand(command)
        guard let applied = try await perform(call).boolValue else {
            throw EditorError.unexpectedResult(function: call.function, expected: "boolean")
        }
        return applied
    }

    public func setAppearance(_ appearance: EditorAppearance) async throws {
        _ = try await perform(.setAppearance(appearance))
    }

    /// Streams one AI panel event to the page.
    public func sendAIEvent(_ event: AIEvent) async throws {
        _ = try await perform(.aiEvent(event))
    }

    /// Shows or hides the page's AI entry points.
    public func setAIState(_ state: AIState) async throws {
        _ = try await perform(.setAIState(state))
    }

    /// Export mode only. Returns when fonts, images and Mermaid diagrams are final.
    public func renderExport(markdown: String, timeout: Duration? = nil) async throws {
        let call = EditorCall.renderExport(markdown: markdown)
        guard mode == .export else { throw EditorError.unavailable(function: call.function, mode: mode) }
        _ = try await perform(call, timeout: timeout)
    }

    /// `{ mode, mermaidRendered, mermaidFailed, blocks }`. The shape is the page's, so it
    /// is returned as JSON.
    public func debugInfo() async throws -> JSONValue {
        try await perform(.debugInfo)
    }

    /// Inserts an `attachments/<file>` image at the selection, or at the document position
    /// under `point` (view coordinates, top-left origin). Returns whether it was inserted.
    @discardableResult
    public func insertImage(path: String, at point: CGPoint? = nil) async throws -> Bool {
        let call = EditorCall.insertImage(path: path, at: point)
        guard let inserted = try await perform(call).boolValue else {
            throw EditorError.unexpectedResult(function: call.function, expected: "boolean")
        }
        return inserted
    }

    /// Gives the editor keyboard focus: the web view becomes first responder and the page
    /// focuses its editable element (keeping its selection).
    public func focus() async {
        webView.window?.makeFirstResponder(webView)
        guard isReady else { return }
        _ = try? await webView.callAsyncJavaScript(
            "document.querySelector('[contenteditable=\"true\"]')?.focus({ preventScroll: true });",
            contentWorld: .page
        )
    }

    /// Whether keyboard focus is in the editor (the web view or a view inside it).
    public var hasKeyboardFocus: Bool {
        guard let responder = webView.window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    /// Finds `string` in the page and selects the match. Returns whether one was found.
    public func find(_ string: String, backwards: Bool = false) async -> Bool {
        guard !string.isEmpty else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let result = try? await webView.find(string, configuration: configuration)
        return result?.matchFound ?? false
    }

    private func string(from call: EditorCall) async throws -> String {
        guard let value = try await perform(call).stringValue else {
            throw EditorError.unexpectedResult(function: call.function, expected: "string")
        }
        return value
    }

    private func perform(_ call: EditorCall, timeout: Duration? = nil) async throws -> JSONValue {
        guard isReady else { throw EditorError.notReady }
        let limit = timeout ?? configuration.callTimeout
        let webView = self.webView
        return try await withTimeout(limit, timeoutError: EditorError.callTimedOut(function: call.function, limit)) {
            var arguments: [String: Any] = [:]
            if let argument = call.argument {
                arguments[EditorCall.argumentName] = argument.foundationObject
            }
            let result: Any?
            do {
                result = try await webView.callAsyncJavaScript(call.script, arguments: arguments, in: nil, contentWorld: .page)
            } catch {
                throw EditorError.scriptFailed(function: call.function, message: Self.describeScriptError(error))
            }
            guard call.returnsValue else { return .null }
            guard let value = JSONValue(foundationObject: result) else {
                throw EditorError.unexpectedResult(function: call.function, expected: "a JSON value")
            }
            return value
        }
    }

    private static func describeScriptError(_ error: any Error) -> String {
        let info = (error as NSError).userInfo
        guard let message = info["WKJavaScriptExceptionMessage"] as? String else { return error.localizedDescription }
        guard let line = info["WKJavaScriptExceptionLineNumber"] as? Int else { return message }
        return "\(message) (line \(line))"
    }

    // MARK: - JS → Swift

    /// Handles one message body. The success value is the reply that resolves the page's
    /// promise (a JSON string, or `nil` for `null`); a failure rejects it with its description.
    func receive(messageBody: String) async -> Result<String?, any Error> {
        let message: EditorMessage
        do {
            message = try BridgeCodec.decode(messageBody)
        } catch {
            diagnose("dropped a message: \(error.localizedDescription)")
            return .failure(error)
        }
        switch message {
        case .saveAttachment(let payload):
            guard let onSaveAttachment else { return .failure(EditorError.unhandledMessage(message.type.rawValue)) }
            do {
                return .success(AttachmentReply(path: try await onSaveAttachment(payload)).json)
            } catch {
                diagnose("saveAttachment failed: \(error.localizedDescription)")
                return .failure(error)
            }
        case .pickImage:
            guard let onPickImage else { return .failure(EditorError.unhandledMessage(message.type.rawValue)) }
            do {
                return .success(try await onPickImage().map { AttachmentReply(path: $0).json })
            } catch {
                diagnose("pickImage failed: \(error.localizedDescription)")
                return .failure(error)
            }
        case .ready, .contentChanged, .openLink, .log, .aiAsk, .aiCancel, .aiReset, .aiOpenSettings:
            return .success(handleEvent(message))
        }
    }

    /// Messages without a reply.
    private func handleEvent(_ message: EditorMessage) -> String? {
        switch message {
        case .ready(let payload):
            if payload.mode == mode {
                finishLoading(.ready)
            } else {
                finishLoading(.failed(.modeMismatch(expected: mode, actual: payload.mode)))
            }
        case .contentChanged(let payload):
            onContentChanged?(payload)
        case .openLink(let payload):
            if let url = NavigationPolicy.externalURL(from: payload.url) {
                onOpenLink?(url)
            } else {
                diagnose("refused to open \(payload.url)")
            }
        case .log(let payload):
            onLog?(payload)
        case .aiAsk(let payload):
            onAIAsk?(payload)
        case .aiCancel(let payload):
            onAICancel?(payload)
        case .aiReset:
            onAIReset?()
        case .aiOpenSettings:
            onAIOpenSettings?()
        case .saveAttachment, .pickImage:
            break
        }
        return nil
    }

    // MARK: - Navigation events

    /// `WebKitErrorFrameLoadInterruptedByPolicyChange`: what a cancelled navigation reports.
    private static let frameLoadInterruptedByPolicyChange = 102

    func navigationFailed(_ error: any Error) {
        // Only the entry page's own load matters: a navigation the policy cancelled
        // (an external link) can surface here too and is not a failure of the editor.
        guard case .loading = readyState else { return }
        let failure = error as NSError
        let wasCancelled = (failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled)
            || (failure.domain == "WebKitErrorDomain" && failure.code == Self.frameLoadInterruptedByPolicyChange)
        guard !wasCancelled else { return }
        diagnose("load failed: \(error.localizedDescription)")
        finishLoading(.failed(.loadFailed(error.localizedDescription)))
    }

    func webContentProcessTerminated() {
        // The page is gone, and its document with it. The host decides when to reload and
        // which note to send again.
        diagnose("web content process terminated")
        finishLoading(.failed(.webContentProcessTerminated))
    }

    func navigationBlocked(_ url: URL?) {
        diagnose("blocked navigation to \(url?.absoluteString ?? "an empty URL")")
    }

    private func diagnose(_ message: String) {
        // URLs here are the bundle's own or links found in a note: keep them out of the
        // persisted log in Release builds.
        #if DEBUG
        Log.editor.error("\(message, privacy: .public)")
        #else
        Log.editor.error("\(message, privacy: .private)")
        #endif
        onDiagnostic?(message)
    }
}

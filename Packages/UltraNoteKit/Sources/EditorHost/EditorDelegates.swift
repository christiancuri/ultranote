import EditorBridge
import WebKit

/// Receives the page's messages. `WKUserContentController` retains its handlers, so the
/// handler registered with WebKit is this proxy, holding the controller weakly.
@MainActor
final class ScriptMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var controller: EditorController?

    /// The async form of `userContentController(_:didReceive:replyHandler:)`. The reply
    /// resolves the page's promise: a JSON string or `null`, or a rejection with a message.
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard message.frameInfo.isMainFrame else {
            return (nil, "messages are accepted from the main frame only")
        }
        guard let body = message.body as? String else {
            return (nil, "the message body must be a JSON string")
        }
        guard let controller else { return (nil, nil) }
        switch await controller.receive(messageBody: body) {
        case .success(let reply): return (reply, nil)
        case .failure(let error): return (nil, error.localizedDescription)
        }
    }
}

/// Locks navigation to the `app` scheme and reports load failures. `WKWebView` holds its
/// navigation delegate weakly; the controller owns this object.
@MainActor
final class NavigationDelegate: NSObject, WKNavigationDelegate {
    weak var controller: EditorController?

    /// The async form: under Swift 6 the completion-handler form is silently never called
    /// unless its handler is typed `@MainActor`.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let decision = NavigationPolicy.decide(url: url, isLinkActivation: navigationAction.navigationType == .linkActivated)
        switch decision {
        case .allow:
            return .allow
        case .openExternally(let url):
            controller?.onOpenLink?(url)
            return .cancel
        case .cancel:
            controller?.navigationBlocked(url)
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        controller?.navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        controller?.navigationFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        controller?.webContentProcessTerminated()
    }
}

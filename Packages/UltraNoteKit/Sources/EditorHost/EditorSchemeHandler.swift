import EditorBridge
import WebKit

/// Serves `app://editor/…` from the editor bundle (and, later, the notes folder's
/// attachments). URL mapping and traversal checks are ``EditorResourceResolver``'s; files
/// are read off the main actor.
@MainActor
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Replaced when the notes folder (and so the attachments folder) changes.
    var resources: EditorResourceResolver
    /// Loads in flight, keyed by their scheme task. A task WebKit stopped must never be
    /// answered (WebKit raises an exception), so answers go out only while the entry exists.
    private var loads: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// A request that was answered with an error status.
    var onFailure: ((_ statusCode: Int, _ url: URL) -> Void)?

    init(resources: EditorResourceResolver) {
        self.resources = resources
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        let request = urlSchemeTask.request
        let resources = self.resources
        loads[key] = Task { [weak self] in
            let payload = await SchemeResponse.load(request.url, method: request.httpMethod, resources: resources)
            guard let self, self.loads.removeValue(forKey: key) != nil else { return }
            guard let url = request.url, let response = payload.httpResponse(for: url) else {
                urlSchemeTask.didFailWithError(URLError(.badServerResponse))
                return
            }
            if payload.statusCode != 200 {
                self.onFailure?(payload.statusCode, url)
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(payload.body)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        loads.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}

/// What the scheme handler answers: an HTTP-style status, headers and body.
struct SchemeResponse: Equatable, Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    /// Resolves the URL and reads the file. Runs off the main actor.
    @concurrent
    static func load(_ url: URL?, method: String?, resources: EditorResourceResolver) async -> SchemeResponse {
        guard let url, (method ?? "GET").uppercased() == "GET" else { return .failure(400) }
        let resource: EditorResource
        do {
            resource = try resources.resolve(url)
        } catch {
            return .failure(error.statusCode)
        }
        guard (try? resource.fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            return .failure(404)
        }
        // Read in full, not memory-mapped: a file that is rewritten while it is being served
        // (a rebuilt bundle, an attachment saved by another app) must not fault.
        guard let body = try? Data(contentsOf: resource.fileURL) else {
            return .failure(500)
        }
        return SchemeResponse(
            statusCode: 200,
            headers: [
                "Content-Type": resource.contentType,
                "Content-Length": String(body.count),
                // The bundle changes with every build; attachments can change on disk.
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
            ],
            body: body
        )
    }

    static func failure(_ statusCode: Int) -> SchemeResponse {
        SchemeResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "text/plain; charset=utf-8", "Content-Length": "0", "Cache-Control": "no-store"],
            body: Data()
        )
    }

    func httpResponse(for url: URL) -> HTTPURLResponse? {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)
    }
}

import EditorBridge
import UniformTypeIdentifiers
import WebKit

/// The web view that hosts the editor bundle. A subclass (rather than SwiftUI's `WebView`)
/// so the host can take image files dropped from Finder, and so export can print it.
///
/// It only ever shows `app://editor/…`: the scheme handler serves the bundle and the page
/// talks to Swift through the `ultranote` message handler.
public final class EditorWebView: WKWebView {
    /// Image files dropped from Finder (file URLs) and the drop point in view coordinates
    /// (top-left origin). When set, such drops are handled natively instead of by the page:
    /// WebKit does not reliably hand file drops from other apps to the page as `File`s.
    var onDropImageFiles: (([URL], CGPoint) -> Void)?

    init(
        frame: CGRect,
        schemeHandler: any WKURLSchemeHandler,
        messageHandler: any WKScriptMessageHandlerWithReply,
        isInspectable: Bool
    ) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: BridgeContract.scheme)
        configuration.userContentController.addScriptMessageHandler(
            messageHandler, contentWorld: .page, name: BridgeContract.messageHandlerName
        )
        // Notes live in files. Nothing the page stores (caches, localStorage) should
        // outlive the process or serve a stale bundle after an update.
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: frame, configuration: configuration)
        self.isInspectable = isInspectable
        allowsBackForwardNavigationGestures = false
        allowsMagnification = false
        allowsLinkPreview = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorWebView is created in code")
    }

    // MARK: - Drops of image files

    /// Image files on a drag pasteboard (Finder), or empty.
    static func imageFileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { url in
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true
        }
    }

    private func handlesDrop(_ sender: any NSDraggingInfo) -> Bool {
        onDropImageFiles != nil && !Self.imageFileURLs(on: sender.draggingPasteboard).isEmpty
    }

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        return handlesDrop(sender) ? .copy : operation
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        return handlesDrop(sender) ? .copy : operation
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let onDropImageFiles, handlesDrop(sender) else { return super.performDragOperation(sender) }
        // Let the page end its drag session without dropping anything.
        super.draggingExited(sender)
        let location = convert(sender.draggingLocation, from: nil)
        let point = CGPoint(x: location.x, y: isFlipped ? location.y : bounds.height - location.y)
        onDropImageFiles(Self.imageFileURLs(on: sender.draggingPasteboard), point)
        return true
    }
}

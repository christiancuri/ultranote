import Foundation

/// The suites that drive a real `WKWebView` run by default: they need no network and no
/// editor build, only a window server. Set `ULTRANOTE_SKIP_WEBVIEW_TESTS=1` to skip them
/// where there is none (a headless session).
public enum WebViewTests {
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ULTRANOTE_SKIP_WEBVIEW_TESTS"] == nil
    }
}

/// A minimal stand-in for the web editor bundle, written to a temporary folder. It follows
/// the bridge contract (an ES module that defines `window.ultranote`, loads a lazy chunk
/// and posts `ready`), so the Swift host can be tested without building `Editor/`.
///
/// Extras for tests only: `window.ultranote.emit(type, payload)` posts any envelope and
/// returns the reply, and `window.lazyChunkLoaded` tells whether the dynamic import ran.
public struct StubEditorBundle: Sendable {
    public let root: URL

    public init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "ultranote-stub-editor-\(UUID().uuidString)", directoryHint: .isDirectory)
        let assets = root.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data(Self.indexHTML.utf8).write(to: root.appending(path: "index.html"))
        try Data(Self.mainScript.utf8).write(to: assets.appending(path: "main.js"))
        try Data(Self.lazyScript.utf8).write(to: assets.appending(path: "lazy.js"))
        try Data(Self.styleSheet.utf8).write(to: assets.appending(path: "style.css"))
    }

    public func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Same shape as Vite's output: relative URLs and `crossorigin` on scripts and styles.
    static let indexHTML = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="color-scheme" content="light dark">
    <script type="module" crossorigin src="./assets/main.js"></script>
    <link rel="modulepreload" crossorigin href="./assets/lazy.js">
    <link rel="stylesheet" crossorigin href="./assets/style.css">
    </head>
    <body><main id="content"></main></body>
    </html>
    """

    static let styleSheet = """
    body { font: 14px -apple-system; margin: 24px; color: #111; background: #fff; }
    p { margin: 0 0 12px; }
    @media print { body { margin: 0; } }
    """

    static let lazyScript = """
    export function mark() { window.lazyChunkLoaded = true; }
    """

    static let mainScript = """
    const mode = new URLSearchParams(location.search).get('mode') === 'export' ? 'export' : 'edit';
    const post = (type, payload) =>
      window.webkit.messageHandlers.ultranote.postMessage(JSON.stringify({ v: 1, type, payload }));
    const content = document.getElementById('content');
    let note = { noteId: '', markdown: '' };

    function show(markdown) {
      const blocks = markdown.split('\\n\\n').filter((text) => text.length > 0).map((text) => {
        const block = document.createElement('p');
        block.textContent = text;
        return block;
      });
      content.replaceChildren(...blocks);
    }

    window.ultranote = {
      async setNote(next) { note = next; show(next.markdown); },
      async getMarkdown() { return note.markdown; },
      async getText() { return [...content.children].map((block) => block.textContent).join('\\n\\n'); },
      async runCommand(name) { return name === 'bold' || name === 'italic'; },
      async setAppearance(appearance) { document.documentElement.dataset.theme = JSON.stringify(appearance); },
      async renderExport({ markdown }) {
        if (mode !== 'export') throw new Error('renderExport is export mode only');
        note = { noteId: 'export', markdown };
        show(markdown);
      },
      async debugInfo() {
        return { mode, mermaidRendered: 0, mermaidFailed: 0, blocks: content.children.length };
      },
      async emit(type, payload) { return await post(type, payload); },
    };

    const lazy = await import('./lazy.js');
    lazy.mark();
    post('ready', { mode });
    """
}

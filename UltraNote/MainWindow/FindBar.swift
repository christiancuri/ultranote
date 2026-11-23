import EditorHost
import Observation
import SwiftUI

/// Find in note (⌘F): the query, whether the last search matched, and the bar's visibility.
/// Searching is WebKit's (`WKWebView.find`), which selects and scrolls to the match.
@MainActor
@Observable
final class FindModel {
    var isVisible = false
    var query = ""
    /// `nil` before the first search of the current query.
    private(set) var lastFound: Bool?
    /// Bumped to move keyboard focus into the field.
    private(set) var focusRequest = 0

    @ObservationIgnored weak var editor: EditorController?

    func show() {
        isVisible = true
        focusRequest += 1
    }

    func hide() {
        isVisible = false
        lastFound = nil
        guard let editor else { return }
        Task { await editor.focus() }
    }

    func next() { search(backwards: false) }
    func previous() { search(backwards: true) }

    func queryChanged() {
        lastFound = nil
        if !query.isEmpty { search(backwards: false) }
    }

    private func search(backwards: Bool) {
        guard let editor, !query.isEmpty else {
            if !isVisible { show() }
            return
        }
        let query = self.query
        Task {
            let found = await editor.find(query, backwards: backwards)
            if query == self.query { lastFound = found }
        }
    }
}

struct FindBar: View {
    @Bindable var find: FindModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("Find in Note"), text: $find.query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { find.next() }
                .onChange(of: find.query) { find.queryChanged() }
                .onKeyPress(.escape) {
                    find.hide()
                    return .handled
                }
            if find.lastFound == false {
                Text(L("Not found"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ControlGroup {
                Button(L("Previous"), systemImage: "chevron.left") { find.previous() }
                    .help(L("Find Previous (⇧⌘G)"))
                Button(L("Next"), systemImage: "chevron.right") { find.next() }
                    .help(L("Find Next (⌘G)"))
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            .disabled(find.query.isEmpty)
            Button(L("Done")) { find.hide() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { fieldFocused = true }
        .onChange(of: find.focusRequest) { fieldFocused = true }
    }
}

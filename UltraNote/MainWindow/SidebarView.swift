import NotesCore
import SwiftUI

/// Search field and the note list, most recently modified first.
struct SidebarView: View {
    @Bindable var notes: NotesModel

    var body: some View {
        let visible = notes.visibleNotes
        List(selection: Binding(get: { notes.selectedID }, set: { notes.select($0) })) {
            ForEach(visible) { note in
                NoteRow(note: note)
                    .tag(note.id)
                    .contextMenu {
                        Button(L("Move to Trash"), role: .destructive) { notes.requestDeletion(of: note.id) }
                    }
            }
        }
        .searchable(text: $notes.query, placement: .sidebar, prompt: Text(L("Search")))
        .onDeleteCommand { notes.requestDeletion() }
        .overlay {
            if notes.isLoaded, visible.isEmpty {
                if notes.query.isEmpty {
                    ContentUnavailableView {
                        Label(L("No Notes"), systemImage: "note.text")
                    } description: {
                        Text(L("Press ⌘N to write your first note."))
                    }
                } else {
                    ContentUnavailableView {
                        Label(L("No Results for “\(notes.query)”"), systemImage: "magnifyingglass")
                    } description: {
                        Text(L("Check the spelling or try a new search."))
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button(L("New Note"), systemImage: "square.and.pencil") { notes.newNote() }
                    .help(L("New Note (⌘N)"))
            }
        }
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.headline)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(note.modified, format: .relative(presentation: .named).locale(Localization.shared.locale))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(note.snippet.isEmpty ? L("No additional text") : note.snippet)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 3)
    }
}

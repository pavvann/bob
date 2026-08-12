import SwiftUI

/// The notes surface — pawan's own scratch files, one glass card in the center
/// of the window. Title chips across the top, the open note underneath as plain
/// text you can type into. No markdown preview: these are his words in his
/// files, and a renderer would only argue with him about them.
///
/// Everything durable lives in NotesStore; this view holds nothing but the
/// naming field's state.
struct NotesSurface: View {
    @ObservedObject private var store = NotesStore.shared

    /// Name-first creation: the `+` opens a field, the name becomes both the
    /// heading and the filename. No untitled notes.
    @State private var naming = false
    @State private var newTitle = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chipsRow
            hairline
            if store.notes.isEmpty {
                emptyState
            } else {
                editor
            }
            whisper
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 220)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.05), lineWidth: 0.5)
        }
        .onAppear {
            store.reload()
            editorFocused = !store.notes.isEmpty
        }
        // leaving the surface commits — a half-typed thought shouldn't wait on
        // the debounce to survive a tab switch.
        .onDisappear { store.flush() }
        .animation(.easeInOut(duration: 0.2), value: store.openID)
        .animation(.easeInOut(duration: 0.25), value: store.conflict)
    }

    // MARK: chips

    private var chipsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(store.notes) { note in
                    chip(note)
                }
                if naming {
                    nameField
                } else {
                    newButton
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .scrollIndicators(.never)
    }

    private func chip(_ note: NotesStore.Note) -> some View {
        let on = note.id == store.openID
        return Button { open(note) } label: {
            HStack(spacing: 5) {
                Text(note.title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // unsaved edits, for the half-second before they land
                if on && store.isDirty {
                    Circle()
                        .fill(Color.accentColor.opacity(0.55))
                        .frame(width: 4, height: 4)
                }
            }
            .foregroundStyle(on ? Color.accentColor.opacity(0.9) : .secondary.opacity(0.75))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(on ? Color.accentColor.opacity(0.14) : .white.opacity(0.06))
            }
        }
        .buttonStyle(.plain)
        .help(note.id)
    }

    private var newButton: some View {
        Button {
            newTitle = ""
            naming = true
            nameFocused = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background { Capsule().fill(.white.opacity(0.06)) }
        }
        .buttonStyle(.plain)
        .help("new note")
    }

    private var nameField: some View {
        TextField(
            "",
            text: $newTitle,
            prompt: Text("name it").foregroundStyle(.secondary.opacity(0.45))
        )
        .textFieldStyle(.plain)
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .frame(width: 130)
        .focused($nameFocused)
        .onSubmit(commitNew)
        .onKeyPress(.escape) {
            cancelNew()
            return .handled
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background { Capsule().fill(Color.accentColor.opacity(0.12)) }
        .transition(.opacity)
    }

    private var hairline: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(height: 0.5)
    }

    // MARK: body

    /// Full-bleed plain text. SF rounded so it reads like the rest of bob
    /// rather than like a code editor.
    private var editor: some View {
        TextEditor(text: Binding(get: { store.text }, set: { store.edit($0) }))
            .font(.system(size: 14, weight: .regular, design: .rounded))
            .foregroundStyle(.primary.opacity(0.9))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .focused($editorFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("nothing here. start one, or tell bob to.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.55))
            if !naming {
                Button {
                    newTitle = ""
                    naming = true
                    nameFocused = true
                } label: {
                    Text("new note")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background { Capsule().fill(Color.accentColor.opacity(0.12)) }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// bob edited the open note while it had unsaved changes. Same voice as a
    /// thread notice — the room talking, not bob.
    @ViewBuilder
    private var whisper: some View {
        if let line = store.conflict {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("⏺")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary.opacity(0.4))
                Text(line)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    // MARK: behaviour

    private func open(_ note: NotesStore.Note) {
        cancelNew()
        store.open(note.id)
        editorFocused = true
    }

    private func commitNew() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { cancelNew(); return }
        naming = false
        newTitle = ""
        store.create(titled: title)
        editorFocused = true
    }

    private func cancelNew() {
        naming = false
        newTitle = ""
    }
}

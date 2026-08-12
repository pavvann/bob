import SwiftUI
import AppKit

/// Screen ↔ board mapping for the pannable, zoomable plane.
/// screen = board × scale + pan. All interaction math funnels through this
/// so pan, zoom and card drags stay consistent.
struct PlaneTransform: Equatable {
    var pan: CGSize = .zero
    var scale: CGFloat = 1

    static let minScale: CGFloat = 0.5
    static let maxScale: CGFloat = 1.5

    func toBoard(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.width) / scale, y: (p.y - pan.height) / scale)
    }

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + pan.width, y: p.y * scale + pan.height)
    }

    /// Rescale keeping the board point under `anchor` (screen coords) fixed.
    mutating func zoom(to newScale: CGFloat, around anchor: CGPoint) {
        let s = min(Self.maxScale, max(Self.minScale, newScale))
        let b = toBoard(anchor)
        scale = s
        pan = CGSize(width: anchor.x - b.x * s, height: anchor.y - b.y * s)
    }
}

/// The canvas surface: board picker chips over a pannable plane of cards.
/// Standalone — reads CanvasStore only; mounted by a later integration commit.
struct CanvasSurface: View {
    @ObservedObject private var store = CanvasStore.shared

    @State private var transform = PlaneTransform()
    @State private var panOrigin: CGSize?
    @State private var zoomOrigin: CGFloat?
    @State private var dragStart: CGPoint?
    @State private var selectedID: UUID?
    @State private var editingID: UUID?
    @State private var draft = ""
    @State private var planeFrame: CGRect = .zero
    @State private var scrollMonitor: Any?
    @FocusState private var editorFocused: Bool
    @FocusState private var planeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            chips
            plane
        }
        .onAppear {
            store.openDefault()
            installScrollMonitor()
        }
        .onDisappear {
            commitEdit()
            store.flush()
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        }
    }

    // MARK: board chips

    private var chips: some View {
        HStack(spacing: 8) {
            ForEach(store.boards) { ref in
                let active = ref.name == store.boardName
                Button {
                    commitEdit()
                    selectedID = nil
                    if !active {
                        store.open(ref.name)
                        transform = PlaneTransform()
                    }
                } label: {
                    Text(ref.name)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay {
                            Capsule().strokeBorder(
                                active ? Color.accentColor.opacity(0.5) : .white.opacity(0.06),
                                lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: plane

    private var plane: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                backdrop
                ForEach(store.cards) { card in
                    cardLayer(card)
                }
                if store.cards.isEmpty {
                    Text("double-click to drop a card.")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: geo.frame(in: .global), initial: true) { _, f in planeFrame = f }
            .simultaneousGesture(magnify(in: geo.size))
        }
        .clipped()
        .focusable()
        .focusEffectDisabled()
        .focused($planeFocused)
        .onDeleteCommand {
            guard editingID == nil, let sel = selectedID else { return }
            store.deleteCard(sel)
            selectedID = nil
        }
    }

    private var backdrop: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(panGesture)
            .onTapGesture(count: 2) { location in
                commitEdit()
                if let id = store.addCard(at: transform.toBoard(location)) {
                    beginEdit(id: id, text: "")
                }
            }
            .onTapGesture {
                commitEdit()
                selectedID = nil
                planeFocused = true
            }
    }

    @ViewBuilder
    private func cardLayer(_ card: CanvasCard) -> some View {
        let pos = transform.toScreen(card.position ?? CGPoint(x: 48, y: 48))
        Group {
            if editingID == card.id {
                editor
            } else {
                CanvasCardView(card: card, selected: selectedID == card.id) {
                    store.deleteCard(card.id)
                }
                .onTapGesture(count: 2) {
                    beginEdit(id: card.id, text: editDraft(for: card))
                }
                .onTapGesture {
                    commitEdit()
                    selectedID = card.id
                    planeFocused = true
                }
                .gesture(cardDrag(card))
            }
        }
        .scaleEffect(transform.scale, anchor: .topLeading)
        .offset(x: pos.x, y: pos.y)
        .zIndex(store.activeDragID == card.id ? 3 : editingID == card.id ? 2 : selectedID == card.id ? 1 : 0)
    }

    // MARK: gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if panOrigin == nil { panOrigin = transform.pan }
                transform.pan = CGSize(width: (panOrigin ?? .zero).width + v.translation.width,
                                       height: (panOrigin ?? .zero).height + v.translation.height)
            }
            .onEnded { _ in panOrigin = nil }
    }

    private func magnify(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if zoomOrigin == nil { zoomOrigin = transform.scale }
                transform.zoom(to: (zoomOrigin ?? 1) * v.magnification,
                               around: CGPoint(x: size.width / 2, y: size.height / 2))
            }
            .onEnded { _ in zoomOrigin = nil }
    }

    private func cardDrag(_ card: CanvasCard) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragStart == nil {
                    dragStart = card.position ?? .zero
                    store.activeDragID = card.id
                    selectedID = card.id
                }
                let start = dragStart ?? .zero
                store.moveCard(card.id, to: CGPoint(x: start.x + v.translation.width / transform.scale,
                                                    y: start.y + v.translation.height / transform.scale))
            }
            .onEnded { _ in
                dragStart = nil
                store.activeDragID = nil
            }
    }

    /// Two-finger scroll pans the plane. A local monitor sidesteps AppKit
    /// hit-testing entirely; events outside the plane pass through untouched.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let view = event.window?.contentView else { return event }
            var p = view.convert(event.locationInWindow, from: nil)
            if !view.isFlipped { p.y = view.bounds.height - p.y }
            guard planeFrame.contains(p) else { return event }
            transform.pan.width += event.scrollingDeltaX
            transform.pan.height += event.scrollingDeltaY
            return nil
        }
    }

    // MARK: editing

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(width: 220, height: 148, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
            }
            .focused($editorFocused)
            .onExitCommand { commitEdit() }
    }

    /// First line of the draft = title, the rest = body.
    private func editDraft(for card: CanvasCard) -> String {
        card.displayBody.isEmpty ? card.title : card.title + "\n" + card.displayBody
    }

    private func beginEdit(id: UUID, text: String) {
        commitEdit()
        editingID = id
        draft = text
        selectedID = id
        store.editingHold = true
        DispatchQueue.main.async { editorFocused = true }
    }

    private func commitEdit() {
        guard let id = editingID else { return }
        editingID = nil
        store.editingHold = false
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            store.deleteCard(id)        // abandoned blank card
            return
        }
        var lines = draft.components(separatedBy: "\n")
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        let title = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let body = lines.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        store.updateCard(id, title: title.isEmpty ? "idea" : title, body: body)
    }
}

/// One card: glass look consistent with Tile, ~220pt wide, body clamped to
/// ~8 lines, hover ✕ to delete.
private struct CanvasCardView: View {
    let card: CanvasCard
    let selected: Bool
    let onDelete: () -> Void

    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(card.title.isEmpty ? "untitled" : card.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(2)
            let body = card.displayBody
            if !body.isEmpty {
                Text(body)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.9))
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let by = card.attribution {
                Text(by.split(separator: ",").first.map(String.init) ?? by)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(width: 220, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : .white.opacity(0.05),
                              lineWidth: selected ? 1 : 0.5)
        }
        .overlay(alignment: .topTrailing) {
            if hover {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(6)
            }
        }
        .onHover { hover = $0 }
        .shadow(color: .black.opacity(selected ? 0.25 : 0.12), radius: selected ? 10 : 5, x: 0, y: 3)
    }
}

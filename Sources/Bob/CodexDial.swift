import SwiftUI

/// A codex session's four settings, in the corner of its own thread: model,
/// reasoning effort, sandbox, approvals (#37 T1.5).
///
/// They are bob's, not codex's config file's — every one rides on the next
/// `turn/start` as an override, so a change lands on the next thing you say
/// with no respawn and no lost context. The label says the two that decide what
/// this session can do to your machine, because those are the ones you want to
/// be able to read without clicking anything.
struct CodexDial: View {
    @ObservedObject var session: CodexSession
    @ObservedObject private var catalog = CodexCatalog.shared

    var body: some View {
        Menu {
            modelSection
            effortSection
            sandboxSection
            approvalSection
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("this session's model, effort, sandbox and approvals")
        // one `model/list` per launch — never from the menu's own closures,
        // which run on every layout pass
        .task { catalog.loadIfNeeded() }
    }

    /// `low · write · asks` — effort, then the two that matter for safety.
    private var label: String {
        [effortWord, sandboxWord, approvalWord].joined(separator: " · ")
    }

    private var effortWord: String { session.config.effort ?? "auto" }

    private var sandboxWord: String {
        switch session.sandboxPolicy {
        case .readOnly: return "read-only"
        case .workspaceWrite: return "write"
        }
    }

    private var approvalWord: String {
        switch session.config.approvalPolicy {
        case .untrusted: return "strict"
        case .onRequest: return "asks"
        case .never: return "no asks"
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Section("model") {
            ForEach(catalog.models) { row in
                check(row.displayName, on: session.config.model == row.id) {
                    session.setModel(row.id)
                }
            }
            check("auto (codex default)", on: session.config.model == nil) {
                session.setModel(nil)
            }
        }
    }

    @ViewBuilder
    private var effortSection: some View {
        let efforts = catalog.efforts(for: session.config.model)
        if !efforts.isEmpty {
            Section("effort") {
                ForEach(efforts, id: \.self) { effort in
                    check(effort, on: session.config.effort == effort) {
                        session.setEffort(effort)
                    }
                }
                check("auto (model's default)", on: session.config.effort == nil) {
                    session.setEffort(nil)
                }
            }
        }
    }

    @ViewBuilder
    private var sandboxSection: some View {
        Section("sandbox") {
            check("write in this project", on: sandboxWord == "write") {
                session.setSandbox(nil)     // nil = writes scoped to this cwd
            }
            check("read-only", on: sandboxWord == "read-only") {
                session.setSandbox(.readOnly)
            }
        }
    }

    @ViewBuilder
    private var approvalSection: some View {
        Section("approvals") {
            check("ask about everything", on: session.config.approvalPolicy == .untrusted) {
                session.setApprovalPolicy(.untrusted)
            }
            check("ask when it needs to", on: session.config.approvalPolicy == .onRequest) {
                session.setApprovalPolicy(.onRequest)
            }
            check("never ask", on: session.config.approvalPolicy == .never) {
                session.setApprovalPolicy(.never)
            }
        }
    }

    private func check(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

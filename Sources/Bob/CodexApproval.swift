import Foundation

/// Turning one of codex's approval requests into the ask-first card bob already
/// draws for claude.
///
/// The buttons come from the request's own `availableDecisions`, verbatim.
/// That field is on the wire and *absent from 0.149.0's generated schema*, so a
/// schema-derived decoder drops it silently — and the live exec approval offered
/// `accept` / `acceptWithExecpolicyAmendment` / `cancel`, with no `decline`,
/// while `decline` is in the schema's enum. A hardcoded button set would have
/// offered a decision that wasn't on the table and hidden one that was.
///
/// The *shape of the answer* is a different question, and it comes from the
/// response schema rather than from the decision list: exec and fileChange
/// answer `{"decision": …}` (a string, or a one-key object carrying an
/// amendment), while `item/permissions/requestApproval` answers
/// `{"permissions": …, "scope": …}` — a grant, not a decision. So a permissions
/// ask gets grant-shaped buttons even if it advertises decisions; anything else
/// carries the wire's own decisions through untouched.
enum CodexApproval {
    /// The three bob can draw a card for. `item/tool/requestUserInput` answers
    /// a map of question ids to answers — there is no button to render for it,
    /// so it stays a visible notice until phase 2.
    static let approvalMethods: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
    ]

    /// nil when there's nothing honest to draw — the card is never a guess.
    static func ask(_ request: CodexServerRequest,
                    sessionId: UUID, sessionName: String) -> PermissionRequest? {
        guard approvalMethods.contains(request.method) else { return nil }
        let params = params(of: request.line)
        let choices = request.method == "item/permissions/requestApproval"
            ? grants(params)
            : (decisions(params) ?? fallbackDecisions())
        guard !choices.isEmpty else { return nil }
        return PermissionRequest(
            requestId: key(request.id),
            sessionId: sessionId,
            sessionName: sessionName,
            toolName: title(request.method),
            input: nil,
            detail: detail(request.method, params: params),
            symbol: symbol(request.method),
            choices: choices
        )
    }

    /// The card's identity for a server-initiated id. app-server numbers these
    /// out of its own space, so the string is only ever a key — the reply
    /// echoes `CodexRequestId` itself.
    static func key(_ id: CodexRequestId) -> String {
        switch id {
        case .int(let n): return "\(n)"
        case .text(let s): return s
        }
    }

    // MARK: - decisions

    private static func decisions(_ params: [String: Any]) -> [PermissionChoice]? {
        guard let raw = params["availableDecisions"] as? [Any], !raw.isEmpty else { return nil }
        let choices = raw.compactMap(choice(from:))
        return choices.isEmpty ? nil : choices
    }

    /// A decision is either a bare string or a one-key object whose payload
    /// (an execpolicy or network amendment) has to travel back exactly as it
    /// arrived — so the whole value is kept, not just its name.
    private static func choice(from raw: Any) -> PermissionChoice? {
        if let name = raw as? String {
            return PermissionChoice(id: name, label: label(name), tone: tone(name),
                                    hint: hint(name), result: ["decision": name])
        }
        if let object = raw as? [String: Any], let name = object.keys.first, object.count == 1 {
            return PermissionChoice(id: name, label: label(name), tone: tone(name),
                                    hint: hint(name), result: ["decision": object])
        }
        return nil
    }

    /// Only for a request that carried no `availableDecisions` at all. Drawn
    /// from the response schema's own enum (accept / acceptForSession / decline
    /// / cancel), narrowed to the three that mean something distinct.
    private static func fallbackDecisions() -> [PermissionChoice] {
        ["accept", "decline", "cancel"].compactMap(choice(from:))
    }

    /// `item/permissions/requestApproval` asks for a permission profile and its
    /// answer *is* a profile: granting means handing the requested one back,
    /// denying means handing back an empty one. Scope is codex's own enum
    /// (`turn` / `session`), which is what makes "always" mean this session.
    private static func grants(_ params: [String: Any]) -> [PermissionChoice] {
        let requested = params["permissions"] as? [String: Any] ?? [:]
        return [
            PermissionChoice(id: "grant", label: "allow", tone: .affirm,
                             hint: "just this turn",
                             result: ["permissions": requested, "scope": "turn"]),
            PermissionChoice(id: "grantSession", label: "allow session", tone: .affirm,
                             hint: "for the rest of this session",
                             result: ["permissions": requested, "scope": "session"]),
            PermissionChoice(id: "denyGrant", label: "deny", tone: .neutral,
                             hint: "grant nothing — codex keeps going without it",
                             result: ["permissions": [:] as [String: Any]]),
        ]
    }

    private static func label(_ decision: String) -> String {
        switch decision {
        case "accept": return "allow"
        case "acceptForSession": return "allow session"
        case "acceptWithExecpolicyAmendment": return "allow always"
        case "applyNetworkPolicyAmendment": return "allow host"
        case "decline": return "deny"
        case "cancel": return "stop"
        default: return spaced(decision)
        }
    }

    /// `decline` and `cancel` are not the same answer and must never wear the
    /// same word: one lets the turn carry on knowing it was refused, the other
    /// ends the turn on the spot.
    private static func hint(_ decision: String) -> String? {
        switch decision {
        case "accept": return "run it, once"
        case "acceptForSession": return "and stop asking for the rest of this session"
        case "acceptWithExecpolicyAmendment": return "and remember this command in codex's policy"
        case "applyNetworkPolicyAmendment": return "and remember this host in codex's policy"
        case "decline": return "no — the turn carries on without it"
        case "cancel": return "no — and stop the turn"
        default: return nil
        }
    }

    private static func tone(_ decision: String) -> PermissionChoice.Tone {
        if decision == "cancel" { return .stop }
        if decision.hasPrefix("accept") || decision.hasPrefix("apply") { return .affirm }
        return .neutral
    }

    /// "acceptWithExecpolicyAmendment" → "accept with execpolicy amendment", so
    /// a decision nobody has seen yet still reads as words on a button.
    private static func spaced(_ raw: String) -> String {
        var out = ""
        for character in raw {
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(Character(character.lowercased()))
        }
        return out
    }

    // MARK: - what the card says

    private static func title(_ method: String) -> String {
        switch method {
        case "item/commandExecution/requestApproval": return "run a command"
        case "item/fileChange/requestApproval": return "change files"
        case "item/permissions/requestApproval": return "extra permissions"
        default: return method
        }
    }

    private static func symbol(_ method: String) -> String {
        switch method {
        case "item/commandExecution/requestApproval": return "terminal"
        case "item/fileChange/requestApproval": return "square.and.pencil"
        default: return "shield.lefthalf.filled"
        }
    }

    /// The one line the owner decides on. Same rule as claude's card: the
    /// argument that matters, whole, first line only.
    private static func detail(_ method: String, params: [String: Any]) -> String {
        let reason = (params["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case "item/commandExecution/requestApproval":
            let command = firstLine(params["command"] as? String) ?? "a command"
            guard let reason, !reason.isEmpty else { return command }
            return "\(command) — \(reason)"
        case "item/fileChange/requestApproval":
            if let root = params["grantRoot"] as? String, !root.isEmpty {
                return "write under \(abbreviate(root))"
            }
            return reason?.isEmpty == false ? reason! : "apply the pending file changes"
        case "item/permissions/requestApproval":
            let asked = profileWords(params["permissions"] as? [String: Any] ?? [:])
            guard let reason, !reason.isEmpty else { return asked }
            return "\(asked) — \(reason)"
        default:
            return method
        }
    }

    /// The requested profile in words: what it would actually let codex do.
    private static func profileWords(_ profile: [String: Any]) -> String {
        var parts: [String] = []
        if let network = profile["network"] as? [String: Any],
           (network["enabled"] as? Bool) == true {
            parts.append("network access")
        }
        let fs = profile["fileSystem"] as? [String: Any] ?? [:]
        var paths: [String] = []
        for entry in fs["entries"] as? [[String: Any]] ?? [] {
            if let path = entry["path"] as? String { paths.append(abbreviate(path)) }
        }
        paths += (fs["write"] as? [String] ?? []).map(abbreviate)
        paths += (fs["read"] as? [String] ?? []).map(abbreviate)
        if !paths.isEmpty { parts.append(paths.prefix(3).joined(separator: ", ")) }
        return parts.isEmpty ? "permissions beyond this session's sandbox"
                             : parts.joined(separator: " + ")
    }

    private static func firstLine(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let line = raw.split(separator: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? raw
        return String(line.trimmingCharacters(in: .whitespaces).prefix(240))
    }

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func params(of line: String) -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return object["params"] as? [String: Any] ?? [:]
    }
}

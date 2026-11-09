import Foundation

/// A Go style rule og checks itself, with the guide section that explains it.
public struct GoStyleRule: Sendable, Hashable {
    /// Stable id, used as the diagnostic `code` (`og/getter`, ...).
    public var id: String
    /// Link title shown in the hover card.
    public var guide: String
    public var url: String
}

public enum GoStyleRules {
    public static let getter = GoStyleRule(
        id: "og/getter", guide: "Effective Go: Getters", url: "https://go.dev/doc/effective_go#Getters")
    public static let stutter = GoStyleRule(
        id: "og/stutter", guide: "Google Go Style: Package vs. exported symbol name",
        url: "https://google.github.io/styleguide/go/decisions#package-vs-exported-symbol-name")
    public static let errorVarName = GoStyleRule(
        id: "og/error-var-name", guide: "Go wiki: Errors — Naming", url: "https://go.dev/wiki/Errors#naming")
    public static let errorTypeName = GoStyleRule(
        id: "og/error-type-name", guide: "Go wiki: Errors — Naming", url: "https://go.dev/wiki/Errors#naming")
    public static let interfaceName = GoStyleRule(
        id: "og/interface-name", guide: "Effective Go: Interface names", url: "https://go.dev/doc/effective_go#interface-names")
    public static let contextFirst = GoStyleRule(
        id: "og/context-first", guide: "Google Go Style: Contexts", url: "https://google.github.io/styleguide/go/decisions#contexts")
    public static let elseAfterReturn = GoStyleRule(
        id: "og/else-after-return", guide: "Effective Go: If", url: "https://go.dev/doc/effective_go#if")
    public static let docComment = GoStyleRule(
        id: "og/doc-comment", guide: "Google Go Style: Doc comments", url: "https://google.github.io/styleguide/go/decisions#doc-comments")
    public static let receiverName = GoStyleRule(
        id: "og/receiver-name", guide: "Google Go Style: Receiver names", url: "https://google.github.io/styleguide/go/decisions#receiver-names")

    public static let all: [GoStyleRule] = [
        getter, stutter, errorVarName, errorTypeName, interfaceName, contextFirst, elseAfterReturn, docComment, receiverName
    ]

    public static func rule(id: String) -> GoStyleRule? { all.first { $0.id == id } }
}

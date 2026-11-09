import Foundation

extension Notification.Name {
    /// object: ProjectContext. userInfo["uri"]: String
    static let ogDiagnosticsChanged = Notification.Name("og.diagnosticsChanged")
    /// object: ProjectContext. userInfo["url"]: URL
    static let ogDocumentSaved = Notification.Name("og.documentSaved")
    /// object: ProjectContext
    static let ogGitStatusChanged = Notification.Name("og.gitStatusChanged")
    /// object: ProjectContext. userInfo["paths"]: [String] (absolute)
    static let ogFilesChanged = Notification.Name("og.filesChanged")
    /// object: ProjectContext
    static let ogBreakpointsChanged = Notification.Name("og.breakpointsChanged")
    /// object: ProjectContext. Debugger stop location changed (see ProjectContext.debugStop)
    static let ogDebugStopChanged = Notification.Name("og.debugStopChanged")
    /// object: ProjectContext
    static let ogGoplsStatusChanged = Notification.Name("og.goplsStatusChanged")
}

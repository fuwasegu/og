import AppKit
import OgCore

// STUB — owned by the Search agent. Keep these entry points.
@MainActor
enum GotoFilePalette {
    /// Cmd-Shift-O: fuzzy file search over context.index; opens the chosen file.
    static func showFiles(in context: ProjectContext) {}
    /// Cmd-Alt-O: workspace symbol search via context.gopls.workspaceSymbols.
    static func showSymbols(in context: ProjectContext) {}
    /// Cmd-E: recent files.
    static func showRecent(in context: ProjectContext, recent: [URL]) {}
}

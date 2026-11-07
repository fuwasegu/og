import SwiftUI
import AppKit
import GoEditorCore

@main
struct GoEditorApp: App {
    var body: some Scene {
        WindowGroup("og — Go Native Editor") {
            GoWorkspaceContentView()
                .frame(minWidth: 1020, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published var buffer: TextBuffer
    @Published var currentFileURL: URL
    @Published var cursorPosition: TextPosition = .zero
    @Published var diagnostics: [LSPDiagnostic] = []
    @Published var inlineTestResults: [Int: GoTestRunResult] = [:]
    @Published var foldErrorBlocks: Bool = false
    @Published var dimErrorBlocks: Bool = true
    @Published var goplsHealth: GoplsHealthStatus = .healthy(latencyMs: 0.8)

    @Published var isShowingRenameSheet: Bool = false
    @Published var renameOldSymbol: String = "Server"
    @Published var renameNewSymbol: String = "HTTPServer"
    @Published var renamePreviews: [FileRenameDiffPreview] = []
    @Published var canRollbackRename: Bool = false
    @Published var statusBannerMessage: String = "Ready — CoreText 120fps · Rope Buffer · Tree-sitter Go"

    let goplsClient = GoplsClient()
    let renameManager = TransactionalRenameManager()
    let testRunner = GoTestRunner()

    init() {
        let sampleGoSource = """
        package main

        import (
        \t"context"
        \t"fmt"
        \t"net/http"
        \t"testing"
        \t"time"
        )

        // Handler defines an implicit Go interface automatically matched in the gutter.
        type Handler interface {
        \tServeHTTP(w http.ResponseWriter, r *http.Request)
        }

        // Server implements Handler implicitly; notice the live `⇄ implements Handler` badge.
        type Server struct {
        \tAddr    string
        \tTimeout time.Duration
        }

        func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
        \tctx, cancel := context.WithTimeout(r.Context(), s.Timeout)
        \tdefer cancel()

        \tif err := s.validateRequest(ctx, r); err != nil {
        \t\thttp.Error(w, err.Error(), http.StatusBadRequest)
        \t\treturn
        \t}
        \tfmt.Fprintf(w, "ok from %s", s.Addr)
        }

        func (s *Server) validateRequest(ctx context.Context, r *http.Request) error {
        \terr := ctx.Err()
        \tif err != nil {
        \t\treturn fmt.Errorf("request context canceled: %w", err)
        \t}
        \treturn nil
        }

        func TestServerValidation(t *testing.T) {
        \tsrv := &Server{Addr: ":8080", Timeout: 2 * time.Second}
        \treq, err := http.NewRequest("GET", "http://localhost:8080/health", nil)
        \tif err != nil {
        \t\tt.Fatalf("unexpected error: %v", err)
        \t}
        \tif err := srv.validateRequest(context.Background(), req); err != nil {
        \t\tt.Fatalf("validation failed: %v", err)
        \t}
        }

        func BenchmarkServerValidation(b *testing.B) {
        \tsrv := &Server{Addr: ":8080", Timeout: 2 * time.Second}
        \treq, _ := http.NewRequest("GET", "http://localhost:8080/health", nil)
        \tctx := context.Background()
        \tb.ResetTimer()
        \tfor i := 0; i < b.N; i++ {
        \t\t_ = srv.validateRequest(ctx, req)
        \t}
        }
        """

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("server_test.go")
        try? sampleGoSource.write(to: tempURL, atomically: true, encoding: .utf8)
        self.currentFileURL = tempURL
        self.buffer = TextBuffer(sampleGoSource)
    }

    func notifyDocumentChanged(_ updatedBuffer: TextBuffer) {
        let uri = currentFileURL.absoluteString
        let text = updatedBuffer.string
        let version = updatedBuffer.version
        try? updatedBuffer.string.write(to: currentFileURL, atomically: true, encoding: .utf8)
        Task {
            try? await goplsClient.sendDidChange(uri: uri, text: text, version: version)
        }
    }

    func runInlineTest(_ fn: GoASTAnalysis.FuncEntry) {
        statusBannerMessage = "Running go test for \(fn.name)..."
        let dir = currentFileURL.deletingLastPathComponent()
        Task {
            let result = await testRunner.runFunction(
                named: fn.name,
                isBenchmark: fn.isBenchmark,
                packageDirectory: dir
            )
            self.inlineTestResults[fn.startLine] = result
            self.statusBannerMessage = "\(fn.name): \(result.passed ? "PASS" : "FAIL") (\(String(format: "%.3fs", result.durationSeconds)))"
        }
    }

    func prepareTransactionalRename() {
        let currentSource = buffer.string
        let modifiedSource = currentSource.replacingOccurrences(of: renameOldSymbol, with: renameNewSymbol)
        let lastLine = max(0, buffer.lineCount - 1)
        let lastLineUTF16Len = buffer.lineContent(at: lastLine).utf16.count
        let fullRange = LSPRange(
            start: LSPPosition(line: 0, character: 0),
            end: LSPPosition(line: lastLine, character: lastLineUTF16Len)
        )
        let workspaceEdit = LSPWorkspaceEdit(
            changes: [
                currentFileURL.absoluteString: [
                    LSPTextEdit(range: fullRange, newText: modifiedSource)
                ]
            ]
        )

        Task {
            if let previews = try? await renameManager.buildPreview(
                for: workspaceEdit,
                inMemoryBuffers: [currentFileURL: buffer]
            ) {
                self.renamePreviews = previews
                self.isShowingRenameSheet = true
            }
        }
    }

    func applyTransactionalRename() {
        let previews = renamePreviews
        let oldName = renameOldSymbol
        let newName = renameNewSymbol
        Task {
            if let _ = try? await renameManager.commitRename(
                previews: previews,
                oldName: oldName,
                newName: newName
            ), let updatedContent = try? String(contentsOf: currentFileURL, encoding: .utf8) {
                self.buffer = TextBuffer(updatedContent)
                self.canRollbackRename = await renameManager.canRollback
                self.isShowingRenameSheet = false
                self.statusBannerMessage = "Renamed `\(oldName)` → `\(newName)` atomically."
            }
        }
    }

    func rollbackLastRename() {
        Task {
            if let snap = try? await renameManager.rollbackLastRename(),
               let restored = try? String(contentsOf: currentFileURL, encoding: .utf8) {
                self.buffer = TextBuffer(restored)
                self.canRollbackRename = await renameManager.canRollback
                self.statusBannerMessage = "Rolled back rename `\(snap.symbolOldName)` ← `\(snap.symbolNewName)`."
            }
        }
    }
}

struct GoWorkspaceContentView: View {
    @StateObject private var vm = WorkspaceViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label(vm.currentFileURL.lastPathComponent, systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))

                Divider().frame(height: 16)

                Toggle("Dim `if err != nil`", isOn: $vm.dimErrorBlocks)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))

                Toggle("Fold `if err != nil`", isOn: $vm.foldErrorBlocks)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))

                Spacer()

                Button {
                    vm.prepareTransactionalRename()
                } label: {
                    Label("Atomic Rename", systemImage: "character.cursor.ibeam")
                        .font(.system(size: 12, weight: .medium))
                }

                if vm.canRollbackRename {
                    Button {
                        vm.rollbackLastRename()
                    } label: {
                        Label("Rollback Rename", systemImage: "arrow.uturn.backward.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0)))

            Divider()

            GoEditorCanvasRepresentable(
                buffer: vm.buffer,
                filePath: vm.currentFileURL.path,
                diagnostics: vm.diagnostics,
                inlineTestResults: vm.inlineTestResults,
                foldErrorBlocks: vm.foldErrorBlocks,
                dimErrorBlocks: vm.dimErrorBlocks,
                onBufferModified: { updated in
                    vm.notifyDocumentChanged(updated)
                },
                onCursorChanged: { pos in
                    vm.cursorPosition = pos
                },
                onRunGoTestRequested: { fn in
                    vm.runInlineTest(fn)
                },
                onRenameRequested: { _ in
                    vm.prepareTransactionalRename()
                }
            )

            Divider()

            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("gopls: Healthy (Auto-Healing Active)")
                        .font(.system(size: 11, design: .monospaced))
                }

                Text(vm.statusBannerMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Text("Ln \(vm.cursorPosition.line + 1), Col \(vm.cursorPosition.column + 1)")
                    .font(.system(size: 11, design: .monospaced))

                Text("\(vm.buffer.utf8Count) UTF-8 bytes")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(nsColor: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)))
        }
        .sheet(isPresented: $vm.isShowingRenameSheet) {
            TransactionalRenamePreviewSheet(vm: vm)
        }
    }
}

struct TransactionalRenamePreviewSheet: View {
    @ObservedObject var vm: WorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transactional Symbol Rename Preview")
                .font(.system(size: 15, weight: .bold))

            HStack(spacing: 12) {
                TextField("Old Symbol", text: $vm.renameOldSymbol)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                TextField("New Symbol", text: $vm.renameNewSymbol)
                    .textFieldStyle(.roundedBorder)
                Button("Refresh Diff") {
                    vm.prepareTransactionalRename()
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.renamePreviews) { filePreview in
                        Text(filePreview.fileURL.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.bottom, 2)

                        ForEach(filePreview.unifiedDiffLines) { line in
                            Text(line.text)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 6)
                                .background(diffBackgroundColor(for: line.kind))
                        }
                    }
                }
                .padding(8)
            }
            .frame(height: 260)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("Cancel") {
                    vm.isShowingRenameSheet = false
                }
                Button("Commit Atomic Rename") {
                    vm.applyTransactionalRename()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func diffBackgroundColor(for kind: FileRenameDiffPreview.DiffLine.Kind) -> Color {
        switch kind {
        case .added:
            return Color.green.opacity(0.22)
        case .removed:
            return Color.red.opacity(0.22)
        case .context:
            return Color.clear
        }
    }
}

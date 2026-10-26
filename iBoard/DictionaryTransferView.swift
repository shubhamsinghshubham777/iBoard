import SwiftUI
import UniformTypeIdentifiers
import IBoardCore

struct DictionaryTransferView: View {
    let store: DictionaryStore
    @State private var importing = false
    @State private var exporting = false
    @State private var exportData: DictionaryDocument?
    @State private var staged: (data: Data, summary: DictionaryFileSummary)?
    @State private var replace = false
    @State private var message: String?
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Import") {
                Button("Choose a .iboarddict file", systemImage: "square.and.arrow.down") { importing = true }
                if let staged {
                    LabeledContent("Words", value: "\(staged.summary.entries.count)")
                    LabeledContent("Phrases", value: "\(staged.summary.phraseCount)")
                    if staged.summary.rejectedLines > 0 { LabeledContent("Skipped lines", value: "\(staged.summary.rejectedLines)") }
                    Toggle("Replace my dictionary", isOn: $replace)
                    Button("Queue import for the keyboard") { queueImport(staged.data) }
                }
                Text("The file is checked here and merged by the keyboard the next time it opens. Words you forgot stay forgotten.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Export") {
                Button("Export shared snapshot", systemImage: "square.and.arrow.up", action: prepareExport)
                Text("Exports the snapshot the keyboard shared with this app (needs Full Access). The file is plain text and contains your words; keep it private.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("Erase personal dictionary", role: .destructive) { confirmClear = true }
            } footer: { Text("Queues a request; the keyboard erases what it learned the next time it opens.") }
            if let message { Section { Text(message) } }
        }
        .navigationTitle("Import and export")
        .fileImporter(isPresented: $importing, allowedContentTypes: DictionaryFileType.importTypes) { result in
            handleImport(result)
        }
        .fileExporter(isPresented: $exporting, document: exportData, contentType: DictionaryFileType.type,
                      defaultFilename: "iBoard-dictionary") { result in
            if case .failure = result { message = "Export failed." } else { message = "Exported." }
        }
        .confirmationDialog("Erase everything iBoard learned?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Erase", role: .destructive) { message = store.send(.clearPersonalData) ? "Erase queued." : "Could not queue the request." }
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { message = "Import cancelled."; return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= ImportPayloadStore.maxBytes,
              let data = try? Data(contentsOf: url) else { message = "The file is too large or could not be read."; return }
        switch DictionaryFileReader.summarize(data) {
        case let .success(s): staged = (data, s); message = nil
        case let .failure(e): staged = nil; message = e.message
        }
    }

    private func queueImport(_ data: Data) {
        switch store.queueImport(data, replaceExisting: replace) {
        case .success: message = "Import queued. The keyboard applies it next time it opens."; staged = nil
        case .failure(.tooLarge): message = "The file is too large."
        case .failure(.empty): message = "The file is empty."
        case .failure(.io): message = "Could not hand the file to the keyboard."
        }
    }

    private func prepareExport() {
        guard let url = SharedFiles.snapshotURL, let data = try? Data(contentsOf: url) else {
            message = "No snapshot to export. The keyboard has not shared one (Full Access is off or unused)."
            return
        }
        exportData = DictionaryDocument(data: data)
        exporting = true
    }
}

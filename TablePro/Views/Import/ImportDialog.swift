//
//  ImportDialog.swift
//  TablePro
//
//  Main import dialog for importing SQL files.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Main import dialog view
struct ImportDialog: View {
    @Binding var isPresented: Bool
    let connection: DatabaseConnection
    let initialFileURL: URL?

    // MARK: - State

    @State private var fileURL: URL?
    @State private var filePreview: String = ""
    @State private var fileSize: Int64 = 0
    @State private var statementCount: Int = 0
    @State private var isCountingStatements = false
    @State private var config = ImportConfiguration()
    @State private var selectedEncoding: ImportEncoding = .utf8
    @State private var showProgressDialog = false
    @State private var showSuccessDialog = false
    @State private var showErrorDialog = false
    @State private var importResult: ImportResult?
    @State private var importError: ImportError?

    // Track temp files for cleanup
    @State private var tempPreviewURL: URL?
    @State private var tempCountURL: URL?

    // Track active tasks for cancellation
    @State private var loadFileTask: Task<Void, Never>?

    // MARK: - Import Service

    @StateObject private var importServiceState = ImportServiceState()

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Content
            VStack(spacing: 16) {
                // File info
                fileInfoView

                Divider()

                // Preview
                filePreviewView

                // Options
                importOptionsView
            }
            .padding(16)
            .frame(width: 600, height: 550)

            Divider()

            // Footer
            footerView
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Load initial file if provided
            if let initialURL = initialFileURL, fileURL == nil {
                await loadFile(initialURL)
            }
        }
        .onExitCommand {
            if !importServiceState.isImporting {
                isPresented = false
            }
        }
        .onDisappear {
            // Cancel any in-progress file loading when dialog is dismissed
            loadFileTask?.cancel()
            // Clean up temp files when dialog is dismissed
            cleanupTempFiles()
        }
        .sheet(isPresented: $showProgressDialog) {
            ImportProgressView(
                currentStatement: importServiceState.currentStatement,
                statementIndex: importServiceState.currentStatementIndex,
                totalStatements: importServiceState.totalStatements,
                statusMessage: importServiceState.statusMessage
            )                {
                importServiceState.service?.cancelImport()
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showSuccessDialog) {
            ImportSuccessView(
                result: importResult
            )                {
                showSuccessDialog = false
                isPresented = false
                // Refresh schema
                NotificationCenter.default.post(name: .refreshData, object: nil)
            }
        }
        .sheet(isPresented: $showErrorDialog) {
            ImportErrorView(
                error: importError
            )                {
                showErrorDialog = false
            }
        }
    }

    // MARK: - View Components

    private var fileSelectionView: some View {
        Button(fileURL == nil ? "Select SQL File..." : "Change File") {
            selectFile()
        }
        .buttonStyle(.borderedProminent)
    }

    private var fileInfoView: some View {
        HStack(alignment: .top, spacing: 12) {
            // File icon
            Image(systemName: "doc.text.fill")
                .font(.system(size: 32))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(fileURL?.lastPathComponent ?? "")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    Button("Change File...") {
                        selectFile()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }

                HStack(spacing: 16) {
                    Label(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file), systemImage: "chart.bar.doc.horizontal")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    if isCountingStatements {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Counting...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    } else if statementCount > 0 {
                        Label("\(statementCount) statements", systemImage: "list.bullet")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filePreviewView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            SQLCodePreview(text: filePreview)
                .frame(height: 280)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }

    private var importOptionsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Options")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 12) {
                // Encoding picker
                HStack(spacing: 8) {
                    Text("Encoding:")
                        .font(.system(size: 13))
                        .frame(width: 80, alignment: .leading)

                    Picker("", selection: $selectedEncoding) {
                        ForEach(ImportEncoding.allCases) { enc in
                            Text(enc.rawValue).tag(enc)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .onChange(of: selectedEncoding) { _, newEncoding in
                        config.encoding = newEncoding.encoding
                        // Cancel previous task to avoid race conditions
                        loadFileTask?.cancel()
                        // Reload preview with new encoding
                        if let url = fileURL {
                            loadFileTask = Task {
                                await loadFile(url)
                            }
                        }
                    }

                    Spacer()
                }

                // Transaction checkbox
                Toggle("Wrap in transaction (BEGIN/COMMIT)", isOn: $config.wrapInTransaction)
                    .font(.system(size: 13))
                    .help("Execute all statements in a single transaction. If any statement fails, all changes are rolled back.")

                // FK checkbox
                Toggle("Disable foreign key checks", isOn: $config.disableForeignKeyChecks)
                    .font(.system(size: 13))
                    .help("Temporarily disable foreign key constraints during import. Useful for importing data with circular dependencies.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerView: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Import") {
                performImport()
            }
            .buttonStyle(.borderedProminent)
            .disabled(fileURL == nil || importServiceState.isImporting)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(16)
    }

    // MARK: - Actions

    private func selectFile() {
        let panel = NSOpenPanel()

        let allowedTypes = ["sql", "gz"].compactMap { UTType(filenameExtension: $0) }
        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        } else {
            // Fallback: restrict by file extensions if UTType lookup fails
            NSLog("ImportDialog.selectFile: UTType lookup for extensions [\"sql\", \"gz\"] returned no results; falling back to deprecated allowedFileTypes.")
            panel.allowedFileTypes = ["sql", "gz"]
        }
        panel.allowsMultipleSelection = false
        panel.message = "Select SQL file to import"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            Task {
                await loadFile(url)
            }
        }
    }

    @MainActor
    private func loadFile(_ url: URL) async {
        // Clean up previous temp files
        cleanupTempFiles()

        // Validate that the URL points to a regular file, not a directory or symlink
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            filePreview = "Error: Selected path is not a regular file"
            return
        }

        fileURL = url

        // Get file size
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = attrs[.size] as? Int64 ?? 0
        } catch {
            print("WARNING: Failed to get file attributes for \(url.path): \(error)")
            fileSize = 0
        }

        // Decompress .gz files before preview
        let urlToRead: URL
        do {
            urlToRead = try await decompressIfNeeded(url)
            // Track temp file if decompression occurred
            if urlToRead != url {
                tempPreviewURL = urlToRead
            }
        } catch {
            filePreview = "Failed to decompress file: \(error.localizedDescription)"
            return
        }

        // Load preview (up to 5MB for preview)
        do {
            let handle = try FileHandle(forReadingFrom: urlToRead)
            defer {
                do {
                    try handle.close()
                } catch {
                    print("WARNING: Failed to close file handle for preview: \(error)")
                }
            }

            // Load up to 5MB for preview (enough for most SQL files)
            let maxPreviewSize = 5 * 1_024 * 1_024 // 5 MB
            let previewData = handle.readData(ofLength: maxPreviewSize)

            if let preview = String(data: previewData, encoding: config.encoding) {
                filePreview = preview
            } else {
                let encodingDescription = String(describing: config.encoding)
                filePreview = """
                Failed to load preview using encoding: \(encodingDescription).
                Try selecting a different text encoding from the encoding picker and reload the preview.
                """
            }
        } catch {
            filePreview = "Failed to load preview: \(error.localizedDescription)"
        }

        // Count statements asynchronously
        Task {
            await countStatements(url: urlToRead)
        }
    }

    @MainActor
    private func countStatements(url: URL) async {
        isCountingStatements = true
        statementCount = 0

        do {
            let parser = SQLFileParser()
            let count = try await parser.countStatements(url: url, encoding: config.encoding)
            statementCount = count
        } catch {
            // If counting fails, use a sentinel value to distinguish from a real 0
            statementCount = -1
        }

        isCountingStatements = false
    }

    private func performImport() {
        guard let url = fileURL else { return }

        let service = ImportService(connection: connection)
        importServiceState.service = service

        showProgressDialog = true

        Task {
            do {
                let result = try await service.importSQL(from: url, config: config)

                await MainActor.run {
                    showProgressDialog = false
                    importResult = result
                    showSuccessDialog = true
                }
            } catch let error as ImportError {
                await MainActor.run {
                    showProgressDialog = false
                    importError = error
                    showErrorDialog = true
                }
            } catch {
                await MainActor.run {
                    showProgressDialog = false
                    importError = ImportError.fileReadFailed(error.localizedDescription)
                    showErrorDialog = true
                }
            }
        }
    }

    /// Clean up temporary decompressed files
    private func cleanupTempFiles() {
        if let tempURL = tempPreviewURL {
            do {
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                print("ImportDialog.cleanupTempFiles: Failed to remove tempPreviewURL at \(tempURL.path): \(error.localizedDescription)")
            }
            tempPreviewURL = nil
        }
        if let tempURL = tempCountURL {
            do {
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                print("ImportDialog.cleanupTempFiles: Failed to remove tempCountURL at \(tempURL.path): \(error.localizedDescription)")
            }
            tempCountURL = nil
        }
    }

    /// Returns filesystem path for URL, using appropriate API for macOS version
    private func fileSystemPath(for url: URL) -> String {
        if #available(macOS 13.0, *) {
            return url.path()
        } else {
            return url.path
        }
    }

    /// Decompress .gz file if needed, returns URL to read
    private func decompressIfNeeded(_ url: URL) async throws -> URL {
        try await FileDecompressor.decompressIfNeeded(url, fileSystemPath: fileSystemPath)
    }
}

// MARK: - Import Service State

@MainActor
final class ImportServiceState: ObservableObject {
    @Published var isImporting: Bool = false
    @Published var currentStatement: String = ""
    @Published var currentStatementIndex: Int = 0
    @Published var totalStatements: Int = 0
    @Published var statusMessage: String = ""

    var service: ImportService? {
        didSet {
            guard let service = service else { return }

            // Bind service properties
            service.$isImporting
                .assign(to: &$isImporting)

            service.$currentStatement
                .assign(to: &$currentStatement)

            service.$currentStatementIndex
                .assign(to: &$currentStatementIndex)

            service.$totalStatements
                .assign(to: &$totalStatements)

            service.$statusMessage
                .assign(to: &$statusMessage)
        }
    }
}

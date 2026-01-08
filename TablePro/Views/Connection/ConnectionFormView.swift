//
//  ConnectionFormView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import SwiftUI
import UniformTypeIdentifiers

/// Form for creating or editing a database connection
struct ConnectionFormView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    // Connection ID: nil = new connection, UUID = edit existing
    let connectionId: UUID?

    private let storage = ConnectionStorage.shared
    @StateObject private var dbManager = DatabaseManager.shared

    // Computed property for isNew
    private var isNew: Bool { connectionId == nil }

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var database: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var type: DatabaseType = .mysql

    // SSH Configuration
    @State private var sshEnabled: Bool = false
    @State private var sshHost: String = ""
    @State private var sshPort: String = "22"
    @State private var sshUsername: String = ""
    @State private var sshPassword: String = ""
    @State private var sshAuthMethod: SSHAuthMethod = .password
    @State private var sshPrivateKeyPath: String = ""
    @State private var keyPassphrase: String = ""
    @State private var sshConfigEntries: [SSHConfigEntry] = []
    @State private var selectedSSHConfigHost: String = ""

    // Color and Tag
    @State private var connectionColor: ConnectionColor = .none
    @State private var selectedTagId: UUID?

    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?

    // Store original connection for editing
    @State private var originalConnection: DatabaseConnection?

    enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Spacer()
                Text(isNew ? "New Connection" : "Edit Connection")
                    .font(.headline)
                Spacer()
            }
            .padding(.top, DesignConstants.Spacing.md)
            .padding(.bottom, 16)

            // Form content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    generalSection
                    appearanceSection
                    connectionSection
                    authSection
                    if type != .sqlite {
                        sshSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 520)
        .ignoresSafeArea()
        .onAppear {
            loadConnectionData()
            loadSSHConfig()
        }
        .onChange(of: type) { _, newType in
            port = String(newType.defaultPort)
        }
    }

    // MARK: - General Section

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                FormField(label: "Name", icon: "tag") {
                    TextField("Connection name", text: $name)
                        .textFieldStyle(.plain)
                }

                FormField(label: "Type", icon: "cylinder.split.1x2") {
                    Picker("", selection: $type) {
                        ForEach(DatabaseType.allCases) { dbType in
                            Label(dbType.rawValue, systemImage: iconForType(dbType))
                                .tag(dbType)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Appearance Section

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                FormField(label: "Color", icon: "paintpalette") {
                    ConnectionColorPicker(selectedColor: $connectionColor)
                }

                FormField(label: "Tag", icon: "tag") {
                    ConnectionTagEditor(selectedTagId: $selectedTagId)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                if type != .sqlite {
                    FormField(label: "Host", icon: "server.rack") {
                        TextField("localhost", text: $host)
                            .textFieldStyle(.plain)
                    }

                    FormField(label: "Port", icon: "number") {
                        TextField(defaultPort, text: $port)
                            .textFieldStyle(.plain)
                    }
                }

                FormField(
                    label: type == .sqlite ? "File Path" : "Database",
                    icon: type == .sqlite ? "doc" : "cylinder"
                ) {
                    HStack {
                        TextField(
                            type == .sqlite ? "/path/to/database.sqlite" : "database_name",
                            text: $database
                        )
                        .textFieldStyle(.plain)

                        if type == .sqlite {
                            Button("Browse...") {
                                browseForFile()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Auth Section

    @ViewBuilder
    private var authSection: some View {
        if type != .sqlite {
            VStack(alignment: .leading, spacing: 12) {
                Text("Authentication")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    FormField(label: "Username", icon: "person") {
                        TextField("root", text: $username)
                            .textFieldStyle(.plain)
                    }

                    FormField(label: "Password", icon: "lock") {
                        SecureField("••••••••", text: $password)
                            .textFieldStyle(.plain)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - SSH Section

    private var sshSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SSH Tunnel")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle("", isOn: $sshEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if sshEnabled {
                VStack(spacing: 12) {
                    // SSH Host - from config or manual
                    if !sshConfigEntries.isEmpty {
                        FormField(label: "SSH Host", icon: "desktopcomputer") {
                            HStack {
                                Picker("", selection: $selectedSSHConfigHost) {
                                    Text("Manual").tag("")
                                    ForEach(sshConfigEntries) { entry in
                                        Text(entry.displayName).tag(entry.host)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                                .onChange(of: selectedSSHConfigHost) { _, newValue in
                                    applySSHConfigEntry(newValue)
                                }

                                Spacer()
                            }
                        }
                    }

                    // Manual SSH Host input
                    if selectedSSHConfigHost.isEmpty || sshConfigEntries.isEmpty {
                        FormField(label: "SSH Host", icon: "desktopcomputer") {
                            TextField("ssh.example.com", text: $sshHost)
                                .textFieldStyle(.plain)
                        }
                    }

                    FormField(label: "SSH Port", icon: "number") {
                        TextField("22", text: $sshPort)
                            .textFieldStyle(.plain)
                    }

                    FormField(label: "SSH User", icon: "person") {
                        TextField("username", text: $sshUsername)
                            .textFieldStyle(.plain)
                    }

                    // Auth method picker
                    FormField(label: "Auth", icon: "key") {
                        HStack {
                            Picker("", selection: $sshAuthMethod) {
                                ForEach(SSHAuthMethod.allCases) { method in
                                    Label(method.rawValue, systemImage: method.iconName)
                                        .tag(method)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()

                            Spacer()
                        }
                    }

                    // Password or Private Key based on auth method
                    if sshAuthMethod == .password {
                        FormField(label: "SSH Pass", icon: "lock.shield") {
                            SecureField("••••••••", text: $sshPassword)
                                .textFieldStyle(.plain)
                        }
                    } else {
                        FormField(label: "Key File", icon: "doc.text") {
                            HStack {
                                TextField("~/.ssh/id_rsa", text: $sshPrivateKeyPath)
                                    .textFieldStyle(.plain)

                                Button("Browse") {
                                    browseForPrivateKey()
                                }
                                .controlSize(.small)
                            }
                        }

                        FormField(label: "Passphrase", icon: "key") {
                            SecureField("(optional)", text: $keyPassphrase)
                                .textFieldStyle(.plain)
                        }
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Error message
            if case .failure(let message) = testResult {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            HStack {
                // Test connection
                Button(action: testConnection) {
                    HStack(spacing: 6) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: testResultIcon)
                                .foregroundStyle(testResultColor)
                        }
                        Text("Test Connection")
                    }
                }
                .disabled(isTesting || !isValid)

                Spacer()

                // Delete button (edit mode only)
                if !isNew {
                    Button("Delete", role: .destructive) {
                        deleteConnection()
                    }
                }

                // Cancel
                Button("Cancel") {
                    dismissWindow(id: "connection-form")
                }
                .keyboardShortcut(.escape)

                // Save
                Button(isNew ? "Create" : "Save") {
                    saveConnection()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers

    private var defaultPort: String {
        switch type {
        case .mysql, .mariadb: return "3306"
        case .postgresql: return "5432"
        case .sqlite: return ""
        }
    }

    private var isValid: Bool {
        let basicValid = !name.isEmpty && (type == .sqlite ? !database.isEmpty : !host.isEmpty)
        if sshEnabled {
            let sshValid = !sshHost.isEmpty && !sshUsername.isEmpty
            let authValid = sshAuthMethod == .password || !sshPrivateKeyPath.isEmpty
            return basicValid && sshValid && authValid
        }
        return basicValid
    }

    private var testResultIcon: String {
        switch testResult {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .none: return "bolt.horizontal"
        }
    }

    private var testResultColor: Color {
        switch testResult {
        case .success: return .green
        case .failure: return .red
        case .none: return .secondary
        }
    }

    private func loadConnectionData() {
        // If editing, load from storage
        if let id = connectionId,
           let existing = storage.loadConnections().first(where: { $0.id == id }) {
            originalConnection = existing
            name = existing.name
            host = existing.host
            port = existing.port > 0 ? String(existing.port) : ""
            database = existing.database
            username = existing.username
            type = existing.type

            // Load SSH configuration
            sshEnabled = existing.sshConfig.enabled
            sshHost = existing.sshConfig.host
            sshPort = String(existing.sshConfig.port)
            sshUsername = existing.sshConfig.username
            sshAuthMethod = existing.sshConfig.authMethod
            sshPrivateKeyPath = existing.sshConfig.privateKeyPath

            // Load color and tag
            connectionColor = existing.color
            selectedTagId = existing.tagId

            // Load passwords from Keychain
            if let savedSSHPassword = storage.loadSSHPassword(for: existing.id) {
                sshPassword = savedSSHPassword
            }
            if let savedPassphrase = storage.loadKeyPassphrase(for: existing.id) {
                keyPassphrase = savedPassphrase
            }
            if let savedPassword = storage.loadPassword(for: existing.id) {
                password = savedPassword
            }
        }
    }

    private func saveConnection() {
        let sshConfig = SSHConfiguration(
            enabled: sshEnabled,
            host: sshHost,
            port: Int(sshPort) ?? 22,
            username: sshUsername,
            authMethod: sshAuthMethod,
            privateKeyPath: sshPrivateKeyPath,
            useSSHConfig: !selectedSSHConfigHost.isEmpty
        )

        let connectionToSave = DatabaseConnection(
            id: connectionId ?? UUID(),
            name: name,
            host: host,
            port: Int(port) ?? 0,
            database: database,
            username: username,
            type: type,
            sshConfig: sshConfig,
            color: connectionColor,
            tagId: selectedTagId
        )

        // Save passwords to Keychain
        if !password.isEmpty {
            storage.savePassword(password, for: connectionToSave.id)
        }
        if sshEnabled && sshAuthMethod == .password && !sshPassword.isEmpty {
            storage.saveSSHPassword(sshPassword, for: connectionToSave.id)
        }
        if sshEnabled && sshAuthMethod == .privateKey && !keyPassphrase.isEmpty {
            storage.saveKeyPassphrase(keyPassphrase, for: connectionToSave.id)
        }

        // Save to storage
        var savedConnections = storage.loadConnections()
        if isNew {
            savedConnections.append(connectionToSave)
            storage.saveConnections(savedConnections)
            // Close and connect to database
            dismissWindow(id: "connection-form")
            connectToDatabase(connectionToSave)
        } else {
            if let index = savedConnections.firstIndex(where: { $0.id == connectionToSave.id }) {
                savedConnections[index] = connectionToSave
                storage.saveConnections(savedConnections)
            }
            dismissWindow(id: "connection-form")
            NotificationCenter.default.post(name: .connectionUpdated, object: nil)
        }
    }

    private func deleteConnection() {
        guard let id = connectionId else { return }
        var savedConnections = storage.loadConnections()
        savedConnections.removeAll { $0.id == id }
        storage.saveConnections(savedConnections)
        dismissWindow(id: "connection-form")
        NotificationCenter.default.post(name: .connectionUpdated, object: nil)
    }

    private func connectToDatabase(_ connection: DatabaseConnection) {
        openWindow(id: "main")
        dismissWindow(id: "welcome")

        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                print("Failed to connect: \(error)")
            }
        }
    }

    func testConnection() {
        isTesting = true
        testResult = nil

        // Build SSH config
        let sshConfig = SSHConfiguration(
            enabled: sshEnabled,
            host: sshHost,
            port: Int(sshPort) ?? 22,
            username: sshUsername,
            authMethod: sshAuthMethod,
            privateKeyPath: sshPrivateKeyPath,
            useSSHConfig: !selectedSSHConfigHost.isEmpty
        )

        // Build connection from form values
        let testConn = DatabaseConnection(
            name: name,
            host: host,
            port: Int(port) ?? 0,
            database: database,
            username: username,
            type: type,
            sshConfig: sshConfig,
            color: connectionColor,
            tagId: selectedTagId
        )

        Task {
            do {
                // Save passwords temporarily for test
                if !password.isEmpty {
                    ConnectionStorage.shared.savePassword(password, for: testConn.id)
                }
                if sshEnabled && sshAuthMethod == .password && !sshPassword.isEmpty {
                    ConnectionStorage.shared.saveSSHPassword(sshPassword, for: testConn.id)
                }
                if sshEnabled && sshAuthMethod == .privateKey && !keyPassphrase.isEmpty {
                    ConnectionStorage.shared.saveKeyPassphrase(keyPassphrase, for: testConn.id)
                }

                let success = try await DatabaseManager.shared.testConnection(
                    testConn, sshPassword: sshPassword)
                await MainActor.run {
                    isTesting = false
                    testResult = success ? .success : .failure("Connection test failed")
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            database = url.path
        }
    }

    private func browseForPrivateKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.showsHiddenFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            sshPrivateKeyPath = url.path
        }
    }

    private func loadSSHConfig() {
        sshConfigEntries = SSHConfigParser.parse()
    }

    private func applySSHConfigEntry(_ host: String) {
        guard let entry = sshConfigEntries.first(where: { $0.host == host }) else {
            return
        }

        sshHost = entry.hostname ?? entry.host
        if let port = entry.port {
            sshPort = String(port)
        }
        if let user = entry.user {
            sshUsername = user
        }
        if let keyPath = entry.identityFile {
            sshPrivateKeyPath = keyPath
            sshAuthMethod = .privateKey
        }
    }

    private func iconForType(_ type: DatabaseType) -> String {
        type.iconName
    }

    private func colorForType(_ type: DatabaseType) -> Color {
        type.themeColor
    }
}

// MARK: - Form Field Component

struct FormField<Content: View>: View {
    let label: String
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)

            Text(label)
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)

            content()
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let connectionUpdated = Notification.Name("connectionUpdated")
}

#Preview("New Connection") {
    ConnectionFormView(connectionId: nil)
}

#Preview("Edit Connection") {
    ConnectionFormView(connectionId: DatabaseConnection.sampleConnections[0].id)
}

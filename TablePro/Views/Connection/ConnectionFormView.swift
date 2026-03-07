//
//  ConnectionFormView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import os
import SwiftUI
import UniformTypeIdentifiers

/// Form for creating or editing a database connection
struct ConnectionFormView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionFormView")
    @Environment(\.openWindow) private var openWindow

    // Connection ID: nil = new connection, UUID = edit existing
    let connectionId: UUID?

    private let storage = ConnectionStorage.shared
    private let dbManager = DatabaseManager.shared

    // Computed property for isNew
    private var isNew: Bool { connectionId == nil }

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var database: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var type: DatabaseType = .mysql
    @State private var connectionURL: String = ""
    @State private var urlParseError: String?
    @State private var showURLImport = false
    @State private var hasLoadedData = false

    // SSH Configuration
    @State private var sshEnabled: Bool = false
    @State private var sshHost: String = ""
    @State private var sshPort: String = "22"
    @State private var sshUsername: String = ""
    @State private var sshPassword: String = ""
    @State private var sshAuthMethod: SSHAuthMethod = .password
    @State private var sshPrivateKeyPath: String = ""
    @State private var sshAgentSocketOption: SSHAgentSocketOption = .systemDefault
    @State private var customSSHAgentSocketPath: String = ""
    @State private var keyPassphrase: String = ""
    @State private var sshConfigEntries: [SSHConfigEntry] = []
    @State private var selectedSSHConfigHost: String = ""

    // SSL Configuration
    @State private var sslMode: SSLMode = .disabled
    @State private var sslCaCertPath: String = ""
    @State private var sslClientCertPath: String = ""
    @State private var sslClientKeyPath: String = ""

    // Color and Tag
    @State private var connectionColor: ConnectionColor = .none
    @State private var selectedTagId: UUID?
    @State private var selectedGroupId: UUID?

    // Read-only mode
    @State private var isReadOnly: Bool = false

    // AI policy
    @State private var aiPolicy: AIConnectionPolicy?

    // MongoDB-specific settings
    @State private var mongoReadPreference: String = ""
    @State private var mongoWriteConcern: String = ""

    // MSSQL-specific settings
    @State private var mssqlSchema: String = "dbo"

    // Oracle-specific settings
    @State private var oracleServiceName: String = ""

    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?

    // Tab selection
    @State private var selectedTab: FormTab = .general

    // Store original connection for editing
    @State private var originalConnection: DatabaseConnection?

    // MARK: - Enums

    enum TestResult {
        case success
        case failure(String)
    }

    private enum FormTab: String, CaseIterable {
        case general = "General"
        case ssh = "SSH Tunnel"
        case ssl = "SSL/TLS"
        case advanced = "Advanced"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(visibleTabs, id: \.rawValue) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            // Tab form content
            tabForm

            Divider()

            footer
        }
        .frame(width: 480, height: 520)
        .navigationTitle(isNew ? String(localized: "New Connection") : String(localized: "Edit Connection"))
        .onAppear {
            loadConnectionData()
            loadSSHConfig()
        }
        .onChange(of: type) {
            if hasLoadedData {
                port = String(type.defaultPort)
            }
            if type == .sqlite && (selectedTab == .ssh || selectedTab == .ssl) {
                selectedTab = .general
            }
        }
    }

    // MARK: - Tab Picker Helpers

    private var visibleTabs: [FormTab] {
        if type == .sqlite {
            return [.general, .advanced]
        }
        return FormTab.allCases
    }

    private var resolvedSSHAgentSocketPath: String {
        sshAgentSocketOption.resolvedPath(customPath: customSSHAgentSocketPath)
    }

    // MARK: - Tab Form Content

    @ViewBuilder
    private var tabForm: some View {
        switch selectedTab {
        case .general:
            generalForm
        case .ssh:
            sshForm
        case .ssl:
            sslForm
        case .advanced:
            advancedForm
        }
    }

    // MARK: - General Tab

    private var generalForm: some View {
        Form {
            Section {
                Picker(String(localized: "Type"), selection: $type) {
                    ForEach(DatabaseType.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                TextField(
                    String(localized: "Name"),
                    text: $name,
                    prompt: Text("Connection name")
                )
                Button {
                    showURLImport = true
                } label: {
                    Label(String(localized: "Import from URL"), systemImage: "link")
                }
            }

            if type == .sqlite {
                Section(String(localized: "Database File")) {
                    HStack {
                        TextField(
                            String(localized: "File Path"),
                            text: $database,
                            prompt: Text("/path/to/database.sqlite")
                        )
                        Button(String(localized: "Browse...")) { browseForFile() }
                            .controlSize(.small)
                    }
                }
            } else {
                Section(String(localized: "Connection")) {
                    TextField(
                        String(localized: "Host"),
                        text: $host,
                        prompt: Text("localhost")
                    )
                    TextField(
                        String(localized: "Port"),
                        text: $port,
                        prompt: Text(defaultPort)
                    )
                    if type != .redis {
                        TextField(
                            String(localized: "Database"),
                            text: $database,
                            prompt: Text("database_name")
                        )
                    }
                }
                Section(String(localized: "Authentication")) {
                    if type != .redis {
                        TextField(
                            String(localized: "Username"),
                            text: $username,
                            prompt: Text("root")
                        )
                    }
                    SecureField(
                        String(localized: "Password"),
                        text: $password
                    )
                }
            }

            Section(String(localized: "Appearance")) {
                LabeledContent(String(localized: "Color")) {
                    ConnectionColorPicker(selectedColor: $connectionColor)
                }
                LabeledContent(String(localized: "Tag")) {
                    ConnectionTagEditor(selectedTagId: $selectedTagId)
                }
                LabeledContent(String(localized: "Group")) {
                    ConnectionGroupPicker(selectedGroupId: $selectedGroupId)
                }
                Toggle(String(localized: "Read-Only"), isOn: $isReadOnly)
                    .help("Prevent write operations (INSERT, UPDATE, DELETE, DROP, etc.)")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showURLImport) {
            connectionURLImportSheet
        }
    }

    // MARK: - Import from URL Sheet

    private var connectionURLImportSheet: some View {
        VStack(spacing: 16) {
            Text(String(localized: "Import from URL"))
                .font(.headline)

            Text(String(localized: "Paste a connection URL to auto-fill the form fields."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField(
                String(localized: "Connection URL"),
                text: $connectionURL,
                prompt: Text("postgresql://user:password@host:5432/database")
            )
            .textFieldStyle(.roundedBorder)

            if let urlParseError {
                Text(urlParseError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(String(localized: "Cancel")) {
                    showURLImport = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "Import")) {
                    parseConnectionURL()
                    if urlParseError == nil && !connectionURL.isEmpty {
                        connectionURL = ""
                        urlParseError = nil
                        showURLImport = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(connectionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - SSH Tunnel Tab

    private var sshForm: some View {
        Form {
            Section {
                Toggle(String(localized: "Enable SSH Tunnel"), isOn: $sshEnabled)
            }

            if sshEnabled {
                Section(String(localized: "Server")) {
                    if !sshConfigEntries.isEmpty {
                        Picker(String(localized: "Config Host"), selection: $selectedSSHConfigHost) {
                            Text(String(localized: "Manual")).tag("")
                            ForEach(sshConfigEntries) { entry in
                                Text(entry.displayName).tag(entry.host)
                            }
                        }
                        .onChange(of: selectedSSHConfigHost) {
                            applySSHConfigEntry(selectedSSHConfigHost)
                        }
                    }
                    if selectedSSHConfigHost.isEmpty || sshConfigEntries.isEmpty {
                        TextField(
                            String(localized: "SSH Host"),
                            text: $sshHost,
                            prompt: Text("ssh.example.com")
                        )
                    }
                    TextField(
                        String(localized: "SSH Port"),
                        text: $sshPort,
                        prompt: Text("22")
                    )
                    TextField(
                        String(localized: "SSH User"),
                        text: $sshUsername,
                        prompt: Text("username")
                    )
                }
                Section(String(localized: "Authentication")) {
                    Picker(String(localized: "Method"), selection: $sshAuthMethod) {
                        ForEach(SSHAuthMethod.allCases) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    if sshAuthMethod == .password {
                        SecureField(String(localized: "Password"), text: $sshPassword)
                    } else if sshAuthMethod == .sshAgent {
                        Picker("Agent Socket", selection: $sshAgentSocketOption) {
                            ForEach(SSHAgentSocketOption.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        if sshAgentSocketOption == .custom {
                            TextField(
                                "Custom Path",
                                text: $customSSHAgentSocketPath,
                                prompt: Text("/path/to/agent.sock")
                            )
                        }
                        Text("Keys are provided by the SSH agent (e.g. 1Password, ssh-agent).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent(String(localized: "Key File")) {
                            HStack {
                                TextField("", text: $sshPrivateKeyPath, prompt: Text("~/.ssh/id_rsa"))
                                Button(String(localized: "Browse")) { browseForPrivateKey() }
                                    .controlSize(.small)
                            }
                        }
                        SecureField(String(localized: "Passphrase"), text: $keyPassphrase)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - SSL/TLS Tab

    private var sslForm: some View {
        Form {
            Section {
                Picker(String(localized: "SSL Mode"), selection: $sslMode) {
                    ForEach(SSLMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }

            if sslMode != .disabled {
                Section {
                    Text(sslMode.description)
                        .foregroundStyle(.secondary)
                }

                if sslMode == .verifyCa || sslMode == .verifyIdentity {
                    Section(String(localized: "CA Certificate")) {
                        LabeledContent(String(localized: "CA Cert")) {
                            HStack {
                                TextField("", text: $sslCaCertPath, prompt: Text("/path/to/ca-cert.pem"))
                                Button(String(localized: "Browse")) {
                                    browseForCertificate(binding: $sslCaCertPath)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Section(String(localized: "Client Certificates (Optional)")) {
                    LabeledContent(String(localized: "Client Cert")) {
                        HStack {
                            TextField("", text: $sslClientCertPath, prompt: Text(String(localized: "(optional)")))
                            Button(String(localized: "Browse")) {
                                browseForCertificate(binding: $sslClientCertPath)
                            }
                            .controlSize(.small)
                        }
                    }
                    LabeledContent(String(localized: "Client Key")) {
                        HStack {
                            TextField("", text: $sslClientKeyPath, prompt: Text(String(localized: "(optional)")))
                            Button(String(localized: "Browse")) {
                                browseForCertificate(binding: $sslClientKeyPath)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Advanced Tab

    private var advancedForm: some View {
        Form {
            if type == .mongodb {
                Section("MongoDB") {
                    Picker(String(localized: "Read Preference"), selection: $mongoReadPreference) {
                        Text(String(localized: "Default")).tag("")
                        Text("Primary").tag("primary")
                        Text("Primary Preferred").tag("primaryPreferred")
                        Text("Secondary").tag("secondary")
                        Text("Secondary Preferred").tag("secondaryPreferred")
                        Text("Nearest").tag("nearest")
                    }
                    Picker(String(localized: "Write Concern"), selection: $mongoWriteConcern) {
                        Text(String(localized: "Default")).tag("")
                        Text("Majority").tag("majority")
                        Text("1").tag("1")
                        Text("2").tag("2")
                        Text("3").tag("3")
                    }
                }
            }

            if type == .redis {
                Section("Redis") {
                    Stepper(
                        value: Binding(
                            get: { Int(database) ?? 0 },
                            set: { database = String($0) }
                        ),
                        in: 0...15
                    ) {
                        Text(String(localized: "Database Index: \(Int(database) ?? 0)"))
                    }
                }
            }

            if type == .mssql {
                Section("SQL Server") {
                    TextField(String(localized: "Schema"), text: Binding(
                        get: { mssqlSchema },
                        set: { mssqlSchema = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            if type == .oracle {
                Section(String(localized: "Oracle")) {
                    TextField(String(localized: "Service Name"), text: Binding(
                        get: { oracleServiceName },
                        set: { oracleServiceName = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            Section(String(localized: "AI")) {
                Picker(String(localized: "AI Policy"), selection: $aiPolicy) {
                    Text(String(localized: "Use Default"))
                        .tag(AIConnectionPolicy?.none as AIConnectionPolicy?)
                    ForEach(AIConnectionPolicy.allCases) { policy in
                        Text(policy.displayName)
                            .tag(AIConnectionPolicy?.some(policy) as AIConnectionPolicy?)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                    NSApplication.shared.closeWindows(withId: "connection-form")
                }

                // Save
                Button(isNew ? String(localized: "Create") : String(localized: "Save")) {
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
        .onExitCommand {
            NSApplication.shared.closeWindows(withId: "connection-form")
        }
    }

    // MARK: - Helpers

    private var defaultPort: String {
        switch type {
        case .mysql, .mariadb: return "3306"
        case .postgresql: return "5432"
        case .redshift: return "5439"
        case .sqlite: return ""
        case .mongodb: return "27017"
        case .redis: return "6379"
        case .mssql: return "1433"
        case .oracle: return "1521"
        }
    }

    private var isValid: Bool {
        // Host and port can be empty (will use defaults: localhost and default port)
        let basicValid = !name.isEmpty && (type == .sqlite ? !database.isEmpty : true)
        if sshEnabled {
            let sshValid = !sshHost.isEmpty && !sshUsername.isEmpty
            let authValid = sshAuthMethod == .password || sshAuthMethod == .sshAgent || !sshPrivateKeyPath.isEmpty
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
            applySSHAgentSocketPath(existing.sshConfig.agentSocketPath)

            // Load SSL configuration
            sslMode = existing.sslConfig.mode
            sslCaCertPath = existing.sslConfig.caCertificatePath
            sslClientCertPath = existing.sslConfig.clientCertificatePath
            sslClientKeyPath = existing.sslConfig.clientKeyPath

            // Load color and tag
            connectionColor = existing.color
            selectedTagId = existing.tagId
            selectedGroupId = existing.groupId
            isReadOnly = existing.isReadOnly
            aiPolicy = existing.aiPolicy

            // Load MongoDB settings
            mongoReadPreference = existing.mongoReadPreference ?? ""
            mongoWriteConcern = existing.mongoWriteConcern ?? ""

            // Load MSSQL settings
            mssqlSchema = existing.mssqlSchema ?? "dbo"

            // Load Oracle settings
            oracleServiceName = existing.oracleServiceName ?? ""

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
        Task { @MainActor in
            hasLoadedData = true
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
            useSSHConfig: !selectedSSHConfigHost.isEmpty,
            agentSocketPath: resolvedSSHAgentSocketPath
        )

        let sslConfig = SSLConfiguration(
            mode: sslMode,
            caCertificatePath: sslCaCertPath,
            clientCertificatePath: sslClientCertPath,
            clientKeyPath: sslClientKeyPath
        )

        // Apply defaults: localhost for empty host, default port for empty/invalid port, root for empty username
        // MongoDB and SQLite commonly run without authentication, so skip the "root" default
        let finalHost = host.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : host
        let finalPort = Int(port) ?? type.defaultPort
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        let finalUsername = trimmedUsername.isEmpty && type.requiresAuthentication ? "root" : trimmedUsername

        let connectionToSave = DatabaseConnection(
            id: connectionId ?? UUID(),
            name: name,
            host: finalHost,
            port: finalPort,
            database: database,
            username: finalUsername,
            type: type,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: connectionColor,
            tagId: selectedTagId,
            groupId: selectedGroupId,
            isReadOnly: isReadOnly,
            aiPolicy: aiPolicy,
            mongoReadPreference: mongoReadPreference.isEmpty ? nil : mongoReadPreference,
            mongoWriteConcern: mongoWriteConcern.isEmpty ? nil : mongoWriteConcern,
            mssqlSchema: mssqlSchema.isEmpty ? nil : mssqlSchema,
            oracleServiceName: oracleServiceName.isEmpty ? nil : oracleServiceName
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
            NSApplication.shared.closeWindows(withId: "connection-form")
            connectToDatabase(connectionToSave)
        } else {
            if let index = savedConnections.firstIndex(where: { $0.id == connectionToSave.id }) {
                savedConnections[index] = connectionToSave
                storage.saveConnections(savedConnections)
            }
            NSApplication.shared.closeWindows(withId: "connection-form")
            NotificationCenter.default.post(name: .connectionUpdated, object: nil)
        }
    }

    private func deleteConnection() {
        guard let id = connectionId else { return }
        var savedConnections = storage.loadConnections()
        savedConnections.removeAll { $0.id == id }
        storage.saveConnections(savedConnections)
        NSApplication.shared.closeWindows(withId: "connection-form")
        NotificationCenter.default.post(name: .connectionUpdated, object: nil)
    }

    private func connectToDatabase(_ connection: DatabaseConnection) {
        openWindow(id: "main", value: EditorTabPayload(connectionId: connection.id))
        NSApplication.shared.closeWindows(withId: "welcome")

        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                Self.logger.error("Failed to connect: \(error.localizedDescription, privacy: .public)")
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
            useSSHConfig: !selectedSSHConfigHost.isEmpty,
            agentSocketPath: resolvedSSHAgentSocketPath
        )

        let sslConfig = SSLConfiguration(
            mode: sslMode,
            caCertificatePath: sslCaCertPath,
            clientCertificatePath: sslClientCertPath,
            clientKeyPath: sslClientKeyPath
        )

        // Apply defaults: localhost for empty host, default port for empty/invalid port, root for empty username
        // MongoDB and SQLite commonly run without authentication, so skip the "root" default
        let finalHost = host.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : host
        let finalPort = Int(port) ?? type.defaultPort
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        let finalUsername = trimmedUsername.isEmpty && type.requiresAuthentication ? "root" : trimmedUsername

        // Build connection from form values
        let testConn = DatabaseConnection(
            name: name,
            host: finalHost,
            port: finalPort,
            database: database,
            username: finalUsername,
            type: type,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: connectionColor,
            tagId: selectedTagId,
            groupId: selectedGroupId,
            mongoReadPreference: mongoReadPreference.isEmpty ? nil : mongoReadPreference,
            mongoWriteConcern: mongoWriteConcern.isEmpty ? nil : mongoWriteConcern,
            mssqlSchema: mssqlSchema.isEmpty ? nil : mssqlSchema,
            oracleServiceName: oracleServiceName.isEmpty ? nil : oracleServiceName
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
                    testResult = success ? .success : .failure(String(localized: "Connection test failed"))
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

        panel.begin { response in
            if response == .OK, let url = panel.url {
                database = url.path(percentEncoded: false)
            }
        }
    }

    private func browseForPrivateKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                sshPrivateKeyPath = url.path(percentEncoded: false)
            }
        }
    }

    private func browseForCertificate(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.showsHiddenFiles = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                binding.wrappedValue = url.path(percentEncoded: false)
            }
        }
    }

    private func loadSSHConfig() {
        sshConfigEntries = SSHConfigParser.parse()
    }

    private func parseConnectionURL() {
        let trimmed = connectionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            urlParseError = nil
            return
        }

        switch ConnectionURLParser.parse(trimmed) {
        case .success(let parsed):
            urlParseError = nil
            type = parsed.type
            host = parsed.host
            port = parsed.port.map(String.init) ?? String(parsed.type.defaultPort)
            database = parsed.database
            username = parsed.username
            password = parsed.password
            sslMode = parsed.sslMode ?? .disabled
            if let sshHostValue = parsed.sshHost {
                sshEnabled = true
                sshHost = sshHostValue
                sshPort = parsed.sshPort.map(String.init) ?? "22"
                sshUsername = parsed.sshUsername ?? ""
                if parsed.usePrivateKey == true {
                    sshAuthMethod = .privateKey
                }
                if parsed.useSSHAgent == true {
                    sshAuthMethod = .sshAgent
                    applySSHAgentSocketPath(parsed.agentSocket ?? "")
                }
            }
            if let connectionName = parsed.connectionName, !connectionName.isEmpty {
                name = connectionName
            } else if name.isEmpty {
                name = parsed.suggestedName
            }
        case .failure(let error):
            urlParseError = error.localizedDescription
        }
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
        if let agentPath = entry.identityAgent {
            applySSHAgentSocketPath(agentPath)
            sshAuthMethod = .sshAgent
        } else if let keyPath = entry.identityFile {
            sshPrivateKeyPath = keyPath
            sshAuthMethod = .privateKey
        }
    }

    private func applySSHAgentSocketPath(_ socketPath: String) {
        let option = SSHAgentSocketOption(socketPath: socketPath)
        sshAgentSocketOption = option

        if option == .custom {
            customSSHAgentSocketPath = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            customSSHAgentSocketPath = ""
        }
    }
}

#Preview("New Connection") {
    ConnectionFormView(connectionId: nil)
}

#Preview("Edit Connection") {
    ConnectionFormView(connectionId: DatabaseConnection.sampleConnections[0].id)
}

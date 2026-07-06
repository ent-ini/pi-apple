import AppKit
import SwiftUI
import ApplePiCore
import ApplePiRemote

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: PiAppState
    @State private var notificationTestStatus: String?
    @State private var apiTokenInput: String = ""
    @State private var apiTokenStatus: String?
    @State private var groqAPIKeyInput: String = ""
    @State private var groqAPIKeyStatus: String?
    @State private var appearanceClipboardStatus: String?
    @State private var diagnosticsCopyStatus: String?
    @State private var isConfirmingClearAPIToken = false
    @State private var isConfirmingClearGroqAPIKey = false
    @State private var isConfirmingHostCommit = false
    @State private var isConfirmingCopyWithToken = false
    @State private var pendingHostCommit: PiHostConfiguration?
    @State private var editingHost: PiHostConfiguration?

    var body: some View {
        Form {
            appearanceSection
            shortcutsSection
            hostSections
            diagnosticsSection
            piDefaultsSection
            voiceSection
            Section("Notifications") {
                Toggle("Pi session notifications", isOn: notificationBinding(\.isEnabled))

                Text(notificationExtensionHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Presentation", selection: notificationBinding(\.presentation)) {
                    ForEach(TerminalNotificationPresentation.allCases) { presentation in
                        Text(presentation.title).tag(presentation)
                    }
                }
                .disabled(!appState.appearance.notifications.isEnabled)

                Toggle("Show while app is in foreground", isOn: notificationBinding(\.allowsForegroundNotifications))
                    .disabled(!appState.appearance.notifications.isEnabled)

                Button("Test Notification") {
                    Task {
                        let result = await appState.sendTestNotification()
                        notificationTestStatus = notificationStatusText(for: result)
                    }
                }
                .disabled(!appState.appearance.notifications.isEnabled)

                if let notificationTestStatus {
                    Text(notificationTestStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if editingHost == nil { editingHost = appState.host }
            refreshAPITokenStatus()
            refreshGroqAPIKeyStatus()
        }
        .onChange(of: appState.host) { _, newValue in
            if editingHost != newValue {
                editingHost = newValue
            }
            refreshAPITokenStatus()
            refreshGroqAPIKeyStatus()
        }
        .onChange(of: editingHost) { _, _ in
            refreshAPITokenStatus()
            refreshGroqAPIKeyStatus()
        }
        .onDisappear { discardHostEdits() }
        .confirmationDialog(
            "Apply host changes?",
            isPresented: $isConfirmingHostCommit,
            titleVisibility: .visible
        ) {
            Button("Apply and reload catalog", role: .destructive) {
                performHostCommit()
            }
            Button("Cancel", role: .cancel) {
                pendingHostCommit = nil
            }
        } message: {
            Text(hostCommitMessage)
        }
        .confirmationDialog(
            "Clear stored API token?",
            isPresented: $isConfirmingClearAPIToken,
            titleVisibility: .visible
        ) {
            Button("Clear Token", role: .destructive) {
                clearAPIToken()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The stored bearer token for this remote daemon will be deleted. You will need to paste it again before pi-app can authenticate to pi-appd.")
        }
        .confirmationDialog(
            "Clear Groq API key?",
            isPresented: $isConfirmingClearGroqAPIKey,
            titleVisibility: .visible
        ) {
            Button("Clear Key", role: .destructive) {
                clearGroqAPIKey()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The locally stored Groq API key will be deleted. Voice recording will still work, but auto-transcription will stop until you save the key again.")
        }
        .confirmationDialog(
            "Copy curl with token?",
            isPresented: $isConfirmingCopyWithToken,
            titleVisibility: .visible
        ) {
            Button("Copy with token") {
                copyCurlCommand(includeToken: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The curl command will include your stored bearer token in plain text. Anyone with access to your clipboard can read it. Prefer the redacted copy unless you need to run the command right now.")
        }
    }

    // MARK: - Pi defaults section

    @ViewBuilder
    private var piDefaultsSection: some View {
        Section("Pi defaults") {
            Picker("Default model", selection: defaultModelSelectionBinding) {
                Text("Use daemon default").tag("")
                ForEach(appState.cachedAvailableModels) { model in
                    Text(model.displayName).tag(model.id)
                }
            }

            Picker("Default thinking", selection: defaultThinkingSelectionBinding) {
                Text("Use daemon default").tag("")
                ForEach(PiAppState.thinkingLevels, id: \.self) { level in
                    Text(level).tag(level)
                }
            }
            .disabled(appState.defaultModelPreference == nil)

            HStack {
                Button(appState.isLoadingAvailableModels ? "Loading models…" : "Refresh model list") {
                    appState.refreshAvailableModelsCache(force: true)
                }
                .disabled(appState.isLoadingAvailableModels)

                if appState.cachedAvailableModels.isEmpty {
                    Text("No cached models yet. Refresh once to populate the picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(appState.cachedAvailableModels.count) cached")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("New sessions use this model explicitly. Existing sessions keep their current model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var defaultModelSelectionBinding: Binding<String> {
        Binding(
            get: { appState.defaultModelPreference?.id ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else {
                    appState.setDefaultModelPreference(nil)
                    return
                }
                guard let model = appState.cachedAvailableModels.first(where: { $0.id == newValue }) else { return }
                appState.setDefaultModelPreference(DefaultModelPreference(
                    provider: model.provider,
                    modelID: model.modelID,
                    thinkingLevel: appState.defaultModelPreference?.thinkingLevel
                ))
            }
        )
    }

    private var defaultThinkingSelectionBinding: Binding<String> {
        Binding(
            get: { appState.defaultModelPreference?.thinkingLevel ?? "" },
            set: { newValue in
                guard var preference = appState.defaultModelPreference else { return }
                preference.thinkingLevel = newValue.nilIfBlank
                appState.setDefaultModelPreference(preference)
            }
        )
    }

    // MARK: - Appearance section

    @ViewBuilder
    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Mode", selection: Binding(
                get: { appState.appearance.colorScheme },
                set: { newValue in appState.updateAppearance { $0.colorScheme = newValue } }
            )) {
                ForEach(AppColorSchemePreference.allCases) { scheme in
                    Text(scheme.title).tag(scheme)
                }
            }
            .pickerStyle(.segmented)

            ColorPicker("Accent", selection: Binding(
                get: { appState.appearance.accentColor },
                set: { newValue in
                    appState.updateAppearance { $0.setAccentColor(newValue) }
                }
            ), supportsOpacity: false)

            ColorPicker("Main background", selection: Binding(
                get: { appState.appearance.mainBackgroundColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)) },
                set: { newValue in
                    appState.updateAppearance { $0.setMainBackgroundColor(newValue) }
                }
            ), supportsOpacity: false)

            ColorPicker("Top bar", selection: Binding(
                get: { appState.appearance.topBarBackgroundColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)) },
                set: { newValue in
                    appState.updateAppearance { $0.setTopBarBackgroundColor(newValue) }
                }
            ), supportsOpacity: false)

            ColorPicker("Sidebars background", selection: Binding(
                get: { appState.appearance.sidebarBackgroundColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)) },
                set: { newValue in
                    appState.updateAppearance { $0.setSidebarBackgroundColor(newValue) }
                }
            ), supportsOpacity: false)

            ColorPicker("Composer area", selection: Binding(
                get: { appState.appearance.composerAreaBackgroundColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)) },
                set: { newValue in
                    appState.updateAppearance { $0.setComposerAreaBackgroundColor(newValue) }
                }
            ), supportsOpacity: false)

            ColorPicker("Text", selection: Binding(
                get: { appState.appearance.textColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)) },
                set: { newValue in
                    appState.updateAppearance { $0.setTextColor(newValue) }
                }
            ), supportsOpacity: false)

            ColorPicker("User message", selection: Binding(
                get: { appState.appearance.userMessageBackgroundColor },
                set: { newValue in
                    appState.updateAppearance { $0.setUserMessageBackgroundColor(newValue) }
                }
            ), supportsOpacity: false)

            ColorPicker("User message text", selection: Binding(
                get: { appState.appearance.userMessageTextColor },
                set: { newValue in
                    appState.updateAppearance { $0.setUserMessageTextColor(newValue) }
                }
            ), supportsOpacity: false)

            ColorPicker("Assistant message", selection: Binding(
                get: { appState.appearance.assistantMessageBackgroundColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)) },
                set: { newValue in
                    appState.updateAppearance { $0.setAssistantMessageBackgroundColor(newValue) }
                }
            ), supportsOpacity: false)

            ColorPicker("Assistant message text", selection: Binding(
                get: { appState.appearance.assistantMessageTextColor(for: appState.appearance.resolvedColorScheme(current: colorScheme)) },
                set: { newValue in
                    appState.updateAppearance { $0.setAssistantMessageTextColor(newValue) }
                }
            ), supportsOpacity: false)

            HStack {
                Button("Copy colors") {
                    copyAppearanceToClipboard()
                }
                Button("Paste colors") {
                    pasteAppearanceFromClipboard()
                }
                if let appearanceClipboardStatus {
                    Text(appearanceClipboardStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button("Reset custom colors") {
                appState.updateAppearance { $0.resetCustomColors() }
            }

            Toggle("Transparent titlebar", isOn: Binding(
                get: { appState.appearance.useTransparentTitlebar },
                set: { newValue in appState.updateAppearance { $0.useTransparentTitlebar = newValue } }
            ))

            TextField("Empty chat message", text: Binding(
                get: { appState.appearance.emptyChatMessage },
                set: { newValue in
                    appState.updateAppearance { $0.emptyChatMessage = newValue }
                }
            ))
        }
    }

    private func copyAppearanceToClipboard() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(AppAppearanceColorTransfer(
                appState.appearance,
                resolvedColorScheme: appState.appearance.resolvedColorScheme(current: colorScheme)
            ))
            guard let text = String(data: data, encoding: .utf8) else {
                appearanceClipboardStatus = "Could not encode colors."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            appearanceClipboardStatus = "Colors copied."
        } catch {
            appearanceClipboardStatus = error.localizedDescription
        }
    }

    private func pasteAppearanceFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let data = text.data(using: .utf8) else {
            appearanceClipboardStatus = "Clipboard is empty."
            return
        }
        do {
            let decoded = try JSONDecoder().decode(AppAppearanceColorTransfer.self, from: data)
            applyPastedAppearance(decoded)
            appearanceClipboardStatus = "Colors pasted."
        } catch {
            appearanceClipboardStatus = "Could not paste colors: \(error.localizedDescription)"
        }
    }

    private func applyPastedAppearance(_ transfer: AppAppearanceColorTransfer) {
        appState.updateAppearance { transfer.apply(to: &$0) }
        // Match the iPhone path: if visible ColorPickers write back a stale
        // binding value during the Form update, the pasted theme is re-applied.
        DispatchQueue.main.async {
            appState.updateAppearance { transfer.apply(to: &$0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            appState.updateAppearance { transfer.apply(to: &$0) }
        }
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        Section {
            ForEach(AppShortcutAction.allCases) { action in
                HStack(spacing: 16) {
                    Text(action.title)
                    Spacer()
                    ShortcutRecorderField(shortcut: shortcutBinding(action))
                        .frame(width: 160, height: 28)
                }
            }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Click a shortcut, then press a new key combination. Esc cancels. If the combo is already used, shortcuts swap places.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var voiceSection: some View {
        Section("Voice & Transcription") {
            VStack(alignment: .leading, spacing: 6) {
                SecureField("Groq API key", text: $groqAPIKeyInput)
                    .textContentType(.password)
                    .onSubmit { saveGroqAPIKey() }

                HStack {
                    Button(appState.hasGroqAPIKeyStored() ? "Update key" : "Save key", action: saveGroqAPIKey)
                    if appState.hasGroqAPIKeyStored() {
                        Button("Clear", role: .destructive) {
                            isConfirmingClearGroqAPIKey = true
                        }
                    }
                    Spacer()
                }

                if let groqAPIKeyStatus {
                    Text(groqAPIKeyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if appState.hasGroqAPIKeyStored() {
                    Text("A Groq API key is stored locally for Whisper transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Stored as a 0600 file in Application Support — never in the Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Diagnostics gateway

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            Toggle("Enable direct diagnostics gateway", isOn: Binding(
                get: { appState.diagnosticsGatewayEnabled },
                set: { appState.setDiagnosticsGatewayEnabled($0) }
            ))

            Text(appState.diagnosticsGatewayState.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Protected with the same bearer token as Remote API. Disable when you are done debugging.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Logs endpoint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appState.diagnosticsGatewayLogsURL)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            HStack {
                Button("Copy curl") {
                    copyDiagnosticsCurlCommand()
                }
                if let diagnosticsCopyStatus {
                    Text(diagnosticsCopyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } header: {
            Text("Diagnostics Gateway")
        } footer: {
            Text("The server listens on port \(appState.diagnosticsGatewayState.port). Use your Mac's Tailscale IP in place of <this-mac-tailscale-ip>.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Host sections (Remote API + Apply/Discard bar)

    @ViewBuilder
    private var hostSections: some View {
        Section {
            TextField("Default workspace", text: editingHostBinding(\.defaultWorkingDirectory))
        } header: {
            Text("Remote workspace")
        } footer: {
            Text("pi-app is remote-daemon-only. New sessions start in this workspace on the daemon host.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            TextField("pi-appd URL or IP", text: editingHostBinding(\.remoteDaemonURL))
                .onChange(of: editingHost?.remoteDaemonURL) { _, _ in
                    apiTokenInput = ""
                    refreshAPITokenStatus()
                }
            remoteAPITokenField
            HStack {
                Button("Test Remote API") {
                    testRemoteAPI()
                }
                Button("Copy curl") {
                    copyCurlCommand(includeToken: false)
                }
                // The "Copy with token" path requires an explicit
                // confirmation dialog because it puts the user's
                // stored bearer token on the clipboard in plain text.
                Button("Copy with token") {
                    requestCopyCurlWithToken()
                }
                .disabled(!canCopyFullCurlCommand)
                Spacer()
            }
        } header: {
            Text("Remote API (pi-appd)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("pi-appd is now the only remote transport. Configure URL and token, then use Test Remote API before Apply.")
                if let redactedCurlCommand {
                    // Always show the redacted form here. The token is
                    // never rendered in the UI; users who really need
                    // a literal token in their command must click
                    // "Copy with token" and confirm the prompt.
                    Text(redactedCurlCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Token is redacted. Use \"Copy with token\" to include it in the clipboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if hasPendingHostChanges {
            Section {
                HStack {
                    Spacer()
                    Button("Discard changes") {
                        discardHostEdits()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Apply") {
                        requestHostCommit()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Host binding helpers

    private func editingHostBinding<Value>(_ keyPath: WritableKeyPath<PiHostConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: {
                if let editingHost { return editingHost[keyPath: keyPath] }
                return appState.host[keyPath: keyPath]
            },
            set: { newValue in
                var current = editingHost ?? appState.host
                current[keyPath: keyPath] = newValue
                editingHost = current
            }
        )
    }

    private var hasPendingHostChanges: Bool {
        guard let editingHost else { return false }
        return editingHost != appState.host
    }

    private var hostCommitMessage: String {
        guard let pending = pendingHostCommit else { return "" }
        return "Applying these Remote API settings will close all open chat tabs and reload the session catalog from \(pending.remoteDaemonDisplayAddress.isEmpty ? "the configured daemon" : pending.remoteDaemonDisplayAddress)."
    }

    private func requestHostCommit() {
        guard let editingHost else { return }
        pendingHostCommit = editingHost
        isConfirmingHostCommit = true
    }

    private func performHostCommit() {
        guard let pending = pendingHostCommit else { return }

        guard pending.remoteDaemonBaseURL != nil else {
            apiTokenStatus = pending.remoteDaemonDisplayAddress.isEmpty
                ? "Remote API URL is required."
                : "Remote API URL is invalid."
            return
        }

        if !apiTokenInput.isEmpty {
            if let error = appState.saveRemoteDaemonToken(apiTokenInput, for: pending) {
                apiTokenStatus = error
                return
            }
            apiTokenInput = ""
            apiTokenStatus = "Saved."
        } else if !appState.hasRemoteDaemonTokenStored(for: pending) {
            apiTokenStatus = "Save a bearer token before applying Remote API settings."
            return
        }

        var remoteOnlyPending = pending
        remoteOnlyPending.mode = .remoteAPI
        appState.host = remoteOnlyPending
        pendingHostCommit = nil
        refreshAPITokenStatus()
    }

    private func discardHostEdits() {
        // Always revert the buffer back to the saved host. We never want
        // half-typed host values (e.g. an incomplete `remoteDaemonURL`)
        // to silently leak into `appState.host` when the user closes
        // the settings window, switches tabs, or otherwise dismisses the
        // view. Committing host changes is an explicit action: the user
        // must press Apply, confirm the dialog, and only then do we
        // touch the persisted host.
        editingHost = appState.host
        pendingHostCommit = nil
        // Also clear the in-flight confirmation state so the destructive
        // "Apply host changes?" dialog does not re-appear on the next
        // open of the settings window after the user dismissed it by
        // closing the window itself.
        isConfirmingHostCommit = false
    }

    // MARK: - Other bindings (unchanged from before)

    private func shortcutBinding(_ action: AppShortcutAction) -> Binding<AppShortcut> {
        Binding(
            get: { appState.shortcut(for: action) },
            set: { newValue in
                appState.updateShortcut(newValue, for: action)
            }
        )
    }

    private var currentEditingHost: PiHostConfiguration {
        editingHost ?? appState.host
    }

    private var curlCommand: String? {
        // Used only by the "Copy with token" path. The view never
        // renders this string in the UI; it is gated by a confirmation
        // dialog and only placed on the clipboard after the user
        // confirms.
        let token = apiTokenInput.nilIfBlank ?? RemoteDaemonTokenStore.readToken(for: currentEditingHost)
        guard let token else { return nil }
        return RemoteCurlCommandBuilder.full(host: currentEditingHost, token: token)
    }

    /// Always-safe version of the curl command shown in the settings
    /// footer. The bearer token is replaced with a `$APPLEPI_TOKEN`
    /// shell variable so the rendered text never reveals a secret.
    private var redactedCurlCommand: String? {
        RemoteCurlCommandBuilder.redacted(host: currentEditingHost)
    }

    /// Whether the user currently has a token they could copy out —
    /// i.e. either the in-progress input is non-blank, or a token is
    /// stored for the editing host. The "Copy with token" button
    /// mirrors this gate so we never offer a "with token" path when
    /// there is nothing to copy.
    private var canCopyFullCurlCommand: Bool {
        guard currentEditingHost.remoteDaemonBaseURL != nil else { return false }
        if apiTokenInput.nilIfBlank != nil { return true }
        return RemoteDaemonTokenStore.hasToken(for: currentEditingHost)
    }

    private func notificationBinding<Value>(_ keyPath: WritableKeyPath<TerminalNotificationPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { appState.appearance.notifications[keyPath: keyPath] },
            set: { newValue in
                appState.updateNotificationPreferences { $0[keyPath: keyPath] = newValue }
                notificationTestStatus = nil
            }
        )
    }

    private var notificationExtensionHelpText: String {
        "Remote sessions need a Pi notification helper installed on the remote host. The bundled helper is not used by the remote-only Mac app."
    }

    private func notificationStatusText(for result: TerminalNotificationDeliveryResult) -> String {
        switch result {
        case .delivered:
            "Test notification sent."
        case .disabled:
            "Notifications are disabled in pi-app."
        case .suppressedInForeground:
            "Foreground notifications are disabled. Put the app in the background or enable foreground notifications."
        case .denied:
            "macOS notifications are disabled for this app. Enable them in System Settings > Notifications."
        case .failed:
            "macOS could not deliver the notification."
        }
    }

    private var remoteAPITokenField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("Bearer token", text: $apiTokenInput)
                .textContentType(.password)
                .onSubmit { saveAPIToken() }
            HStack {
                Button(appState.hasRemoteDaemonTokenStored(for: currentEditingHost) ? "Update token" : "Save token", action: saveAPIToken)
                if appState.hasRemoteDaemonTokenStored(for: currentEditingHost) {
                    Button("Clear", role: .destructive) {
                        isConfirmingClearAPIToken = true
                    }
                }
                Spacer()
            }
            if let apiTokenStatus {
                Text(apiTokenStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.hasRemoteDaemonTokenStored(for: currentEditingHost) {
                Text("A bearer token is stored locally for this daemon endpoint only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Stored as a 0600 file in Application Support — never in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshAPITokenStatus() {
        apiTokenStatus = appState.hasRemoteDaemonTokenStored(for: currentEditingHost)
            ? "A token is stored for this daemon endpoint."
            : nil
    }

    private func refreshGroqAPIKeyStatus() {
        groqAPIKeyStatus = appState.hasGroqAPIKeyStored()
            ? "A Groq API key is stored for Whisper transcription."
            : nil
    }

    private func testRemoteAPI() {
        let host = currentEditingHost
        let tokenOverride = apiTokenInput.nilIfBlank
        Task {
            do {
                let message = try await RemoteDaemonClient().testConnection(host: host, tokenOverride: tokenOverride)
                await MainActor.run {
                    apiTokenStatus = message
                }
            } catch {
                await MainActor.run {
                    apiTokenStatus = error.localizedDescription
                }
            }
        }
    }

    private func copyDiagnosticsCurlCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appState.diagnosticsGatewayCurlCommand, forType: .string)
        diagnosticsCopyStatus = "Copied. Set APPLEPI_TOKEN to the stored bearer token."
    }

    private func requestCopyCurlWithToken() {
        // The "Copy with token" path always goes through a
        // confirmation dialog. The dialog is gated by `canCopyFullCurlCommand`
        // (the button is disabled otherwise) so the user cannot reach
        // this branch with an empty token.
        isConfirmingCopyWithToken = true
    }

    private func copyCurlCommand(includeToken: Bool) {
        if includeToken {
            // Full path: the caller already confirmed via
            // `requestCopyCurlWithToken()`. We still re-check the
            // inputs so a stale dialog cannot leak a token after the
            // user clears the URL or the input field.
            guard let curlCommand else {
                apiTokenStatus = "Set URL and token first."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(curlCommand, forType: .string)
            apiTokenStatus = "curl command with token copied. Treat the clipboard as sensitive."
            return
        }

        // Default path: copy the redacted form. We never put the
        // stored token on the clipboard unless the user explicitly
        // opted into the with-token variant above.
        guard let redactedCurlCommand else {
            apiTokenStatus = "Set URL first."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(redactedCurlCommand, forType: .string)
        apiTokenStatus = "Redacted curl copied. Run with APPLEPI_TOKEN=<your-token>."
    }

    private func saveAPIToken() {
        guard !apiTokenInput.isEmpty else {
            apiTokenStatus = "Token is empty."
            return
        }
        if let error = appState.saveRemoteDaemonToken(apiTokenInput, for: currentEditingHost) {
            apiTokenStatus = error
        } else {
            apiTokenInput = ""
            apiTokenStatus = "Saved."
        }
    }

    private func clearAPIToken() {
        if let error = appState.clearRemoteDaemonToken(for: currentEditingHost) {
            apiTokenStatus = error
        } else {
            apiTokenStatus = "Cleared."
        }
    }

    private func saveGroqAPIKey() {
        guard !groqAPIKeyInput.isEmpty else {
            groqAPIKeyStatus = "API key is empty."
            return
        }
        if let error = appState.saveGroqAPIKey(groqAPIKeyInput) {
            groqAPIKeyStatus = error
        } else {
            groqAPIKeyInput = ""
            groqAPIKeyStatus = "Saved."
        }
    }

    private func clearGroqAPIKey() {
        if let error = appState.clearGroqAPIKey() {
            groqAPIKeyStatus = error
        } else {
            groqAPIKeyStatus = "Cleared."
        }
    }
}

private struct AppAppearanceColorTransfer: Codable {
    var accentColorValue: CodableAccentColor?
    var mainBackgroundColorValue: CodableAccentColor?
    var topBarBackgroundColorValue: CodableAccentColor?
    var sidebarBackgroundColorValue: CodableAccentColor?
    var composerAreaBackgroundColorValue: CodableAccentColor?
    var textColorValue: CodableAccentColor?
    var userMessageBackgroundColorValue: CodableAccentColor?
    var userMessageTextColorValue: CodableAccentColor?
    var assistantMessageBackgroundColorValue: CodableAccentColor?
    var assistantMessageTextColorValue: CodableAccentColor?
    var colorScheme: AppColorSchemePreference?

    init(_ appearance: AppAppearance, resolvedColorScheme: ColorScheme) {
        // Store concrete resolved colors, not only user-overridden optionals.
        // This makes the clipboard payload portable between Mac/iPhone and
        // preserves the exact visible theme even when some values were defaults.
        accentColorValue = appearance.accentColorValue
        mainBackgroundColorValue = CodableAccentColor(appearance.mainBackgroundColor(for: resolvedColorScheme))
        topBarBackgroundColorValue = CodableAccentColor(appearance.topBarBackgroundColor(for: resolvedColorScheme))
        sidebarBackgroundColorValue = CodableAccentColor(appearance.sidebarBackgroundColor(for: resolvedColorScheme))
        composerAreaBackgroundColorValue = CodableAccentColor(appearance.composerAreaBackgroundColor(for: resolvedColorScheme))
        textColorValue = CodableAccentColor(appearance.textColor(for: resolvedColorScheme))
        userMessageBackgroundColorValue = CodableAccentColor(appearance.userMessageBackgroundColor)
        userMessageTextColorValue = CodableAccentColor(appearance.userMessageTextColor)
        assistantMessageBackgroundColorValue = CodableAccentColor(appearance.assistantMessageBackgroundColor(for: resolvedColorScheme))
        assistantMessageTextColorValue = CodableAccentColor(appearance.assistantMessageTextColor(for: resolvedColorScheme))
        colorScheme = appearance.colorScheme
    }

    func apply(to appearance: inout AppAppearance) {
        // Be tolerant of older/partial clipboard payloads: missing fields leave
        // current settings untouched instead of resetting them to defaults.
        if let accentColorValue { appearance.accentColorValue = accentColorValue }
        if let mainBackgroundColorValue { appearance.mainBackgroundColorValue = mainBackgroundColorValue }
        if let topBarBackgroundColorValue { appearance.topBarBackgroundColorValue = topBarBackgroundColorValue }
        if let sidebarBackgroundColorValue { appearance.sidebarBackgroundColorValue = sidebarBackgroundColorValue }
        if let composerAreaBackgroundColorValue { appearance.composerAreaBackgroundColorValue = composerAreaBackgroundColorValue }
        if let textColorValue { appearance.textColorValue = textColorValue }
        if let userMessageBackgroundColorValue {
            appearance.userMessageBackgroundColorValue = userMessageBackgroundColorValue
        } else if let accentColorValue {
            appearance.userMessageBackgroundColorValue = accentColorValue
        }
        if let userMessageTextColorValue {
            appearance.userMessageTextColorValue = userMessageTextColorValue
        } else if let accentColorValue {
            appearance.userMessageTextColorValue = accentColorValue.readableForegroundColorValue
        }
        if let assistantMessageBackgroundColorValue { appearance.assistantMessageBackgroundColorValue = assistantMessageBackgroundColorValue }
        if let assistantMessageTextColorValue { appearance.assistantMessageTextColorValue = assistantMessageTextColorValue }
        if let colorScheme { appearance.colorScheme = colorScheme }
    }
}

private extension String {
    /// Returns nil when the string is empty, otherwise the string itself.
    /// Lets `Picker` selection bindings work with `Optional<String>` without
    /// scattering `.nilIfBlank` checks.
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

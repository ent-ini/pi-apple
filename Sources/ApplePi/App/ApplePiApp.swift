import SwiftUI
import AppKit
@preconcurrency import UserNotifications
import ApplePiCore
import ApplePiRemote

@main
struct ApplePiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = PiAppState()

    var body: some Scene {
        WindowGroup("pi-app", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 260, minHeight: 180)
                .onAppear {
                    appDelegate.configure(appState: appState)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.shutdownForTermination()
                }
        }
        .commands {
            ApplePiCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .preferredColorScheme(appState.appearance.colorScheme.colorScheme)
                .overlay(alignment: .topLeading) {
                    // Mirror the main window's appearance so the titlebar
                    // toggle and opacity apply here too. The overlay is
                    // zero-sized and non-interactive.
                    WindowAppearanceConfigurator(appearance: appState.appearance)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private weak var appState: PiAppState?
    private var shortcutsObserver: NSObjectProtocol?
    private var floatingChatObserver: NSObjectProtocol?
    private var globalHotKeyObserver: NSObjectProtocol?
    private var overlayController: GlobalChatOverlayController?

    deinit {
        if let shortcutsObserver {
            NotificationCenter.default.removeObserver(shortcutsObserver)
        }
        if let floatingChatObserver {
            NotificationCenter.default.removeObserver(floatingChatObserver)
        }
        if let globalHotKeyObserver {
            NotificationCenter.default.removeObserver(globalHotKeyObserver)
        }
    }

    @MainActor
    func configure(appState: PiAppState) {
        self.appState = appState
        let overlayController = overlayController ?? GlobalChatOverlayController()
        self.overlayController = overlayController
        installShortcutObserverIfNeeded()
        refreshGlobalOverlayShortcut()
        DispatchQueue.main.async {
            overlayController.prepareChatWindowIfAvailable()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
    }

    @MainActor
    private func installShortcutObserverIfNeeded() {
        guard shortcutsObserver == nil else { return }
        shortcutsObserver = NotificationCenter.default.addObserver(
            forName: .piAppShortcutsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshGlobalOverlayShortcut()
            }
        }
        floatingChatObserver = NotificationCenter.default.addObserver(
            forName: .piAppToggleFloatingChat,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.overlayController?.toggle()
            }
        }
        globalHotKeyObserver = NotificationCenter.default.addObserver(
            forName: .piAppGlobalChatHotKeyPressed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.overlayController?.toggle()
            }
        }
    }

    @MainActor
    private func refreshGlobalOverlayShortcut() {
        guard let appState, let overlayController else { return }
        let status = overlayController.register(appState.shortcut(for: .toggleChatOverlay))
        appState.setGlobalOverlayShortcutStatus(status)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let preferences = ChatNotificationPreferenceReader.current()
        guard preferences.isEnabled, preferences.allowsForegroundNotifications else { return [] }

        var options: UNNotificationPresentationOptions = []
        if preferences.presentation.usesBanner {
            options.insert(.banner)
        }
        if preferences.presentation.usesSound {
            options.insert(.sound)
        }
        return options
    }
}

enum ChatNotificationPreferenceReader {
    private static let appearanceDefaultsKey = "ApplePi.appearance"

    static func current() -> TerminalNotificationPreferences {
        let defaults = Foundation.UserDefaults.standard
        guard let data = defaults.data(forKey: appearanceDefaultsKey),
              let appearance = try? JSONDecoder().decode(AppAppearance.self, from: data) else {
            return TerminalNotificationPreferences()
        }
        return appearance.notifications
    }
}

struct ApplePiCommands: Commands {
    @ObservedObject var appState: PiAppState

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Button("Find Sessions") {
                appState.requestSessionSearchFocus()
            }
            .keyboardShortcut(shortcut(for: .findSessions).keyEquivalent, modifiers: shortcut(for: .findSessions).eventModifiers)
        }

        CommandMenu("Pi") {
            Button("Toggle Floating Chat") {
                // The actual key binding is registered through Carbon so it
                // works from every application; this menu item is a visible
                // in-app alternative and intentionally has no menu shortcut.
                appState.toggleFloatingChatRequest()
            }

            Divider()

            Button("New Session") {
                appState.openNewSessionInCurrentFolder()
            }
            .keyboardShortcut(shortcut(for: .newSession).keyEquivalent, modifiers: shortcut(for: .newSession).eventModifiers)

            Button("New Session in Folder...") {
                appState.presentNewSessionInFolder()
            }
            .keyboardShortcut(shortcut(for: .newSessionInFolder).keyEquivalent, modifiers: shortcut(for: .newSessionInFolder).eventModifiers)

            Divider()

            Button("Refresh Sessions") {
                appState.refreshCatalog()
            }
            .keyboardShortcut(shortcut(for: .refreshSessions).keyEquivalent, modifiers: shortcut(for: .refreshSessions).eventModifiers)
        }
    }

    private func shortcut(for action: AppShortcutAction) -> AppShortcut {
        appState.shortcut(for: action)
    }
}

import AppKit
import Carbon.HIToolbox
import SwiftUI

private final class FloatingChatPanel: NSPanel {
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) {
        orderOut(sender)
        onDismiss?()
    }
}

/// Owns the system-wide hot key and a real non-activating AppKit panel. A
/// SwiftUI Window cannot be reliably placed over another app's full-screen
/// Space; this panel can, while the ordinary pi-app window stays conventional.
@MainActor
final class GlobalChatOverlayController: NSObject {
    private static let hotKeySignature: OSType = 0x50494150 // "PIAP"
    private static let hotKeyIdentifier: UInt32 = 1

    private let overlayAppState: PiAppState
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var panel: FloatingChatPanel?
    private var activationPolicyBeforeFloatingChat: NSApplication.ActivationPolicy?

    init(overlayAppState: PiAppState) {
        self.overlayAppState = overlayAppState
        super.init()
        installEventHandler()
    }

    func register(_ shortcut: AppShortcut) -> String {
        unregisterHotKey()
        guard let keyCode = shortcut.globalVirtualKeyCode else {
            return "This key combination cannot be used as a global shortcut. Record it again."
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyIdentifier)
        let status = RegisterEventHotKey(
            keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            return "Global shortcut is unavailable (macOS status \(status)). Choose another combination."
        }

        self.hotKeyRef = hotKeyRef
        return "Active everywhere: \(shortcut.displayString) toggles the floating chat."
    }

    var isFloatingChatVisible: Bool {
        guard let panel else { return false }
        return panel.isVisible && !panel.isMiniaturized
    }

    func toggleFloatingChat() {
        if isFloatingChatVisible {
            hideFloatingChat()
        } else {
            presentFloatingChat()
        }
    }

    func hideFloatingChat() {
        panel?.orderOut(nil)
        restoreRegularApplicationMode()
    }

    private func presentFloatingChat() {
        beginFloatingChatPresentation()
        let panel = panel ?? createPanel()
        configure(panel)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func createPanel() -> FloatingChatPanel {
        let rootView = ContentView(presentation: .floatingOverlay)
            .environmentObject(overlayAppState)
            .frame(minWidth: 520, minHeight: 420)
        let hostingController = NSHostingController(rootView: rootView)
        // macOS 14+ bridges the existing SwiftUI .toolbar declaration into
        // the AppKit panel, so the floating chat keeps the full top bar.
        hostingController.sceneBridgingOptions = [.toolbars, .title]

        let panel = FloatingChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Pi Chat"
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.onDismiss = { [weak self] in
            self?.restoreRegularApplicationMode()
        }
        self.panel = panel
        return panel
    }

    private func beginFloatingChatPresentation() {
        guard activationPolicyBeforeFloatingChat == nil else { return }
        let currentPolicy = NSApp.activationPolicy()
        guard currentPolicy == .regular,
              NSApp.setActivationPolicy(.accessory) else { return }
        activationPolicyBeforeFloatingChat = currentPolicy
    }

    private func restoreRegularApplicationMode() {
        guard let activationPolicyBeforeFloatingChat else { return }
        _ = NSApp.setActivationPolicy(activationPolicyBeforeFloatingChat)
        self.activationPolicyBeforeFloatingChat = nil
    }

    private func configure(_ panel: FloatingChatPanel) {
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = floatingCollectionBehavior
    }

    private var floatingCollectionBehavior: NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary]
        if #available(macOS 15.0, *) {
            // Apple's full-screen/Stage Manager overlay flag. It is mutually
            // exclusive with the auxiliary/primary family of flags.
            behavior.insert(.canJoinAllApplications)
        } else {
            behavior.insert(.fullScreenAuxiliary)
        }
        return behavior
    }

    private func position(_ panel: FloatingChatPanel) {
        // Preserve a user-adjusted panel position after its first appearance.
        guard panel.frame.origin == .zero else { return }
        let screen = NSScreen.main
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let width = min(760, visibleFrame.width - 40)
        let height = min(980, visibleFrame.height - 40)
        panel.setFrame(
            NSRect(
                x: visibleFrame.maxX - width - 20,
                y: visibleFrame.maxY - height - 20,
                width: width,
                height: height
            ),
            display: true,
            animate: false
        )
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        if status != noErr {
            eventHandlerRef = nil
        }
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private static let hotKeyEventHandler: EventHandlerUPP = { _, event, _ in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var receivedID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        guard status == noErr,
              receivedID.signature == hotKeySignature,
              receivedID.id == hotKeyIdentifier else {
            return OSStatus(eventNotHandledErr)
        }

        NotificationCenter.default.post(name: .piAppToggleFloatingChat, object: nil)
        return noErr
    }
}

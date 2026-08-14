import AppKit
import Carbon.HIToolbox

/// Owns the system-wide hot key and the dedicated floating-chat window. The
/// normal WindowGroup is intentionally never changed: opening pi-app from the
/// Dock remains a conventional macOS app window.
@MainActor
final class GlobalChatOverlayController: NSObject {
    private static let hotKeySignature: OSType = 0x50494150 // "PIAP"
    private static let hotKeyIdentifier: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private weak var floatingChatWindow: NSWindow?
    private var hasPositionedWindow = false
    private var activationPolicyBeforeFloatingChat: NSApplication.ActivationPolicy?

    override init() {
        super.init()
        installEventHandler()
    }

    /// Replaces the current registration. The caller displays the returned
    /// string in Settings so a system/application conflict is visible.
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

    func prepareFloatingChatWindowIfAvailable() {
        guard let window = locateFloatingChatWindow() else { return }
        configure(window)
    }

    var isFloatingChatVisible: Bool {
        guard let window = locateFloatingChatWindow() else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    func hideFloatingChat() {
        locateFloatingChatWindow()?.orderOut(nil)
        restoreRegularApplicationMode()
    }

    func floatingChatWindowClosed() {
        restoreRegularApplicationMode()
    }

    func beginFloatingChatPresentation() {
        // A regular foreground app cannot put a window over another app's
        // full-screen Space. Switch only while the palette is visible; the
        // normal pi-app window remains a regular Dock/window-menu app.
        guard activationPolicyBeforeFloatingChat == nil else { return }
        let currentPolicy = NSApp.activationPolicy()
        guard currentPolicy == .regular,
              NSApp.setActivationPolicy(.accessory) else { return }
        activationPolicyBeforeFloatingChat = currentPolicy
    }

    func presentFloatingChat() {
        guard let window = locateFloatingChatWindow() else { return }
        configure(window)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        positionOnFirstPresentation(window)
        // Do not activate the regular app here: that moves a full-screen
        // browser away from its Space. An accessory palette can become key
        // while the browser remains visually full screen underneath it.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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

    private func locateFloatingChatWindow() -> NSWindow? {
        if let floatingChatWindow { return floatingChatWindow }
        guard let window = NSApp.windows.first(where: {
            $0.title == FloatingChatWindow.title && $0.contentView != nil
        }) else {
            return nil
        }
        floatingChatWindow = window
        return window
    }

    private func configure(_ window: NSWindow) {
        // screenSaver is the level macOS composites over a different app's
        // full-screen Space; statusBar still sits below that shield.
        window.level = .screenSaver
        window.hidesOnDeactivate = false

        // AppKit rejects canJoinAllSpaces together with moveToActiveSpace.
        // On macOS 15+ canJoinAllApplications is the full-screen/Stage
        // Manager counterpart of canJoinAllSpaces and must not be combined
        // with fullScreenAuxiliary.
        var behavior = window.collectionBehavior
        behavior.remove(.moveToActiveSpace)
        behavior.remove(.fullScreenPrimary)
        behavior.remove(.fullScreenAuxiliary)
        behavior.formUnion([.canJoinAllSpaces, .stationary])
        if #available(macOS 15.0, *) {
            behavior.formUnion(.canJoinAllApplications)
        } else {
            behavior.formUnion(.fullScreenAuxiliary)
        }
        window.collectionBehavior = behavior
    }

    private func restoreRegularApplicationMode() {
        guard let activationPolicyBeforeFloatingChat else { return }
        _ = NSApp.setActivationPolicy(activationPolicyBeforeFloatingChat)
        self.activationPolicyBeforeFloatingChat = nil
    }

    private func positionOnFirstPresentation(_ window: NSWindow) {
        guard !hasPositionedWindow else { return }
        hasPositionedWindow = true

        let screen = window.screen ?? NSScreen.main
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let width = min(760, visibleFrame.width - 40)
        let height = min(980, visibleFrame.height - 40)
        let frame = NSRect(
            x: visibleFrame.maxX - width - 20,
            y: visibleFrame.maxY - height - 20,
            width: width,
            height: height
        )
        window.setFrame(frame, display: true, animate: false)
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

        // Keep the Carbon callback data-only; SwiftUI's launcher below safely
        // performs the UI work on MainActor.
        NotificationCenter.default.post(name: .piAppToggleFloatingChat, object: nil)
        return noErr
    }
}

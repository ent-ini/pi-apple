import AppKit
import Carbon.HIToolbox

/// Registers one system-wide hot key and turns the existing SwiftUI chat window
/// into a floating palette. Carbon hot keys work outside the app without an
/// Accessibility/Input Monitoring permission prompt.
@MainActor
final class GlobalChatOverlayController: NSObject, NSWindowDelegate {
    private static let hotKeySignature: OSType = 0x50494150 // "PIAP"
    private static let hotKeyIdentifier: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private weak var chatWindow: NSWindow?
    private var hasPositionedWindow = false

    override init() {
        super.init()
        installEventHandler()
    }

    /// Replaces the current registration. The caller should display the
    /// returned text in Settings so a system/application conflict is visible.
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

    func prepareChatWindowIfAvailable() {
        guard let window = locateChatWindow() else { return }
        configure(window)
    }

    func toggle() {
        toggleChatWindow()
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

    private func toggleChatWindow() {
        guard let window = locateChatWindow() else { return }
        configure(window)

        if window.isVisible && !window.isMiniaturized {
            window.orderOut(nil)
            return
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        positionOnFirstPresentation(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func locateChatWindow() -> NSWindow? {
        if let chatWindow { return chatWindow }
        guard let window = NSApp.windows.first(where: {
            $0.title == "pi-app" && $0.contentView != nil
        }) else {
            return nil
        }
        chatWindow = window
        return window
    }

    private func configure(_ window: NSWindow) {
        window.level = .floating
        window.hidesOnDeactivate = false
        // AppKit rejects canJoinAllSpaces together with moveToActiveSpace.
        // SwiftUI may set the latter on a WindowGroup, so replace it before
        // committing the collection behavior instead of simply unioning flags.
        var behavior = window.collectionBehavior
        behavior.remove(.moveToActiveSpace)
        behavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.collectionBehavior = behavior
        if window.delegate == nil {
            window.delegate = self
        }
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep the SwiftUI WindowGroup alive: the global hot key can bring the
        // palette back even after the user clicks the red close button.
        sender.orderOut(nil)
        return false
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

        // Do not bridge the Carbon callback directly to a @MainActor object:
        // Swift 6 can trap on an executor assumption here. NotificationCenter
        // hands the action to the app delegate, which safely hops to MainActor.
        NotificationCenter.default.post(name: .piAppGlobalChatHotKeyPressed, object: nil)
        return noErr
    }
}

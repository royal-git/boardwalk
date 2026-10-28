import AppKit
import BetterDockCore
import Carbon.HIToolbox

/// The arrange shortcuts: hold ⌃⌥ and press arrows to place the front window (see
/// `ArrowCombo`), ↩ to maximize, C to center, T to tile every window.
final class ArrangeShortcuts {
    private let hotKeys = HotKeys()
    private var combo = ArrowCombo()
    private var releaseCheck: Timer?

    init(arrange: @escaping (WindowLayout) -> Void, center: @escaping () -> Void, tileAll: @escaping () -> Void) {
        let arrows: [(Int, ArrowCombo.Arrow)] = [
            (kVK_LeftArrow, .left), (kVK_RightArrow, .right), (kVK_UpArrow, .up), (kVK_DownArrow, .down),
        ]
        for (keyCode, arrow) in arrows {
            hotKeys.register(keyCode: keyCode) { [weak self] in
                guard let self else { return }
                arrange(combo.press(arrow))
                watchForRelease()
            }
        }
        hotKeys.register(keyCode: kVK_Return) { arrange(.maximize) }
        hotKeys.register(keyCode: kVK_ANSI_C, action: center)
        hotKeys.register(keyCode: kVK_ANSI_T, action: tileAll)
    }

    /// Arrows combine while ⌃⌥ stay held. Carbon reports presses but not letting
    /// go, so look at the modifier keys until they're up; reading them needs no
    /// permission. The combined session state counts keys held by software
    /// (automation, remote control) as well as the keyboard.
    private func watchForRelease() {
        releaseCheck?.invalidate()
        releaseCheck = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            let flags = CGEventSource.flagsState(.combinedSessionState)
            guard !flags.isSuperset(of: [.maskControl, .maskAlternate]) else { return }
            timer.invalidate()
            self?.combo.reset()
        }
    }
}

/// Global shortcuts with ⌃⌥ through Carbon's RegisterEventHotKey. Unlike watching
/// every key press, it needs no permission, and it's still how Mac apps register them.
final class HotKeys {
    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// ⌃⌥ plus `keyCode` runs `action`, whichever app is in front.
    func register(keyCode: Int, action: @escaping () -> Void) {
        installHandler()
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: OSType(0x4244_6B63), id: id), // "BDkc"
            GetApplicationEventTarget(), 0, &ref
        )
        // Taken by another app: that one shortcut just doesn't work.
        guard status == noErr, let ref else { return }
        refs.append(ref)
        actions[id] = action
    }

    deinit {
        refs.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            hotKeys.actions[id.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

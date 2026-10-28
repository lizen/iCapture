import Carbon.HIToolbox

enum HotKeyError: Error, Equatable {
    /// A combo another app already uses or the system refused.
    case unavailable(HotKeyCombo)
}

private let iCaptureHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard event != nil, let userData else {
        return OSStatus(eventNotHandledErr)
    }
    let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        monitor.fire()
    }
    return noErr
}

@MainActor
final class HotKeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (@MainActor () -> Void)?
    private let signature = OSType(0x49_43_41_50) // "ICAP"

    /// Unregisters any previous registration first, then registers the new one.
    func register(_ combo: HotKeyCombo, handler: @escaping @MainActor () -> Void) throws {
        unregister()

        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
        ]
        var installedHandler: EventHandlerRef?
        let handlerStatus = eventTypes.withUnsafeBufferPointer { events in
            InstallEventHandler(
                GetApplicationEventTarget(),
                iCaptureHotKeyHandler,
                events.count,
                events.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &installedHandler
            )
        }
        guard handlerStatus == noErr, let installedHandler else {
            throw HotKeyError.unavailable(combo)
        }

        var registeredKey: EventHotKeyRef?
        let keyStatus = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            EventHotKeyID(signature: signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &registeredKey
        )
        guard keyStatus == noErr, let registeredKey else {
            RemoveEventHandler(installedHandler)
            throw HotKeyError.unavailable(combo)
        }

        eventHandler = installedHandler
        hotKeyRef = registeredKey
        self.handler = handler
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
        handler = nil
    }

    fileprivate func fire() {
        handler?()
    }
}

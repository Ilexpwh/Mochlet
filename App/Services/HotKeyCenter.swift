import AppKit
import Carbon.HIToolbox

// Carbon hot keys with press and release (hold-to-talk). Adapted from Mochlet v1 / Coucou (MIT).
private func mochletHotKeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var key = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                            MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
          key.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
    let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    MainActor.assumeIsolated { HotKeyCenter.shared.deliver(key.id, down: down) }
    return noErr
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    nonisolated static let signature: OSType = 0x4D4F4348 // MOCH

    enum Key: UInt32, CaseIterable {
        case ask = 1, pushToTalk = 2, jumpToTerminal = 3, pendingAlert = 4

        var label: String {
            switch self {
            case .ask: return "⌃⌥Space"
            case .pushToTalk: return "⌃⌥V"
            case .jumpToTerminal: return "⌃⌥T"
            case .pendingAlert: return "⌃⌥A"
            }
        }

        var keyCode: UInt32 {
            switch self {
            case .ask: return UInt32(kVK_Space)
            case .pushToTalk: return UInt32(kVK_ANSI_V)
            case .jumpToTerminal: return UInt32(kVK_ANSI_T)
            case .pendingAlert: return UInt32(kVK_ANSI_A)
            }
        }
    }

    private(set) var conflicts: [String] = []
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private var pressed: Set<UInt32> = []
    private var action: (@MainActor (Key, Bool) -> Void)?
    private(set) var enabled = true

    private init() {}

    func start(enabled: Bool, action: @escaping @MainActor (Key, Bool) -> Void) {
        self.action = action
        self.enabled = enabled
        if handler == nil {
            var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), mochletHotKeyHandler, specs.count, &specs, nil, &handler)
            guard status == noErr else {
                conflicts = ["Keyboard handler unavailable (\(status))."]
                return
            }
        }
        register()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        register()
    }

    private func register() {
        releaseHeldKeys()
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        conflicts = []
        guard enabled, handler != nil else { return }
        for key in Key.allCases {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key.keyCode, UInt32(controlKey | optionKey),
                                             EventHotKeyID(signature: Self.signature, id: key.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                conflicts.append("\(key.label) is unavailable or held by another app (\(status)).")
            }
        }
    }

    func deliver(_ id: UInt32, down: Bool) {
        guard enabled, let key = Key(rawValue: id) else { return }
        if down {
            guard pressed.insert(id).inserted else { return }
        } else {
            guard pressed.remove(id) != nil else { return }
        }
        action?(key, down)
    }

    func releaseHeldKeys() {
        for id in pressed { if let k = Key(rawValue: id) { action?(k, false) } }
        pressed = []
    }

    func stop() {
        releaseHeldKeys()
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        action = nil
    }
}

import AppKit
import Carbon.HIToolbox
import Observation

// Adapted from Coucou HotKeyCenter.swift, Copyright (c) 2026 Louis Raillé, MIT.
// Adds release events for hold-to-talk; all Carbon registration is main-thread-only.
private func mochletHotKeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var key = EventHotKeyID()
    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr, key.signature == 0x4D4F4348 else { return OSStatus(eventNotHandledErr) }
    let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    MainActor.assumeIsolated { HotKeyCenter.shared.deliver(key.id, down: down) }
    return noErr
}

@MainActor @Observable final class HotKeyCenter {
    static let shared = HotKeyCenter()
    var enabled = UserDefaults.standard.object(forKey: "shortcutsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "shortcutsEnabled"); register() }
    }
    private(set) var conflicts: [String] = []
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private var pressed: Set<UInt32> = []
    private var action: (@MainActor (UInt32, Bool) -> Void)?
    private init() {}
    func start(action: @escaping @MainActor (UInt32, Bool) -> Void) {
        self.action = action
        if handler == nil {
            var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let status = InstallEventHandler(GetApplicationEventTarget(), mochletHotKeyHandler, specs.count, &specs, nil, &handler)
            guard status == noErr else { conflicts = ["Keyboard handler unavailable (\(status))."]; return }
        }
        register()
    }
    private func register() {
        releaseHeldKeys()
        for ref in refs { UnregisterEventHotKey(ref) }; refs = []; conflicts = []
        guard enabled, handler != nil else { return }
        for (id, code, label) in [(UInt32(1), UInt32(kVK_Space), "⌃⌥Space"), (UInt32(2), UInt32(kVK_ANSI_V), "⌃⌥V")] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(code, UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4D4F4348, id: id), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
            else { conflicts.append("\(label) is unavailable or held by another app (\(status)).") }
        }
    }
    func deliver(_ id: UInt32, down: Bool) {
        guard enabled else { return }
        if down { guard pressed.insert(id).inserted else { return } }
        else { guard pressed.remove(id) != nil else { return } }
        action?(id, down)
    }
    func releaseHeldKeys() {
        for id in pressed { action?(id, false) }; pressed = []
    }
    func stop() {
        releaseHeldKeys()
        for ref in refs { UnregisterEventHotKey(ref) }; refs = []
        if let handler { RemoveEventHandler(handler) }; handler = nil; action = nil
    }
}

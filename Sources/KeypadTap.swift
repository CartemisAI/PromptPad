// Listens for the keypad's F13–F20 combos on its own thread, so slow work on the main thread never
// holds up typing anywhere on the Mac.
import AppKit

final class KeypadTap {
    /// keycode, combo name, isDown, isAutorepeat. Called on the main thread.
    var onKey: ((Int64, String, Bool, Bool) -> Void)?
    /// macOS switched the tap off for a moment (it was too slow, or secure input). Called on the main thread.
    var onInterrupted: (() -> Void)?

    private var tap: CFMachPort?
    /// What each held key was decided to be on key-down, so its key-up goes the same way
    /// even if the front app or modifiers changed in between. Only touched on the tap thread.
    private var held: [Int64: (combo: String, passed: Bool)] = [:]

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "PromptPad keypad"; t.qualityOfService = .userInteractive
        t.start()
    }

    private func run() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(mask), callback: { _, type, event, ctx in
            Unmanaged<KeypadTap>.fromOpaque(ctx!).takeUnretainedValue().handle(type, event)
        }, userInfo: ctx)
        guard let tap else { log("Keypad listener failed to start (missing permission?)"); return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("Keypad listener started (F13–F20)")
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            held.removeAll()
            DispatchQueue.main.async { [weak self] in self?.onInterrupted?() }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let down = type == .keyDown

        if MapState.isOpen {
            if keypadKeyNames[code] == nil {
                // Cmd+Tab / Cmd+` would switch away from the map; everything else from the real keyboard goes through.
                let f = event.flags
                return f.contains(.maskCommand) && (code == 48 || code == 50) ? nil : Unmanaged.passUnretained(event)
            }
            let combo = down ? keyCombo(code, event.flags) ?? "" : held[code]?.combo ?? keyCombo(code, event.flags) ?? ""
            if down { held[code] = (combo, false) } else { held.removeValue(forKey: code) }
            if let real = mapKeys[combo] {   // keypad Enter / Tab / knob drive the map
                event.setIntegerValueField(.keyboardEventKeycode, value: real.code)
                event.flags = real.flags
                return Unmanaged.passUnretained(event)
            }
            if PadLayout.current.action(for: combo, appID: nil) == "cheatsheet" { dispatch(code, combo, down, event) }
            return nil
        }

        guard keypadKeyNames[code] != nil else { return Unmanaged.passUnretained(event) }
        let combo: String
        let passed: Bool
        if down {
            combo = keyCombo(code, event.flags) ?? ""
            passed = passesThrough(combo)
            held[code] = (combo, passed)
        } else if let h = held.removeValue(forKey: code) {
            (combo, passed) = (h.combo, h.passed)
        } else {
            combo = keyCombo(code, event.flags) ?? ""
            passed = passesThrough(combo)
        }
        if passed { return Unmanaged.passUnretained(event) }   // the front app has its own binding ("pass")
        dispatch(code, combo, down, event)
        return nil   // F13–F20 come only from the keypad; never let them reach other apps
    }

    private func dispatch(_ code: Int64, _ combo: String, _ down: Bool, _ event: CGEvent) {
        let rep = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        DispatchQueue.main.async { [weak self] in self?.onKey?(code, combo, down, rep) }
    }
}

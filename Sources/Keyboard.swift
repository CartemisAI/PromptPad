// Writes key maps to a QMK/VIA keyboard over its raw-HID interface (cable mode only).
// Which keyboard: the layout's "device" (vendorID / productID). Before changing a key for the first time,
// its current value is saved to keyboard-backup.txt, so "restore" can always put it back.
import Foundation
import IOKit.hid

final class KeyboardWriter {
    private var device: IOHIDDevice?
    private var reply = [UInt8](repeating: 0, count: 32)
    private var gotReply = false
    private let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    deinit { inBuf.deallocate() }

    /// Each change: (isEncoder, layer, rowOrEncoderID, colOrClockwise, keycode).
    typealias Change = (enc: Bool, layer: UInt8, a: UInt8, b: UInt8, code: UInt16)

    private static func hex(_ s: String?) -> Int? {
        guard let s else { return nil }
        return Int(s.hasPrefix("0x") ? String(s.dropFirst(2)) : s, radix: 16)
    }

    /// Opens the keyboard's VIA interface. False if it isn't plugged in by cable.
    private func open() -> Bool {
        let dev = PadLayout.current.device
        guard let vid = Self.hex(dev["vendorID"]), let pid = Self.hex(dev["productID"]) else { return false }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid,
                                          kIOHIDPrimaryUsagePageKey: 0xFF60, kIOHIDPrimaryUsageKey: 0x61] as CFDictionary)
        IOHIDManagerOpen(m, 0)
        guard let d = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.first,
              IOHIDDeviceOpen(d, 0) == kIOReturnSuccess else { return false }
        device = d
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(d, inBuf, 64, { ctx, _, _, _, _, r, len in
            let me = Unmanaged<KeyboardWriter>.fromOpaque(ctx!).takeUnretainedValue()
            for i in 0..<min(32, len) { me.reply[i] = r[i] }
            me.gotReply = true
        }, ctx)
        return true
    }

    private func close() {
        if let d = device { IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue); IOHIDDeviceClose(d, 0) }
        device = nil
    }

    private func send(_ b: [UInt8]) -> [UInt8]? {
        guard let d = device else { return nil }
        var out = [UInt8](repeating: 0, count: 32); for (i, x) in b.enumerated() { out[i] = x }
        gotReply = false
        guard IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, out, 32) == kIOReturnSuccess else { return nil }
        let end = Date().addingTimeInterval(1)
        while !gotReply && Date() < end { CFRunLoopRunInMode(.defaultMode, 0.01, true) }
        return gotReply ? reply : nil
    }

    private func read(_ c: Change) -> UInt16? {
        guard let r = send([c.enc ? 0x14 : 0x04, c.layer, c.a, c.b]) else { return nil }
        return UInt16(r[4]) << 8 | UInt16(r[5])
    }

    /// Writes and reads back every change. Returns (ok, failed), or nil if the keyboard isn't reachable.
    /// With `backup`, first saves the current value of any key that has no saved original yet.
    func apply(_ changes: [Change], backup: Bool) -> (ok: Int, failed: Int)? {
        guard open() else { return nil }
        defer { close() }
        guard send([0x01]) != nil else { return nil }   // protocol version: proves it answers
        if backup {
            let known = Set(Self.factory().map(Self.slot) + Self.saved().map(Self.slot))
            var lines: [String] = []
            for c in changes where !known.contains(Self.slot(c)) {
                if let v = read(c) { lines.append(Self.line((c.enc, c.layer, c.a, c.b, v))) }
            }
            if !lines.isEmpty {
                try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
                let old = (try? String(contentsOf: keyboardBackupURL, encoding: .utf8)) ?? ""
                try? (old + lines.joined(separator: "\n") + "\n").write(to: keyboardBackupURL, atomically: true, encoding: .utf8)
                log("Saved the original setting of \(lines.count) keys")
            }
        }
        var ok = 0, failed = 0
        for c in changes {
            let hi = UInt8(c.code >> 8), lo = UInt8(c.code & 0xFF)
            _ = send([c.enc ? 0x15 : 0x05, c.layer, c.a, c.b, hi, lo])
            if read(c) == c.code { ok += 1 } else { failed += 1 }
        }
        return (ok, failed)
    }

    // MARK: What to write

    private static func slot(_ c: Change) -> String { "\(c.enc ? "enc" : "key") \(c.layer) \(c.a) \(c.b)" }
    private static func line(_ c: Change) -> String { slot(c) + String(format: " %04x", c.code) }

    private static func parse(_ text: String) -> [Change] {
        text.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ").map(String.init)
            guard p.count == 5, let l = UInt8(p[1]), let a = UInt8(p[2]), let b = UInt8(p[3]),
                  let code = UInt16(p[4], radix: 16) else { return nil }
            return (p[0] == "enc", l, a, b, code)
        }
    }

    /// Factory settings shipped with PromptPad for this keyboard (layout "device.factory").
    static func factory() -> [Change] {
        guard let name = PadLayout.current.device["factory"],
              let url = Bundle.main.url(forResource: (name as NSString).deletingPathExtension,
                                        withExtension: (name as NSString).pathExtension),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// Originals saved from this keyboard before PromptPad first changed them.
    static func saved() -> [Change] {
        parse((try? String(contentsOf: keyboardBackupURL, encoding: .utf8)) ?? "")
    }

    /// Everything to put back: the factory list, plus saved originals for keys it doesn't cover.
    static func restoreChanges() -> [Change] {
        let f = factory()
        let covered = Set(f.map(slot))
        return f + saved().filter { !covered.contains(slot($0)) }
    }

    /// Changes described by the layout (all layers, keys and the knob).
    static func layoutChanges() -> [Change] {
        let layout = PadLayout.current
        let layers = (layout.json["layers"] as? [String: Int]) ?? ["base": 0, "fn": 1, "m3": 2]
        var out: [Change] = []
        for (_, key) in layout.keys {
            guard let pos = key["pos"] as? [Int], pos.count == 2 else { continue }
            for (name, idx) in layers {
                guard let l = key[name] as? [String: Any], let code = hex(l["code"] as? String) else { continue }
                out.append((false, UInt8(idx), UInt8(pos[0]), UInt8(pos[1]), UInt16(code)))
            }
        }
        for (name, idx) in layers {
            guard let e = (layout.json["encoder"] as? [String: [String: String]])?[name] else { continue }
            if let c = hex(e["ccw"]) { out.append((true, UInt8(idx), 0, 0, UInt16(c))) }
            if let c = hex(e["cw"]) { out.append((true, UInt8(idx), 0, 1, UInt16(c))) }
        }
        return out
    }
}

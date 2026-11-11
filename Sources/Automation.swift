// Acts on apps through macOS Accessibility: finds and presses buttons, the message box and menu items,
// and posts keys, text and clicks.
import AppKit
import ApplicationServices

/// Set by --dump / --press so diagnostics can look at whatever app is in front.
var dumpAnyFrontApp = false

/// Virtual key codes by name, for "keys:" actions.
let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
    "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ".": 47, ",": 43, "/": 44, ";": 41,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "esc": 53, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126, "[": 33, "]": 30, "`": 50, "\\": 42, "=": 24, "-": 27, "'": 39,
    "pageup": 116, "pagedown": 121, "home": 115, "end": 119, "forwarddelete": 117, "fwddelete": 117, "f12": 111,
    "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90]

/// "cmd+shift+d" → key code and modifier flags.
func parseKeys(_ s: String) -> (CGKeyCode, CGEventFlags)? {
    var flags: CGEventFlags = []; var code: CGKeyCode?
    for part in s.lowercased().split(separator: "+").map(String.init) {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "opt", "alt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: code = keyCodes[part]
        }
    }
    return code.map { ($0, flags) }
}

final class AppAutomation {
    /// The app to act on: the front app if it's one of the chat apps in the layout (or any app during diagnostics).
    /// Never a background app: keys always go to the front app, so acting elsewhere could send text in the wrong place.
    var target: NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return dumpAnyFrontApp || frontIsAI ? front : nil
    }
    var frontIsAI: Bool { PadLayout.current.app(bundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.ai == true }

    func activate(_ bundleID: String) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        log("Switch to \(bundleID)")
    }

    // MARK: Accessibility helpers

    /// Electron apps only build their accessibility tree when asked. Also caps each call at 1 s so a hung app
    /// can't stall PromptPad.
    func axApp(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(app, 1.0)
        return app
    }

    func enableAccessibilityTree() {
        if let pid = target?.processIdentifier { _ = axApp(pid) }
    }

    private func str(_ e: AXUIElement, _ a: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success, let s = v as? String else { return "" }
        return s
    }

    private func attrString(_ e: AXUIElement, _ a: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success, let v else { return "" }
        if let s = v as? String { return s }
        if let arr = v as? [String] { return arr.joined(separator: ",") }
        return ""
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success,
              let arr = kids as? [AXUIElement] else { return [] }
        return arr
    }

    /// On-screen frame of an element.
    private func frame(_ e: AXUIElement) -> CGRect? {
        var posV: CFTypeRef?, sizeV: CFTypeRef?; var pt = CGPoint.zero, sz = CGSize.zero
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &posV) == .success, let posV,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sizeV) == .success, let sizeV else { return nil }
        AXValueGetValue(posV as! AXValue, .cgPoint, &pt); AXValueGetValue(sizeV as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// Breadth-first walk over at most `limit` elements. `visit` returns false to stop early.
    private func walk(_ roots: [AXUIElement], limit: Int = 80000, _ visit: (AXUIElement) -> Bool) -> Int {
        var queue = roots; var i = 0
        while i < queue.count && i < limit {
            let e = queue[i]; i += 1
            if !visit(e) { break }
            queue.append(contentsOf: children(e))
        }
        return i
    }

    /// Every attribute a button might keep its name in, each checked on its own.
    private func names(_ e: AXUIElement) -> [String] {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXValueAttribute]
            .map { str(e, $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Scanning for buttons

    struct Scan {
        var windowNote = ""
        var visited = 0
        var roles: [String: Int] = [:]
        var buttons: [(AXUIElement, [String])] = []
        var roleOf: [String] = []
        var apiDisabled = false
    }

    /// Control types a button can show up as (toggle buttons are often AXCheckBox).
    private func controlRoles() -> Set<String> {
        if let list = readConfig()["roles"] as? [String], !list.isEmpty { return Set(list) }
        return ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXRadioButton"]
    }

    /// Walks the target app's front window and collects every button.
    func scan() -> Scan {
        var r = Scan()
        guard let pid = target?.processIdentifier else { r.windowNote = "front app is not a chat app"; return r }
        let app = axApp(pid)
        var roots: [AXUIElement] = []
        for a in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var v: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(app, a as CFString, &v)
            r.windowNote += "\(a)=\(err.rawValue) "
            if err == .apiDisabled { r.apiDisabled = true }
            if err == .success, let v { roots.append(v as! AXUIElement); break }
        }
        if roots.isEmpty {
            var v: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
            let wins = (v as? [AXUIElement]) ?? []
            r.windowNote += "AXWindows=\(err.rawValue) count=\(wins.count)"
            roots = wins
        }
        let wanted = controlRoles()
        r.visited = walk(roots) { e in
            let role = str(e, kAXRoleAttribute)
            r.roles[role, default: 0] += 1
            if wanted.contains(role) {
                r.buttons.append((e, names(e)))
                let sub = str(e, kAXSubroleAttribute)
                r.roleOf.append(sub.isEmpty ? role : role + "/" + sub)
            }
            return true
        }
        return r
    }

    /// Scans, waiting up to ~2 s for Electron to finish building its tree.
    func scanWhenReady() -> Scan {
        var last = scan()
        guard target != nil else { return last }
        for _ in 0..<8 where last.buttons.filter({ !$0.1.isEmpty }).count < 4 {
            usleep(250_000); last = scan()
        }
        return last
    }

    private func find(_ sc: Scan, labels: Set<String>) -> (AXUIElement, String)? {
        guard let hit = sc.buttons.last(where: { $0.1.contains { labels.contains($0.lowercased()) } }) else { return nil }
        return (hit.0, hit.1.joined(separator: " | "))
    }

    /// Writes a full list of the target window's controls to PromptPad-dump.txt, for tuning button names.
    func dumpButtons(reason: String, scan given: Scan? = nil) {
        let sc = given ?? scanWhenReady()
        let roles = sc.roles.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        var lines = ["\(reason)",
                     "  trusted=\(AXIsProcessTrusted()) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")",
                     "  window: \(sc.windowNote)",
                     "  visited \(sc.visited) elements, roles: \(roles)",
                     "  controls: \(sc.buttons.count), named: \(sc.buttons.filter { !$0.1.isEmpty }.count):"]
        var seen = Set<String>()
        for (i, (e, n)) in sc.buttons.enumerated() {
            let key = "[\(sc.roleOf[i])] " + n.joined(separator: " | ")
            guard seen.insert(key).inserted else { continue }
            let dom = [attrString(e, "AXDOMIdentifier"), attrString(e, "AXDOMClassList")].filter { !$0.isEmpty }.joined(separator: " ")
            lines.append("    - \(n.isEmpty ? key + "(no name)" : String(key.prefix(100)))\(dom.isEmpty ? "" : "   [" + String(dom.prefix(80)) + "]")")
        }
        // The full list (it can contain chat titles) goes only to the dump file, which is deleted after 3 days.
        try? lines.joined(separator: "\n").write(to: dumpURL, atomically: true, encoding: .utf8)
        log(lines.prefix(4).joined(separator: "\n") + "\n  controls listed in \(dumpURL.path)")
    }

    // MARK: Pressing things

    /// Presses a control, with a real mouse click for apps that ignore Accessibility presses.
    private func press(_ e: AXUIElement, _ name: String, what: String) -> Bool {
        if needsRealClick() {
            let ok = clickElement(e); log("\(what): mouse click “\(name)” -> " + (ok ? "ok" : "failed")); return ok
        }
        let err = AXUIElementPerformAction(e, kAXPressAction as CFString)
        log("\(what): press “\(name)” -> \(err.rawValue)")
        return err == .success
    }

    /// Presses the last control named exactly one of `labels` (e.g. "Queue for later") in the front chat app.
    @discardableResult
    func pressNamed(_ labels: Set<String>, what: String) -> Bool {
        let sc = scanWhenReady()
        guard let (target, name) = find(sc, labels: labels) else {
            dumpButtons(reason: "\(what): button not found", scan: sc); return false
        }
        return press(target, name, what: what)
    }

    /// Presses a control in the front app (any app) whose name starts with `prefix`, e.g. "Voice Input".
    @discardableResult
    func pressFrontButton(prefix: String) -> Bool {
        dumpAnyFrontApp = true; defer { dumpAnyFrontApp = false }
        let sc = scanWhenReady()
        let want = prefix.lowercased()
        guard let hit = sc.buttons.first(where: { $0.1.contains { $0.lowercased().hasPrefix(want) } }) else { return false }
        return press(hit.0, hit.1.joined(separator: " | "), what: "Button")
    }

    /// The voice button, pressed only if it's showing one of `labels` (so a release never starts a recording).
    @discardableResult
    func pressVoice(ifShowing labels: Set<String>, what: String) -> Bool {
        let sc = scanWhenReady()
        if sc.apiDisabled && AXIsProcessTrusted() { relaunchSelf(); return false }
        guard let (target, name) = find(sc, labels: labels) else {
            log("\(what): no voice button in that state, skipped"); return false
        }
        return press(target, name, what: what)
    }

    /// True if the voice button currently shows a "stop" state.
    func isRecording() -> Bool { find(scanWhenReady(), labels: voiceStopLabels()) != nil }

    /// Optional config override: {"voiceShortcut": {"key": "d", "modifiers": ["cmd"]}} for the headset's voice gesture.
    private func voiceShortcut() -> (CGKeyCode, CGEventFlags)? {
        guard let sc = readConfig()["voiceShortcut"] as? [String: Any], let key = sc["key"] as? String else { return nil }
        return parseKeys((((sc["modifiers"] as? [String]) ?? []) + [key]).joined(separator: "+"))
    }

    /// Starts or stops the chat app's voice input (used by the headset add-on).
    @discardableResult
    func toggleVoice() -> Bool {
        if let (code, flags) = voiceShortcut() { postKey(code, flags: flags); log("Voice shortcut from config.json"); return true }
        let sc = scanWhenReady()
        if sc.apiDisabled && AXIsProcessTrusted() { log("Permission granted but not active in this process yet, restarting"); relaunchSelf(); return false }
        if let (target, name) = find(sc, labels: voiceLabels()) { return press(target, name, what: "Voice button") }
        dumpButtons(reason: "Voice button not found", scan: sc)
        return false
    }

    /// A real mouse click on an element's center, then the pointer goes back. Only clicks if that point really
    /// is the element's app (not a notification or panel covering it).
    @discardableResult
    func clickElement(_ e: AXUIElement) -> Bool {
        guard let f = frame(e) else { return false }
        let c = CGPoint(x: f.midX, y: f.midY)
        var hit: AXUIElement?; var elementPid: pid_t = 0, hitPid: pid_t = 0
        AXUIElementGetPid(e, &elementPid)
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(c.x), Float(c.y), &hit) == .success,
              let hit, AXUIElementGetPid(hit, &hitPid) == .success, hitPid == elementPid else {
            log("Something covers the button, so it was not clicked"); return false
        }
        let back = CGEvent(source: nil)?.location ?? c
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        CGWarpMouseCursorPosition(back)
        return true
    }

    /// Apps whose buttons need a real click: "realClick" in the layout, or config "realClickApps".
    func needsRealClick() -> Bool {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if let list = readConfig()["realClickApps"] as? [String] { return list.contains(id) }
        return PadLayout.current.app(bundle: id)?.realClick == true
    }

    // MARK: Message box

    /// The message box: the lowest text area in the front window, with its on-screen frame.
    func findComposer() -> (AXUIElement, CGRect)? {
        guard let pid = target?.processIdentifier else { return nil }
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp(pid), kAXFocusedWindowAttribute as CFString, &win) == .success, let root = win
        else { return nil }
        var best: (AXUIElement, CGRect)?
        _ = walk([root as! AXUIElement]) { e in
            let role = str(e, kAXRoleAttribute)
            if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String, let f = frame(e),
               best == nil || f.origin.y >= best!.1.origin.y {
                best = (e, f)
            }
            return true
        }
        return best
    }

    /// Puts the cursor back in the message box.
    @discardableResult
    func focusComposer() -> Bool {
        guard let (box, _) = findComposer() else { log("Focus message box: not found"); return false }
        let err = AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        log("Focus message box -> \(err.rawValue)")
        return err == .success
    }

    private var scrollPoint: (CGPoint, Date, pid_t)?

    /// Scrolls the conversation a little, wherever the mouse pointer and text cursor are.
    /// It aims just above the message box, which is the conversation in Claude and ChatGPT.
    func scrollConversation(up: Bool) {
        guard let app = target else { return }
        let pid = app.processIdentifier
        if scrollPoint == nil || scrollPoint!.2 != pid || Date().timeIntervalSince(scrollPoint!.1) > 3 {
            guard let (_, f) = findComposer() else { log("Fine scroll: message box not found"); return }
            scrollPoint = (CGPoint(x: f.midX, y: max(f.minY - 160, 80)), Date(), pid)
        }
        let cfg = readConfig()
        let point = scrollPoint!.0
        let px = Int32((cfg["fineScrollPixels"] as? Int) ?? 60)
        let flip = (cfg["invertFineScroll"] as? Bool) == true
        guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: (up != flip) ? px : -px, wheel2: 0, wheel3: 0) else { return }
        ev.location = point
        if (cfg["scrollMethod"] as? String) == "warp" {
            // Briefly move the pointer over the conversation, scroll, and move it back.
            let back = CGEvent(source: nil)?.location ?? point
            CGWarpMouseCursorPosition(point); ev.post(tap: .cghidEventTap); CGWarpMouseCursorPosition(back)
        } else {
            ev.postToPid(pid)
        }
    }

    /// Sends a queued message now ("Send now" in Claude, "Steer" in ChatGPT). If the message is still in the
    /// box, sends it first so it queues, then presses the button.
    @discardableResult
    func forceSend() -> Bool {
        let labels = sendNowLabels()
        func tryPress() -> Bool {
            let sc = scanWhenReady()
            guard let hit = sc.buttons.first(where: { $0.1.contains { labels.contains($0.lowercased()) } }) else { return false }
            return press(hit.0, hit.1.joined(separator: " | "), what: "Send now")   // a real click where the app needs one
        }
        guard frontIsAI else { return false }
        if tryPress() { return true }
        pressEnter()                    // put the typed message in the queue first
        usleep(500_000)
        if tryPress() { return true }
        dumpButtons(reason: "Send now: button not found")
        return false
    }

    // MARK: Menus

    /// Presses a menu item of the front app by path, e.g. "View>Toggle Side Chat".
    /// Names match case-insensitively, exactly first, then by prefix.
    @discardableResult
    func pressMenu(_ path: String, quiet: Bool = false) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar else { return false }
        var level = children(bar as! AXUIElement)
        let parts = path.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for (i, want) in parts.enumerated() {
            guard let hit = level.first(where: { str($0, kAXTitleAttribute).lowercased() == want })
                    ?? level.first(where: { str($0, kAXTitleAttribute).lowercased().hasPrefix(want) }) else {
                if !quiet { log("Menu: “\(want)” not found") }
                return false
            }
            if i == parts.count - 1 {
                let err = AXUIElementPerformAction(hit, kAXPressAction as CFString)
                if !quiet { log("Menu: press “\(path)” -> \(err.rawValue)") }
                return err == .success
            }
            level = children(hit).flatMap { children($0) }   // item -> its AXMenu -> items
        }
        return false
    }

    /// macOS dictation through the front app's Edit menu ("Start Dictation…" / "Stop Dictation").
    @discardableResult
    func toggleSystemDictation(stopOnly: Bool = false) -> Bool {
        if pressMenu("Edit>Stop Dictation", quiet: true) { return true }
        if stopOnly { return false }
        return pressMenu("Edit>Start Dictation")
    }

    /// Writes every menu item with its shortcut, for every app in the layout, to PromptPad-menus.txt.
    func dumpMenus() {
        var lines: [String] = []
        func mods(_ m: Int) -> String {   // AXMenuItemCmdModifiers: bit0 shift, bit1 option, bit2 control, bit3 no command
            var s = ""
            if m & 4 != 0 { s += "Ctrl+" }; if m & 2 != 0 { s += "Opt+" }; if m & 1 != 0 { s += "Shift+" }
            if m & 8 == 0 { s += "Cmd+" }; return s
        }
        func walkMenu(_ e: AXUIElement, _ prefix: String, _ depth: Int) {
            for item in children(e) {
                let title = str(item, kAXTitleAttribute)
                var key = ""
                var c: CFTypeRef?, m: CFTypeRef?
                if AXUIElementCopyAttributeValue(item, "AXMenuItemCmdChar" as CFString, &c) == .success,
                   let ch = c as? String, !ch.isEmpty {
                    AXUIElementCopyAttributeValue(item, "AXMenuItemCmdModifiers" as CFString, &m)
                    key = "   [" + mods((m as? Int) ?? 0) + ch + "]"
                }
                let path = prefix.isEmpty ? title : prefix + ">" + title
                if !title.isEmpty { lines.append(String(repeating: "  ", count: depth) + path + key) }
                for sub in children(item) where depth < 4 { walkMenu(sub, path, depth + 1) }
            }
        }
        for info in PadLayout.current.apps {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: info.bundle).first else {
                lines.append("== \(info.bundle) not running"); continue
            }
            lines.append("== \(info.bundle)")
            var bar: CFTypeRef?
            if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute as CFString, &bar) == .success, let bar {
                for top in children(bar as! AXUIElement) {
                    let t = str(top, kAXTitleAttribute); lines.append(t)
                    for menu in children(top) { walkMenu(menu, t, 1) }
                }
            }
        }
        try? lines.joined(separator: "\n").write(to: menusDumpURL, atomically: true, encoding: .utf8)
        log("Menus written to \(menusDumpURL.path)")
    }

    /// Opens an app's keyboard-shortcut sheet (Cmd+/), saves every text on screen, then closes it.
    func dumpShortcutSheet(_ bundleID: String) {
        activate(bundleID); usleep(1_200_000)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            log("Shortcut sheet: \(bundleID) didn't come to the front, no keys sent"); return
        }
        postKey(44, flags: .maskCommand); usleep(1_500_000)   // Cmd+/
        var lines: [String] = []
        var win: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &win) == .success, let root = win {
            _ = walk([root as! AXUIElement]) { e in
                let role = str(e, kAXRoleAttribute)
                if role == kAXStaticTextRole as String || role == "AXHeading" {
                    let v = str(e, kAXValueAttribute).isEmpty ? str(e, kAXTitleAttribute) : str(e, kAXValueAttribute)
                    let t = v.isEmpty ? str(e, kAXDescriptionAttribute) : v
                    if !t.isEmpty && t.count < 120 { lines.append(t) }
                }
                return true
            }
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { postKey(53) }   // Esc closes the sheet
        usleep(400_000)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            _ = pressFrontButton(prefix: "close dialog")   // ChatGPT keeps it open after Esc
        }
        let url = home.appendingPathComponent("Library/Logs/PromptPad-shortcuts-\(bundleID).txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        log("Shortcut sheet written to \(url.path), \(lines.count) lines")
    }

    // MARK: Posting keys and text

    /// Posts a key with exactly these modifiers (whatever is physically held is ignored).
    func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    func pressEnter() { postKey(36); log("Return") }

    /// Types characters directly (e.g. "，" or ","), whatever input method is active.
    func typeText(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for ch in text.utf16 {
            var c = ch
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []   // the keypad combo's own Ctrl / Cmd may still be held
                e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Pastes text into the focused field without touching the input method, then restores the clipboard,
    /// unless something else changed it meanwhile. Marked transient so clipboard managers skip it.
    func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ours = pb.changeCount
        postKey(9, flags: .maskCommand)   // Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard pb.changeCount == ours else { return }
            pb.clearContents()
            let items = saved.map { d -> NSPasteboardItem in
                let it = NSPasteboardItem(); for (t, v) in d { it.setData(v, forType: t) }; return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        log("Pasted \(text.count) characters")
    }

    func relaunchSelf() {
        let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// PromptPad: a menu bar app that turns a macro keypad into controls for voice-first work with AI apps
// (Claude, ChatGPT), VS Code and the browser.
//
// The keypad sends F13–F20 with modifier combos (never Option: Claude opens its quick entry on a double Option).
// KeypadTap catches those combos, the layout says what each one does in the front app, and AppDelegate does it.
// Nothing runs at login unless you turn on "Open at Login", nothing is installed system-wide, and every input
// device is only read, never seized.
import Cocoa
import ApplicationServices
import CoreAudio
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, AddonHost {
    let automation = AppAutomation()
    private lazy var voice = VoiceKey(automation)
    private let keypad = KeypadTap()
    private var statusItem: NSStatusItem!
    private var enabled = true
    private var lastAction = ""
    /// Modifier keys an action is holding down, by the keypad key that holds them ("hold:" actions).
    private var heldKeys: [Int64: String] = [:]

    // MARK: Start

    func applicationDidFinishLaunching(_ n: Notification) {
        if runDiagnostics() { return }
        trimLogs()
        log("—— start ——")
        FrontApp.startTracking()
        FrontApp.onChange = { [weak self] in self?.voice.appChanged(); self?.releaseHeldKeys() }
        voice.note = { [weak self] in self?.note(L("Voice key → %@", $0)) }
        PadLayout.reload()
        Lang.load()
        log("Language: \(Lang.code) (setting: \(Lang.preference))")
        log("Open at login: " + (SMAppService.mainApp.status == .enabled ? "on" : "off"))
        automation.enableAccessibilityTree()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        // Accessibility lets PromptPad press buttons and post keys; Input Monitoring lets the keypad tap see F13–F20.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let axAtLaunch = AXIsProcessTrustedWithOptions(opts)
        let imAtLaunch = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if axAtLaunch && !imAtLaunch { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        if !axAtLaunch || !imAtLaunch {
            // A process that started without a permission never gets it; restart once it's granted.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                let ax = AXIsProcessTrusted()
                let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
                if ax && !axAtLaunch && !im && !imAtLaunch { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
                if (ax && !axAtLaunch) || (im && !imAtLaunch) {
                    t.invalidate(); log("Permission granted, restarting"); self?.automation.relaunchSelf()
                }
            }
        }

        for a in installedAddons where Addons.isEnabled(a.id) { a.start(host: self); log("Add-on started: \(a.id)") }

        keypad.onKey = { [weak self] code, combo, down, rep in self?.handleCombo(code, combo, down, rep) }
        keypad.onInterrupted = { [weak self] in log("macOS paused the keypad listener; it is back on"); self?.releaseHeldKeys() }
        if AXIsProcessTrusted() { keypad.start() }
    }

    /// Command-line diagnostics. Returns true if one ran (the app then quits).
    private func runDiagnostics() -> Bool {
        let args = CommandLine.arguments
        func arg(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let id = arg("--shortcuts") { automation.dumpShortcutSheet(id) }
        else if let p = arg("--press") {
            let ok = automation.pressFrontButton(prefix: p); log("Diagnostic press “\(p)”: " + (ok ? "pressed" : "not found"))
        }
        else if args.contains("--menus") { automation.dumpMenus() }
        else if args.contains("--dump") { dumpAnyFrontApp = true; automation.dumpButtons(reason: "Dump from the command line") }
        else if args.contains("--write-keyboard") {
            let r = KeyboardWriter().apply(KeyboardWriter.layoutChanges(), backup: true)
            log(r.map { "Write layout from the command line: \($0.ok) ok, \($0.failed) failed" } ?? "Write layout from the command line: keypad not connected")
        }
        else if args.contains("--install-vscode") { log("Command line: " + VSCodeRules.install()) }
        else if args.contains("--remove-vscode") { VSCodeRules.remove() }
        else { return false }
        NSApp.terminate(nil); return true
    }

    func applicationWillTerminate(_ n: Notification) {
        releaseHeldKeys()
        for a in installedAddons { a.stop() }
        log("—— quit ——")
    }

    // MARK: AddonHost

    var isActive: Bool { enabled && !MapState.isOpen }

    func note(_ text: String) {
        lastAction = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium) + " " + text
    }

    // MARK: Keys

    /// A keypad combo arrived (on the main thread). The layout decides what it does in the front app.
    private func handleCombo(_ code: Int64, _ combo: String, _ down: Bool, _ rep: Bool) {
        // A key that is holding a modifier lets go on its own release, whatever happened in between.
        if !down, let name = heldKeys.removeValue(forKey: code) { holdKey(name, down: false); return }
        let app = FrontApp.info
        guard let act = PadLayout.current.action(for: combo, appID: app?.id), !act.isEmpty else { return }
        let lower = act.lowercased()
        guard enabled || lower == "cheatsheet" else { return }   // paused: nothing but the map
        if lower.hasPrefix("hold:") {
            if down && !rep && !MapState.isOpen {
                let name = String(act.dropFirst(5)); holdKey(name, down: true); heldKeys[code] = name
                note(L("%@ → holding %@", combo, name))
            }
            return
        }
        if lower == "voice" || lower.hasPrefix("voice:") {   // voice keys act on both press and release
            guard !rep else { return }
            if down && lower.hasPrefix("voice:") {
                guard automation.frontIsAI else { return }
                startWithText(String(act.dropFirst(6)))
            }
            voice.key(down: down)
            return
        }
        guard down, !rep || isRepeatable(lower) else { return }
        let ok = perform(act)
        note("\(combo) → \(act)" + (ok ? "" : L(" (failed)")))
        log("Combo \(combo) → \(act) " + (ok ? "ok" : "failed"))
    }

    /// Holding a key repeats only movement and editing; anything else (close tab, new chat…) happens once.
    private func isRepeatable(_ act: String) -> Bool {
        if act.hasPrefix("type:") || act.hasPrefix("scroll:") { return true }
        guard act.hasPrefix("keys:") else { return false }
        let key = act.dropFirst(5).split(separator: ",").last?.split(separator: "+").last.map(String.init) ?? ""
        return ["left", "right", "up", "down", "delete", "forwarddelete", "fwddelete", "pageup", "pagedown",
                "home", "end", "space", "tab", "return", "enter", "z", "[", "]"].contains(key)
    }

    /// Runs one layout action. See docs/customize.md for the list.
    @discardableResult
    func perform(_ act: String) -> Bool {
        let lower = act.lowercased()
        let auto = automation
        func arg(_ prefix: String) -> String { String(act.dropFirst(prefix.count)) }
        if lower.hasPrefix("keys:") {
            // A comma makes a chord sequence, e.g. "cmd+k,v".
            for (i, part) in arg("keys:").split(separator: ",").enumerated() {
                guard let (code, flags) = parseKeys(String(part)) else { return false }
                if i > 0 { usleep(60_000) }
                auto.postKey(code, flags: flags)
            }
            return true
        }
        if lower.hasPrefix("type:") { auto.typeText(arg("type:")); return true }
        if lower.hasPrefix("menu:") { return auto.pressMenu(arg("menu:")) }
        if lower.hasPrefix("button:") { return auto.pressFrontButton(prefix: arg("button:")) }
        if lower.hasPrefix("app:") { auto.activate(PadLayout.current.bundle(for: arg("app:"))); return true }
        if lower.hasPrefix("cycle:") {
            // Rotates through the listed apps: from one of them go to the next, otherwise to the first.
            let ids = arg("cycle:").split(separator: ",").map { PadLayout.current.bundle(for: $0.trimmingCharacters(in: .whitespaces)) }
            guard !ids.isEmpty else { return false }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            auto.activate(ids.firstIndex(of: front).map { ids[($0 + 1) % ids.count] } ?? ids[0]); return true
        }
        // The rest act on a chat app's window, so they only run when one is in front.
        let chatOnly = ["say:", "paste:", "scroll:", "voice:"].contains { lower.hasPrefix($0) } || ["focus", "queue", "forcesend"].contains(lower)
        if chatOnly && !auto.frontIsAI { return false }
        if lower.hasPrefix("say:") {
            auto.focusComposer(); auto.pasteText(L(arg("say:")))
            usleep(150_000); auto.pressEnter(); return true
        }
        if lower.hasPrefix("paste:") { auto.focusComposer(); auto.pasteText(L(arg("paste:"))); return true }
        if lower.hasPrefix("scroll:") { auto.scrollConversation(up: lower == "scroll:up"); return true }
        if lower.hasPrefix("voice:") { startWithText(arg("voice:")); voice.key(down: true); voice.key(down: false); return true }
        switch lower {
        case "none": return true   // deliberately does nothing (e.g. editing keys in VS Code)
        case "voice": voice.key(down: true); voice.key(down: false); return true
        case "send": auto.pressEnter(); return true
        case "forcesend": return auto.forceSend()
        case "queue": return auto.pressNamed(queueLabels(), what: "Queue for later")
        case "focus": return auto.focusComposer()
        case "toggledictation": showHUD(voice.toggleEngine()); return true
        case "cheatsheet": toggleCheatSheet(); return true
        case "nextmic":
            // First press only shows the list; pressing again while it's up moves to the next mic.
            guard micPanel?.isVisible == true else { showMicPanel(); return true }
            guard let name = Microphones.next() else { showHUD(L("Couldn't switch the microphone")); return false }
            showMicPanel(); log("Microphone switched to \(name)"); return true
        default: return false
        }
    }

    /// Puts `text` at the start of the chat app's message box, ready for voice to continue it (e.g. "/btw ").
    private func startWithText(_ text: String) {
        automation.focusComposer()
        automation.postKey(126, flags: .maskCommand)   // Cmd+↑: to the start of the box
        automation.pasteText(text)
        usleep(150_000)
        note(L("Typed “%@”, then voice", text.trimmingCharacters(in: .whitespaces)))
    }

    /// Holds or releases a modifier key on its own, e.g. "hold right Option" to record a voice message.
    private func holdKey(_ name: String, down: Bool) {
        // keycode and the device-specific flag bit for each side of the modifier
        let table: [String: (CGKeyCode, CGEventFlags, UInt64)] = [
            "rightoption": (61, .maskAlternate, 0x40), "leftoption": (58, .maskAlternate, 0x20),
            "rightcommand": (54, .maskCommand, 0x10), "rightshift": (60, .maskShift, 0x04), "fn": (63, .maskSecondaryFn, 0)]
        guard let (code, flag, device) = table[name.lowercased()],
              let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = down ? CGEventFlags(rawValue: flag.rawValue | device) : []
        e.post(tap: .cghidEventTap)
        log("Hold \(name) " + (down ? "down" : "up"))
    }

    /// Lets go of every modifier an action is holding (pause, map, app switch, quit).
    private func releaseHeldKeys() {
        for name in Set(heldKeys.values) { holdKey(name, down: false) }
        heldKeys.removeAll()
    }

    // MARK: Menu bar

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: enabled ? "waveform.circle.fill" : "waveform.circle", accessibilityDescription: "PromptPad")
        button.appearsDisabled = !enabled
        button.toolTip = enabled ? L("PromptPad: on") : L("PromptPad: paused")
    }

    // Rebuilt each time it opens so the status lines are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func item(_ title: String, _ action: Selector, _ key: String = "") {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.target = self; menu.addItem(i)
        }

        info(enabled ? L("● PromptPad is on") : L("○ PromptPad is paused: keys do nothing"))
        for a in installedAddons where Addons.isEnabled(a.id) { if let s = a.statusLine() { info(s) } }
        let micItem = NSMenuItem(title: L("Microphone: %@", Microphones.current()?.name ?? L("unknown")), action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let cur = Microphones.current()?.id
        for d in Microphones.rotation() {
            let i = NSMenuItem(title: d.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = d.id; i.state = d.id == cur ? .on : .off
            i.image = NSImage(systemSymbolName: MicIcon.symbol(name: d.name, transport: d.transport), accessibilityDescription: nil)
            micMenu.addItem(i)
        }
        micItem.submenu = micMenu; menu.addItem(micItem)
        info(AXIsProcessTrusted() ? L("Permissions: Accessibility granted") : L("Permissions: Accessibility missing"))
        info(L("Last: %@", lastAction.isEmpty ? L("no key pressed yet") : lastAction))
        menu.addItem(.separator())

        item(L("Show Key Map (Fn+NumLock)"), #selector(showCheatSheet), "k")
        item(enabled ? L("Pause") : L("Resume"), #selector(toggleEnabled), "p")
        let login = NSMenuItem(title: L("Open at Login"), action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
        if !AXIsProcessTrusted() { item(L("Open Accessibility Settings…"), #selector(openAccessibility)) }
        menu.addItem(.separator())

        let names = Addons.allNames()
        if !names.isEmpty {
            let addonItem = NSMenuItem(title: L("Add-ons"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for name in names {
                let i = NSMenuItem(title: Addons.title(name), action: #selector(toggleAddon(_:)), keyEquivalent: "")
                i.target = self; i.representedObject = name; i.state = Addons.isEnabled(name) ? .on : .off
                sub.addItem(i)
            }
            addonItem.submenu = sub; menu.addItem(addonItem)
        }
        let custom = NSMenuItem(title: L("Customize"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        func subItem(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; sub.addItem(i)
        }
        subItem(L("Edit My Layout…"), #selector(editPersonalLayout))
        subItem(L("Reload Layout"), #selector(reloadLayout))
        sub.addItem(.separator())
        subItem(L("Write Layout to Keypad"), #selector(writeKeyboardLayout))
        subItem(L("Restore Keypad Layout…"), #selector(restoreKeyboard))
        sub.addItem(.separator())
        subItem(VSCodeRules.isInstalled ? L("Update VS Code Rules") : L("Install VS Code Rules"), #selector(installVSCode))
        if VSCodeRules.isInstalled { subItem(L("Remove VS Code Rules"), #selector(removeVSCode)) }
        sub.addItem(.separator())
        subItem(L("List the Front App’s Buttons"), #selector(dumpButtons))
        subItem(L("Show Log"), #selector(openLog))
        custom.submenu = sub; menu.addItem(custom)
        let lang = NSMenuItem(title: L("Language") == "Language" ? "Language" : L("Language") + " / Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for (code, title) in [("auto", L("Same as macOS"))] + Lang.available() {
            let i = NSMenuItem(title: title, action: #selector(setLanguage(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = code; i.state = Lang.preference == code ? .on : .off
            langMenu.addItem(i)
        }
        lang.submenu = langMenu; menu.addItem(lang)
        menu.addItem(.separator())

        item(L("Quit"), #selector(quit), "q")
        item(L("Uninstall…"), #selector(uninstall))
    }

    /// Starts PromptPad when you log in (off unless you turn it on). It shows up in System Settings → Login Items,
    /// where it can also be switched off.
    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister(); log("Open at login: off") }
            else { try service.register(); log("Open at login: on") }
        } catch {
            log("Open at login failed: \(error.localizedDescription)")
            showMessage(L("Open at Login"), L("macOS didn't allow it: %@", error.localizedDescription))
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func toggleEnabled() {
        enabled.toggle(); refreshIcon(); releaseHeldKeys(); log(enabled ? "Resumed" : "Paused")
    }

    @objc private func toggleAddon(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        let on = !Addons.isEnabled(name)
        guard Addons.setEnabled(name, on) else { showMessage(L("Add-ons"), L("config.json has an error, so nothing was saved.")); return }
        if let a = installedAddons.first(where: { $0.id == name }) { on ? a.start(host: self) : a.stop() }
        PadLayout.reload()
        log("Add-on \(name) " + (on ? "on" : "off"))
    }

    @objc private func editPersonalLayout() {
        if !FileManager.default.fileExists(atPath: userLayoutURL.path) {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let about = L("Your layout: write only what you change; it is merged on top of PromptPad's default layout. Then choose Customize → Reload Layout. See docs/customize.md.")
            let starter = "{\n \"about\": \"\(about)\",\n \"actions\": {\n }\n}\n"
            try? starter.write(to: userLayoutURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(userLayoutURL)
    }

    @objc private func reloadLayout() { PadLayout.reload(); Lang.load(); cheatModel = nil; showHUD(L("Layout reloaded")) }

    @objc private func setLanguage(_ item: NSMenuItem) {
        guard let code = item.representedObject as? String, Config.update({ $0["language"] = code }) else { return }
        Lang.load(); cheatModel = nil; cheatWindow?.orderOut(nil); MapState.isOpen = false
        log("Language: \(code) → \(Lang.code)")
    }

    @objc private func installVSCode() { showMessage(L("VS Code Rules"), VSCodeRules.install()) }
    @objc private func removeVSCode() { VSCodeRules.remove(); showMessage(L("VS Code Rules"), L("Removed PromptPad's VS Code rules. Your own shortcuts are untouched.")) }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openLog() { NSWorkspace.shared.open(logURL) }
    @objc private func dumpButtons() {
        dumpAnyFrontApp = true; automation.dumpButtons(reason: "Dump from the menu"); dumpAnyFrontApp = false; openLog()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showMessage(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }

    // MARK: Notices

    private var hud: NSPanel?
    private var hudGeneration = 0

    /// A small notice in the middle of the screen that fades after 1.5 s. Never takes focus.
    func showHUD(_ text: String) {
        guard !text.isEmpty else { return }
        let panel = hud ?? {
            let p = floatingPanel()
            let v = NSVisualEffectView(); v.material = .hudWindow; v.state = .active
            v.wantsLayer = true; v.layer?.cornerRadius = 14
            let label = NSTextField(wrappingLabelWithString: ""); label.tag = 1
            label.font = .systemFont(ofSize: 15, weight: .semibold); label.alignment = .left
            label.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
                                         label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
                                         label.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
            p.contentView = v; hud = p; return p
        }()
        (panel.contentView?.viewWithTag(1) as? NSTextField)?.stringValue = text
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map { $0.count }.max() ?? 10
        let size = CGSize(width: max(240, min(560, CGFloat(longest) * 15 + 60)), height: CGFloat(lines.count) * 24 + 32)
        hudGeneration += 1
        present(panel, size: size, for: lines.count > 1 ? 2.5 : 1.5, generation: hudGeneration) { [weak self] in self?.hudGeneration }
    }

    private func floatingPanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    /// Centers a panel, shows it, and fades it out after `seconds` unless it was shown again meanwhile.
    private func present(_ panel: NSPanel, size: CGSize, for seconds: Double, generation: Int, current: @escaping () -> Int?) {
        if let f = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1; panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak panel] in
            guard current() == generation else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel?.animator().alphaValue = 0 },
                                                 completionHandler: { if current() == generation { panel?.orderOut(nil) } })
        }
    }

    private var micPanel: NSPanel?
    private var micGeneration = 0

    /// Every microphone with an icon, the one in use highlighted. Stays while you keep pressing,
    /// closes 3 seconds after the last press. Never takes focus.
    func showMicPanel() {
        let cur = Microphones.current()?.id
        let items = Microphones.rotation().map {
            MicItem(id: String($0.id), name: $0.name, symbol: MicIcon.symbol(name: $0.name, transport: $0.transport), current: $0.id == cur)
        }
        let panel = micPanel ?? { let p = floatingPanel(); micPanel = p; return p }()
        let fx = NSVisualEffectView(); fx.material = .hudWindow; fx.state = .active
        fx.wantsLayer = true; fx.layer?.cornerRadius = 14; fx.layer?.masksToBounds = true
        let host = NSHostingView(rootView: MicListView(items: items))
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        panel.contentView = fx
        micGeneration += 1
        present(panel, size: host.fittingSize, for: 3, generation: micGeneration) { [weak self] in self?.micGeneration }
    }

    @objc private func selectMic(_ item: NSMenuItem) {
        guard let id = item.representedObject as? AudioObjectID else { return }
        if Microphones.select(id) { log("Microphone set from the menu: \(item.title)"); showMicPanel() }
    }

    // MARK: Key map window

    private var cheatWindow: NSWindow?
    private var cheatReturnApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var cheatModel: CheatModel?
    private var previewArmed = false
    private var previewWork: DispatchWorkItem?

    @objc private func showCheatSheet() {
        releaseHeldKeys()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { cheatReturnApp = front }
        let w = cheatWindow ?? {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("PromptPad Key Map")
            w.isReleasedWhenClosed = false
            w.level = .floating
            cheatWindow = w
            // Closing with the red button, or clicking another window, ends the map's exclusive mode.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MapState.isOpen = false
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
                guard MapState.isOpen else { return }
                self?.closeCheatSheet(returnFocus: false)
            }
            return w
        }()
        let appID = PadLayout.current.app(bundle: cheatReturnApp?.bundleIdentifier)?.id
        if let model = cheatModel {
            // Same app as last time: keep the layer and position. Another app from the layout: start on its page.
            // Some other app (Finder, …): keep whatever was on screen.
            if let id = appID, id != model.app { model.app = id; model.layer = .base; model.focusRow = 0 }
            if !PadLayer.all().contains(model.layer) { model.layer = .base }
        } else {
            let model = CheatModel(app: appID ?? PadLayout.current.apps.first?.id ?? "")
            cheatModel = model
            w.contentView = NSHostingView(rootView: CheatSheetView(model: model))
            w.setContentSize(w.contentView!.fittingSize)
        }
        if !w.isVisible { w.center() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        MapState.isOpen = true
        previewArmed = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        guard keyMonitor == nil else { return }
        // Keys while the map is in front: 8 4 6 2 / knob move, Enter goes into the keys, Tab changes layer, Esc closes.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.cheatWindow?.isKeyWindow == true, let m = self.cheatModel else { return e }
            switch e.keyCode {
            case 53: self.closeCheatSheet()
            case 123: m.move(dx: -1, dy: 0)           // ← : knob left, key 4
            case 124: m.move(dx: 1, dy: 0)            // → : knob right, key 6
            case 126, 116: m.move(dx: 0, dy: -1)      // ↑ / Page Up : key 8
            case 125, 121: m.move(dx: 0, dy: 1)       // ↓ / Page Down : key 2
            case 36, 76: m.activate()                 // Enter
            case 48: m.stepLayer(e.modifierFlags.contains(.shift) ? -1 : 1)   // Tab / Fn+Tab
            default: break                            // anything else: swallow, so no alert beep / screen flash
            }
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            guard let self, self.cheatWindow?.isKeyWindow == true else { return e }
            let f = e.modifierFlags.intersection([.command, .control, .option, .shift])
            // The Fn+NumLock that opened the map is usually still held: wait until every modifier is up once.
            if f.isEmpty { self.previewArmed = true }
            guard self.previewArmed else { return e }
            // Fn holds Shift, M4 holds Command: show that layer while held. Combo keys (like the comma key,
            // Ctrl+Cmd+F17) pass through brief single-modifier states, so only a state held 0.15 s counts.
            let target: PadLayer? = f.contains(.shift) ? .fn : (f == .command ? .m3 : nil)
            self.previewWork?.cancel()
            if target == nil && f.isEmpty { self.cheatModel?.preview(nil); return e }
            guard let t = target else { return e }
            let work = DispatchWorkItem { [weak self] in
                let now = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift])
                let still: PadLayer? = now.contains(.shift) ? .fn : (now == .command ? .m3 : nil)
                if still == t { self?.cheatModel?.preview(t) }
            }
            self.previewWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return e
        }
    }

    func closeCheatSheet(returnFocus: Bool = true) {
        MapState.isOpen = false
        cheatModel?.preview(nil)
        cheatWindow?.orderOut(nil)
        if returnFocus { cheatReturnApp?.activate() }
    }

    /// One key opens the map; pressing it again closes it.
    func toggleCheatSheet() {
        if cheatWindow?.isVisible == true { closeCheatSheet() } else { showCheatSheet() }
    }

    // MARK: Keyboard firmware

    private func runKeyboard(_ changes: [KeyboardWriter.Change], backup: Bool, what: String, done: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            let r = KeyboardWriter().apply(changes, backup: backup)
            log("\(what): " + (r.map { "\($0.ok) ok, \($0.failed) failed" } ?? "keypad not connected"))
            let msg = r.map { L("%@: %@ keys written, %@ failed.", L(what), "\($0.ok)", "\($0.failed)") }
                ?? L("%@ failed: the keypad isn't connected. Connect it by USB cable and set the switch on its back to wired.", L(what))
            DispatchQueue.main.async { done(msg) }
        }
    }

    @objc private func writeKeyboardLayout() {
        runKeyboard(KeyboardWriter.layoutChanges(), backup: true, what: "Write Layout to Keypad") { [weak self] in self?.showMessage(L("Write Layout to Keypad"), $0) }
    }

    @objc private func restoreKeyboard() {
        let a = NSAlert()
        a.messageText = L("Restore the keypad's layout?")
        a.informativeText = L("Every key PromptPad changed goes back to its earlier setting. The keypad must be connected by USB cable.")
        a.addButton(withTitle: L("Restore")); a.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        runKeyboard(KeyboardWriter.restoreChanges(), backup: false, what: "Restore Keypad Layout") { [weak self] in self?.showMessage(L("Restore Keypad Layout"), $0) }
    }

    // MARK: Uninstall

    @objc private func uninstall() {
        let alert = NSAlert()
        alert.messageText = L("Uninstall PromptPad?")
        alert.informativeText = L("PromptPad will quit, remove its permissions, logs and settings, take its rules out of VS Code (your own shortcuts stay), put the keypad back the way it was if it is connected by cable, and move itself to the Trash.")
        alert.addButton(withTitle: L("Uninstall")); alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        releaseHeldKeys()
        for a in installedAddons { a.stop() }
        if KeyboardWriter().apply(KeyboardWriter.restoreChanges(), backup: false) == nil {
            let a = NSAlert()
            a.messageText = L("The keypad wasn't restored")
            a.informativeText = L("The keypad isn't connected, so it still has PromptPad's layout. Connect it by USB cable in wired mode first if you can. If you uninstall anyway, the keypad keeps its current layout and the record of its earlier settings is deleted too.")
            a.addButton(withTitle: L("Uninstall Anyway")); a.addButton(withTitle: L("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        VSCodeRules.remove()
        try? SMAppService.mainApp.unregister()
        if let id = Bundle.main.bundleIdentifier {
            for service in ["Accessibility", "ListenEvent"] {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                p.arguments = ["reset", service, id]; try? p.run(); p.waitUntilExit()
            }
            // The local signing certificate made by scripts/make-signing-cert.sh, if any.
            let c = Process(); c.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            c.arguments = ["delete-identity", "-c", "PromptPad Local Signing"]; try? c.run(); c.waitUntilExit()
        }
        stopLogging()
        let fm = FileManager.default
        for url in [logURL, dumpURL, menusDumpURL, supportDir] {
            try? fm.removeItem(at: url)
        }
        let logs = home.appendingPathComponent("Library/Logs")
        for f in (try? fm.contentsOfDirectory(atPath: logs.path)) ?? [] where f.hasPrefix("PromptPad-shortcuts-") {
            try? fm.removeItem(at: logs.appendingPathComponent(f))
        }
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

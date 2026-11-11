// Loads the layout (built-in + enabled add-ons + the user's own file) and answers "what does this key do here?".
import AppKit

/// An app PromptPad knows about, from the layout's "apps" list.
struct AppInfo {
    let id: String          // short name used in actions and "show", e.g. "claude"
    let name: String        // shown on the map
    let bundle: String      // macOS bundle identifier
    let ai: Bool            // a chat app with a message box: focus, scroll, queue, force-send, say: work here
    let voice: String       // shortcut | button | toggleButton | system | off
    let voiceKeys: String?  // for "shortcut", e.g. "cmd+d"
    let voiceButton: String?// for "toggleButton": the start of the button's name, e.g. "voice input"
    let realClick: Bool     // the app ignores Accessibility presses, so click with the mouse

    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""
        name = d["name"] as? String ?? id
        bundle = d["bundle"] as? String ?? ""
        ai = d["ai"] as? Bool ?? false
        voice = d["voice"] as? String ?? "system"
        voiceKeys = d["voiceKeys"] as? String
        voiceButton = d["voiceButton"] as? String
        realClick = d["realClick"] as? Bool ?? false
    }
}

final class PadLayout {
    private static let lock = NSLock()
    private static var _current = PadLayout()
    /// The layout in use. Safe to read from the keypad thread.
    static var current: PadLayout { lock.lock(); defer { lock.unlock() }; return _current }
    static func reload() { let l = PadLayout(); lock.lock(); _current = l; lock.unlock(); log("Layout loaded: " + l.sources.joined(separator: " + ")) }

    let json: [String: Any]
    let apps: [AppInfo]
    private(set) var sources: [String] = []

    init() {
        var merged: [String: Any] = [:]
        var sources: [String] = []
        func add(_ url: URL, _ name: String) {
            guard let data = try? Data(contentsOf: url) else { return }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                log("Layout file has an error, skipped: \(url.path)"); return
            }
            merged = deepMerge(merged, obj); sources.append(name)
        }
        if let url = Bundle.main.url(forResource: "layout", withExtension: "json") { add(url, "default") }
        else if let p = ProcessInfo.processInfo.environment["PROMPTPAD_LAYOUT"] { add(URL(fileURLWithPath: p), "default") }
        for addon in Addons.overlayNames() where Addons.isEnabled(addon) {
            if let url = Bundle.main.url(forResource: addon, withExtension: "json", subdirectory: "addons") { add(url, addon) }
        }
        add(userLayoutURL, "my layout")
        json = merged
        apps = ((merged["apps"] as? [[String: Any]]) ?? []).map(AppInfo.init).filter { !$0.id.isEmpty }
        actions = Dictionary(((merged["actions"] as? [String: Any]) ?? [:]).map { (normalizeCombo($0.key), $0.value) }) { a, _ in a }
        self.sources = sources
    }

    var keys: [String: [String: Any]] { (json["keys"] as? [String: [String: Any]]) ?? [:] }
    /// Actions by combo name, normalised (computed once: read from the keypad thread too).
    let actions: [String: Any]
    var layerNames: [String: String] { (json["layerNames"] as? [String: String]) ?? [:] }
    var device: [String: String] { (json["device"] as? [String: String]) ?? [:] }

    func app(bundle: String?) -> AppInfo? { apps.first { $0.bundle == bundle } }
    func app(id: String) -> AppInfo? { apps.first { $0.id == id } }
    /// An app id or a bundle id, as written in "app:" and "cycle:" actions.
    func bundle(for name: String) -> String { app(id: name)?.bundle ?? name }

    /// The action for a key combo in an app: the app's own entry, else "default", else nil.
    /// config.json "keyActions" (older way to customise) is checked first.
    func action(for combo: String, appID: String?) -> String? {
        let custom = (readConfig()["keyActions"] as? [String: Any]).map { Dictionary($0.map { (normalizeCombo($0.key), $0.value) }) { a, _ in a } }
        let entry = custom?[combo] ?? actions[combo]
        if let s = entry as? String { return s }
        guard let d = entry as? [String: String] else { return nil }
        return appID.flatMap { d[$0] } ?? d["default"]
    }
}

/// Merges b into a: objects merge key by key, lists of objects with an "id" merge by id, anything else is replaced.
func deepMerge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
    var out = a
    for (k, bv) in b {
        if let ad = out[k] as? [String: Any], let bd = bv as? [String: Any] {
            out[k] = deepMerge(ad, bd)
        } else if let al = out[k] as? [[String: Any]], let bl = bv as? [[String: Any]],
                  (al + bl).allSatisfy({ $0["id"] is String }) {
            var list = al
            for item in bl {
                if let i = list.firstIndex(where: { ($0["id"] as? String) == (item["id"] as? String) }) {
                    list[i] = deepMerge(list[i], item)
                } else { list.append(item) }
            }
            out[k] = list
        } else {
            out[k] = bv
        }
    }
    return out
}

/// The frontmost app, kept current from the main thread so the keypad thread can read it cheaply.
enum FrontApp {
    private static let lock = NSLock()
    private static var _bundle: String?
    static var bundleID: String? { lock.lock(); defer { lock.unlock() }; return _bundle }
    static var info: AppInfo? { PadLayout.current.app(bundle: bundleID) }
    static var onChange: (() -> Void)?

    static func startTracking() {
        set(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            set(app?.bundleIdentifier); onChange?()
        }
    }
    private static func set(_ id: String?) { lock.lock(); _bundle = id; lock.unlock() }
}

/// True while the key-map window is open and in front: only the map's own keys work then.
enum MapState {
    private static let lock = NSLock()
    private static var _open = false
    static var isOpen: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _open }
        set { lock.lock(); _open = newValue; lock.unlock() }
    }
}

// MARK: - Key combos

let keyF13: Int64 = 105, keyF14: Int64 = 107, keyF15: Int64 = 113, keyF16: Int64 = 106, keyF17: Int64 = 64
let keyF18: Int64 = 79, keyF19: Int64 = 80, keyF20: Int64 = 90
let keypadKeyNames: [Int64: String] = [keyF13: "f13", keyF14: "f14", keyF15: "f15", keyF16: "f16",
                                       keyF17: "f17", keyF18: "f18", keyF19: "f19", keyF20: "f20"]

/// The layout name of a keypad combo, always in the order ctrl, opt, shift, cmd, e.g. "ctrl+shift+cmd+f15".
func keyCombo(_ code: Int64, _ flags: CGEventFlags) -> String? {
    guard let keyName = keypadKeyNames[code] else { return nil }
    var mods: [String] = []
    if flags.contains(.maskControl) { mods.append("ctrl") }
    if flags.contains(.maskAlternate) { mods.append("opt") }
    if flags.contains(.maskShift) { mods.append("shift") }
    if flags.contains(.maskCommand) { mods.append("cmd") }
    return (mods + [keyName]).joined(separator: "+")
}

/// "cmd+shift+F13" and "shift+cmd+f13" both become "shift+cmd+f13" (the order keyCombo produces).
func normalizeCombo(_ s: String) -> String {
    let parts = s.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    let alias = ["control": "ctrl", "option": "opt", "alt": "opt", "command": "cmd"]
    let mods = Set(parts.dropLast().map { alias[$0] ?? $0 })
    return (["ctrl", "opt", "shift", "cmd"].filter(mods.contains) + [parts.last ?? ""]).joined(separator: "+")
}

/// Keypad combos that stand for real keys while the map is open (Enter, Tab, Fn+Tab, the knob).
let mapKeys: [String: (code: Int64, flags: CGEventFlags)] = [
    "ctrl+f13": (36, []), "ctrl+f17": (48, []), "ctrl+shift+f17": (48, .maskShift),
    "ctrl+cmd+f18": (123, []), "ctrl+cmd+f19": (124, [])]

/// True when the front app handles this combo itself (layout action "pass", e.g. VS Code's keybindings).
func passesThrough(_ combo: String) -> Bool {
    PadLayout.current.action(for: combo, appID: FrontApp.info?.id) == "pass"
}

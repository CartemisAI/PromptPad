// The voice key: tap to start / stop, or hold to talk and let go to stop.
// How each app starts voice input comes from the layout's "apps" list ("voice"):
//   shortcut      press the app's own shortcut ("voiceKeys", e.g. Claude's Cmd+D), falling back to its mic button
//   button        press the app's voice button, found by name (voiceStartLabels / voiceStopLabels)
//   toggleButton  press a button whose name starts with "voiceButton"; it doesn't change name, so PromptPad keeps count
//   system        macOS dictation (Edit > Start Dictation)
//   off           nothing
// Apps not in the list use macOS dictation. M4+0 switches the front app between its own way and macOS dictation.
import AppKit

final class VoiceKey {
    private let auto: AppAutomation
    var note: (String) -> Void = { _ in }

    private var downAt: Date?
    private var startedThisPress = false
    private var shortcutOn = false     // "shortcut": whether we started it
    private var toggleOn = false       // "toggleButton": whether the button is on
    private var usingFallback = false  // "toggleButton" button not found: this press uses macOS dictation

    init(_ automation: AppAutomation) { auto = automation }

    /// What we remember about a recording belongs to the app it was started in.
    func appChanged() { shortcutOn = false; toggleOn = false; startedThisPress = false; usingFallback = false }

    private var heldLongEnough: Bool { (downAt.map { Date().timeIntervalSince($0) } ?? 0) >= holdThreshold() }

    func key(down: Bool) {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let info = PadLayout.current.app(bundle: bundle)
        var method = info?.voice ?? "system"
        if method != "off" && engine(bundle) == "system" { method = "system" }
        if down { downAt = Date(); log("Voice key down, front \(bundle ?? "?"), method \(method)") }
        switch method {
        case "off":          if down { note(L("off in %@", L(info?.name ?? "this app"))) }
        case "shortcut":     shortcut(down, keys: info?.voiceKeys ?? "cmd+d")
        case "toggleButton": toggleButton(down, prefix: info?.voiceButton ?? "voice input")
        case "button":       button(down)
        default:             system(down)
        }
    }

    private func system(_ down: Bool) {
        if down {
            startedThisPress = !auto.toggleSystemDictation(stopOnly: true)
            if startedThisPress { startedThisPress = auto.toggleSystemDictation() }
            note(startedThisPress ? L("macOS dictation on") : L("macOS dictation off"))
        } else {
            if startedThisPress && heldLongEnough { auto.toggleSystemDictation(stopOnly: true); note(L("released → macOS dictation off")) }
            startedThisPress = false
        }
    }

    private func shortcut(_ down: Bool, keys: String) {
        guard let (code, flags) = parseKeys(keys) else { button(down); return }
        if down {
            if !shortcutOn { auto.focusComposer() }
            auto.postKey(code, flags: flags)
            shortcutOn.toggle(); startedThisPress = shortcutOn
            note(shortcutOn ? L("voice on (%@)", keys) : L("voice off (%@)", keys))
            if shortcutOn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    guard let self, self.shortcutOn, !self.auto.isRecording() else { return }
                    log("\(keys) didn't start voice, pressing the button")   // the shortcut didn't start it: press the mic button
                    self.shortcutOn = self.auto.pressVoice(ifShowing: voiceStartLabels(), what: "Voice on (fallback)")
                }
            }
        } else {
            if startedThisPress && heldLongEnough && shortcutOn {
                auto.postKey(code, flags: flags); shortcutOn = false; note(L("released → voice off (%@)", keys))
            }
            startedThisPress = false
        }
    }

    private func button(_ down: Bool) {
        if down {
            if auto.isRecording() {
                startedThisPress = false
                note(auto.pressVoice(ifShowing: voiceStopLabels(), what: "Voice off") ? L("voice off") : L("couldn't stop voice"))
            } else {
                startedThisPress = auto.pressVoice(ifShowing: voiceStartLabels(), what: "Voice on")
                note(startedThisPress ? L("voice on") : L("couldn't start voice"))
            }
        } else {
            if startedThisPress && heldLongEnough {
                note(auto.pressVoice(ifShowing: voiceStopLabels(), what: "Voice off on release") ? L("released → voice off") : L("not recording"))
            }
            startedThisPress = false
        }
    }

    private func toggleButton(_ down: Bool, prefix: String) {
        if down {
            if auto.pressFrontButton(prefix: prefix) {
                toggleOn.toggle(); startedThisPress = toggleOn; usingFallback = false
                note(toggleOn ? L("voice input on") : L("voice input off"))
                return
            }
            log("No “\(prefix)” button, using macOS dictation")
            usingFallback = true; system(true)
        } else {
            if usingFallback { usingFallback = false; system(false); return }
            if startedThisPress && heldLongEnough && toggleOn {
                if auto.pressFrontButton(prefix: prefix) { toggleOn = false }
                note(L("released → voice input off"))
            }
            startedThisPress = false
        }
    }

    // MARK: App's own voice input or macOS dictation, per app (config "dictationEngine")

    private func engine(_ bundleID: String?) -> String {
        guard let id = bundleID else { return "app" }
        return ((readConfig()["dictationEngine"] as? [String: String]) ?? [:])[id] ?? "app"
    }

    /// Switches the front app between its own voice input and macOS dictation. Returns the message to show.
    func toggleEngine() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return "" }
        let now = engine(id) == "app" ? "system" : "app"
        guard Config.update({ cfg in
            var map = (cfg["dictationEngine"] as? [String: String]) ?? [:]
            map[id] = now; cfg["dictationEngine"] = map
        }) else { return L("config.json has an error, so nothing was saved. Fix that file first.") }
        log("Dictation for \(id) → \(now)")
        let name = app.localizedName ?? L("this app")
        return now == "system" ? L("%@: the voice key now uses macOS dictation", name) : L("%@: the voice key now uses %@'s own voice input", name, name)
    }
}

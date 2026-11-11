// Add-ons: optional extras that live outside the core, in personal/<name>/ (or addons/<name>/).
//   <name>/layout.json   merged on top of the default layout (apps, actions, what the map shows)
//   <name>/*.swift       optional code: a `final class …: PadAddon` is found and started by build.sh
// Each add-on can be switched off from the menu bar (Add-ons); config.json "addons": {"<name>": false}.
import AppKit
import SwiftUI

/// What an add-on can use from PromptPad.
protocol AddonHost: AnyObject {
    /// PromptPad is not paused and the key map isn't open: add-ons should only act when this is true.
    var isActive: Bool { get }
    var automation: AppAutomation { get }
    /// Shows what just happened in the menu's "最近" line.
    func note(_ text: String)
    /// Runs a layout action string, e.g. "keys:cmd+z" or "voice".
    @discardableResult func perform(_ action: String) -> Bool
}

protocol PadAddon: AnyObject {
    /// Folder name, e.g. "headset". Also the key in config.json "addons".
    var id: String { get }
    /// Shown in the menu (in English; translations go in the add-on's layout "strings"), e.g. "Headset".
    var title: String { get }
    func start(host: AddonHost)
    func stop()
    /// A status line for the menu, e.g. "耳机：已连接".
    func statusLine() -> String?
    /// An extra page on the key map, next to the layer tabs.
    func mapPage() -> AnyView?
}

extension PadAddon {
    func statusLine() -> String? { nil }
    func mapPage() -> AnyView? { nil }
}

enum Addons {
    /// Add-ons with a layout file bundled in the app (Resources/addons/<name>.json).
    static func overlayNames() -> [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "addons") ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// Every add-on in this build: code add-ons and layout-only ones.
    static func allNames() -> [String] {
        Array(Set(overlayNames() + installedAddons.map(\.id))).sorted()
    }

    static func title(_ name: String) -> String {
        L(installedAddons.first { $0.id == name }?.title ?? overlayTitle(name) ?? name)
    }

    /// "title" field of an add-on's layout file.
    private static func overlayTitle(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "addons"),
              let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] else { return nil }
        return obj["title"] as? String
    }

    /// On unless config.json "addons" says false.
    static func isEnabled(_ name: String) -> Bool {
        ((readConfig()["addons"] as? [String: Bool]) ?? [:])[name] ?? true
    }

    @discardableResult
    static func setEnabled(_ name: String, _ on: Bool) -> Bool {
        Config.update { cfg in
            var map = (cfg["addons"] as? [String: Bool]) ?? [:]
            map[name] = on; cfg["addons"] = map
        }
    }
}
